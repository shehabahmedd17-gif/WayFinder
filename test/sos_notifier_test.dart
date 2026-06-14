// Unit tests for SosNotifier (Step D — two-finger tap SOS).
//
// autoSpeak=false avoids real platform calls (HapticFeedback, TTS).
// Tests use real timers; the slowest case (countdown → sent) takes ~3 s.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smart_nav/core/constants.dart';
import 'package:smart_nav/models/location_fix.dart';
import 'package:smart_nav/services/audio/tts_service.dart';
import 'package:smart_nav/services/location/gps_service.dart';
import 'package:smart_nav/services/sms_service.dart';
import 'package:smart_nav/state/sos_notifier.dart';

/// SmsService stand-in that returns a configured result without touching
/// any platform channel. Used by test 8 to verify the spoken phrase for
/// each SmsDispatchResult.
class FakeSmsService extends SmsService {
  SmsDispatchResult result;
  int calls = 0;
  FakeSmsService(this.result);
  @override
  Future<SmsDispatchResult> sendEmergencySms({
    required List<String> contacts,
    required LocationFix? location,
  }) async {
    calls++;
    return result;
  }
}

class FakeTts extends TtsService {
  final List<String> spoken = [];
  @override
  Future<void> speak(String text) async => spoken.add(text);
  @override
  void speakBackground(String text) => spoken.add(text);
  @override
  Future<void> stopSpeaking() async {}
  @override
  bool get isSpeaking => false;
}

ProviderContainer _container(FakeTts tts,
    {LocationFix? fix, FakeSmsService? sms}) {
  final c = ProviderContainer(overrides: [
    ttsServiceProvider.overrideWithValue(tts),
    if (sms != null) smsServiceProvider.overrideWithValue(sms),
  ]);
  if (fix != null) {
    c.read(currentLocationProvider.notifier).set(fix);
  }
  return c;
}

