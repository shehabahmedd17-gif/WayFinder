// Gates per-frame DetectionState updates into spoken announcements.
//
// SINGLE SOURCE OF TRUTH: each frame produces exactly ONE category —
// `obstacle` or `clear` — never both. This kills the old bug where an
// obstacle phrase and a contradictory navigation decision were concatenated
// into the same utterance ("person close ahead. path clear").
//
// Port lineage: py:1923-1943 (throttle/dedup), but the mutually-exclusive
// category model + per-category cooldowns + obstacle-preempts-clear are new,
// driven by the 2026-05-18 audio-conflict report.

import 'package:flutter/foundation.dart' show debugPrint;

import '../../core/constants.dart';
import '../../models/obstacle.dart';
import '../../models/detection.dart';
import '../../state/detection_notifier.dart';
import 'tts_service.dart';

enum SpokenCategory { none, clear, obstacle }

const String _kClearMessage = 'path clear';

class ObstacleAnnouncer {
  final SpeechSink tts;

  // Injectable clock so cooldown logic is unit-testable without real time.
  final DateTime Function() _clock;

  // Per-category last-spoken timestamps + the last category/text actually
  // emitted. py:121-125 globals, split per category.
  DateTime _lastObstacleTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastClearTime = DateTime.fromMillisecondsSinceEpoch(0);
  SpokenCategory _lastSpokenCategory = SpokenCategory.none;
  String _lastMessage = '';

  int _frameCounter = 0;
  DateTime _lastDecisionLog = DateTime.fromMillisecondsSinceEpoch(0);

  // Obstacle cooldown is tunable at runtime ("faster"/"slower" voice cmds —
  // py:1462-1468); seeded from kObstacleCooldown. Clear cooldown is fixed.
  double cooldownSec = kObstacleCooldown;
  bool verbose = false;
  bool paused = false;
  bool sttActive = false;

