// Named-args wrapper around the existing positional `haversineMeters` in
// `lib/utils/haversine.dart`. The wrapper is what the active-navigation
// step-advance logic uses (`required` keyword args read more clearly in
// the poll tick + the unit tests).
//
// The original positional API stays in place — the navigation poller and
// re-route deviation check have been calling it since Step M6, and there's
// no reason to churn those call sites.

import '../utils/haversine.dart' as utils;

/// Great-circle distance in metres between two lat/lng points.
/// Suitable for distances up to ~50 km where Earth-curvature error
/// stays under ~0.5 m. Symmetric: d(A,B) == d(B,A).
double haversineMeters({
  required double lat1,
  required double lng1,
  required double lat2,
  required double lng2,
}) =>
    utils.haversineMeters(lat1, lng1, lat2, lng2);
