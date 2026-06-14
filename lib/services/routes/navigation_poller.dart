// Turn-by-turn poller for outdoor navigation. py:1168-1240 navigation_poller.
//
// Every kNavPollIntervalSec it reads the latest GPS fix and:
//   • advances to the next step when within kStepAdvanceMeters of the
//     current step's end (vibrate short → speak the new instruction);
//   • triggers the arrived callback when the last step is consumed;
//   • re-routes if the user is > kRouteDeviationMeters off the current
//     step's start→end segment for kRouteDeviationPolls consecutive polls.
//
// Re-route discipline (the classic state-machine leak): the current Timer is
// cancelled BEFORE the new route is fetched, and a fresh Timer is started
// only after. "Re-routing" preempts any in-flight instruction via the same
// TTS barge-in (stopSpeaking) the obstacle announcer uses.
//
// Note (resolved ambiguity): TtsService runs awaitSpeakCompletion(false) so
// the obstacle announcer stays non-blocking. The poller therefore can't truly
// await utterance completion; instead a _busy reentrancy guard prevents
// overlapping ticks and barge-in handles re-route preemption. Documented per
// the M6 plan.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/constants.dart';
import '../../models/location_fix.dart';
import '../../models/route.dart';
import '../../models/route_step.dart';
import '../../utils/haversine.dart';
import '../audio/tts_service.dart';
import '../feedback/haptics_service.dart';
import 'routes_service.dart';

typedef LocationGetter = LocationFix? Function();

class NavigationPoller {
  Route route;
  int stepIndex;

  final RoutesService routes;
  final TtsService tts;
  final HapticsService haptics;
  final LocationGetter getLocation;
  final void Function() onArrived;
  final void Function(int newStepIndex) onStep;
  final void Function(Route newRoute) onReroute;

  Timer? _timer;
  int _deviationStreak = 0;
  bool _busy = false;
  bool _rerouting = false;
  // After a manual "next" the user typically stands still while listening
  // to the new instruction. Without a grace window the off-route streak
  // accumulates immediately and triggers a re-route that barge-ins on the
  // step-N TTS. While the settle window is live, off-route is ignored
  // AND the streak is reset on every tick.
  DateTime? _settleUntil;

  NavigationPoller({
    required this.route,
    required this.routes,
    required this.tts,
    required this.haptics,
    required this.getLocation,
    required this.onArrived,
    required this.onStep,
    required this.onReroute,
    this.stepIndex = 0,
  });

  RouteStep? get currentStep =>
      stepIndex < route.steps.length ? route.steps[stepIndex] : null;

  int get remainingMeters {
    var m = 0;
    for (var i = stepIndex; i < route.steps.length; i++) {
      m += route.steps[i].distanceMeters;
    }
    return m;
  }

  void start() {
    _timer?.cancel(); // never leak a previous Timer
    _timer = Timer.periodic(
      const Duration(seconds: kNavPollIntervalSec),
      (_) => _safeTick(),
    );
    debugPrint('[POLL] started (every ${kNavPollIntervalSec}s, '
        '${route.steps.length} steps)');
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    debugPrint('[POLL] stopped');
  }

  /// Arm a settle window for [duration] starting now. While active, the
  /// off-route streak is reset on every tick AND the re-route trigger is
  /// suppressed. Called by OutdoorNavNotifier after every manual skipStep().
  void armSettleWindow(Duration duration) {
    _settleUntil = DateTime.now().add(duration);
    _deviationStreak = 0;
    debugPrint('[STEP] settle window armed for ${duration.inSeconds}s');
  }

  bool get _inSettleWindow {
    final until = _settleUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  Future<void> _safeTick() async {
    if (_busy) return;
    _busy = true;
    try {
      await tick();
    } catch (e, st) {
      debugPrint('[POLL] tick error: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  @visibleForTesting
  Future<void> tick() async {
    final loc = getLocation();
    if (loc == null) return;
    final step = currentStep;
    if (step == null) return;

    final dToEnd =
        haversineMeters(loc.lat, loc.lng, step.endLat, step.endLng);

    if (dToEnd <= kStepAdvanceMeters) {
      _deviationStreak = 0;
      stepIndex++;
      if (stepIndex >= route.steps.length) {
        stop();
        onArrived();
        return;
      }
      await haptics.short();
      // ignore: discarded_futures — non-blocking by design (see header note)
      tts.speak(route.steps[stepIndex].instruction);
      onStep(stepIndex);
      return;
    }

    // Off-route check vs the current step's start→end segment.
    final dev = pointToSegmentMeters(
      loc.lat,
      loc.lng,
      step.startLat,
      step.startLng,
      step.endLat,
      step.endLng,
    );
    if (dev > kRouteDeviationMeters) {
      if (_inSettleWindow) {
        // User just got a manual "next" — they're standing still listening
        // to the new step. Suppress the streak so a re-route can't fire
        // during this grace period.
        debugPrint('[POLL] off-route ignored — within manual-advance '
            'settle window');
        _deviationStreak = 0;
        return;
      }
      _deviationStreak++;
      debugPrint('[POLL] off-route ${dev.toStringAsFixed(0)}m '
          '(streak $_deviationStreak/$kRouteDeviationPolls)');
      if (_deviationStreak >= kRouteDeviationPolls && !_rerouting) {
        await _reroute(loc);
      }
    } else {
      _deviationStreak = 0;
    }
  }

  Future<void> _reroute(LocationFix loc) async {
    _rerouting = true;
    stop(); // cancel current Timer FIRST — no leak
    await tts.stopSpeaking(); // barge-in: drop any in-flight instruction
    // ignore: discarded_futures
    tts.speak(kPromptRerouting);
    try {
      final dest = route.steps.last;
      final fresh = await routes.computeWalkingRoute(
        originLat: loc.lat,
        originLng: loc.lng,
        destLat: dest.endLat,
        destLng: dest.endLng,
      );
      route = fresh;
      stepIndex = 0;
      _deviationStreak = 0;
      onReroute(fresh);
      start(); // fresh Timer only after the new route is in place
    } catch (e) {
      debugPrint('[POLL] reroute failed: $e — continuing on old route');
      _deviationStreak = 0;
      start();
    } finally {
      _rerouting = false;
    }
  }
}
