// Pure Dart — no Flutter dependencies. Safe to import from any isolate.
// Ports of py:624-899: risk/zone weights, calc_priority, dist_label,
// make_decision, smoothed_depth, decision smoothing, approach detection.

import 'dart:math' show max, min;
import '../../core/constants.dart';

// ── Depth label — py:833-837 dist_label() ─────────────────────────────────

String distLabel(double norm) {
  if (norm >= kDepthExtremelyClose) return 'extremely close';
  if (norm >= kDepthVeryClose) return 'very close';
  if (norm >= kDepthClose) return 'close';
  return 'far';
}

// ── Priority — py:880-884 calc_priority() ─────────────────────────────────

double calcPriority({
  required String label,
  required String position,
  required double distance, // normalized MiDaS depth value
}) {
  final risk = kRiskWeights[label] ?? 1.0;
  final zone = kZoneWeights[position] ?? 1.0;
  return (risk * 2) + (zone * 1.5) + (distance * 3);
}

// ── Decision — py:886-899 make_decision() ─────────────────────────────────
//
// Receives only detections whose distLabel is 'extremely close' or 'very close'.
// Maps position → direction flags, then picks the safest evasion.

String makeDecision(List<Map<String, dynamic>> detections) {
  bool dl = false, dc = false, dr = false;
  for (final d in detections) {
    final dl2 = d['distLabel'] as String;
    if (dl2 != 'extremely close' && dl2 != 'very close') continue;
    switch (d['position'] as String) {
      case 'on left':
        dl = true;
      case 'ahead':
        dc = true;
      case 'on right':
        dr = true;
    }
  }
  if (dc) {
    if (!dl) return 'move left';
    if (!dr) return 'move right';
    return 'stop';
  }
  if (dl) return 'move right';
  if (dr) return 'move left';
  return 'path clear';
}

// ── Smoothed depth — py:827-831 smoothed_depth(), DEPTH_HISTORY_SIZE=5 ────
//
// Rolling mean over the last kDepthHistorySize samples, keyed by (label, position).
// The map is owned by the isolate so it persists across frames.

double smoothedDepth(
  Map<String, List<double>> history,
  String key,
  double rawValue,
) {
  final h = history.putIfAbsent(key, () => []);
  h.add(rawValue);
  if (h.length > kDepthHistorySize) h.removeAt(0);
  return h.reduce((a, b) => a + b) / h.length;
}

// ── Decision smoothing — py:1913-1916 decision_history[-3:] ───────────────
//
// Majority vote over the last kDecisionHistorySize decisions.

String smoothedDecision(List<String> history, String raw) {
  history.add(raw);
  if (history.length > kDecisionHistorySize) history.removeAt(0);
  // Majority vote
  final counts = <String, int>{};
  for (final d in history) { counts[d] = (counts[d] ?? 0) + 1; }
  return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
}

// ── Position band — py:1873-1875 ──────────────────────────────────────────
//
// cx is the box center x, normalized [0,1] relative to frame width.

String positionBand(double cxNorm) {
  if (cxNorm < 1 / 3) return 'on left';
  if (cxNorm < 2 / 3) return 'ahead';
  return 'on right';
}

// ── Sample depth patch — py:1878-1881 ─────────────────────────────────────
//
// Samples a 7×7 patch centred on the object in the 256×256 depth map.
// cx, cy are normalized [0,1] object centre coordinates.
// Returns the mean depth value over the patch.
// py: "we deliberately do NOT interpolate back to (h,w)" — sample small map directly.

double sampleDepthPatch(
  List<double> depthFlat, // 256*256 values, row-major
  double cxNorm,
  double cyNorm, {
  int mapSize = 256,
  int patchRadius = 3,
}) {
  final dcx = (cxNorm * mapSize).toInt().clamp(0, mapSize - 1);
  final dcy = (cyNorm * mapSize).toInt().clamp(0, mapSize - 1);
  final py1 = max(0, dcy - patchRadius);
  final py2 = min(mapSize - 1, dcy + patchRadius);
  final px1 = max(0, dcx - patchRadius);
  final px2 = min(mapSize - 1, dcx + patchRadius);

  double sum = 0;
  int count = 0;
  for (int row = py1; row <= py2; row++) {
    for (int col = px1; col <= px2; col++) {
      sum += depthFlat[row * mapSize + col];
      count++;
    }
  }
  return count > 0 ? sum / count : 0.0;
}

// ── NMS helpers ─────────────────────────────────────────────────────────────

double _iou(Map<String, dynamic> a, Map<String, dynamic> b) {
  final x1 = max(a['x1'] as double, b['x1'] as double);
  final y1 = max(a['y1'] as double, b['y1'] as double);
  final x2 = min(a['x2'] as double, b['x2'] as double);
  final y2 = min(a['y2'] as double, b['y2'] as double);
  if (x2 <= x1 || y2 <= y1) return 0.0;
  final inter = (x2 - x1) * (y2 - y1);
  final aArea = ((a['x2'] as double) - (a['x1'] as double)) *
      ((a['y2'] as double) - (a['y1'] as double));
  final bArea = ((b['x2'] as double) - (b['x1'] as double)) *
      ((b['y2'] as double) - (b['y1'] as double));
  return inter / (aArea + bArea - inter + 1e-6);
}

List<Map<String, dynamic>> nonMaxSuppression(
  List<Map<String, dynamic>> boxes, {
  double iouThreshold = 0.45,
}) {
  boxes.sort((a, b) =>
      (b['conf'] as double).compareTo(a['conf'] as double));
  final suppressed = List<bool>.filled(boxes.length, false);
  final keep = <Map<String, dynamic>>[];
  for (int i = 0; i < boxes.length; i++) {
    if (suppressed[i]) { continue; }
    keep.add(boxes[i]);
    for (int j = i + 1; j < boxes.length; j++) {
      if (suppressed[j]) { continue; }
      if (boxes[i]['label'] != boxes[j]['label']) { continue; }
      if (_iou(boxes[i], boxes[j]) > iouThreshold) { suppressed[j] = true; }
    }
  }
  return keep;
}
