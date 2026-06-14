// Riverpod wiring for TTS + obstacle announcer.
//
// Keeps both objects long-lived for the app's lifetime, listens to
// detectionProvider, and routes per-frame DetectionState into the announcer
// ONLY while AppMode == indoor. Outdoor mode uses navigation TTS (not the
// obstacle announcer) and the pipeline is disposed there; welcome/paused are
// silent.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../state/app_state_notifier.dart';
import '../../state/detection_notifier.dart';
import '../../state/navigation_notifier.dart';
import 'obstacle_announcer.dart';
import 'outdoor_obstacle_filter.dart';
import 'tts_coordinator.dart';
import 'tts_service.dart';

// ttsServiceProvider now lives in tts_service.dart (next to its class) so
// state-machine files can depend on it without importing this audio wiring.

// ── Obstacle announcer ─────────────────────────────────────────────────────
//
// Side-effect provider: watching it once (e.g. in NavigationScreen.build)
// activates the announcer for the rest of the app lifetime.

final obstacleAnnouncerProvider = Provider<ObstacleAnnouncer>((ref) {
  final tts = ref.watch(ttsServiceProvider);
  final announcer = ObstacleAnnouncer(tts);

  // Keep flags in sync with global toggles.
  ref.listen<bool>(pausedProvider, (_, next) {
    announcer.paused = next;
    if (next) {
      debugPrint('[ANNOUNCER] paused');
    } else {
      announcer.reset();
      debugPrint('[ANNOUNCER] resumed');
    }
  });
  ref.listen<bool>(verboseModeProvider, (_, next) {
    announcer.verbose = next;
    debugPrint('[ANNOUNCER] verbose=$next');
  });

  // Reset dedup state on mode transitions so the first detection after
  // (re)entering indoor mode is spoken even if it matches the last thing
  // heard before switching away.
  ref.listen<AppMode>(appModeProvider, (prev, next) {
    if (prev != next) announcer.reset();
  });

  // Main wiring — per-frame detection results. Indoor mode only.
  ref.listen<DetectionState>(detectionProvider, (_, state) {
    if (ref.read(appModeProvider) != AppMode.indoor) return;
    announcer.onDetection(state);
  });

  return announcer;
});

// ── Outdoor obstacle dispatcher (Part B) ──────────────────────────────────
//
// Listens to detectionProvider during AppMode.outdoor + OutdoorPhase
// .navigating, filters via outdoor_obstacle_filter (risk + proximity),
// and dispatches qualified messages through TtsCoordinator with HIGH
// priority — preempts step instructions, drops "GPS restored" chatter.
//
// A per-message cooldown matches the indoor announcer's cadence so a
// stationary obstacle doesn't get reannounced every cycle.
final outdoorObstacleDispatcherProvider = Provider<void>((ref) {
  final coordinator = ref.read(ttsCoordinatorProvider);
  String? lastMessage;
  DateTime lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);

  ref.listen<DetectionState>(detectionProvider, (_, state) {
    if (ref.read(appModeProvider) != AppMode.outdoor) return;
    if (ref.read(outdoorNavProvider).phase != OutdoorPhase.navigating) {
      return;
    }
    final decision = filterOutdoorDetections(state);
    if (decision == null) return;
    final now = DateTime.now();
    final cooldownMs = (kObstacleCooldown * 1000).round();
    if (decision.message == lastMessage &&
        now.difference(lastSpoken).inMilliseconds < cooldownMs) {
      return;
    }
    debugPrint(
        '[OBSTACLE] outdoor announcing (risk=${decision.riskWeight}, '
        'prox=${decision.proximity}): ${decision.message}');
    lastMessage = decision.message;
    lastSpoken = now;
    // ignore: discarded_futures
    coordinator.speak(decision.message, TtsPriority.high);
  });

  // Reset cooldown bookkeeping on mode flip so the first detection after
  // (re)entering outdoor navigating is always spoken.
  ref.listen<AppMode>(appModeProvider, (prev, next) {
    if (prev != next) {
      lastMessage = null;
      lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
    }
  });
});
