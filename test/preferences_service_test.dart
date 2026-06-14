// Unit tests for PreferencesService (Step F-1).
//
// SharedPreferences.setMockInitialValues gives us a clean in-memory store
// per test — no real disk I/O needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smart_nav/services/preferences_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('1. hasSeenOnboarding returns false on fresh install', () async {
    final prefs = PreferencesService();
    expect(await prefs.hasSeenOnboarding(), isFalse);
  });

  test('2. setOnboardingSeen persists the flag', () async {
    final prefs = PreferencesService();
    await prefs.setOnboardingSeen();
    expect(await prefs.hasSeenOnboarding(), isTrue);
  });

  test('3. hasSeenOnboarding returns true after setOnboardingSeen, '
      'and survives a new PreferencesService instance', () async {
    final p1 = PreferencesService();
    await p1.setOnboardingSeen();

    final p2 = PreferencesService();
    expect(await p2.hasSeenOnboarding(), isTrue);
  });

  test('4. clearOnboardingSeen resets the flag', () async {
    final prefs = PreferencesService();
    await prefs.setOnboardingSeen();
    expect(await prefs.hasSeenOnboarding(), isTrue);
    await prefs.clearOnboardingSeen();
    expect(await prefs.hasSeenOnboarding(), isFalse);
  });

  // ── Emergency contacts (Step F-2) ───────────────────────────────────────
  test('5. emergency contacts default to empty list', () async {
    final prefs = PreferencesService();
    expect(await prefs.getEmergencyContacts(), isEmpty);
  });

  test('6. setEmergencyContacts persists and trims blanks', () async {
    final prefs = PreferencesService();
    await prefs.setEmergencyContacts([
      ' +20 100 000 0000 ',
      '',
      '+1 555 0123',
      '   ',
    ]);
    final stored = await prefs.getEmergencyContacts();
    expect(stored, ['+20 100 000 0000', '+1 555 0123']);
  });

  test('7. emergency phone get/set/clear round-trip', () async {
    final prefs = PreferencesService();
    expect(await prefs.getEmergencyPhone(), isNull);
    await prefs.setEmergencyPhone('+20 100 000 0000');
    expect(await prefs.getEmergencyPhone(), '+20 100 000 0000');
    await prefs.setEmergencyPhone('');
    expect(await prefs.getEmergencyPhone(), isNull);
  });

  test('8. precise location defaults to true and persists', () async {
    final prefs = PreferencesService();
    expect(await prefs.getPreciseLocation(), isTrue);
    await prefs.setPreciseLocation(false);
    expect(await prefs.getPreciseLocation(), isFalse);
  });

  test('9. app language defaults to kDefaultAppLanguage', () async {
    final prefs = PreferencesService();
    expect(await prefs.getAppLanguage(), isNotEmpty);
    await prefs.setAppLanguage('ar-EG');
    expect(await prefs.getAppLanguage(), 'ar-EG');
  });
}
