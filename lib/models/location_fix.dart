// A single resolved device location.
//
// Mirrors the Python GPS resolution outcome (py:255-328): a coordinate plus
// metadata about how trustworthy it is. `isFallback == true` means we could
// not get a real fix and are using the Cairo default — the UI must surface
// this as "Using approximate location".
class LocationFix {
  final double lat;
  final double lng;
  final double accuracyMeters; // horizontal accuracy; large for fallback
  final DateTime timestamp;
  final bool isFallback;

  const LocationFix({
    required this.lat,
    required this.lng,
    required this.accuracyMeters,
    required this.timestamp,
    required this.isFallback,
  });

  @override
  String toString() =>
      'LocationFix(${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}, '
      '±${accuracyMeters.toStringAsFixed(0)}m, '
      '${isFallback ? "FALLBACK" : "real"})';
}
