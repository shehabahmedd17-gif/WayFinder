// Keys are injected at build time — NEVER hardcoded in source.
//
// Build command:
//   flutter build apk --debug \
//     --dart-define=GOOGLE_PLACES_KEY=AIza... \
//     --dart-define=GOOGLE_ROUTES_KEY=AIza... \
//     --dart-define=GOOGLE_GEOCODING_KEY=AIza...   # optional (reverse geocode)
//
// The three keys burned in Rahaf_strials_egypt.py (lines 68-70) are
// COMPROMISED. Delete them in Google Cloud Console → APIs & Services →
// Credentials before creating new ones.
//
// Graceful degradation: a missing key does NOT crash the app. The feature
// that needs it surfaces a user-facing error when invoked; everything else
// keeps working. `logMissingAtStartup()` prints one [API] line per absent
// key so a missing key is obvious in logcat.

import 'package:flutter/foundation.dart' show debugPrint;

abstract final class ApiKeys {
  static const String places = String.fromEnvironment('GOOGLE_PLACES_KEY');
  static const String routes = String.fromEnvironment('GOOGLE_ROUTES_KEY');
  static const String geocoding =
      String.fromEnvironment('GOOGLE_GEOCODING_KEY');

  static bool get hasPlaces => places.isNotEmpty;
  static bool get hasRoutes => routes.isNotEmpty;
  static bool get hasGeocoding => geocoding.isNotEmpty;

  /// True only if the keys required for core outdoor navigation are present.
  /// Geocoding is optional (only the "Where am I?" street-name P2 feature).
  static bool get outdoorReady => hasPlaces && hasRoutes;

  /// Call once at startup. Logs a clear [API] line for each missing key so
  /// field builds without `--dart-define` are immediately diagnosable.
  static void logMissingAtStartup() {
    if (!hasPlaces) {
      debugPrint('[API] key missing for places '
          '(--dart-define=GOOGLE_PLACES_KEY) — outdoor search disabled');
    }
    if (!hasRoutes) {
      debugPrint('[API] key missing for routes '
          '(--dart-define=GOOGLE_ROUTES_KEY) — walking routes disabled');
    }
    if (!hasGeocoding) {
      debugPrint('[API] key missing for geocoding '
          '(--dart-define=GOOGLE_GEOCODING_KEY) — '
          '"Where am I?" will speak raw coordinates only');
    }
    if (hasPlaces && hasRoutes && hasGeocoding) {
      debugPrint('[API] all keys present');
    }
  }
}
