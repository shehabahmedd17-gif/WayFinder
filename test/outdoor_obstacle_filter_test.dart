// Unit tests for filterOutdoorDetections.

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_nav/models/detection.dart';
import 'package:smart_nav/services/audio/outdoor_obstacle_filter.dart';
import 'package:smart_nav/state/detection_notifier.dart';

Detection _det(String label, String distLabel, String position,
        {double confidence = 0.9}) =>
    Detection(
      label: label,
      x1: 0.4, y1: 0.4, x2: 0.6, y2: 0.6,
      confidence: confidence,
      distLabel: distLabel,
      position: position,
      priority: 1.0,
    );

DetectionState _state(List<Detection> dets) =>
    DetectionState(detections: dets, decision: 'path clear');

void main() {
  test('E3a. Low-risk static (chair) — suppressed', () {
    final r = filterOutdoorDetections(
        _state([_det('chair', 'very close', 'ahead')]));
    expect(r, isNull);
  });

  test('E3b. Distant person (far) — suppressed', () {
    final r = filterOutdoorDetections(
        _state([_det('person', 'far', 'ahead')]));
    expect(r, isNull);
  });

  test('E4a. Person very close ahead — announced', () {
    final r = filterOutdoorDetections(
        _state([_det('person', 'very close', 'ahead')]));
    expect(r, isNotNull);
    expect(r!.message, 'person very close ahead');
    expect(r.riskWeight, greaterThanOrEqualTo(2.5));
    expect(r.proximity, greaterThanOrEqualTo(0.5));
  });

  test('E4b. Car close on left — announced', () {
    final r = filterOutdoorDetections(
        _state([_det('car', 'close', 'on left')]));
    expect(r, isNotNull);
    expect(r!.message, 'car close on left');
  });

  test('E4c. Bicycle extremely close — announced (highest priority)', () {
    final r = filterOutdoorDetections(
        _state([_det('bicycle', 'extremely close', 'ahead')]));
    expect(r, isNotNull);
    expect(r!.proximity, 1.0);
  });

  test('E5. Empty detections → null', () {
    expect(filterOutdoorDetections(_state(const [])), isNull);
  });

  test('E6. Mixed: chooses the highest risk×proximity', () {
    // person/close (2.5 * 0.5 = 1.5) vs car/very close (3.0 * 0.75 = 2.25)
    final r = filterOutdoorDetections(_state([
      _det('person', 'close', 'on left'),
      _det('car', 'very close', 'ahead'),
    ]));
    expect(r, isNotNull);
    expect(r!.message, 'car very close ahead');
  });

  test('E7. Path clear / unknown label is never announced', () {
    final r = filterOutdoorDetections(
        _state([_det('teddy bear', 'extremely close', 'ahead')]));
    expect(r, isNull);
  });
}
