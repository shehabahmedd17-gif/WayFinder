// Unit tests for lib/services/ml/priority_engine.dart
//
// Priority engine is pure Dart (no Flutter, no plugins, no isolates), so these
// tests run on the Dart VM directly — fast and deterministic.
//
// Cross-references py source line numbers in test names so they remain
// auditable against the Python prototype.

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_nav/core/constants.dart';
import 'package:smart_nav/services/ml/priority_engine.dart';

// ── Test helpers ───────────────────────────────────────────────────────────

Map<String, dynamic> _det({
  required String label,
  required String position,
  required String distLabel,
  double conf = 0.9,
  double x1 = 0,
  double y1 = 0,
  double x2 = 0.1,
  double y2 = 0.1,
}) {
  return {
    'label': label,
    'position': position,
    'distLabel': distLabel,
    'conf': conf,
    'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2,
  };
}

void main() {
  // ────────────────────────────────────────────────────────────────────────
  group('distLabel — py:833-837', () {
    test('1. boundary thresholds 0.75 / 0.50 / 0.25', () {
      // py:834-837 hard cut-offs
      expect(distLabel(0.90), 'extremely close');
      expect(distLabel(0.75), 'extremely close'); // == threshold counts as ≥
      expect(distLabel(0.74), 'very close');
      expect(distLabel(0.50), 'very close');
      expect(distLabel(0.49), 'close');
      expect(distLabel(0.25), 'close');
      expect(distLabel(0.24), 'far');
      expect(distLabel(0.0), 'far');
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  group('calcPriority — py:880-884', () {
    test('2. person ahead outranks bottle on right at same depth', () {
      // py:625-630 weights:
      //   person risk=3, bottle risk=1
      //   zone ahead=3, zone on right=1.5
      final personAhead = calcPriority(
          label: 'person', position: 'ahead', distance: 0.5);
      final bottleRight = calcPriority(
          label: 'bottle', position: 'on right', distance: 0.5);
      // person ahead = 3*2 + 3*1.5 + 0.5*3 = 6 + 4.5 + 1.5 = 12.0
      // bottle right = 1*2 + 1.5*1.5 + 0.5*3 = 2 + 2.25 + 1.5 = 5.75
      expect(personAhead, closeTo(12.0, 1e-9));
      expect(bottleRight, closeTo(5.75, 1e-9));
      expect(personAhead, greaterThan(bottleRight));
    });

    test('3. unknown label falls back to risk=1.0', () {
      // py:881 risk_weights.get(label, 1)
      final unknown = calcPriority(
          label: 'flamingo', position: 'ahead', distance: 0.0);
      // unknown ahead = 1*2 + 3*1.5 + 0 = 6.5
      expect(unknown, closeTo(6.5, 1e-9));
    });

    test('4. closer object outranks farther same-class object', () {
      final close = calcPriority(
          label: 'car', position: 'ahead', distance: 0.8);
      final far = calcPriority(
          label: 'car', position: 'ahead', distance: 0.1);
      expect(close, greaterThan(far));
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  group('makeDecision — py:886-899', () {
    test('5. no detections → "path clear"', () {
      expect(makeDecision([]), 'path clear');
    });

    test('6. only "far" / "close" objects ignored → "path clear"', () {
      // py:889 only blocks for extremely close / very close
      expect(
        makeDecision([
          _det(label: 'chair', position: 'ahead', distLabel: 'close'),
          _det(label: 'person', position: 'on left', distLabel: 'far'),
        ]),
        'path clear',
      );
    });

    test('7. ahead+left blocked → "move right"', () {
      // py:893-894 — dc && !dr → move right (away from the left wall)
      final out = makeDecision([
        _det(
            label: 'person',
            position: 'ahead',
            distLabel: 'very close'),
        _det(
            label: 'chair',
            position: 'on left',
            distLabel: 'extremely close'),
      ]);
      expect(out, 'move right');
    });

    test('8. ahead+right blocked → "move left"', () {
      // py:892 — dc && !dl → move left
      final out = makeDecision([
        _det(
            label: 'person',
            position: 'ahead',
            distLabel: 'very close'),
        _det(
            label: 'car',
            position: 'on right',
            distLabel: 'very close'),
      ]);
      expect(out, 'move left');
    });

    test('9. all three blocked → "stop"', () {
      // py:895 — dc && dl && dr → stop
      final out = makeDecision([
        _det(
            label: 'person',
            position: 'on left',
            distLabel: 'very close'),
        _det(
            label: 'car',
            position: 'ahead',
            distLabel: 'extremely close'),
        _det(
            label: 'bicycle',
            position: 'on right',
            distLabel: 'very close'),
      ]);
      expect(out, 'stop');
    });

    test('10. only left blocked, ahead clear → "move right"', () {
      // py:897 — dl only → move right
      final out = makeDecision([
        _det(
            label: 'chair',
            position: 'on left',
            distLabel: 'extremely close'),
      ]);
      expect(out, 'move right');
    });

    test('11. only right blocked, ahead clear → "move left"', () {
      // py:898 — dr only → move left
      final out = makeDecision([
        _det(
            label: 'chair',
            position: 'on right',
            distLabel: 'extremely close'),
      ]);
      expect(out, 'move left');
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  group('smoothedDepth — py:826-831, hist=5', () {
    test('12. rolling mean is capped at kDepthHistorySize', () {
      expect(kDepthHistorySize, 5);
      final hist = <String, List<double>>{};
      final key = 'person:ahead';
      // Push 7 values; only the last 5 should remain.
      smoothedDepth(hist, key, 0.10);
      smoothedDepth(hist, key, 0.20);
      smoothedDepth(hist, key, 0.30);
      smoothedDepth(hist, key, 0.40);
      smoothedDepth(hist, key, 0.50);
      smoothedDepth(hist, key, 0.60);
      final result = smoothedDepth(hist, key, 0.70);
      // Window now: [0.30, 0.40, 0.50, 0.60, 0.70] → mean 0.50
      expect(hist[key]!.length, 5);
      expect(result, closeTo(0.50, 1e-9));
    });

    test('13. separate keys do not pollute each other', () {
      final hist = <String, List<double>>{};
      smoothedDepth(hist, 'person:ahead', 0.9);
      smoothedDepth(hist, 'person:ahead', 0.9);
      // Different key — should start fresh.
      final out = smoothedDepth(hist, 'car:on left', 0.1);
      expect(out, closeTo(0.1, 1e-9));
      expect(hist['person:ahead']!.length, 2);
      expect(hist['car:on left']!.length, 1);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  group('smoothedDecision — py:1913-1916, n=3 majority', () {
    test('14. majority wins over single dissenting frame', () {
      // The function MUTATES the supplied history list.
      final hist = <String>[];
      expect(smoothedDecision(hist, 'move left'), 'move left');
      expect(smoothedDecision(hist, 'move left'), 'move left');
      // Last 3 are [move left, move left, stop] → majority is move left.
      expect(smoothedDecision(hist, 'stop'), 'move left');
    });

    test('15. window slides — once stop is majority of last 3, it wins', () {
      final hist = <String>[];
      smoothedDecision(hist, 'path clear');
      smoothedDecision(hist, 'stop');
      smoothedDecision(hist, 'stop');
      // Last 3 now [path clear, stop, stop] → stop majority.
      expect(smoothedDecision(hist, 'stop'), 'stop');
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  group('positionBand — py:1873-1875', () {
    test('16. thirds split at 1/3 and 2/3', () {
      expect(positionBand(0.0), 'on left');
      expect(positionBand(0.33), 'on left');
      expect(positionBand(1 / 3), 'ahead'); // boundary: ≥ goes ahead
      expect(positionBand(0.5), 'ahead');
      expect(positionBand(0.66), 'ahead');
      expect(positionBand(2 / 3), 'on right'); // boundary: ≥ goes right
      expect(positionBand(0.99), 'on right');
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  group('nonMaxSuppression', () {
    test('17. keeps highest-conf box and drops same-class overlap', () {
      final a = _det(
        label: 'person',
        position: 'ahead',
        distLabel: 'close',
        conf: 0.9,
        x1: 0.1, y1: 0.1, x2: 0.5, y2: 0.5,
      );
      final b = _det(
        label: 'person',
        position: 'ahead',
        distLabel: 'close',
        conf: 0.5,
        x1: 0.12, y1: 0.12, x2: 0.48, y2: 0.48, // ~95% IoU with a
      );
      final out = nonMaxSuppression([a, b]);
      expect(out.length, 1);
      expect(out.first['conf'], 0.9);
    });

    test('18. different classes are kept even with high IoU', () {
      // py: NMS is per-class only — overlapping detections of different
      // labels both survive.
      final person = _det(
        label: 'person',
        position: 'ahead',
        distLabel: 'close',
        conf: 0.9,
        x1: 0.1, y1: 0.1, x2: 0.5, y2: 0.5,
      );
      final chair = _det(
        label: 'chair',
        position: 'ahead',
        distLabel: 'close',
        conf: 0.8,
        x1: 0.12, y1: 0.12, x2: 0.48, y2: 0.48,
      );
      final out = nonMaxSuppression([person, chair]);
      expect(out.length, 2);
    });
  });
}
