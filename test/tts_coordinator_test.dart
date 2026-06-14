// Unit tests for TtsCoordinator priority semantics.
//
// FakeTts captures every speak() + records stopSpeaking() calls. A
// configurable delay simulates the TTS engine's real elapsed playback
// time so preemption can be observed.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_nav/services/audio/tts_coordinator.dart';
import 'package:smart_nav/services/audio/tts_service.dart';

class FakeTts extends TtsService {
  final List<String> spoken = [];
  int stopCalls = 0;
  Duration speakDelay = const Duration(milliseconds: 50);
  Completer<void>? _current;

  @override
  bool get isSpeaking => _current != null && !_current!.isCompleted;

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    final c = Completer<void>();
    _current = c;
    // Simulate engine playback time. Preemption (stopSpeaking) completes
    // the completer early.
    Future<void>.delayed(speakDelay).then((_) {
      if (!c.isCompleted) c.complete();
    });
    return c.future;
  }

  @override
  Future<void> stopSpeaking() async {
    stopCalls++;
    if (_current != null && !_current!.isCompleted) {
      _current!.complete();
    }
  }

  @override
  void speakBackground(String text) => spoken.add(text);
}

void main() {
  // FakeTts.extends TtsService whose field initializer constructs
  // FlutterTts(), which calls setMethodCallHandler — needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('D1. high priority interrupts medium', () async {
    final tts = FakeTts()..speakDelay = const Duration(milliseconds: 200);
    final c = TtsCoordinator(tts);

    // Fire medium first; do not await — let it start playing.
    // ignore: discarded_futures
    c.speak('step 1', TtsPriority.medium);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // High preempts.
    await c.speak('stop person ahead', TtsPriority.high);

    expect(tts.spoken, ['step 1', 'stop person ahead']);
    expect(tts.stopCalls, greaterThanOrEqualTo(1));
  });

  test('D2. medium does NOT interrupt high (request dropped)', () async {
    final tts = FakeTts()..speakDelay = const Duration(milliseconds: 100);
    final c = TtsCoordinator(tts);

    // ignore: discarded_futures
    c.speak('person ahead', TtsPriority.high);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await c.speak('step 2', TtsPriority.medium);

    // Only the high-priority utterance was spoken.
    expect(tts.spoken, ['person ahead']);
    expect(tts.stopCalls, 0);
  });

  test('D3. same-priority preempts (latest wins)', () async {
    final tts = FakeTts()..speakDelay = const Duration(milliseconds: 200);
    final c = TtsCoordinator(tts);

    // ignore: discarded_futures
    c.speak('step 1', TtsPriority.medium);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await c.speak('step 2', TtsPriority.medium);

    expect(tts.spoken, ['step 1', 'step 2']);
    expect(tts.stopCalls, greaterThanOrEqualTo(1));
  });

  test('D4. stopAll cancels in-flight + clears the priority slot',
      () async {
    final tts = FakeTts()..speakDelay = const Duration(milliseconds: 500);
    final c = TtsCoordinator(tts);

    // ignore: discarded_futures
    c.speak('long sentence', TtsPriority.medium);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.currentPriority, TtsPriority.medium);
    await c.stopAll();
    expect(c.currentPriority, isNull);
    expect(tts.stopCalls, 1);
  });

  test('D5. natural completion clears the priority slot', () async {
    final tts = FakeTts()..speakDelay = const Duration(milliseconds: 50);
    final c = TtsCoordinator(tts);
    await c.speak('hello', TtsPriority.medium);
    // After natural completion, no priority is in flight.
    expect(c.currentPriority, isNull);
  });

  test('D6. low priority dropped by in-flight high priority', () async {
    final tts = FakeTts()..speakDelay = const Duration(milliseconds: 150);
    final c = TtsCoordinator(tts);
    // ignore: discarded_futures
    c.speak('stop', TtsPriority.high);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await c.speak('gps restored', TtsPriority.low);
    expect(tts.spoken, ['stop']);
  });
}
