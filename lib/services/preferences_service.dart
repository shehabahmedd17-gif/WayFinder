// Thin wrapper around SharedPreferences. Currently tracks only the
// onboarding flag; Step F-2 will extend it with the emergency-contact
// preferences. The class is intentionally tiny and easy to mock from
// tests via SharedPreferences.setMockInitialValues.
//
// Caller pattern:
//   final prefs = ref.read(preferencesServiceProvider);
//   final firstLaunch = !await prefs.hasSeenOnboarding();
//   ...
//   await prefs.setOnboardingSeen();

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';

class PreferencesService {
  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<bool> hasSeenOnboarding() async {
    final p = await _prefs;
    return p.getBool(kPrefHasSeenOnboarding) ?? false;
  }

  Future<void> setOnboardingSeen() async {
    final p = await _prefs;
    await p.setBool(kPrefHasSeenOnboarding, true);
  }

  /// Test/debug helper — used by the dev "reset onboarding" path if/when we
  /// add one. Never called from production code paths.
  Future<void> clearOnboardingSeen() async {
    final p = await _prefs;
    await p.remove(kPrefHasSeenOnboarding);
  }

  // ── Emergency contacts (Step F-2) ────────────────────────────────────────
  /// Ordered list — index 0 is the primary contact, 1 is secondary, plus any
  /// additional numbers the user has added. Empty when not yet configured.
  Future<List<String>> getEmergencyContacts() async {
    final p = await _prefs;
    return p.getStringList(kPrefEmergencyContacts) ?? const [];
  }

  Future<void> setEmergencyContacts(List<String> contacts) async {
    final p = await _prefs;
    // Drop blanks + trim whitespace before persisting.
    final cleaned = contacts
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    await p.setStringList(kPrefEmergencyContacts, cleaned);
  }

  Future<String?> getEmergencyPhone() async {
    final p = await _prefs;
    return p.getString(kPrefEmergencyPhone);
  }

  Future<void> setEmergencyPhone(String value) async {
    final p = await _prefs;
    final v = value.trim();
    if (v.isEmpty) {
      await p.remove(kPrefEmergencyPhone);
    } else {
      await p.setString(kPrefEmergencyPhone, v);
    }
  }

  // ── Global ─────────────────────────────────────────────────────────────
  Future<String> getAppLanguage() async {
    final p = await _prefs;
    return p.getString(kPrefAppLanguage) ?? kDefaultAppLanguage;
  }

  Future<void> setAppLanguage(String tag) async {
    final p = await _prefs;
    await p.setString(kPrefAppLanguage, tag);
  }

  // ── Navigation ─────────────────────────────────────────────────────────
  Future<bool> getPreciseLocation() async {
    final p = await _prefs;
    return p.getBool(kPrefPreciseLocation) ?? true; // default: ON
  }

  Future<void> setPreciseLocation(bool value) async {
    final p = await _prefs;
    await p.setBool(kPrefPreciseLocation, value);
  }
}

final preferencesServiceProvider =
    Provider<PreferencesService>((_) => PreferencesService());
