// Represents one YOLO detection merged with its MiDaS depth sample.
//
// Two coordinate spaces are carried:
//   (x1,y1,x2,y2)             — normalized [0,1] to CAMERA pixel space (after
//                                un-letterbox). This is the canonical form
//                                that the overlay paints + the depth sampler
//                                consumes. py: equivalent of structured[obj]
//                                after the un-letterbox in _detection_loop.
//   (yoloX1..yoloY2)          — normalized [0,1] to YOLO 640 input space
//                                (before un-letterbox). Used ONLY by the cyan
//                                debug overlay to A/B-verify letterbox math.
class Detection {
  final String label;
  // Camera-space normalized corners.
  final double x1, y1, x2, y2;
  // YOLO-space normalized corners (debug-only).
  final double yoloX1, yoloY1, yoloX2, yoloY2;
  final double confidence;
  final String distLabel; // 'extremely close' | 'very close' | 'close' | 'far'
  final String position; // 'on left' | 'ahead' | 'on right'
  final double priority; // calc_priority() result

  const Detection({
    required this.label,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.confidence,
    required this.distLabel,
    required this.position,
    required this.priority,
    this.yoloX1 = 0,
    this.yoloY1 = 0,
    this.yoloX2 = 0,
    this.yoloY2 = 0,
  });
}
