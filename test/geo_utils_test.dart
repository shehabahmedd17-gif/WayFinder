// Unit tests for the named-args geo_utils.haversineMeters wrapper.

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_nav/core/geo_utils.dart';

void main() {
  // Reference points used in the tests.
  // Cairo (Tahrir Sq)    : (30.0444, 31.2357)
  // Alexandria (downtown): (31.2001, 29.9187) — ~180 km from Tahrir
  // Giza Pyramids        : (29.9792, 31.1342) — ~13 km from Tahrir
  // Sydney Opera House   : (-33.8568, 151.2153)

  test('1. zero distance for identical points', () {
    final d = haversineMeters(
        lat1: 30.0444, lng1: 31.2357, lat2: 30.0444, lng2: 31.2357);
    expect(d, closeTo(0.0, 1e-6));
  });

  test('2. Tahrir → Pyramids is ~13 km', () {
    final d = haversineMeters(
        lat1: 30.0444, lng1: 31.2357, lat2: 29.9792, lng2: 31.1342);
    expect(d, greaterThan(11000));
    expect(d, lessThan(15000));
  });

  test('3. Tahrir → Alexandria is ~180 km', () {
    final d = haversineMeters(
        lat1: 30.0444, lng1: 31.2357, lat2: 31.2001, lng2: 29.9187);
    expect(d, greaterThan(170000));
    expect(d, lessThan(195000));
  });

  test('4. symmetric: d(A,B) == d(B,A)', () {
    final ab = haversineMeters(
        lat1: 30.0444, lng1: 31.2357, lat2: 31.2001, lng2: 29.9187);
    final ba = haversineMeters(
        lat1: 31.2001, lng1: 29.9187, lat2: 30.0444, lng2: 31.2357);
    expect(ab, closeTo(ba, 1e-6));
  });

  test('5. southern hemisphere coords work (Sydney → Cairo ≈ 14 Mm)', () {
    final d = haversineMeters(
        lat1: -33.8568, lng1: 151.2153, lat2: 30.0444, lng2: 31.2357);
    expect(d, greaterThan(13_500_000));
    expect(d, lessThan(15_500_000));
  });
}
