// Unit tests for lib/utils/orientation.dart — pure-Dart rotation math.
//
// Coordinate convention throughout: normalized [0,1] with origin at top-left,
// x increasing right, y increasing down. `rotDeg` is the clockwise rotation
// to apply (matches CameraDescription.sensorOrientation semantics).

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_nav/utils/orientation.dart';

void main() {
  // Shared fixture — a small rectangle in the top-left quadrant.
  // Sensor-space: 0.4 wide × 0.6 tall.
  const sx1 = 0.1, sy1 = 0.2, sx2 = 0.5, sy2 = 0.8;
  const sw = sx2 - sx1; // 0.4
  const sh = sy2 - sy1; // 0.6

  group('rotateBoxNorm', () {
    test('1. 0° → identity', () {
      final r = rotateBoxNorm(sx1, sy1, sx2, sy2, 0);
      expect(r.x1, closeTo(sx1, 1e-9));
      expect(r.y1, closeTo(sy1, 1e-9));
      expect(r.x2, closeTo(sx2, 1e-9));
      expect(r.y2, closeTo(sy2, 1e-9));
    });

    test('2. 90° CW: top-left of sensor lands at top-right of display', () {
      // Sensor box at the top-left corner: (0,0)-(0.2, 0.4)
      final r = rotateBoxNorm(0.0, 0.0, 0.2, 0.4, 90);
      // Expected after 90° CW:
      //   xd1 = 1 - ys2 = 0.6
      //   yd1 = xs1    = 0.0
      //   xd2 = 1 - ys1 = 1.0
      //   yd2 = xs2    = 0.2
      expect(r.x1, closeTo(0.6, 1e-9));
      expect(r.y1, closeTo(0.0, 1e-9));
      expect(r.x2, closeTo(1.0, 1e-9));
      expect(r.y2, closeTo(0.2, 1e-9));
    });

    test('3. 90° CW: wide sensor box becomes tall display box (W↔H swap)', () {
      // The bug we set out to fix: a standing person in a landscape sensor
      // appears WIDE in sensor coords; on the portrait display it should
      // appear TALL.
      final r = rotateBoxNorm(sx1, sy1, sx2, sy2, 90);
      final w = r.x2 - r.x1;
      final h = r.y2 - r.y1;
      expect(w, closeTo(sh, 1e-9)); // display width  == sensor height
      expect(h, closeTo(sw, 1e-9)); // display height == sensor width
    });

    test('4. 180°: flips both axes, box stays same aspect', () {
      final r = rotateBoxNorm(sx1, sy1, sx2, sy2, 180);
      expect(r.x1, closeTo(1 - sx2, 1e-9));
      expect(r.y1, closeTo(1 - sy2, 1e-9));
      expect(r.x2, closeTo(1 - sx1, 1e-9));
      expect(r.y2, closeTo(1 - sy1, 1e-9));
      expect(r.x2 - r.x1, closeTo(sw, 1e-9));
      expect(r.y2 - r.y1, closeTo(sh, 1e-9));
    });

    test('5. 270° CW (= 90° CCW): also swaps W↔H, opposite direction to 90°', () {
      final r = rotateBoxNorm(sx1, sy1, sx2, sy2, 270);
      // Expected:
      //   xd1 = ys1     = 0.2
      //   yd1 = 1 - xs2 = 0.5
      //   xd2 = ys2     = 0.8
      //   yd2 = 1 - xs1 = 0.9
      expect(r.x1, closeTo(0.2, 1e-9));
      expect(r.y1, closeTo(0.5, 1e-9));
      expect(r.x2, closeTo(0.8, 1e-9));
      expect(r.y2, closeTo(0.9, 1e-9));
      expect(r.x2 - r.x1, closeTo(sh, 1e-9));
      expect(r.y2 - r.y1, closeTo(sw, 1e-9));
    });

    test('6. 90° + 270° round-trips back to original', () {
      final once = rotateBoxNorm(sx1, sy1, sx2, sy2, 90);
      final back = rotateBoxNorm(once.x1, once.y1, once.x2, once.y2, 270);
      expect(back.x1, closeTo(sx1, 1e-9));
      expect(back.y1, closeTo(sy1, 1e-9));
      expect(back.x2, closeTo(sx2, 1e-9));
      expect(back.y2, closeTo(sy2, 1e-9));
    });

    test('7. Four 90° rotations return to original', () {
      var r = rotateBoxNorm(sx1, sy1, sx2, sy2, 90);
      r = rotateBoxNorm(r.x1, r.y1, r.x2, r.y2, 90);
      r = rotateBoxNorm(r.x1, r.y1, r.x2, r.y2, 90);
      r = rotateBoxNorm(r.x1, r.y1, r.x2, r.y2, 90);
      expect(r.x1, closeTo(sx1, 1e-9));
      expect(r.y1, closeTo(sy1, 1e-9));
      expect(r.x2, closeTo(sx2, 1e-9));
      expect(r.y2, closeTo(sy2, 1e-9));
    });

    test('8. Non-canonical degree values normalize modulo 360', () {
      final ref0 = rotateBoxNorm(sx1, sy1, sx2, sy2, 0);
      final r360 = rotateBoxNorm(sx1, sy1, sx2, sy2, 360);
      final rNeg = rotateBoxNorm(sx1, sy1, sx2, sy2, -360);
      final r720 = rotateBoxNorm(sx1, sy1, sx2, sy2, 720);
      for (final r in [r360, rNeg, r720]) {
        expect(r.x1, closeTo(ref0.x1, 1e-9));
        expect(r.y1, closeTo(ref0.y1, 1e-9));
        expect(r.x2, closeTo(ref0.x2, 1e-9));
        expect(r.y2, closeTo(ref0.y2, 1e-9));
      }
      // 450° ≡ 90°
      final r90 = rotateBoxNorm(sx1, sy1, sx2, sy2, 90);
      final r450 = rotateBoxNorm(sx1, sy1, sx2, sy2, 450);
      expect(r450.x1, closeTo(r90.x1, 1e-9));
      expect(r450.y2, closeTo(r90.y2, 1e-9));
    });

    test('9. Non-multiple-of-90 input falls through to identity (no crash)', () {
      // Real devices only report 0/90/180/270 for sensorOrientation, but we
      // shouldn't crash on unexpected values.
      final r = rotateBoxNorm(sx1, sy1, sx2, sy2, 45);
      expect(r.x1, closeTo(sx1, 1e-9));
      expect(r.y2, closeTo(sy2, 1e-9));
    });
  });

  group('isQuarterTurn', () {
    test('10. True for 90/270, false for 0/180', () {
      expect(isQuarterTurn(0), isFalse);
      expect(isQuarterTurn(90), isTrue);
      expect(isQuarterTurn(180), isFalse);
      expect(isQuarterTurn(270), isTrue);
      // Wraps:
      expect(isQuarterTurn(-90), isTrue);
      expect(isQuarterTurn(450), isTrue);
    });
  });

  // ── Concrete scenario that matches the bug we fixed ─────────────────────
  group('Real-world: landscape sensor, portrait phone, back camera (90° CW)', () {
    test('11. Standing person (tall) appears wide in sensor → tall after rot', () {
      // Sensor 720×480 (landscape). A standing person in front of the camera
      // is rotated 90° in the raw sensor image — so the bounding box comes
      // out WIDE (e.g. 0.64) and SHORT (e.g. 0.29) in sensor-norm coords.
      final r = rotateBoxNorm(0.256, 0.379, 0.897, 0.666, 90);
      final w = r.x2 - r.x1;
      final h = r.y2 - r.y1;
      // After 90° CW: should be a TALL, NARROW box — width and height swap.
      expect(w, closeTo(0.666 - 0.379, 1e-9)); // 0.287
      expect(h, closeTo(0.897 - 0.256, 1e-9)); // 0.641
      expect(h, greaterThan(w)); // unambiguously portrait
    });
  });
}
