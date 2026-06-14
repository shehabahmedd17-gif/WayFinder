// YUV420 → RGB conversion, stride-aware.
// Designed to run inside the pipeline isolate, never on the UI thread.
//
// Android CameraImage planes:
//   planes[0] — Y luma,  bytesPerRow may be padded,  bytesPerPixel = 1
//   planes[1] — U/Cb,   bytesPerRow may be padded,  bytesPerPixel = 1 (planar)
//                                                   or 2 (NV12 interleaved)
//   planes[2] — V/Cr,   same as planes[1] but offset by 1 byte in NV12
//
// Using bytesPerRow (yRowStride / uvRowStride) and bytesPerPixel (uvPixelStride)
// handles both YUV420 planar and NV12 semi-planar correctly.

import 'dart:typed_data';

/// Convert YUV420 (planar or NV12) to a flat RGB Uint8List of length w*h*3.
///
/// Parameters match CameraImage.planes[*] properties directly.
Uint8List yuv420ToRgb({
  required Uint8List yBytes,
  required int yRowStride,
  required Uint8List uBytes,
  required Uint8List vBytes,
  required int uvRowStride,
  required int uvPixelStride, // 1 = planar YUV420; 2 = NV12 interleaved
  required int width,
  required int height,
}) {
  final rgb = Uint8List(width * height * 3);
  int idx = 0;

  for (int row = 0; row < height; row++) {
    for (int col = 0; col < width; col++) {
      final yVal = yBytes[row * yRowStride + col] & 0xFF;

      final uvRow = row >> 1;
      final uvCol = col >> 1;
      final uvBase = uvRow * uvRowStride + uvCol * uvPixelStride;

      final uVal = (uBytes[uvBase] & 0xFF) - 128;
      final vVal = (vBytes[uvBase] & 0xFF) - 128;

      // ITU-R BT.601 — matches OpenCV's COLOR_YUV2RGB_I420
      rgb[idx++] = _clamp(yVal + 1.402 * vVal);
      rgb[idx++] = _clamp(yVal - 0.344136 * uVal - 0.714136 * vVal);
      rgb[idx++] = _clamp(yVal + 1.772 * uVal);
    }
  }

  return rgb;
}

int _clamp(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.toInt());
