import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/detection.dart';
import '../models/obstacle.dart';

// Holds the latest detection frame results for the UI overlay.
// Updated by detection_pipeline.dart on the worker isolate result channel.
//
// `imgW` and `imgH` are the camera-image pixel dimensions used to interpret
// the `x1..y2` fields of each Detection (camera-space normalized [0,1]).
// The overlay needs these to do BoxFit.cover math against the widget size.
class DetectionState {
  final List<Detection> detections;
  final Obstacle? mainObstacle; // highest priority this frame
  final String decision; // 'move left' | 'move right' | 'stop' | 'path clear'
  final String? approachWarning; // nullable — py: approach_warn

  // ── Display-oriented frame dims ───────────────────────────────────────
  // imgW/imgH are the dimensions of the displayed image (after sensor →
  // display rotation). For a portrait-locked back camera on Android, these
  // are typically the SWAP of the raw CameraImage dims (e.g. raw 720×480
  // sensor → display 480×720). The overlay uses these to do BoxFit.cover.
  final int imgW; // displayed image width
  final int imgH; // displayed image height

  // Clockwise rotation (degrees) applied to detection coords going from
  // sensor space → display space. 0/90/180/270. Diagnostic-only — the
  // detection x1..y2 fields are already rotated by this amount.
  final int rotationDeg;

  const DetectionState({
    required this.detections,
    this.mainObstacle,
    required this.decision,
    this.approachWarning,
    this.imgW = 0,
    this.imgH = 0,
    this.rotationDeg = 0,
  });

  static const DetectionState empty = DetectionState(
    detections: [],
    decision: 'path clear',
  );
}

class DetectionNotifier extends Notifier<DetectionState> {
  @override
  DetectionState build() => DetectionState.empty;

  void update(DetectionState next) => state = next;

  void clear() => state = DetectionState.empty;
}

final detectionProvider =
    NotifierProvider<DetectionNotifier, DetectionState>(
  DetectionNotifier.new,
);

// Debug toggle — when true, the overlay also draws each detection's raw
// YOLO-space rectangle in cyan, so we can visually A/B the letterbox
// un-mapping. Off by default.
class ShowRawYoloBoxesNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
}

final showRawYoloBoxesProvider =
    NotifierProvider<ShowRawYoloBoxesNotifier, bool>(
  ShowRawYoloBoxesNotifier.new,
);
