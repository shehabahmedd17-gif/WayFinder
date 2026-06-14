// Priority-aware wrapper around TtsService.
//
// During outdoor navigation we have THREE concurrent sources competing
// for the TTS engine:
//   • HIGH   — obstacle warnings (safety-critical, immediate)
//   • MEDIUM — navigation step instructions, route updates
//   • LOW    — status chatter ("GPS restored", info)
//
// Rules:
//   - A higher-priority `speak()` preempts any in-flight lower-priority
//     utterance (calls `tts.stopSpeaking()` before continuing).
//   - A lower-priority `speak()` while a higher-priority utterance is
//     in flight is DROPPED (logged, then discarded). The user doesn't
//     need a queued "GPS restored" stomping all over a "STOP" warning.
//   - Equal-priority `speak()` preempts (latest wins) — matches the
//     underlying Android QUEUE_FLUSH semantics.
//
// The current priority + a Completer<void> per in-flight utterance are
// the entire state machine. Designed to layer ON TOP of TtsService —
// existing direct callers (obstacle announcer fire-and-forget) still
// work unchanged because the coordinator only intercepts calls that
// route through it.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tts_service.dart';

enum TtsPriority { low, medium, high }

class TtsCoordinator {
  final TtsService _tts;
  TtsPriority? _currentPriority;
  Completer<void>? _currentCompleter;

  TtsCoordinator(this._tts);

  TtsPriority? get currentPriority => _currentPriority;

  /// Speak [text] with [priority]. Returns when speech actually finishes
  /// (natural completion or preemption). Drops + returns immediately if
  /// dropped due to a higher-priority utterance in flight.
  Future<void> speak(String text, TtsPriority priority) async {
    if (text.trim().isEmpty) return;

    final current = _currentPriority;
    if (current != null && _rank(current) > _rank(priority)) {
      debugPrint('[TTSC] dropped (priority=$priority, current=$current): '
          '"$text"');
      return;
    }

    // Same or lower priority in flight — preempt it. Capture the
    // completer first because `await stopSpeaking()` lets the previous
    // speak's `finally` block null out `_currentCompleter`.
    final preempting = _currentCompleter;
    if (preempting != null && !preempting.isCompleted) {
      debugPrint(
          '[TTSC] preempting current (was $current) with $priority: "$text"');
      await _tts.stopSpeaking();
      if (!preempting.isCompleted) preempting.complete();
    }

    final completer = Completer<void>();
    _currentPriority = priority;
    _currentCompleter = completer;

    debugPrint('[TTSC] speaking [$priority]: "$text"');
    try {
      await _tts.speak(text);
    } finally {
      // Clear bookkeeping only if no newer call has already taken over.
      if (identical(_currentCompleter, completer)) {
        _currentPriority = null;
        _currentCompleter = null;
      }
      if (!completer.isCompleted) completer.complete();
    }
  }

  /// Hard stop — cancels in-flight TTS and clears the priority slot.
  Future<void> stopAll() async {
    await _tts.stopSpeaking();
    if (_currentCompleter != null && !_currentCompleter!.isCompleted) {
      _currentCompleter!.complete();
    }
    _currentCompleter = null;
    _currentPriority = null;
  }

  // Internal numeric rank (higher wins).
  int _rank(TtsPriority p) => switch (p) {
        TtsPriority.high => 2,
        TtsPriority.medium => 1,
        TtsPriority.low => 0,
      };
}

final ttsCoordinatorProvider = Provider<TtsCoordinator>(
    (ref) => TtsCoordinator(ref.read(ttsServiceProvider)));
