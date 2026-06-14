// SOS state machine — driven by the two-finger tap on every main screen.
//
// Lifecycle:
//   idle      → startCountdown()        → countdown(3)
//   countdown → abort()                 → idle
//   countdown → (timer ticks to 0)      → sending → sent → idle (5 s later)
//
// All TTS phrases announce the current countdown digit so a blind user can
// abort confidently. Location is captured at fire-time from the existing
// `currentLocationProvider` and embedded in the spoken "sent" prompt.
//
// SMS / call dispatch is DEFERRED — the user spec calls this out
// explicitly. For now `_fireAlert` only logs + speaks; a later step will
// add `url_launcher` `sms:` / `tel:` URIs with configurable contacts.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/location_fix.dart';
import '../services/audio/tts_service.dart';
import '../services/location/gps_service.dart';
import '../services/preferences_service.dart';
import '../services/sms_service.dart';

enum SosPhase { idle, countdown, sending, sent }

class SosState {
  final SosPhase phase;
  final int countdownValue; // 3 → 0
  // Captured silently at fire-time. Used later by SMS dispatch; NOT spoken
  // (a blind user gets no value from hearing raw coordinates). Null when
  // no fix was available.
  final LocationFix? lastLocation;

  const SosState({
    this.phase = SosPhase.idle,
    this.countdownValue = 0,
    this.lastLocation,
  });

  SosState copyWith({
    SosPhase? phase,
    int? countdownValue,
    LocationFix? lastLocation,
  }) =>
      SosState(
        phase: phase ?? this.phase,
        countdownValue: countdownValue ?? this.countdownValue,
        lastLocation: lastLocation ?? this.lastLocation,
      );
}

class SosNotifier extends Notifier<SosState> {
  Timer? _timer;
  Timer? _autoResetTimer;
  // Tests set false so no platform haptic / TTS is invoked.
  bool autoSpeak = true;
  // Vendor-block hint is spoken at most ONCE per app launch — every
  // subsequent SOS that falls back to the launcher gets only
  // kPromptSosLaunchedApp so the user isn't lectured every emergency.
  static bool _hasSpokenBlockedSession = false;

