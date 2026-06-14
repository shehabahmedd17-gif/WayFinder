// Top-level app mode + the exclusive indoor↔outdoor↔welcome switch.
//
// Indoor obstacle detection and outdoor GPS navigation NEVER run together
// (sequential, not parallel — Snapdragon 685 can't afford both). Each
// switch fully tears one side down before starting the other.
//
// Concurrency model — **single in-flight switch + latest-wins queue.**
// Loading YOLO+MiDaS into the isolate takes 7-10 s. If the user taps
// mode buttons rapidly the second tap used to race the first switch's
// camera-disposal path → `CameraException: Disposed CameraController,
// startImageStream() was called on a disposed CameraController`. The
// new `_executeSwitch` wrapper serializes calls:
//
//   - First call acquires the lock, runs to completion (or hits the
//     30 s hard timeout → graceful recovery to welcome).
//   - Subsequent calls during the in-flight switch DON'T return early;
//     they record their target as `_pendingSwitchTarget` (latest wins)
//     and return. When the in-flight switch's `finally` runs, the
//     pending target is applied via the public API.
//
// On any unhandled error inside an action body, the wrapper force-tears
// down both sides and reverts to welcome, so the user never lands on a
// red error screen with a half-disposed camera.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../services/audio/tts_service.dart';
import '../services/camera_service.dart';
import '../services/location/gps_service.dart';
import '../services/ml/pipeline_provider.dart';
import '../state/detection_notifier.dart';
import '../state/navigation_notifier.dart';
import '../state/welcome_notifier.dart';

enum AppMode { welcome, indoor, outdoor, paused }

// Hard cap on a single switch's execution. 10 s was too tight — model
// load alone takes ~7 s on Snapdragon 685; combined with camera open +
// pipeline attach the happy path runs ~12 s. 30 s leaves real headroom
// while still failing loud if something genuinely wedges.
const int _kSwitchTimeoutSec = 30;

class AppModeNotifier extends Notifier<AppMode> {
  bool _switching = false;
  AppMode? _pendingSwitchTarget;
  bool get isSwitching => _switching;

  @override
  // Boot into the welcome menu — nothing auto-starts. The camera + pipeline
  // are spun up explicitly by switchToIndoor() (Option-1 explicit lifecycle),
  // never by a provider watching appModeProvider.
  AppMode build() => AppMode.welcome;

  void _say(String s) {
    // ignore: discarded_futures
    ref.read(ttsServiceProvider).speak(s);
  }

  // ── Public switch API ───────────────────────────────────────────────────
  Future<void> switchToOutdoor() =>
      _executeSwitch(AppMode.outdoor, _doSwitchToOutdoor);

  Future<void> switchToIndoor() =>
      _executeSwitch(AppMode.indoor, _doSwitchToIndoor);

  /// Public exit (long-press cancel from either mode). Idempotent.
  Future<void> switchToWelcome() =>
      _executeSwitch(AppMode.welcome, _doSwitchToWelcome);

  /// Internal cancel-back-to-welcome — used by `_returnToWelcome` (called
  /// from OutdoorNavNotifier.onRequestExit after a navigation cancel /
  /// arrival). Goes through the same lock so it can't race a user-driven
  /// switchToIndoor.
  Future<void> _exitToWelcomeFromOutdoor() =>
      _executeSwitch(AppMode.welcome, _doReturnToWelcomeFromOutdoor);

