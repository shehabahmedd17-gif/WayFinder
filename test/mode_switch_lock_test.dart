// Tests for the AppModeNotifier switch lock + queue (pre-submission fix).
//
// We can't drive the real camera / pipeline / GPS platform plugins in a
// unit test, so we exercise the lock via the public switchToWelcome()
// path — which only touches GPS + outdoor notifier (both gracefully
// no-op when their platform calls fail). The interesting behavior — the
// _switching flag, the latest-wins queue, and the recovery path — lives
// in _executeSwitch and is independent of which action body runs.
//
// We instead test the underlying observable behavior:
//   • starting at AppMode.welcome (build()) is correct
//   • multiple rapid switchToWelcome calls don't crash + leave state at
//     welcome
//   • setMode() works as the @visibleForTesting seam
// plus a deterministic test for kRiskWeights coverage.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_nav/core/constants.dart';
import 'package:smart_nav/state/app_state_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  debugPrint = (_, {wrapWidth}) {};

  group('AppModeNotifier — switch lock + queue', () {
    test('F0. boots into welcome', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(appModeProvider), AppMode.welcome);
    });

    test('F1. Rapid double-tap of the same target is collapsed', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(appModeProvider.notifier);
      // Seed a non-welcome state via the test seam so switchToWelcome
      // actually has work to do.
      n.setMode(AppMode.indoor);
      expect(c.read(appModeProvider), AppMode.indoor);

      // Fire two welcome switches back-to-back. The first acquires the
      // lock; the second sees `_switching == true` and is queued. Neither
      // should throw; both should resolve to welcome eventually.
      final a = n.switchToWelcome();
      final b = n.switchToWelcome();
      await Future.wait([a, b]);
      expect(c.read(appModeProvider), AppMode.welcome);
    });

    test('F2. Already-at-target is a no-op (returns immediately)', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(appModeProvider.notifier);
      // Welcome → switchToWelcome should short-circuit without touching
      // any teardown logic.
      expect(c.read(appModeProvider), AppMode.welcome);
      await n.switchToWelcome();
      expect(c.read(appModeProvider), AppMode.welcome);
    });

    test('F3. Switch failure recovers to welcome (no stuck state)',
        () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(appModeProvider.notifier);
      n.setMode(AppMode.indoor);

      // switchToWelcome's internal action calls platform plugins (camera
      // stop, pipeline stop, GPS stop) which throw MissingPluginException
      // in unit tests — the catch-all inside _executeSwitch must swallow
      // those and force-recover to welcome via _forceTeardownToWelcome.
      try {
        await n.switchToWelcome();
      } catch (_) {}
      // Final state MUST be welcome regardless of plugin failures.
      expect(c.read(appModeProvider), AppMode.welcome);
    });
  });

  // ── G1. kRiskWeights coverage (pre-submission expansion) ────────────────
  group('kRiskWeights — pre-submission expansion', () {
    test('G1a. Common indoor classes are all present', () {
      const indoor = [
        'person',
        'chair',
        'couch',
        'bed',
        'tv',
        'laptop',
        'mouse',
        'keyboard',
        'refrigerator',
        'microwave',
        'oven',
        'sink',
        'toilet',
        'cup',
        'bottle',
        'book',
      ];
      for (final label in indoor) {
        expect(kRiskWeights.containsKey(label), isTrue,
            reason: 'expected $label in kRiskWeights');
      }
    });

    test('G1b. Common outdoor classes are all present', () {
      const outdoor = [
        'car',
        'bus',
        'truck',
        'motorcycle',
        'bicycle',
        'dog',
        'cat',
        'bird',
        'horse',
        'cow',
        'sheep',
        'traffic light',
        'stop sign',
        'fire hydrant',
        'parking meter',
        'bench',
        'umbrella',
        'backpack',
        'suitcase',
      ];
      for (final label in outdoor) {
        expect(kRiskWeights.containsKey(label), isTrue,
            reason: 'expected $label in kRiskWeights');
      }
    });

    test('G1c. High-risk band (≥ 2.5) still includes safety-critical',
        () {
      for (final label in ['person', 'car', 'bus', 'truck', 'bear']) {
        expect((kRiskWeights[label] ?? 0) >= 2.5, isTrue);
      }
    });

    test('G1d. Total entry count is substantially larger than before', () {
      // Before: 17 entries. After expansion target ≥ 60.
      expect(kRiskWeights.length, greaterThanOrEqualTo(60));
    });
  });
}
