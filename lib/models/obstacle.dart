// Highest-priority detection after calc_priority() — snapshot for approach detection.
class Obstacle {
  final String label;
  final double distance; // normalized MiDaS depth value
  final String distLabel;
  final String position;

  const Obstacle({
    required this.label,
    required this.distance,
    required this.distLabel,
    required this.position,
  });

  Obstacle copyWith({
    String? label,
    double? distance,
    String? distLabel,
    String? position,
  }) {
    return Obstacle(
      label: label ?? this.label,
      distance: distance ?? this.distance,
      distLabel: distLabel ?? this.distLabel,
      position: position ?? this.position,
    );
  }
}
