// Sensor → display coordinate rotation for ML detections.
//
// Android camera sensors are typically mounted in landscape inside the device.
// `CameraDescription.sensorOrientation` reports how many degrees clockwise
// the raw sensor image needs to be rotated to appear upright on the display
// at the device's natural orientation. For a back camera on a portrait-held
// phone, this is almost always 90°.
//
// CameraPreview applies that rotation automatically when rendering, but our
// ML pipeline runs on the raw unrotated CameraImage. So a person standing
// in front of the camera comes out as a wide, short bounding box in sensor
// coords — even though they fill a tall, narrow region on the display.
//
// `rotateBoxNorm(...)` rotates a normalized [0,1] bounding box from sensor
// space to display space. After applying it, the box dimensions match the
// display orientation and the overlay's BoxFit.cover math gets the right
// aspect ratio.

class RotatedBox {
  final double x1, y1, x2, y2;
  const RotatedBox(this.x1, this.y1, this.x2, this.y2);
}

/// Rotate a normalized sensor-space box to display-space.
///
/// `rotDeg` is the clockwise angle to apply (matches `sensorOrientation`):
///   0   — identity
///   90  — sensor's top edge becomes display's right edge
///   180 — flip both axes
///   270 — sensor's top edge becomes display's left edge
///
/// Non-multiples-of-90 fall through to identity (no devices use them).
RotatedBox rotateBoxNorm(
    double x1, double y1, double x2, double y2, int rotDeg) {
  final r = ((rotDeg % 360) + 360) % 360;
  switch (r) {
    case 0:
      return RotatedBox(x1, y1, x2, y2);
    case 90:
      // 90° CW: (xs, ys) → (1 - ys, xs). Box corners swap so x1<x2, y1<y2.
      return RotatedBox(1 - y2, x1, 1 - y1, x2);
    case 180:
      // 180°: (xs, ys) → (1 - xs, 1 - ys). Swap corners.
      return RotatedBox(1 - x2, 1 - y2, 1 - x1, 1 - y1);
    case 270:
      // 270° CW == 90° CCW: (xs, ys) → (ys, 1 - xs).
      return RotatedBox(y1, 1 - x2, y2, 1 - x1);
    default:
      return RotatedBox(x1, y1, x2, y2);
  }
}

/// True if a 90° or 270° rotation is being applied — caller should swap
/// imgW/imgH when consuming a rotated box.
bool isQuarterTurn(int rotDeg) {
  final r = ((rotDeg % 360) + 360) % 360;
  return r == 90 || r == 270;
}
