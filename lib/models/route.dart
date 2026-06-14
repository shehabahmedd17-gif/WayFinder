import 'route_step.dart';

// A full walking route: ordered steps + trip totals.
// py:get_walking_route() returned a flat step list; M6 adds totals for the
// "How far?" voice command and the outdoor status UI.
class Route {
  final List<RouteStep> steps;
  final int totalDistanceMeters;
  final int totalDurationSeconds;

  const Route({
    required this.steps,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
  });

  bool get isEmpty => steps.isEmpty;

  @override
  String toString() =>
      'Route(${steps.length} steps, ${totalDistanceMeters}m, '
      '${totalDurationSeconds}s)';
}
