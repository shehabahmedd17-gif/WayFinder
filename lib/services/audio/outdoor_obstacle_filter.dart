// Outdoor obstacle filter — translates a DetectionState into AT MOST ONE
// safety-critical announcement, dropping everything that's irrelevant
// while the user is walking the street.
//
// Rules (Part B):
//   1. Only labels whose kRiskWeights value is >= kOutdoorObstacleRisk
//      threshold (≥ 2.5 = person, car, bus, truck, motorcycle, bicycle,
//      dog) are candidates. Static-fixture risks (chair, plant, bin)
//      that matter indoors are NOT relevant on a street.
//   2. Only proximity above kOutdoorObstacleProximityThreshold qualifies.
//      "far" objects are noise while walking — only `close`, `very
//      close`, or `extremely close` get spoken.
//   3. "path clear" is never returned in outdoor mode — it's chatter.
//
// Returns the spoken message string or null when nothing qualifies.
// Pure — easy to unit-test, easy to reason about.

import '../../core/constants.dart';
import '../../models/detection.dart';
import '../../state/detection_notifier.dart';

// 0.0 ("far") → 1.0 ("extremely close"). Derived from the four discrete
// distLabel buckets the pipeline already emits — kept in this filter so
// the announcer / coordinator don't need to know about depth thresholds.
double proximityScore(String distLabel) {
  switch (distLabel) {
    case 'extremely close':
      return 1.0;
    case 'very close':
      return 0.75;
    case 'close':
      return 0.5;
    case 'far':
    default:
      return 0.0;
  }
}

class OutdoorObstacleDecision {
  final String message;
  final double riskWeight;
  final double proximity;
  const OutdoorObstacleDecision({
    required this.message,
    required this.riskWeight,
    required this.proximity,
  });
}

/// Returns the highest-priority qualifying obstacle for outdoor mode, or
/// null if nothing meets BOTH the risk and proximity thresholds.
OutdoorObstacleDecision? filterOutdoorDetections(DetectionState state) {
  Detection? best;
  double bestRisk = 0.0;
  double bestProx = 0.0;

  for (final d in state.detections) {
    final risk = kRiskWeights[d.label] ?? 0.0;
    if (risk < kOutdoorObstacleRiskThreshold) continue;
    final prox = proximityScore(d.distLabel);
    if (prox < kOutdoorObstacleProximityThreshold) continue;
    // Score = risk × proximity — same intent as the indoor priority engine.
    final score = risk * prox;
    final bestScore = bestRisk * bestProx;
    if (best == null || score > bestScore) {
      best = d;
      bestRisk = risk;
      bestProx = prox;
    }
  }

  if (best == null) return null;
  return OutdoorObstacleDecision(
    message: '${best.label} ${best.distLabel} ${best.position}',
    riskWeight: bestRisk,
    proximity: bestProx,
  );
}
