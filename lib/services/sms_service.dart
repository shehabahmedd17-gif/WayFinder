// SMS dispatch for SOS alerts. Hybrid strategy (F-3 follow-up):
//
//   1. Direct silent send via `another_telephony` — preferred. A blind
//      user can't tap "Send" in an external SMS app, so we send straight
//      from the background once the SOS countdown reaches 0.
//
//   2. Fallback to launching the user's SMS composer via `url_launcher`
//      with an `smsto:` URI (not `sms:`, which some Android messenger
//      apps register as a handler for — observed WhatsApp picking it up
//      and offering "Invite contact"). `smsto:` is the standard Android
//      "compose an SMS to this recipient" scheme and is rarely hijacked.
//
// `buildSmsUri` is a pure function so the URI logic is unit-testable
// without mocking either the launcher or the telephony platform channel.
//
// All telephony calls are wrapped in try/catch so a missing SEND_SMS
// permission, a missing SIM, or any platform-level failure degrades to
// the launcher path without throwing.

import 'package:another_telephony/telephony.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants.dart';
import '../models/location_fix.dart';

/// Status of the SEND_SMS permission. Vendor security layers (MIUI,
/// Samsung Auto Blocker, EMUI Pure Mode, ColorOS) can promote `denied` →
/// `permanentlyDenied` for sideloaded apps even when the user grants the
/// underlying Android permission — handle each case explicitly in the UI.
enum SmsPermissionState {
  granted,
  denied,
  permanentlyDenied,
}

/// Outcome of `sendEmergencySms`. The SOS state machine picks the spoken
/// message based on which case applies.
enum SmsDispatchResult {
  /// Every recipient received the message silently via Telephony.sendSms.
  directSentAll,

  /// At least one direct send succeeded, but at least one also failed.
  directSentPartial,

  /// The fallback `smsto:` URI was launched — user must tap Send in the
  /// SMS app to actually transmit the message.
  appLaunched,

  /// The contacts list was empty after trimming; nothing was attempted.
  noContacts,

  /// Direct send was unavailable AND the URI launcher returned false.
  failed,
}

class SmsService {
  final Telephony _telephony;

  SmsService({Telephony? telephony})
      : _telephony = telephony ?? Telephony.instance;

  /// Pure function — kept for tests and for the fallback launcher path.
  /// Uses `smsto:` (not `sms:`) — see file header.
  static Uri buildSmsUri({
    required List<String> contacts,
    required LocationFix? location,
  }) {
    final cleaned = contacts
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList(growable: false);
    final recipients = cleaned.join(',');
    final body = _buildBody(location);
    return Uri(
      scheme: 'smsto',
      path: recipients,
      queryParameters: {'body': body},
    );
  }

  static String _buildBody(LocationFix? location) {
    if (location != null) {
      final maps =
          'https://maps.google.com/?q=${location.lat},${location.lng}';
      return kSosSmsBodyWithLocation.replaceAll('{maps}', maps);
    }
    return kSosSmsBodyNoLocation;
  }

  /// Hybrid SMS dispatch. Tries direct send first, falls back to opening
  /// the user's SMS app.
  Future<SmsDispatchResult> sendEmergencySms({
    required List<String> contacts,
    required LocationFix? location,
  }) async {
    final cleaned = contacts
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList(growable: false);
    if (cleaned.isEmpty) {
      debugPrint('[SMS] no contacts — refusing dispatch');
      return SmsDispatchResult.noContacts;
    }

    final body = _buildBody(location);

    // ── Attempt 1: direct silent send ────────────────────────────────
    final canDirect = await _canDirectSend();
    if (canDirect) {
      debugPrint(
          '[SMS] attempting direct send to ${cleaned.length} contact(s)');
      var failures = 0;
      for (final number in cleaned) {
        try {
          await _telephony.sendSms(to: number, message: body);
          debugPrint('[SMS] direct sent to $number');
        } catch (e) {
          debugPrint('[SMS] direct send to $number failed: $e');
          failures++;
        }
      }
      if (failures == 0) return SmsDispatchResult.directSentAll;
      if (failures < cleaned.length) {
        return SmsDispatchResult.directSentPartial;
      }
      debugPrint('[SMS] all direct sends failed — falling back to picker');
    } else {
      debugPrint('[SMS] direct send unavailable (permission denied or no SIM)');
    }

    // ── Attempt 2: launch the SMS composer ───────────────────────────
    final uri = buildSmsUri(contacts: cleaned, location: location);
    debugPrint('[SMS] fallback launch uri=$uri');
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalNonBrowserApplication,
      );
      debugPrint('[SMS] fallback launched=$launched');
      return launched
          ? SmsDispatchResult.appLaunched
          : SmsDispatchResult.failed;
    } catch (e) {
      debugPrint('[SMS] fallback launch failed: $e');
      return SmsDispatchResult.failed;
    }
  }

  /// Silent status probe — never prompts. Use this to decide which UI
  /// row to show in Settings without surprising the user with a dialog.
  Future<SmsPermissionState> getSmsPermissionState() async {
    try {
      final status = await Permission.sms.status;
      debugPrint('[SMS] permission status: $status');
      if (status.isGranted) return SmsPermissionState.granted;
      if (status.isPermanentlyDenied) {
        return SmsPermissionState.permanentlyDenied;
      }
      return SmsPermissionState.denied;
    } catch (e) {
      debugPrint('[SMS] status check failed: $e');
      return SmsPermissionState.denied;
    }
  }

  /// Whether direct silent send is currently available. May prompt the
  /// user (one chance) when status is `denied`; returns false immediately
  /// when `permanentlyDenied` (vendor-block path) so SOS doesn't stall.
  Future<bool> _canDirectSend() async {
    final state = await getSmsPermissionState();
    if (state == SmsPermissionState.granted) return true;
    if (state == SmsPermissionState.permanentlyDenied) {
      debugPrint('[SMS] permanently denied (vendor security restriction)');
      return false;
    }
    try {
      final newStatus = await Permission.sms.request();
      debugPrint('[SMS] post-request status: $newStatus');
      return newStatus.isGranted;
    } catch (e) {
      debugPrint('[SMS] request failed: $e');
      return false;
    }
  }

  /// Used by the onboarding "Help is one press away" page to ask for the
  /// permission up-front. Safe to call repeatedly. Returns true if granted.
  Future<bool> requestSendSmsPermission() => _canDirectSend();

  /// Open the system "App info" page so the user can manually grant SMS
  /// permission when a vendor security layer has permanently denied it.
  Future<bool> openAppSettingsPage() async {
    try {
      final ok = await openAppSettings();
      debugPrint('[SMS] openAppSettings → $ok');
      return ok;
    } catch (e) {
      debugPrint('[SMS] openAppSettings failed: $e');
      return false;
    }
  }
}

final smsServiceProvider = Provider<SmsService>((_) => SmsService());