  Future<void> _executeSwitch(
    AppMode target,
    Future<void> Function() action,
  ) async {
    // No-op if we're already at the target AND nothing is in flight.
    if (!_switching && state == target) return;

    if (_switching) {
      // Latest-wins queue: the user's most recent intent supersedes any
      // earlier queued one. The in-flight switch's `finally` will pick
      // this up.
      debugPrint('[MODE] queueing switch → $target '
          '(in-flight switch still running)');
      _pendingSwitchTarget = target;
      return;
    }

    _switching = true;
    _pendingSwitchTarget = null;
    debugPrint('[MODE] switch to $target — lock acquired');

    try {
      await action().timeout(
        const Duration(seconds: _kSwitchTimeoutSec),
        onTimeout: () {
          debugPrint('[MODE] switch to $target hung after '
              '${_kSwitchTimeoutSec}s — force-cancelling');
          throw TimeoutException('Mode switch timed out');
        },
      );
      debugPrint('[MODE] switch to $target — completed');
    } catch (e, st) {
      debugPrint('[MODE] switch to $target FAILED: $e');
      debugPrint('[MODE] stack: $st');
      await _forceTeardownToWelcome();
    } finally {
      _switching = false;
      // Apply any pending switch (latest user intent). Don't await — let
      // the next switch run on its own future so we release the lock now.
      final pending = _pendingSwitchTarget;
      _pendingSwitchTarget = null;
      if (pending != null && pending != state) {
        debugPrint('[MODE] applying queued switch → $pending');
        switch (pending) {
          case AppMode.indoor:
            // ignore: discarded_futures
            switchToIndoor();
          case AppMode.outdoor:
            // ignore: discarded_futures
            switchToOutdoor();
          case AppMode.welcome:
            // ignore: discarded_futures
            switchToWelcome();
          case AppMode.paused:
            break;
        }
      }
    }
  }

  // Best-effort teardown when an in-flight switch fails / times out. Lands
  // the user safely on welcome with a spoken apology.
  Future<void> _forceTeardownToWelcome() async {
    debugPrint('[MODE] force teardown → welcome');
    try {
      await ref.read(pipelineProvider.notifier).stop();
    } catch (_) {}
    try {
      await ref.read(cameraProvider.notifier).stop();
    } catch (_) {}
    try {
      ref.invalidate(detectionProvider);
    } catch (_) {}
    try {
      ref.read(outdoorNavProvider.notifier).teardown();
    } catch (_) {}
    try {
      await ref.read(gpsServiceProvider).stop();
      ref.read(currentLocationProvider.notifier).clear();
    } catch (_) {}
    state = AppMode.welcome;
    _say('Switch failed, returning to menu.');
    try {
      // ignore: discarded_futures
      ref.read(welcomeProvider.notifier).reset();
    } catch (_) {}
  }

  // ── Internal switch actions ─────────────────────────────────────────────
  // indoor → outdoor (or welcome → outdoor)
  Future<void> _doSwitchToOutdoor() async {
    debugPrint('[MODE] indoor→outdoor start');
    // 1. Explicit teardown of the indoor side. Pipeline first (detach the
    //    stream + kill the isolate), THEN the camera. notifier.stop() is
    //    idempotent + never rethrows.
    await ref.read(pipelineProvider.notifier).stop();
    await ref.read(cameraProvider.notifier).stop();
    debugPrint('[MODE] indoor disposed');

    state = AppMode.outdoor;
    ref.invalidate(detectionProvider);

    final gps = ref.read(gpsServiceProvider);
    await gps.start(
      onFix: (fix) => ref.read(currentLocationProvider.notifier).set(fix),
    );

    final nav = ref.read(outdoorNavProvider.notifier);
    nav.onRequestExit = () {
      // ignore: discarded_futures
      _exitToWelcomeFromOutdoor();
    };
    nav.enterOutdoor();

    debugPrint('[MODE] outdoor ready');
  }

  // outdoor → indoor (or welcome → indoor)
  Future<void> _doSwitchToIndoor() async {
    debugPrint('[MODE] outdoor→indoor start');
    ref.read(outdoorNavProvider.notifier).teardown();
    await ref.read(gpsServiceProvider).stop();
    ref.read(currentLocationProvider.notifier).clear();
    debugPrint('[MODE] outdoor disposed');

    state = AppMode.indoor;
    ref.invalidate(detectionProvider);

    // Camera first so the controller exists before the pipeline tries to
    // attach a stream. Both calls are idempotent. If the camera fails
    // to come up, pipeline.start() will short-circuit on the
    // controller-null guard inside the notifier (no CameraException).
    await ref.read(cameraProvider.notifier).start();
    await ref.read(pipelineProvider.notifier).start();

    debugPrint('[MODE] indoor ready');
  }