  @override
  SosState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _autoResetTimer?.cancel();
    });
    return const SosState();
  }

  TtsService get _tts => ref.read(ttsServiceProvider);
  GpsService get _gps => ref.read(gpsServiceProvider);
  PreferencesService get _prefs => ref.read(preferencesServiceProvider);
  SmsService get _sms => ref.read(smsServiceProvider);

  // Tests set false so no SMS composer is launched.
  bool autoSendSms = true;

  /// Begin the countdown. No-op if a countdown is already in flight or an
  /// alert is already being sent. Pre-warms the GPS via a one-shot fetch so
  /// a fresh fix is more likely to be available by the time the alert fires
  /// 3 seconds later.
  Future<void> startCountdown() async {
    if (state.phase != SosPhase.idle) return;
    debugPrint('[SOS] two-finger detected, countdown started');
    state = const SosState(
      phase: SosPhase.countdown,
      countdownValue: kSosCountdownSeconds,
    );
    if (autoSpeak) {
      // ignore: discarded_futures
      HapticFeedback.heavyImpact();
      // ignore: discarded_futures
      _tts.speak(kPromptSosStart);
      // Pre-warm GPS — fire-and-forget, gets a fix into
      // currentLocationProvider before _fireAlert runs.
      // ignore: discarded_futures
      _prewarmGps();
    }
    _scheduleTick(kSosCountdownSeconds - 1);
  }

  Future<void> _prewarmGps() async {
    final fix = await _gps.getOneShot();
    if (fix != null) {
      ref.read(currentLocationProvider.notifier).set(fix);
      debugPrint('[SOS] pre-warm GPS fix: $fix');
    }
  }

  void _scheduleTick(int next) {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), () async {
      if (state.phase != SosPhase.countdown) return;
      state = state.copyWith(countdownValue: next);
      if (next <= 0) {
        await _fireAlert();
        return;
      }
      if (autoSpeak) {
        // ignore: discarded_futures
        HapticFeedback.heavyImpact();
        // ignore: discarded_futures
        _tts.speak('$next.');
      }
      _scheduleTick(next - 1);
    });
  }

  /// Cancel a countdown in progress. Idempotent — no-op if already idle or
  /// the alert has already been dispatched.
  Future<void> abort() async {
    if (state.phase != SosPhase.countdown) return;
    debugPrint('[SOS] aborted by user');
    _timer?.cancel();
    _timer = null;
    if (autoSpeak) {
      // ignore: discarded_futures
      _tts.speak(kPromptSosCancelled);
    }
    state = const SosState();
  }

  /// Whether a countdown is actively running (precedence check used by
  /// voice command handlers — "cancel" should abort SOS first).
  bool get isCountingDown => state.phase == SosPhase.countdown;

  // Map dispatch outcome → spoken phrase. Kept near _fireAlert so it's
  // easy to keep both in sync.
  String _spokenFor(SmsDispatchResult r) {
    switch (r) {
      case SmsDispatchResult.directSentAll:
        return kPromptSosSent;
      case SmsDispatchResult.directSentPartial:
        return kPromptSosSentPartial;
      case SmsDispatchResult.appLaunched:
        return kPromptSosLaunchedApp;
      case SmsDispatchResult.noContacts:
        return kPromptSosNoContact;
      case SmsDispatchResult.failed:
        return kPromptSosFailed;
    }
  }

  // Cached → fresh fallback. Never throws; null result is acceptable (the
  // alert still goes out, just without coordinates in the eventual SMS).
  Future<LocationFix?> _captureLocation() async {
    final cached = ref.read(currentLocationProvider);
    if (cached != null) {
      debugPrint('[SOS] using cached fix: $cached');
      return cached;
    }
    debugPrint('[SOS] no cached fix — requesting one-shot');
    return _gps.getOneShot();
  }

  Future<void> _fireAlert() async {
    _timer?.cancel();
    _timer = null;
    state = state.copyWith(phase: SosPhase.sending);
    debugPrint('[SOS] firing alert');

    final fix = await _captureLocation();
    if (fix == null) {
      debugPrint('[SOS] WARN: no location captured for alert');
    } else {
      debugPrint('[SOS] location captured: '
          '${fix.lat.toStringAsFixed(5)}, ${fix.lng.toStringAsFixed(5)}');
      // copyWith treats null as "no change"; bypass it to write the fix.
      state = SosState(
        phase: state.phase,
        countdownValue: state.countdownValue,
        lastLocation: fix,
      );
    }

    // SMS dispatch — hybrid send (direct first, SMS composer fallback).
    final contacts = await _prefs.getEmergencyContacts();
    final cleaned =
        contacts.where((c) => c.trim().isNotEmpty).toList(growable: false);

    SmsDispatchResult result;
    if (cleaned.isEmpty) {
      debugPrint('[SOS] no contacts configured — skipping SMS dispatch');
      result = SmsDispatchResult.noContacts;
    } else if (!autoSendSms) {
      // Test-only path: short-circuit so we never touch the platform.
      debugPrint('[SOS] autoSendSms=false — skipping actual dispatch');
      result = SmsDispatchResult.directSentAll;
    } else {
      result = await _sms.sendEmergencySms(
        contacts: cleaned,
        location: fix,
      );
    }
    debugPrint('[SOS] sms result: $result');

    final spoken = _spokenFor(result);
    if (autoSpeak) {
      // ignore: discarded_futures
      HapticFeedback.heavyImpact();
      // If we fell back to the launcher AND we haven't already explained
      // it this session, prepend the vendor-block warning so the user
      // understands why the SMS app opened instead of sending silently.
      if (result == SmsDispatchResult.appLaunched &&
          !_hasSpokenBlockedSession) {
        _hasSpokenBlockedSession = true;
        // ignore: discarded_futures
        _tts.speak(kPromptSmsBlockedSession);
      }
      // ignore: discarded_futures
      _tts.speak(spoken);
    }
    state = state.copyWith(phase: SosPhase.sent);

    // Auto-reset via a cancellable Timer (NOT Future.delayed — the latter
    // can't be cancelled on dispose and would try to set state on a
    // disposed notifier in unit tests).
    _autoResetTimer?.cancel();
    _autoResetTimer = Timer(const Duration(seconds: 5), () {
      if (state.phase == SosPhase.sent) {
        // Preserve lastLocation across the auto-reset (SMS dispatch in a
        // later step may still want to reference it).
        state = SosState(lastLocation: state.lastLocation);
      }
    });
  }
}

final sosProvider =
    NotifierProvider<SosNotifier, SosState>(SosNotifier.new);
