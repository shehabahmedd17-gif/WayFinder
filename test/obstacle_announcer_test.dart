// Unit tests for lib/services/audio/obstacle_announcer.dart
//
// The announcer is behind the SpeechSink interface, so we feed it a fake
// (no flutter_tts / platform channels) and an injected clock so cooldown
// timing is deterministic.

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_nav/core/constants.dart';
import 'package:smart_nav/models/detection.dart';
import 'package:smart_nav/services/audio/obstacle_announcer.dart';
import 'package:smart_nav/services/audio/tts_service.dart';
import 'package:smart_nav/state/detection_notifier.dart';

// ── Fakes ──────────────────────────────────────────────────────────────────

class FakeSpeechSink implements SpeechSink {
  bool speaking = false;
  int stopCalls = 0;
  final List<String> spoken = [];

  @override
  bool get isSpeaking => speaking;

  @override
  void speakBackground(String text) => spoken.add(text);

  @override
  Future<void> stopSpeaking() async {
    stopCalls++;
    speaking = false;
  }
}

// Mutable clock the tests advance by hand.
class FakeClock {
  DateTime t = DateTime(2026, 1, 1, 12, 0, 0);
  DateTime call() => t;
  void advanceMs(int ms) => t = t.add(Duration(milliseconds: ms));
}

Detection _risk(
  String label, {
  String dist = 'close',
  String pos = 'ahead',
  double priority = 10,
}) =>
    Detection(
      label: label, // 'person' / 'car' are in kRiskWeights
      x1: 0.2, y1: 0.2, x2: 0.6, y2: 0.8,
      confidence: 0.9,
      distLabel: dist,
      position: pos,
      priority: priority,
    );

DetectionState _obstacleFrame({
  String label = 'person',
  String decision = 'path clear',
  String? approach,
}) =>
    mockDetectionState(
      detections: [_risk(label)],
      decision: decision,
      approachWarning: approach,
    );

DetectionState _clearFrame() =>
    mockDetectionState(detections: const [], decision: 'path clear');

void main() {
  test('0. cooldown constants are as specified', () {
    expect(kObstacleCooldownMs, 2500);
    expect(kClearCooldownMs, 10000);
  });

  test('1. obstacle frame never produces a "path clear" utterance', () {
    final tts = FakeSpeechSink();
    final clock = FakeClock();
    final a = ObstacleAnnouncer(tts, clock: clock.call);

    final msg = a.onDetection(_obstacleFrame(decision: 'path clear'));
    expect(msg, isNotNull);
    // The contradictory concatenation bug: obstacle phrase must NOT contain
    // "path clear" even when state.decision == 'path clear'.
    expect(msg, contains('person'));
    expect(msg!.toLowerCase(), isNot(contains('path clear')));
    expect(tts.spoken.single, msg);
  });

  test('2. clear frame says exactly "path clear", nothing appended', () {
    final tts = FakeSpeechSink();
    final a = ObstacleAnnouncer(tts, clock: FakeClock().call);
    final msg = a.onDetection(_clearFrame());
    expect(msg, 'path clear');
  });

  test('3. identical obstacle within 2.5 s is suppressed; spoken after', () {
    final tts = FakeSpeechSink();
    final clock = FakeClock();
    final a = ObstacleAnnouncer(tts, clock: clock.call);

    expect(a.onDetection(_obstacleFrame()), isNotNull); // 1st: new-category
    clock.advanceMs(1000);
    expect(a.onDetection(_obstacleFrame()), isNull); // same-as-last
    clock.advanceMs(1000);
    expect(a.onDetection(_obstacleFrame()), isNull); // still < 2500 ms
    clock.advanceMs(600); // total 2600 ms ≥ 2500
    expect(a.onDetection(_obstacleFrame()), isNotNull); // cooldown-elapsed
    expect(tts.spoken.length, 2);
  });

  test('4. "path clear" respects the 10 s cooldown', () {
    final tts = FakeSpeechSink();
    final clock = FakeClock();
    final a = ObstacleAnnouncer(tts, clock: clock.call);

    expect(a.onDetection(_clearFrame()), 'path clear'); // new-category
    clock.advanceMs(5000);
    expect(a.onDetection(_clearFrame()), isNull); // 5 s < 10 s
    clock.advanceMs(4000);
    expect(a.onDetection(_clearFrame()), isNull); // 9 s < 10 s
    clock.advanceMs(1500); // total 10.5 s
    expect(a.onDetection(_clearFrame()), 'path clear'); // cooldown-elapsed
    expect(tts.spoken.length, 2);
  });

  test('5. category change always speaks immediately (ignores cooldown)', () {
    final tts = FakeSpeechSink();
    final clock = FakeClock();
    final a = ObstacleAnnouncer(tts, clock: clock.call);

    expect(a.onDetection(_obstacleFrame()), isNotNull); // obstacle
    clock.advanceMs(200); // well within both cooldowns
    // Switching to clear is a new category → speaks despite 10 s clear CD
    expect(a.onDetection(_clearFrame()), 'path clear');
    clock.advanceMs(200);
    // Back to obstacle → new category again → speaks despite 2.5 s CD
    expect(a.onDetection(_obstacleFrame()), isNotNull);
    expect(tts.spoken.length, 3);
  });

  test('6. obstacle preempts an in-flight "path clear" (tts.stop called)', () {
    final tts = FakeSpeechSink();
    final clock = FakeClock();
    final a = ObstacleAnnouncer(tts, clock: clock.call);

    expect(a.onDetection(_clearFrame()), 'path clear');
    tts.speaking = true; // simulate the clear utterance still playing
    clock.advanceMs(300);

    final msg = a.onDetection(_obstacleFrame(decision: 'move left'));
    expect(msg, isNotNull);
    expect(tts.stopCalls, 1); // clear was preempted
    expect(msg, contains('move left'));
    expect(tts.spoken.last, msg);
  });

  test('7. "path clear" is skipped (not queued) while TTS is busy', () {
    final tts = FakeSpeechSink();
    final clock = FakeClock();
    final a = ObstacleAnnouncer(tts, clock: clock.call);

    expect(a.onDetection(_obstacleFrame()), isNotNull); // obstacle spoken
    tts.speaking = true; // obstacle utterance still playing
    clock.advanceMs(300);

    // Clear wants to fire (category change) but TTS is busy → skip, and
    // crucially do NOT call stop() (clear must never interrupt an obstacle).
    final msg = a.onDetection(_clearFrame());
    expect(msg, isNull);
    expect(tts.stopCalls, 0);
    expect(tts.spoken.length, 1);
  });

  test('8. changed obstacle text speaks within cooldown; paused suppresses',
      () {
    final tts = FakeSpeechSink();
    final clock = FakeClock();
    final a = ObstacleAnnouncer(tts, clock: clock.call);

    expect(a.onDetection(_obstacleFrame(label: 'person')), isNotNull);
    clock.advanceMs(500); // < 2.5 s
    // Different obstacle text (person → car) → obstacle-text-changed
    expect(a.onDetection(_obstacleFrame(label: 'car')), isNotNull);
    expect(tts.spoken.length, 2);

    // Paused: nothing is spoken regardless of category/cooldown.
    a.paused = true;
    clock.advanceMs(5000);
    expect(a.onDetection(_obstacleFrame(label: 'person')), isNull);
    expect(a.onDetection(_clearFrame()), isNull);
    expect(tts.spoken.length, 2);
  });
}