  ObstacleAnnouncer(this.tts, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// Reset all gate state. Call on app-state transitions so the first
  /// detection after (re)entering indoor/navigating is always spoken.
  void reset() {
    _lastObstacleTime = DateTime.fromMillisecondsSinceEpoch(0);
    _lastClearTime = DateTime.fromMillisecondsSinceEpoch(0);
    _lastSpokenCategory = SpokenCategory.none;
    _lastMessage = '';
  }

  /// Evaluate one detection frame. Returns the spoken message, or null if
  /// nothing was spoken (paused, cooldown, dedup, …). Always emits exactly
  /// one [DECISION] log decision (rate-limited).
  String? onDetection(DetectionState state) {
    _frameCounter++;

    // ── 1. Filter to risk-weighted detections ────────────────────────────
    final risks = <Detection>[];
    final dropped = <String>{};
    for (final d in state.detections) {
      if (kRiskWeights.containsKey(d.label)) {
        risks.add(d);
      } else {
        dropped.add(d.label);
      }
    }
    if (dropped.isNotEmpty) {
      debugPrint('[ANNOUNCER] filtered: $dropped');
    }

    // ── 2. EXACTLY ONE category + message for this frame ─────────────────
    // Mutually exclusive by construction — there is no code path that can
    // produce an obstacle phrase AND a "path clear" phrase for one frame.
    final SpokenCategory category =
        risks.isNotEmpty ? SpokenCategory.obstacle : SpokenCategory.clear;
    final String message = category == SpokenCategory.obstacle
        ? _buildObstacleMessage(state, risks)
        : _kClearMessage;

    // ── 3. Decide whether to actually speak ──────────────────────────────
    final now = _clock();
    bool willSpeak;
    String reason;
    bool preempt = false;

    if (paused) {
      willSpeak = false;
      reason = 'paused';
    } else if (sttActive) {
      willSpeak = false;
      reason = 'stt-active';
    } else {
      final cooldownMs = category == SpokenCategory.obstacle
          ? (cooldownSec * 1000).round()
          : kClearCooldownMs;
      final lastTime = category == SpokenCategory.obstacle
          ? _lastObstacleTime
          : _lastClearTime;
      final sinceMs = now.difference(lastTime).inMilliseconds;
      final categoryChanged = category != _lastSpokenCategory;

      if (categoryChanged) {
        willSpeak = true;
        reason = 'new-category';
      } else if (category == SpokenCategory.obstacle &&
          message != _lastMessage) {
        willSpeak = true;
        reason = 'obstacle-text-changed';
      } else if (sinceMs >= cooldownMs) {
        willSpeak = true;
        reason = 'cooldown-elapsed';
      } else {
        willSpeak = false;
        if (category == SpokenCategory.obstacle && message == _lastMessage) {
          reason = 'same-as-last';
        } else {
          final remain = ((cooldownMs - sinceMs) / 1000).toStringAsFixed(1);
          reason = 'cooldown(${remain}s remaining)';
        }
      }

      // Obstacle preempts an in-flight "path clear": the blind user needs
      // the warning NOW, not after the clear finishes playing.
      if (willSpeak &&
          category == SpokenCategory.obstacle &&
          _lastSpokenCategory == SpokenCategory.clear &&
          tts.isSpeaking) {
        preempt = true;
      }

      // "clear" is the lowest priority — never queue it behind something
      // already playing; just skip and re-evaluate next frame.
      if (willSpeak &&
          category == SpokenCategory.clear &&
          tts.isSpeaking) {
        willSpeak = false;
        reason = 'tts-busy-skip-clear';
      }
    }

    _logDecision(
      category,
      message,
      willSpeak,
      preempt ? '$reason+preempt' : reason,
    );

    if (!willSpeak) return null;

    if (preempt) {
      // ignore: discarded_futures
      tts.stopSpeaking();
    }
    tts.speakBackground(message);
    if (category == SpokenCategory.obstacle) {
      _lastObstacleTime = now;
    } else {
      _lastClearTime = now;
    }
    _lastSpokenCategory = category;
    _lastMessage = message;
    return message;
  }

  // ── Obstacle message construction ──────────────────────────────────────
  // py:1925-1939, but the navigation decision is ONLY appended when it is an
  // actionable evasion (move left / move right / stop). "path clear" is
  // NEVER appended — that was the contradictory-concatenation bug.
  String _buildObstacleMessage(DetectionState state, List<Detection> risks) {
    final String core;
    if (verbose) {
      final sorted = [...risks]
        ..sort((a, b) => b.priority.compareTo(a.priority));
      core = sorted
          .take(3)
          .map((d) => '${d.label} ${d.distLabel} ${d.position}')
          .join('. ');
    } else {
      final main = risks.reduce((a, b) => b.priority > a.priority ? b : a);
      core = '${main.label} ${main.distLabel} ${main.position}';
    }

    final buf = StringBuffer(core);
    final dec = state.decision;
    if (dec == 'move left' || dec == 'move right' || dec == 'stop') {
      buf.write('. ');
      buf.write(dec);
    }
    if (state.approachWarning != null) {
      buf.write('. ');
      buf.write(state.approachWarning);
    }
    return buf.toString();
  }

  // One decision per frame. Always log an actual utterance (rare — gated by
  // cooldown); rate-limit the suppressed lines so logcat stays readable.
  void _logDecision(
    SpokenCategory cat,
    String text,
    bool spoke,
    String reason,
  ) {
    final now = _clock();
    if (!spoke &&
        now.difference(_lastDecisionLog).inMilliseconds < kDiagLogIntervalMs) {
      return;
    }
    _lastDecisionLog = now;
    debugPrint('[DECISION] frame=$_frameCounter intended=${cat.name} '
        'text="$text" spoke=$spoke reason=$reason');
  }
}

// ── Test-only helper ────────────────────────────────────────────────────────
// Build a DetectionState fixture without spinning up the full pipeline.
DetectionState mockDetectionState({
  List<Detection> detections = const [],
  Obstacle? mainObstacle,
  String decision = 'path clear',
  String? approachWarning,
}) =>
    DetectionState(
      detections: detections,
      mainObstacle: mainObstacle,
      decision: decision,
      approachWarning: approachWarning,
    );