  // indoor → welcome (user-driven long-press cancel)
  Future<void> _doSwitchToWelcome() async {
    debugPrint('[MODE] *→welcome start');
    // Stop whichever side is up. notifier.stop() is idempotent.
    await ref.read(pipelineProvider.notifier).stop();
    await ref.read(cameraProvider.notifier).stop();
    ref.read(outdoorNavProvider.notifier).teardown();
    await ref.read(gpsServiceProvider).stop();
    ref.read(currentLocationProvider.notifier).clear();
    ref.invalidate(detectionProvider);
    _say(kPromptIndoorCancelled);
    state = AppMode.welcome;
    // ignore: discarded_futures
    ref.read(welcomeProvider.notifier).reset();
    debugPrint('[MODE] welcome ready');
  }

  // outdoor → welcome (after navigation cancel / arrival). Different from
  // _doSwitchToWelcome because there's no camera/pipeline to stop here
  // and we don't want the "Indoor mode cancelled" spoken cue.
  Future<void> _doReturnToWelcomeFromOutdoor() async {
    debugPrint('[MODE] outdoor→welcome start');
    await ref.read(gpsServiceProvider).stop();
    ref.read(currentLocationProvider.notifier).clear();
    state = AppMode.welcome;
    // ignore: discarded_futures
    ref.read(welcomeProvider.notifier).reset();
    debugPrint('[MODE] welcome ready');
  }

  /// Explicit mode set (e.g. test seam). Avoid in production code — the
  /// public switchTo* methods carry the teardown/setup logic.
  void setMode(AppMode m) => state = m;

  // ── Indoor push-to-talk command handler ────────────────────────────────────
  void handleIndoorCommand(String raw) {
    final lc = raw.trim().toLowerCase();
    if (lc.isEmpty) return;
    debugPrint('[CMD] indoor heard: "$lc"');

    if (kOutdoorVariants.any(lc.contains) || lc.contains('outdoor')) {
      // ignore: discarded_futures
      switchToOutdoor();
      return;
    }
    if (_cmd(lc, ['pause', 'quiet', 'silence', 'stop talking', 'stop'])) {
      ref.read(pausedProvider.notifier).set(true);
      _say('Announcements paused.');
      return;
    }
    if (_cmd(lc, ['resume', 'continue', 'start talking', 'unpause'])) {
      ref.read(pausedProvider.notifier).set(false);
      _say('Announcements resumed.');
      return;
    }
    if (_cmd(lc, [
      'verbose', 'what do you see', 'what is around', "what's around",
      'describe', 'surroundings',
    ])) {
      ref.read(verboseModeProvider.notifier).set(true);
      _say('Verbose mode on.');
      return;
    }
    if (_cmd(lc, ['simple', 'less detail', 'brief'])) {
      ref.read(verboseModeProvider.notifier).set(false);
      _say('Simple mode on.');
      return;
    }
    _say(kPromptDidntCatch);
  }

  bool _cmd(String lc, List<String> phrases) =>
      phrases.any((p) => lc == p || lc.contains(p));
}

final appModeProvider =
    NotifierProvider<AppModeNotifier, AppMode>(AppModeNotifier.new);

// ── Announcer pause — py: paused global ───────────────────────────────────
class PausedNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  // ignore: avoid_positional_boolean_parameters
  void set(bool v) => state = v;
  void toggle() => state = !state;
}

final pausedProvider =
    NotifierProvider<PausedNotifier, bool>(PausedNotifier.new);

// ── Verbose mode — py: verbose_mode global ────────────────────────────────
class VerboseModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  // ignore: avoid_positional_boolean_parameters
  void set(bool v) => state = v;
  void toggle() => state = !state;
}

final verboseModeProvider =
    NotifierProvider<VerboseModeNotifier, bool>(VerboseModeNotifier.new);
