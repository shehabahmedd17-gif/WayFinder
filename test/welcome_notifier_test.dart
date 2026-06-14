// Unit tests for WelcomeNotifier (Step C — voice-first welcome).
//
// autoListen=false keeps the notifier away from real platform calls
// (HapticFeedback, SystemSound, STT, TTS). Tests drive the notifier via
// the same single seam STT/text input uses: submitTranscript().

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_nav/services/audio/stt_service.dart';
import 'package:smart_nav/services/audio/tts_service.dart';
import 'package:smart_nav/state/welcome_notifier.dart';

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

class FakeStt extends SttService {
  FakeStt(super.tts);
  String nextResult = '';
  @override
  Future<bool> initialize() async => true;
  @override
  Future<String> listenOnce({
    Duration window = const Duration(seconds: 8),
    Duration pauseFor = const Duration(seconds: 3),
  }) async =>
      nextResult;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  debugPrint = (_, {wrapWidth}) {}; // keep test output clean

  late ProviderContainer container;
  late FakeTts tts;
  late FakeStt stt;
  late WelcomeNotifier nav;
  late int outdoorCalls;
  late int indoorCalls;
  late int settingsCalls;

  setUp(() {
    tts = FakeTts();
    stt = FakeStt(tts);
    outdoorCalls = 0;
    indoorCalls = 0;
    settingsCalls = 0;
    container = ProviderContainer(overrides: [
      ttsServiceProvider.overrideWithValue(tts),
      sttServiceProvider.overrideWithValue(stt),
    ]);
    nav = container.read(welcomeProvider.notifier)
      ..autoListen = false
      ..onSwitchOutdoor = () {
        outdoorCalls++;
      }
      ..onSwitchIndoor = () {
        indoorCalls++;
      }
      ..onOpenSettings = () {
        settingsCalls++;
      };
  });

  tearDown(() {
    container.dispose();
  });

  test('1. "outdoor" → onSwitchOutdoor fires', () async {
    await nav.submitTranscript('outdoor');
    expect(outdoorCalls, 1);
    expect(indoorCalls, 0);
    expect(container.read(welcomeProvider).lastHeard, 'outdoor');
  });

  test('1b. variant "navigation" also matches outdoor', () async {
    await nav.submitTranscript('I want navigation please');
    expect(outdoorCalls, 1);
    expect(indoorCalls, 0);
  });

  test('2. "indoor" → onSwitchIndoor fires', () async {
    await nav.submitTranscript('indoor');
    expect(indoorCalls, 1);
    expect(outdoorCalls, 0);
  });

  test('2b. variant "obstacle detection" matches indoor', () async {
    await nav.submitTranscript('start obstacle detection');
    expect(indoorCalls, 1);
    expect(outdoorCalls, 0);
  });

  test('3. unknown command → no switch, stays idle for retry', () async {
    await nav.submitTranscript('the weather is nice today');
    expect(outdoorCalls, 0);
    expect(indoorCalls, 0);
    expect(container.read(welcomeProvider).phase, WelcomePhase.idle);
  });

  test('4. empty transcript → idle, no switch', () async {
    await nav.submitTranscript('   ');
    expect(outdoorCalls, 0);
    expect(indoorCalls, 0);
    expect(container.read(welcomeProvider).phase, WelcomePhase.idle);
  });

  test('5. "help" → onOpenSettings not fired, idle for retry', () async {
    await nav.submitTranscript('help');
    expect(outdoorCalls, 0);
    expect(indoorCalls, 0);
    expect(settingsCalls, 0);
    expect(container.read(welcomeProvider).phase, WelcomePhase.idle);
  });

  test('6. "settings" → onOpenSettings fires', () async {
    await nav.submitTranscript('settings');
    expect(settingsCalls, 1);
    expect(outdoorCalls, 0);
    expect(indoorCalls, 0);
  });

  test('7. cancelListening drops back to idle', () async {
    await nav.cancelListening();
    expect(container.read(welcomeProvider).phase, WelcomePhase.idle);
  });

  test('8. reset() clears stale processing phase and returns to idle',
      () async {
    // Simulate the bug scenario: user matched "outdoor", state moved to
    // processing, mode-flipped away, came back to welcome.
    await nav.submitTranscript('outdoor');
    expect(container.read(welcomeProvider).phase, WelcomePhase.processing);
    // ↑ outdoor branch intentionally leaves phase=processing (the mode
    // flip is supposed to tear down the screen). On return-to-welcome,
    // reset() must clear it.
    await nav.reset();
    expect(container.read(welcomeProvider).phase, WelcomePhase.idle);
    expect(container.read(welcomeProvider).lastHeard, isNull);
  });

  // ── STT mishear variants (Step F-2 follow-up) ─────────────────────────
  test('10a. "sitting" matches settings (common STT mishear)', () async {
    await nav.submitTranscript('sitting');
    expect(settingsCalls, 1);
    expect(outdoorCalls, 0);
    expect(indoorCalls, 0);
  });

  test('10b. "menu" matches settings', () async {
    await nav.submitTranscript('menu please');
    expect(settingsCalls, 1);
  });

  test('11a. "indore" matches indoor (city Indore, same phoneme)', () async {
    await nav.submitTranscript('indore');
    expect(indoorCalls, 1);
    expect(outdoorCalls, 0);
  });

  test('11b. exact "ind" matches indoor', () async {
    await nav.submitTranscript('ind');
    expect(indoorCalls, 1);
  });

  test('11c. "ind" inside a longer word does NOT false-positive indoor',
      () async {
    await nav.submitTranscript('industrial');
    expect(indoorCalls, 0);
    expect(outdoorCalls, 0);
    // Falls through to unknown — still idle.
    expect(container.read(welcomeProvider).phase, WelcomePhase.idle);
  });

  test('11d. "in door" (with space) matches indoor', () async {
    await nav.submitTranscript('in door');
    expect(indoorCalls, 1);
  });

  test('12a. "out door" (with space) matches outdoor', () async {
    await nav.submitTranscript('out door');
    expect(outdoorCalls, 1);
    expect(indoorCalls, 0);
  });

  test('12b. "auto door" matches outdoor', () async {
    await nav.submitTranscript('auto door');
    expect(outdoorCalls, 1);
  });

  test('13. "guide" matches help', () async {
    await nav.submitTranscript('guide');
    // Help doesn't fire any switch / settings callback — phase stays idle.
    expect(outdoorCalls, 0);
    expect(indoorCalls, 0);
    expect(settingsCalls, 0);
    expect(container.read(welcomeProvider).phase, WelcomePhase.idle);
  });

  test('9. initialize() called twice acts as reset on the second call',
      () async {
    // First initialize — moves from greeting → idle.
    await nav.initialize();
    expect(container.read(welcomeProvider).phase, WelcomePhase.idle);

    // Pollute the state to simulate the bug (notifier left in processing
    // after matching a command, then screen re-mounts).
    await nav.submitTranscript('outdoor');
    expect(container.read(welcomeProvider).phase, WelcomePhase.processing);

    // Second initialize — must NOT short-circuit; must reset.
    await nav.initialize();
    expect(container.read(welcomeProvider).phase, WelcomePhase.idle);
  });
}