LocationFix _fix(double lat, double lng) => LocationFix(
      lat: lat,
      lng: lng,
      accuracyMeters: 5,
      timestamp: DateTime.now(),
      isFallback: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  debugPrint = (_, {wrapWidth}) {};

  // Mock SharedPreferences for every test — SosNotifier reads emergency
  // contacts from PreferencesService during _fireAlert, and an unmocked
  // SharedPreferences call throws MissingPluginException in unit tests.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('1. startCountdown moves phase to countdown=3', () async {
    final tts = FakeTts();
    final c = _container(tts);
    addTearDown(c.dispose);
    final sos = c.read(sosProvider.notifier)..autoSpeak = false;

    await sos.startCountdown();
    expect(c.read(sosProvider).phase, SosPhase.countdown);
    expect(c.read(sosProvider).countdownValue, 3);
  });

  test('2. abort during countdown returns to idle, no alert fired', () async {
    final tts = FakeTts();
    final c = _container(tts);
    addTearDown(c.dispose);
    final sos = c.read(sosProvider.notifier)..autoSpeak = false;

    await sos.startCountdown();
    await sos.abort();
    expect(c.read(sosProvider).phase, SosPhase.idle);
    expect(c.read(sosProvider).lastLocation, isNull);
  });

  test('3. countdown reaching 0 fires alert (sent phase, location captured)',
      () async {
    final tts = FakeTts();
    final fix = _fix(30.25101, 31.46389);
    final c = _container(tts, fix: fix);
    addTearDown(c.dispose);
    final sos = c.read(sosProvider.notifier)..autoSpeak = false;

    await sos.startCountdown();
    // Wait just past the 3rd tick — _fireAlert runs synchronously up to its
    // 5 s auto-reset delay, which we don't elapse here.
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    expect(c.read(sosProvider).phase, SosPhase.sent);
    final captured = c.read(sosProvider).lastLocation;
    expect(captured, isNotNull);
    expect(captured!.lat, fix.lat);
    expect(captured.lng, fix.lng);
  });

  test('3b. spoken alert is kPromptSosSent (no coordinates) when contacts present',
      () async {
    // Seed a contact so we take the with-contacts branch.
    SharedPreferences.setMockInitialValues({
      'emergency_contacts': ['+201234567890'],
    });
    final tts = FakeTts();
    final c = _container(tts, fix: _fix(30.0, 31.0));
    addTearDown(c.dispose);
    // autoSendSms=false so we don't try to launch the SMS composer.
    final sos = c.read(sosProvider.notifier)..autoSendSms = false;

    await sos.startCountdown();
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    expect(c.read(sosProvider).phase, SosPhase.sent);
    expect(tts.spoken, contains(kPromptSosSent));
    // No spoken string should contain raw coordinates.
    for (final s in tts.spoken) {
      expect(s, isNot(contains('30.0')));
      expect(s, isNot(contains('31.0')));
    }
  });

  test('3c. no contacts configured → speaks kPromptSosNoContact, '
      'no SMS launched', () async {
    // setUp already set empty initial values.
    final tts = FakeTts();
    final c = _container(tts, fix: _fix(30.0, 31.0));
    addTearDown(c.dispose);
    final sos = c.read(sosProvider.notifier)..autoSendSms = false;

    await sos.startCountdown();
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    expect(c.read(sosProvider).phase, SosPhase.sent);
    expect(tts.spoken, contains(kPromptSosNoContact));
    expect(tts.spoken, isNot(contains(kPromptSosSent)));
  });

  test('4. abort after sent is a no-op (idempotent)', () async {
    final tts = FakeTts();
    final c = _container(tts, fix: _fix(30.0, 31.0));
    addTearDown(c.dispose);
    final sos = c.read(sosProvider.notifier)..autoSpeak = false;

    await sos.startCountdown();
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    expect(c.read(sosProvider).phase, SosPhase.sent);
    await sos.abort();
    expect(c.read(sosProvider).phase, SosPhase.sent);
  });

  test('5. no cached fix + contacts present → lastLocation null, '
      'still spoken kPromptSosSent (location capture is best-effort)',
      () async {
    SharedPreferences.setMockInitialValues({
      'emergency_contacts': ['+201234567890'],
    });
    final tts = FakeTts();
    final c = _container(tts); // no fix; one-shot will fail without GPS perm
    addTearDown(c.dispose);
    final sos = c.read(sosProvider.notifier)..autoSendSms = false;

    await sos.startCountdown();
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    expect(c.read(sosProvider).phase, SosPhase.sent);
    expect(c.read(sosProvider).lastLocation, isNull);
    // Alert still spoken — user shouldn't know location failed.
    expect(tts.spoken, contains(kPromptSosSent));
  });

  test('6. startCountdown is no-op while a countdown is already running',
      () async {
    final tts = FakeTts();
    final c = _container(tts);
    addTearDown(c.dispose);
    final sos = c.read(sosProvider.notifier)..autoSpeak = false;
    await sos.startCountdown();
    final v1 = c.read(sosProvider).countdownValue;
    await sos.startCountdown(); // ignored
    expect(c.read(sosProvider).countdownValue, v1);
  });

  test('7. isCountingDown reflects phase', () async {
    final tts = FakeTts();
    final c = _container(tts);
    addTearDown(c.dispose);
    final sos = c.read(sosProvider.notifier)..autoSpeak = false;
    expect(sos.isCountingDown, isFalse);
    await sos.startCountdown();
    expect(sos.isCountingDown, isTrue);
    await sos.abort();
    expect(sos.isCountingDown, isFalse);
  });

  // ── SmsDispatchResult → spoken phrase mapping (F-3 follow-up) ──────────
  Future<void> runDispatch({
    required SmsDispatchResult result,
    required String expectSpoken,
  }) async {
    SharedPreferences.setMockInitialValues({
      'emergency_contacts': ['+201234567890'],
    });
    final tts = FakeTts();
    final sms = FakeSmsService(result);
    final c = _container(tts, fix: _fix(30.0, 31.0), sms: sms);
    addTearDown(c.dispose);
    final sos = c.read(sosProvider.notifier);

    await sos.startCountdown();
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    expect(c.read(sosProvider).phase, SosPhase.sent);
    expect(sms.calls, 1);
    expect(tts.spoken, contains(expectSpoken));
  }

  test('8a. directSentAll → speaks kPromptSosSent', () =>
      runDispatch(
          result: SmsDispatchResult.directSentAll,
          expectSpoken: kPromptSosSent));

  test('8b. directSentPartial → speaks kPromptSosSentPartial', () =>
      runDispatch(
          result: SmsDispatchResult.directSentPartial,
          expectSpoken: kPromptSosSentPartial));

  test('8c. appLaunched → speaks kPromptSosLaunchedApp', () =>
      runDispatch(
          result: SmsDispatchResult.appLaunched,
          expectSpoken: kPromptSosLaunchedApp));

  test('8d. failed → speaks kPromptSosFailed', () =>
      runDispatch(
          result: SmsDispatchResult.failed,
          expectSpoken: kPromptSosFailed));
}
