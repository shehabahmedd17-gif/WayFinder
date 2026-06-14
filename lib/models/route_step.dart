// One walking step from Google Routes API (New) computeRoutes.
// py:get_walking_route() dict (lines 682-741).
class RouteStep {
  final String instruction; // navigationInstruction.instructions, HTML-stripped
  final double startLat;
  final double startLng;
  final double endLat;
  final double endLng;
  final int distanceMeters;

  const RouteStep({
    required this.instruction,
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    required this.distanceMeters,
  });

  @override
  String toString() =>
      'RouteStep("$instruction" ${distanceMeters}m → $endLat,$endLng)';
}
