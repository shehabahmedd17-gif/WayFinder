// Unit tests for lib/utils/haversine.dart — great-circle + point-to-segment.

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_nav/utils/haversine.dart';

void main() {
  group('haversineMeters', () {
    test('1. same point → 0', () {
      expect(haversineMeters(30.0444, 31.2357, 30.0444, 31.2357),
          closeTo(0, 0.001));
    });

    test('2. 1° of longitude at the equator ≈ 111.19 km', () {
      // At lat 0, 1° lng = R * (π/180) = 6371000 * 0.0174533 ≈ 111194.9 m
      final d = haversineMeters(0, 0, 0, 1);
      expect(d, closeTo(111194.9, 5.0));
    });

    test('3. both points at the north pole → 0', () {
      // (90, 0) and (90, 90) are the same physical point.
      expect(haversineMeters(90, 0, 90, 90), closeTo(0, 0.001));
    });

    test('4. Cairo → Alexandria ≈ 180 km (known reference)', () {
      // Cairo (30.0444, 31.2357) → Alexandria (31.2001, 29.9187).
      final d = haversineMeters(30.0444, 31.2357, 31.2001, 29.9187);
      // Great-circle is ~180 km; allow a generous band.
      expect(d, greaterThan(170000));
      expect(d, lessThan(190000));
    });

    test('5. symmetric: d(a,b) == d(b,a)', () {
      final ab = haversineMeters(30.0, 31.0, 31.2, 29.9);
      final ba = haversineMeters(31.2, 29.9, 30.0, 31.0);
      expect(ab, closeTo(ba, 1e-6));
    });
  });

  group('pointToSegmentMeters', () {
    test('6. point exactly on the segment → ~0', () {
      // Segment due-east at lat 30; midpoint lies on it.
      final d = pointToSegmentMeters(
        30.0, 31.05, // P = midpoint
        30.0, 31.0, // A
        30.0, 31.1, // B
      );
      expect(d, closeTo(0, 0.5));
    });

    test('7. point ~100 m perpendicular off the segment → ≈100 m', () {
      // 100 m north of the midpoint of a due-east segment.
      // 1° lat ≈ 111195 m  →  100 m ≈ 0.000899°.
      final d = pointToSegmentMeters(
        30.000899, 31.05, // P, ~100 m north of the line
        30.0, 31.0, // A
        30.0, 31.1, // B
      );
      expect(d, closeTo(100, 2.0));
    });

    test('8. point beyond endpoint B clamps to distance from B', () {
      // P is 0.001° east of B, on the same latitude → distance ≈ dist(P,B).
      final d = pointToSegmentMeters(
        30.0, 31.101, // P just past B
        30.0, 31.0, // A
        30.0, 31.1, // B
      );
      final pb = haversineMeters(30.0, 31.101, 30.0, 31.1);
      expect(d, closeTo(pb, 0.5));
    });

    test('9. degenerate segment (A == B) → point-to-point distance', () {
      final d = pointToSegmentMeters(
        30.01, 31.0,
        30.0, 31.0,
        30.0, 31.0,
      );
      final pp = haversineMeters(30.01, 31.0, 30.0, 31.0);
      expect(d, closeTo(pp, 0.5));
    });

    test('10. Cairo→Alex route, point ~100 m off → roughly 100 m', () {
      // Realistic slanted segment. A pure-latitude offset near the midpoint
      // is approximately perpendicular; widen tolerance for the slant.
      const aLat = 30.0444, aLng = 31.2357; // Cairo
      const bLat = 31.2001, bLng = 29.9187; // Alexandria
      final midLat = (aLat + bLat) / 2;
      final midLng = (aLng + bLng) / 2;
      final d = pointToSegmentMeters(
        midLat + 0.000899, midLng, // ~100 m north of midpoint
        aLat, aLng,
        bLat, bLng,
      );
      expect(d, greaterThan(60));
      expect(d, lessThan(140));
    });
  });
}
