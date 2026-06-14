// Great-circle distance + point-to-segment distance for GPS coordinates.
// py:744-752 _haversine_m()
import 'dart:math';

const double _earthR = 6371000.0; // metres

double haversineMeters(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  final p1 = lat1 * pi / 180;
  final p2 = lat2 * pi / 180;
  final dp = (lat2 - lat1) * pi / 180;
  final dl = (lon2 - lon1) * pi / 180;
  final a = sin(dp / 2) * sin(dp / 2) +
      cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2);
  return 2 * _earthR * asin(sqrt(a));
}

// Perpendicular distance (metres) from point P to the segment A→B.
//
// Used by the navigation poller's re-route trigger: "did the user wander
// > 50 m off the current step's start→end line?". A point-to-endpoint
// haversine is wrong here (you can be near the line yet far from both
// endpoints, or vice-versa) so we need true point-to-segment distance.
//
// Method: equirectangular projection centred on A. At walking-step scale
// (< ~1 km) the projection error is < 0.5 m — well inside the 50 m
// deviation threshold. The projection parameter t is clamped to [0, 1] so
// the result is distance to the nearest point ON the segment (not its
// infinite line), i.e. endpoints are handled correctly.
double pointToSegmentMeters(
  double pLat,
  double pLng,
  double aLat,
  double aLng,
  double bLat,
  double bLng,
) {
  // Local planar coords (metres) with origin at A.
  final lat0 = aLat * pi / 180;
  double toX(double lng) => (lng - aLng) * pi / 180 * _earthR * cos(lat0);
  double toY(double lat) => (lat - aLat) * pi / 180 * _earthR;

  final px = toX(pLng), py = toY(pLat);
  final bx = toX(bLng), by = toY(bLat);
  // A is the origin (0, 0).

  final segLenSq = bx * bx + by * by;
  if (segLenSq == 0) {
    // Degenerate segment (A == B): distance to the point.
    return sqrt(px * px + py * py);
  }

  // Projection scalar of P onto AB, clamped to the segment.
  var t = (px * bx + py * by) / segLenSq;
  t = t.clamp(0.0, 1.0);

  final cx = t * bx; // closest point on segment
  final cy = t * by;
  final dx = px - cx;
  final dy = py - cy;
  return sqrt(dx * dx + dy * dy);
}
