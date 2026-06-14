// Detection pipeline — ports py:1805-1970 _run_depth/_run_yolo parallel blocks.
//
// Architecture:
//   Camera stream (YUV420)  →  _onFrame() on main isolate
//     │ adaptive frame skip (py:1757-1758, 1956-1970)
//     ▼
//   _pipelineIsolate (one long-lived Dart isolate on its own OS thread)
//     ├── YUV→RGB conversion      (yuv_to_rgb.dart)
//     ├── Resize 640→640×640      (YOLO input, image package)
//     ├── Resize 640→256×256      (MiDaS input, image package)
//     ├── YOLOv8n inference        (tflite_flutter, NNAPI→CPU fallback)
//     ├── MiDaS inference          (tflite_flutter, NNAPI→CPU fallback)
//     ├── Priority engine          (priority_engine.dart)
//     ├── Depth smoothing (hist=5) (py:827-831)
//     ├── Decision smoothing (n=3) (py:1913-1916)
//     └── Approach detection (2s) (py:1901-1909)
//     ▼
//   DetectionPipelineService._onResult() on main isolate
//     └── onResult(DetectionState) callback → DetectionNotifier

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math; // letterbox uses math.min

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'; // ChangeNotifier
import 'package:flutter/services.dart' show rootBundle; // load .tflite assets on main isolate
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../../core/constants.dart';
import '../../models/detection.dart';
import '../../models/obstacle.dart';
import '../../state/detection_notifier.dart';
import '../../utils/orientation.dart';
import '../../utils/yuv_to_rgb.dart';
import 'priority_engine.dart';

// ─────────────────────────────────────────────────────────────────────────────
// YOLO label list — COCO 80 classes, cached once per isolate (py:340 YOLO_NAMES)
// ─────────────────────────────────────────────────────────────────────────────
const _kCoco80 = [
  'person', 'bicycle', 'car', 'motorcycle', 'airplane', 'bus', 'train',
  'truck', 'boat', 'traffic light', 'fire hydrant', 'stop sign',
  'parking meter', 'bench', 'bird', 'cat', 'dog', 'horse', 'sheep',
  'cow', 'elephant', 'bear', 'zebra', 'giraffe', 'backpack', 'umbrella',
  'handbag', 'tie', 'suitcase', 'frisbee', 'skis', 'snowboard',
  'sports ball', 'kite', 'baseball bat', 'baseball glove', 'skateboard',
  'surfboard', 'tennis racket', 'bottle', 'wine glass', 'cup', 'fork',
  'knife', 'spoon', 'bowl', 'banana', 'apple', 'sandwich', 'orange',
  'broccoli', 'carrot', 'hot dog', 'pizza', 'donut', 'cake', 'chair',
  'couch', 'potted plant', 'bed', 'dining table', 'toilet', 'tv',
  'laptop', 'mouse', 'remote', 'keyboard', 'cell phone', 'microwave',
  'oven', 'toaster', 'sink', 'refrigerator', 'book', 'clock', 'vase',
  'scissors', 'teddy bear', 'hair drier', 'toothbrush',
];

// ─────────────────────────────────────────────────────────────────────────────
// Isolate message types
// ─────────────────────────────────────────────────────────────────────────────

class _FrameMsg {
  final Uint8List yBytes;
  final Uint8List uBytes;
  final Uint8List vBytes;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;
  final int width;
  final int height;

  const _FrameMsg({
    required this.yBytes,
    required this.uBytes,
    required this.vBytes,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
    required this.width,
    required this.height,
  });
}

// Letterbox transform — preserve aspect ratio when fitting camera frame to a
// square ML input (640×640 for YOLO, 256×256 for MiDaS). Matches Ultralytics'
// default preprocessing: pad with gray (114) so the model doesn't hallucinate
// objects in the padded region.
class _Letterbox {
  final double scale;  // multiplier: camera pixel × scale = letterboxed pixel
  final double padX;   // letterboxed pixels of horizontal padding on each side
  final double padY;   // vertical padding
  final int target;    // letterboxed canvas size (square)
  const _Letterbox(this.scale, this.padX, this.padY, this.target);

  /// Inverse map a coordinate from letterboxed pixel space back to camera
  /// pixel space (subtract pad, divide by scale).
  double unmapX(double xLb) => (xLb - padX) / scale;
  double unmapY(double yLb) => (yLb - padY) / scale;

  /// Forward map a camera coord to letterboxed pixel space.
  double mapX(double xCam) => xCam * scale + padX;
  double mapY(double yCam) => yCam * scale + padY;
}

_Letterbox _computeLetterbox(int srcW, int srcH, int target) {
  final scale = math.min(target / srcW, target / srcH);
  final newW = srcW * scale;
  final newH = srcH * scale;
  final padX = (target - newW) / 2.0;
  final padY = (target - newH) / 2.0;
  return _Letterbox(scale, padX, padY, target);
}

// Build the NHWC nested input buffer reused across YOLO frames. Allocated
// once at startup (and again iff the runtime sanity check falls 416 → 640).
List<List<List<List<double>>>> _buildYoloInputBuf(int size) {
  return List.generate(
    1,
    (_) => List.generate(
      size,
      (_) => List.generate(size, (_) => List<double>.filled(3, 0.0)),
    ),
  );
}

img.Image _applyLetterbox(img.Image src, _Letterbox lb, {int padGray = 114}) {
  final newW = (src.width * lb.scale).round();
  final newH = (src.height * lb.scale).round();
  final resized = img.copyResize(
    src,
    width: newW,
    height: newH,
    interpolation: img.Interpolation.linear,
  );
  final canvas = img.Image(width: lb.target, height: lb.target);
  img.fill(canvas, color: img.ColorRgb8(padGray, padGray, padGray));
  img.compositeImage(
    canvas,
    resized,
    dstX: lb.padX.round(),
    dstY: lb.padY.round(),
  );
  return canvas;
}

class _PipelineResult {
  // All boxes after NMS — each map has: label, conf, x1, y1, x2, y2 (normalized
  // to CAMERA pixel space), plus yoloX1..yoloY2 (normalized to YOLO 640 space
  // for the cyan debug overlay).
  final List<Map<String, dynamic>> boxes;
  // Normalized depth map — 256*256 values, row-major
  final Float32List depthMap;
  final int cycleMs;

  // ── Diagnostics ────────────────────────────────────────────────────────
  final int rawCount;     // anchors with class score >= 0.10
  final int preNmsCount;  // anchors above the per-class threshold
  final int postNmsCount; // == boxes.length, for symmetry
  final Map<String, dynamic>? topRaw; // top-scoring anchor in raw coords
  final int frameW, frameH; // camera image dimensions
  final int uvPixelStride;  // 1 = planar, 2 = NV12
  final double rgbMeanR, rgbMeanG, rgbMeanB; // sanity check for YUV→RGB

  // ── MiDaS letterbox params — used by main isolate when sampling depth ──
  final double midasScale;
  final double midasPadX;
  final double midasPadY;
  // Resolved MiDaS input/output size — may be the constant (192) or, if the
  // model rejected the resize, the native 256. Needed by the main isolate to
  // normalize depth-map indices.
  final int midasSize;
  // Resolved YOLO input size — 416 if resize succeeded, else native 640.
  // Used by main-isolate [BOX] log to compute the letterbox padding it shows.
  final int yoloSize;

  const _PipelineResult({
    required this.boxes,
    required this.depthMap,
    required this.cycleMs,
    required this.rawCount,
    required this.preNmsCount,
    required this.postNmsCount,
    required this.topRaw,
    required this.frameW,
    required this.frameH,
    required this.uvPixelStride,
    required this.rgbMeanR,
    required this.rgbMeanG,
    required this.rgbMeanB,
    required this.midasScale,
    required this.midasPadX,
    required this.midasPadY,
    required this.midasSize,
    required this.yoloSize,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Isolate entry — MUST be a top-level function
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Adreno A610 (Snapdragon 685) hangs INDEFINITELY when compiling MiDaS's
// 17,349-op shader program on GpuDelegateV2 — neither succeeds nor throws.
// The TFLite GPU prepare-step doesn't yield control back, so Future.any +
// timeout doesn't help (the isolate's event loop is blocked by a synchronous
// native call). The only reliable mitigation is to skip the GPU tier entirely
// for MiDaS on devices known to have this limitation. YOLOv8n is much smaller
// (377 ops vs 17,349) and compiles on the same GPU within ~4 seconds, so YOLO
// keeps the GPU path.
const bool _kSkipGpuForMidas = true;

// ── Performance try #1 (2026-05-15) — VERDICT: reverted ─────────────────────
// We tried forcing YOLO to XNNPACK(4t) on the assumption that Adreno A610 was
// the bottleneck. On-device measurement showed CPU was 35% SLOWER than GPU
// (avg ~4700 ms vs ~3500 ms, high variance 4200–8200 ms suggesting thermal
// throttling). GPU stays the default. Flag preserved for future re-tests on
// other hardware.
const bool _kForceCpuYolo = false;

// Per-model interpreter loader with explicit fallback chain.
// Tries in order (with optional skipGpu):
//   1. GPU                     — GpuDelegateV2 (precision-loss allowed)
//   2. XNNPACK + 4 threads     — fast CPU kernels for FP models
//   3. Plain CPU + 4 threads   — last-resort baseline
//
// Each tier emits three logs (attempting / fromBuffer returned / tensors
// allocated) so a hang is visible in logcat without needing a debugger.
({Interpreter interp, String delegate}) _loadInterpreterWithFallback(
    Uint8List bytes, String name,
    {bool skipGpu = false}) {
  // NOTE: we no longer call interp.allocateTensors() eagerly here.
  //   - Once an input is fed with a shape that exactly matches the tensor's
  //     declared shape, getInputShapeIfDifferent() returns null, no resize
  //     happens, and the lazy `if (!_allocated) allocateTensors()` inside
  //     runInference works cleanly.
  //   - The eager allocate was originally meant to surface GPU OOM at load.
  //     With _kSkipGpuForMidas in place, that's no longer a concern: the
  //     only GPU path left (YOLO) is known to compile within ~4 s on the
  //     target devices, and any genuine failure surfaces from fromBuffer.

  // ── Tier 1: GPU ──────────────────────────────────────────────────────────
  if (!skipGpu) {
    try {
      debugPrint('[ISO] $name attempting GPU load (bytes=${bytes.length})...');
      final opts = InterpreterOptions()
        ..addDelegate(GpuDelegateV2(
          options: GpuDelegateOptionsV2(isPrecisionLossAllowed: true),
        ));
      final interp = Interpreter.fromBuffer(bytes, options: opts);
      debugPrint('[ISO] $name loaded — delegate=GPU');
      return (interp: interp, delegate: 'GPU');
    } catch (e) {
      debugPrint('[ISO] $name GPU failed: $e — falling back to XNNPACK');
    }
  } else {
    debugPrint('[ISO] $name skipping GPU (known device limitation)');
  }

  // ── Tier 2: XNNPACK + threads ───────────────────────────────────────────
  try {
    debugPrint('[ISO] $name attempting XNNPACK load (bytes=${bytes.length})...');
    final opts = InterpreterOptions()
      ..threads = 4
      ..addDelegate(XNNPackDelegate());
    final interp = Interpreter.fromBuffer(bytes, options: opts);
    debugPrint('[ISO] $name loaded — delegate=XNNPACK(4t)');
    return (interp: interp, delegate: 'XNNPACK(4t)');
  } catch (e) {
    debugPrint('[ISO] $name XNNPACK failed: $e — falling back to plain CPU');
  }

  // ── Tier 3: Plain CPU + threads ─────────────────────────────────────────
  try {
    debugPrint('[ISO] $name attempting CPU(4t) load (bytes=${bytes.length})...');
    final opts = InterpreterOptions()..threads = 4;
    final interp = Interpreter.fromBuffer(bytes, options: opts);
    debugPrint('[ISO] $name loaded — delegate=CPU(4t)');
    return (interp: interp, delegate: 'CPU(4t)');
  } catch (e) {
    debugPrint('[ISO] $name CPU also failed: $e');
    rethrow;
  }
}

@pragma('vm:entry-point')
Future<void> _pipelineIsolateEntry(List<dynamic> args) async {
  final mainSendPort = args[0] as SendPort;
  final yoloBytes = args[1] as Uint8List?;
  final midasBytes = args[2] as Uint8List?;

  // NOTE: no BackgroundIsolateBinaryMessenger.ensureInitialized here.
  // `rootBundle.load()` reads from `ServicesBinding.instance.defaultBundle`,
  // and `ServicesBinding` is a singleton that only exists on the root
  // isolate — the binary-messenger shim doesn't help. Loading model bytes
  // happens on the main isolate (see DetectionPipelineService.initialize)
  // and the bytes are passed in via this spawn arg list. We then use
  // `Interpreter.fromBuffer(bytes)` instead of `Interpreter.fromAsset()`.

  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort); // handshake — send our listen port

  // ── Load models from bytes ─────────────────────────────────────────────────
  //
  // Model formats:
  //   YOLOv8n float16 — weights are float16, but TFLite upcasts I/O tensors to
  //                     float32 at the boundary. We feed Float32List, get
  //                     Float32List back. GPU delegate runs float16 natively.
  //   MiDaS v2.1 small — pure float32 conversion of the Intel MiDaS_small model.
  //
  // Delegate chain: GPU → CPU. NNAPI is enabled automatically by the TFLite
  // runtime on API 27+ when no explicit delegate is set.
  // py: GPU delegate when available, else NNAPI, else CPU

  Interpreter? yolo;
  Interpreter? midas;
  String yoloDelegate = 'none';
  String midasDelegate = 'none';

  String tensorDescription(Tensor t) =>
      'shape=${t.shape}, dtype=${t.type}, name="${t.name}"';

  // ── YOLO ─ load via per-model fallback ───────────────────────────────────
  // We do NOT call `interpreter.resizeInputTensor` here. On Snapdragon 685 +
  // Adreno A610 + GpuDelegateV2 it SIGSEGVs inside libtensorflowlite_jni.so
  // (see kYoloInputSize comment for the full diagnosis). The model's native
  // input size — read straight from the loaded tensor — is the source of
  // truth. If the bundled file is re-exported at 416, this picks it up
  // automatically with no code changes.
  int yoloInputSize = 640;   // overwritten from inT.shape[1] below
  int yoloAnchors = 8400;    // overwritten from outT.shape.last below

  if (yoloBytes == null) {
    debugPrint('[ISO] YOLO bytes missing (asset load failed on main isolate)');
    mainSendPort.send({'type': 'error', 'msg': 'YOLO: bytes null'});
  } else {
    try {
      final loaded = _loadInterpreterWithFallback(
        yoloBytes,
        'YOLOv8n',
        skipGpu: _kForceCpuYolo,
      );
      yolo = loaded.interp;
      yoloDelegate = loaded.delegate;
      final inT = yolo.getInputTensor(0);
      final outT = yolo.getOutputTensor(0);
      debugPrint('[ISO]   YOLO input:  ${tensorDescription(inT)}');
      debugPrint('[ISO]   YOLO output: ${tensorDescription(outT)}');

      // NHWC: [1, H, W, 3]. H == W for square YOLO inputs.
      yoloInputSize = inT.shape[1];
      yoloAnchors = outT.shape.last;
      debugPrint('[ISO] YOLO model is ${yoloInputSize}x$yoloInputSize '
          '(anchors=$yoloAnchors) — using directly');
    } catch (e) {
      debugPrint('[ISO] YOLO all tiers failed: $e');
      mainSendPort.send({'type': 'error', 'msg': 'YOLO: $e'});
    }
  }

  // ── MiDaS ─ load via per-model fallback ──────────────────────────────────
  // Skip the GPU tier — the Adreno A610 hangs forever inside
  // TfLiteGpuDelegateV2.Prepare for MiDaS's 17,349-op graph, and the hang is
  // unkillable because the native call doesn't yield (see _kSkipGpuForMidas).
  // MiDaS input size. Read from the loaded tensor's shape, NOT modified at
  // runtime — calling resizeInputTensor would mark the graph dynamic-sized
  // and break the GPU delegate for YOLO. See kMidasInputSize comment.
  int midasSize = kMidasInputSize;

  if (midasBytes == null) {
    debugPrint('[ISO] MiDaS bytes missing (asset load failed on main isolate)');
    mainSendPort.send({'type': 'error', 'msg': 'MiDaS: bytes null'});
  } else {
    try {
      final loaded = _loadInterpreterWithFallback(
        midasBytes,
        'MiDaS',
        skipGpu: _kSkipGpuForMidas,
      );
      midas = loaded.interp;
      midasDelegate = loaded.delegate;
      final inT0 = midas.getInputTensor(0);
      final outT0 = midas.getOutputTensor(0);
      debugPrint('[ISO]   MiDaS input:  ${tensorDescription(inT0)}');
      debugPrint('[ISO]   MiDaS output: ${tensorDescription(outT0)}');
      // Native shape is [1, 3, H, W] NCHW; last dim = W = H (square).
      // Use whatever the model declares — do NOT resize.
      midasSize = inT0.shape.last;
    } catch (e) {
      debugPrint('[ISO] MiDaS all tiers failed: $e');
      mainSendPort.send({'type': 'error', 'msg': 'MiDaS: $e'});
    }
  }

  // Send tensor shape strings to main isolate so the debug panel can display them.
  String? yoloInShape, yoloOutShape, midasInShape, midasOutShape;
  try {
    final t = yolo?.getInputTensor(0);
    if (t != null) yoloInShape = '${t.shape} ${t.type}';
  } catch (_) {}
  try {
    final t = yolo?.getOutputTensor(0);
    if (t != null) yoloOutShape = '${t.shape} ${t.type}';
  } catch (_) {}
  try {
    final t = midas?.getInputTensor(0);
    if (t != null) midasInShape = '${t.shape} ${t.type}';
  } catch (_) {}
  try {
    final t = midas?.getOutputTensor(0);
    if (t != null) midasOutShape = '${t.shape} ${t.type}';
  } catch (_) {}

  mainSendPort.send({
    'type': 'ready',
    'yoloDelegate': yoloDelegate,
    'midasDelegate': midasDelegate,
    'yoloInputShape': yoloInShape,
    'yoloOutputShape': yoloOutShape,
    'midasInputShape': midasInShape,
    'midasOutputShape': midasOutShape,
  });

  // ── Pre-allocated input buffers ────────────────────────────────────────────
  // Allocating ≈1.2 M / 200 k nested list cells every frame would tank the GC.
  // Build them ONCE per isolate; fill values in-place each frame.
  //
  // YOLOv8n  expects NHWC [1, yoloInputSize, yoloInputSize, 3].
  // MiDaS    expects NCHW [1, 3, midasSize, midasSize].
  // Both buffers are allocated once at the loaded model's native size and
  // reused for the lifetime of the isolate. No runtime resize.
  final yoloInputBuf = _buildYoloInputBuf(yoloInputSize);
  final midasInputBuf = List.generate(
    1,
    (_) => List.generate(
      3,
      (_) => List.generate(
        midasSize,
        (_) => List<double>.filled(midasSize, 0.0),
      ),
    ),
  );

  // ── Frame loop ─────────────────────────────────────────────────────────────
  //
  // Per-frame cadence:
  //   YOLO  — every frame (cheap on GPU, ≈30–60 ms)
  //   MiDaS — every 2nd frame (≈200–400 ms on CPU; depth doesn't change fast
  //           enough at walking pace to need fresh frames every cycle)
  //
  // When MiDaS is skipped we reuse the previous depth map. The obstacle
  // priority logic on the main isolate works fine with slightly-stale depth
  // because object positions are smoothed over kDepthHistorySize=5 frames
  // anyway (priority_engine.smoothedDepth).
  int midasFrameCounter = 0;
  Float32List? cachedDepthMap;

  // [PERF] log rate-limit — emit at most once per second so logcat stays
  // readable. The values reflect the most recent cycle when the gate opens.
  DateTime lastPerfLog = DateTime.fromMillisecondsSinceEpoch(0);


  await for (final msg in receivePort) {
    if (msg == 'dispose') break;
    if (msg is! _FrameMsg) continue;

    // Per-phase timers — total / yolo / midas. Postprocess is derived
    // (total minus the two inferences) and covers YUV→RGB, letterbox,
    // image build, result emit. See [PERF] log below.
    final swTotal = Stopwatch()..start();
    int yoloMs = 0;
    int midasMs = -1; // -1 sentinel == "skipped this frame"

    try {
      // 1. YUV → RGB
      final rgb = yuv420ToRgb(
        yBytes: msg.yBytes,
        yRowStride: msg.yRowStride,
        uBytes: msg.uBytes,
        vBytes: msg.vBytes,
        uvRowStride: msg.uvRowStride,
        uvPixelStride: msg.uvPixelStride,
        width: msg.width,
        height: msg.height,
      );

      // Sanity-check RGB conversion — sample the centre 32×32 patch's mean.
      // If the whole image is ≈0 or ≈128, YUV→RGB is broken (Hypothesis G).
      double sumR = 0, sumG = 0, sumB = 0;
      const int patch = 32;
      final cy0 = (msg.height ~/ 2) - patch ~/ 2;
      final cx0 = (msg.width ~/ 2) - patch ~/ 2;
      for (int yy = 0; yy < patch; yy++) {
        for (int xx = 0; xx < patch; xx++) {
          final idx = ((cy0 + yy) * msg.width + (cx0 + xx)) * 3;
          sumR += rgb[idx];
          sumG += rgb[idx + 1];
          sumB += rgb[idx + 2];
        }
      }
      final pixCount = patch * patch;
      final meanR = sumR / pixCount;
      final meanG = sumG / pixCount;
      final meanB = sumB / pixCount;

      // 2. Build image, then LETTERBOX to each model's input size to preserve
      //    aspect ratio (matches Ultralytics' default — naive copyResize would
      //    stretch the camera frame and misalign every detection).
      final srcImage = img.Image.fromBytes(
        width: msg.width,
        height: msg.height,
        bytes: rgb.buffer,
        numChannels: 3,
        order: img.ChannelOrder.rgb,
      );
      final yoloLb = _computeLetterbox(msg.width, msg.height, yoloInputSize);
      final midasLb = _computeLetterbox(msg.width, msg.height, midasSize);
      final imYolo = _applyLetterbox(srcImage, yoloLb);
      final imMidas = _applyLetterbox(srcImage, midasLb);

      // 3. YOLO inference (py:_run_yolo) — pass camera dims so post-processing
      //    can un-letterbox detection coords back to camera pixel space.
      _YoloRun yoloRun = const _YoloRun([], 0, 0, null);
      if (yolo != null) {
        final swYolo = Stopwatch()..start();
        yoloRun = _runYolo(
          yolo,
          imYolo,
          yoloInputBuf,
          yoloLb,
          msg.width,
          msg.height,
          yoloInputSize,
          yoloAnchors,
        );
        yoloMs = swYolo.elapsedMilliseconds;
      }

      // 4. MiDaS inference (py:_run_depth) — every 2nd frame, otherwise reuse
      // the cached depth map. The first frame always runs (cache is null).
      Float32List depthMap;
      final runMidasThisFrame =
          midas != null &&
              (cachedDepthMap == null || midasFrameCounter % 2 == 0);
      if (runMidasThisFrame) {
        final swMidas = Stopwatch()..start();
        depthMap = _runMidas(midas, imMidas, midasInputBuf, midasSize);
        midasMs = swMidas.elapsedMilliseconds;
        cachedDepthMap = depthMap;
      } else {
        depthMap = cachedDepthMap ?? Float32List(midasSize * midasSize);
      }
      midasFrameCounter++;

      swTotal.stop();
      final totalMs = swTotal.elapsedMilliseconds;
      mainSendPort.send(_PipelineResult(
        boxes: yoloRun.boxes,
        depthMap: depthMap,
        cycleMs: totalMs,
        rawCount: yoloRun.rawCount,
        preNmsCount: yoloRun.preNmsCount,
        postNmsCount: yoloRun.boxes.length,
        topRaw: yoloRun.topRaw,
        frameW: msg.width,
        frameH: msg.height,
        uvPixelStride: msg.uvPixelStride,
        rgbMeanR: meanR,
        rgbMeanG: meanG,
        rgbMeanB: meanB,
        midasScale: midasLb.scale,
        midasPadX: midasLb.padX,
        midasPadY: midasLb.padY,
        midasSize: midasSize,
        yoloSize: yoloInputSize,
      ));

      // [PERF] log — rate-limited to once per second so logcat stays readable.
      // postMs is everything except inference: YUV→RGB, image build, letterbox,
      // copyResize, RGB sanity sample, result emit.
      final now = DateTime.now();
      if (now.difference(lastPerfLog).inMilliseconds >= kDiagLogIntervalMs) {
        lastPerfLog = now;
        final midasField = midasMs >= 0 ? '${midasMs}ms' : 'skipped';
        final postMs = (totalMs - yoloMs - (midasMs >= 0 ? midasMs : 0))
            .clamp(0, totalMs);
        debugPrint('[PERF] yolo=${yoloMs}ms midas=$midasField '
            'post=${postMs}ms total=${totalMs}ms  '
            '(skip=${midasFrameCounter % 2 == 1 ? "next" : "this"} frame)');
      }
    } catch (e, st) {
      debugPrint('[ISO] Frame error: $e\n$st');
      mainSendPort.send({'type': 'frame_error', 'msg': '$e\n$st'});
    }
  }

  final yoloReleased = yolo != null;
  final midasReleased = midas != null;
  yolo?.close();
  midas?.close();
  // Confirm interpreter release back to the main isolate so the mode-switch
  // teardown can log a verifiable [PIPE] disposed line before killing us.
  mainSendPort.send({
    'type': 'disposed',
    'yolo': yoloReleased,
    'midas': midasReleased,
  });
  receivePort.close();
  debugPrint('[ISO] interpreters closed '
      '(yolo=${yoloReleased ? "released" : "n/a"}, '
      'midas=${midasReleased ? "released" : "n/a"}) — isolate exiting');
}

// ─────────────────────────────────────────────────────────────────────────────
// YOLO inference + post-processing
// ─────────────────────────────────────────────────────────────────────────────

// YOLO inference result, including diagnostics for the panel.
class _YoloRun {
  final List<Map<String, dynamic>> boxes; // after NMS + threshold
  final int rawCount;     // anchors with any class score >= 0.10 (diag)
  final int preNmsCount;  // anchors above the active min-conf threshold
  final Map<String, dynamic>? topRaw; // highest-scoring anchor, raw values
  const _YoloRun(this.boxes, this.rawCount, this.preNmsCount, this.topRaw);
}

// Top-level so we can log first-N frame samples without a class.
int _yoloFrameDebugCounter = 0;

_YoloRun _runYolo(
  Interpreter interp,
  img.Image imYolo,
  List<List<List<List<double>>>> inputBuf, // [1][size][size][3] NHWC, reused
  _Letterbox lb,                            // letterbox params to un-map outputs
  int imgW,                                 // original camera width
  int imgH,                                 // original camera height
  int size,                                 // YOLO input size: 416 or 640
  int anchorCount,                          // 3549 @416, 8400 @640 (from tensor)
) {
  // ── Fill the pre-allocated NHWC input in place ────────────────────────────
  // CRITICAL: input MUST be a nested list whose .shape matches the tensor's
  // declared shape exactly. tflite_flutter's runInference checks
  // getInputShapeIfDifferent() before invoke — if the shapes differ it calls
  // resizeInputTensor() which sets _allocated=false, then allocateTensors()
  // and that fails. A nested [1][size][size][3] passes cleanly.
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final p = imYolo.getPixel(x, y);
      inputBuf[0][y][x][0] = p.r.toDouble() / 255.0;
      inputBuf[0][y][x][1] = p.g.toDouble() / 255.0;
      inputBuf[0][y][x][2] = p.b.toDouble() / 255.0;
    }
  }

  // First-frame sanity-check log: prove the input vector has actual data and
  // not zeros (would indicate broken YUV→RGB or image conversion).
  if (_yoloFrameDebugCounter < 3) {
    final mid = size ~/ 2;
    final c = inputBuf[0][mid][mid];
    debugPrint('[YOLO] frame $_yoloFrameDebugCounter (size=${size}x$size): '
        'centre pixel = [${c[0].toStringAsFixed(3)}, '
        '${c[1].toStringAsFixed(3)}, ${c[2].toStringAsFixed(3)}]');
    _yoloFrameDebugCounter++;
  }

  // ── Output shape: [1, 84, anchorCount] ────────────────────────────────────
  // anchorCount comes from the interpreter's output tensor shape at load time
  // (8400 for 640 input, 3549 for 416 input). DO NOT hardcode — the count
  // changes with input size because YOLOv8 sums three feature-map grids:
  //   (size/8)² + (size/16)² + (size/32)²
  //   = (52² + 26² + 13²) = 3549   for size=416
  //   = (80² + 40² + 20²) = 8400   for size=640
  //   [0:4]  = cx, cy, w, h  (Ultralytics: NORMALIZED [0,1] for tflite export)
  //   [4:84] = 80 COCO class scores (sigmoid already applied)
  final output = List<List<List<double>>>.generate(
    1,
    (_) => List<List<double>>.generate(
      84,
      (_) => List<double>.filled(anchorCount, 0.0),
    ),
  );
  interp.run(inputBuf, output);

  final raw = output[0]; // [84][anchorCount]

  // Active minimum confidence used for the filtered (visible) boxes.
  // Drop to kDebugMinConf in debug mode so we still see something when the
  // model is uncertain.
  const double diagMinConf = 0.10;

  final candidates = <Map<String, dynamic>>[];
  int rawCount = 0;
  int preNmsCount = 0;
  Map<String, dynamic>? topRaw;
  double topRawScore = -1;

  for (int a = 0; a < anchorCount; a++) {
    // Find max class score across rows 4..83
    double maxScore = 0;
    int maxCls = 0;
    for (int c = 4; c < 84; c++) {
      final s = raw[c][a];
      if (s > maxScore) {
        maxScore = s;
        maxCls = c - 4;
      }
    }

    if (maxScore >= diagMinConf) rawCount++;

    // Record the top-scoring anchor across the whole image — for diagnostics.
    if (maxScore > topRawScore) {
      topRawScore = maxScore;
      topRaw = {
        'label': maxCls < _kCoco80.length ? _kCoco80[maxCls] : 'unknown',
        'conf': maxScore,
        'rawCx': raw[0][a],
        'rawCy': raw[1][a],
        'rawW': raw[2][a],
        'rawH': raw[3][a],
      };
    }

    final label = maxCls < _kCoco80.length ? _kCoco80[maxCls] : 'unknown';

    // ── Normalize box to [0,1] of YOLO 640 space FIRST ─────────────────────
    // We need the area to apply the distance-aware priority threshold below.
    // Ultralytics YOLOv8 TFLite export emits normalized [0,1] cx,cy,w,h.
    // Some custom exports emit pixel space [0,640]; auto-detect by magnitude.
    var cxY = raw[0][a];
    var cyY = raw[1][a];
    var bwY = raw[2][a];
    var bhY = raw[3][a];
    if (cxY > 1.5 || cyY > 1.5 || bwY > 1.5 || bhY > 1.5) {
      final s = size.toDouble();
      cxY /= s; cyY /= s; bwY /= s; bhY /= s;
    }

    // ── Distance-aware confidence filter ──────────────────────────────────
    // For person/car (the two classes a blind user *must* hear about):
    //   - Small/far boxes are accepted at 0.40 — far obstacles need early
    //     warning even when the model is uncertain.
    //   - Big/near boxes need 0.55 — filters out the giant phantom person/car
    //     bounding boxes that occasionally span a whole indoor frame.
    // Everything else uses the single kMinConfGeneral cutoff.
    final isPriority = (label == 'person' || label == 'car');
    final boxAreaYolo = bwY * bhY; // normalized [0,1] area in YOLO space
    final double minConf;
    if (isPriority) {
      minConf = boxAreaYolo > kAreaPriorityNearThreshold
          ? kMinConfPriorityNear
          : kMinConfPriorityFar;
    } else {
      minConf = kMinConfGeneral;
    }
    if (maxScore < minConf) continue;
    preNmsCount++;

    // YOLO-space normalized corners (for the cyan debug overlay).
    final yX1 = (cxY - bwY / 2).clamp(0.0, 1.0);
    final yY1 = (cyY - bhY / 2).clamp(0.0, 1.0);
    final yX2 = (cxY + bwY / 2).clamp(0.0, 1.0);
    final yY2 = (cyY + bhY / 2).clamp(0.0, 1.0);

    // ── Un-letterbox: YOLO size-px → camera pixel → camera normalized ──────
    // Box corners in YOLO pixel space (size is 416 or 640 depending on runtime).
    final yX1px = yX1 * size.toDouble();
    final yY1px = yY1 * size.toDouble();
    final yX2px = yX2 * size.toDouble();
    final yY2px = yY2 * size.toDouble();

    // Subtract pad, divide by scale (the inverse of letterbox preprocessing).
    final cX1 = lb.unmapX(yX1px) / imgW;
    final cY1 = lb.unmapY(yY1px) / imgH;
    final cX2 = lb.unmapX(yX2px) / imgW;
    final cY2 = lb.unmapY(yY2px) / imgH;

    candidates.add({
      'label': label,
      'conf': maxScore,
      // Camera-space normalized [0,1] — what the overlay + depth sampling use.
      'x1': cX1.clamp(0.0, 1.0),
      'y1': cY1.clamp(0.0, 1.0),
      'x2': cX2.clamp(0.0, 1.0),
      'y2': cY2.clamp(0.0, 1.0),
      // YOLO-space normalized [0,1] — kept around for the cyan A/B debug overlay.
      'yoloX1': yX1,
      'yoloY1': yY1,
      'yoloX2': yX2,
      'yoloY2': yY2,
    });
  }

  return _YoloRun(nonMaxSuppression(candidates), rawCount, preNmsCount, topRaw);
}

// ─────────────────────────────────────────────────────────────────────────────
// MiDaS inference
// ─────────────────────────────────────────────────────────────────────────────

// ImageNet normalization stats (required by MiDaS_small — py:midas_transform)
const _midasMean = [0.485, 0.456, 0.406];
const _midasStd = [0.229, 0.224, 0.225];

Float32List _runMidas(
  Interpreter interp,
  img.Image imMidas,
  List<List<List<List<double>>>> inputBuf, // [1][3][size][size] NCHW, reused
  int size,                                 // typically kMidasInputSize (192)
) {
  // ── Fill the pre-allocated NCHW input in place ────────────────────────────
  // MiDaS_small TFLite preserves the PyTorch NCHW layout: input tensor shape
  // is [1, 3, size, size]. ImageNet normalization is applied.
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final p = imMidas.getPixel(x, y);
      inputBuf[0][0][y][x] =
          (p.r.toDouble() / 255.0 - _midasMean[0]) / _midasStd[0];
      inputBuf[0][1][y][x] =
          (p.g.toDouble() / 255.0 - _midasMean[1]) / _midasStd[1];
      inputBuf[0][2][y][x] =
          (p.b.toDouble() / 255.0 - _midasMean[2]) / _midasStd[2];
    }
  }

  // Output shape: [1, size, size] — inverse depth (higher = closer).
  final output = List<List<List<double>>>.generate(
    1,
    (_) => List<List<double>>.generate(
      size,
      (_) => List<double>.filled(size, 0.0),
    ),
  );
  interp.run(inputBuf, output);

  // Flatten + normalize to [0,1] — py:1825-1826
  final flat = Float32List(size * size);
  double minD = double.infinity, maxD = double.negativeInfinity;
  for (int r = 0; r < size; r++) {
    for (int c = 0; c < size; c++) {
      final v = output[0][r][c];
      flat[r * size + c] = v;
      if (v < minD) minD = v;
      if (v > maxD) maxD = v;
    }
  }
  final range = maxD - minD + 1e-6;
  for (int j = 0; j < flat.length; j++) {
    flat[j] = (flat[j] - minD) / range;
  }
  return flat;
}

// ─────────────────────────────────────────────────────────────────────────────
// DetectionPipelineService — runs on main isolate
// ─────────────────────────────────────────────────────────────────────────────

// Extends ChangeNotifier so the debug panel can listen and rebuild on every
// cycle without polling. notifyListeners() is called from _handleResult and
// when a frame error arrives.
class DetectionPipelineService extends ChangeNotifier {
  Isolate? _isolate;
  SendPort? _isolateSendPort;
  ReceivePort? _fromIsolate;

  // Frame skipping — py:1671-1675, 1956-1970
  int _frameCount = 0;
  int _adaptiveSkip = kFrameSkipStart;
  int _slowCycles = 0;

  // Busy flag — prevents concurrent frame dispatch
  bool _busy = false;

  // Smoothing state — owned on main isolate (receives per-frame results)
  // py:126-131, 1912-1916
  final _depthHistory = <String, List<double>>{};
  final _decisionHistory = <String>[];

  // Approach detection state — py:1901-1910
  Obstacle? _snapshotObstacle;
  DateTime _lastSnapshotTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastBoxLogTime = DateTime.fromMillisecondsSinceEpoch(0);

  bool _modelsReady = false;
  bool get modelsReady => _modelsReady;

  String? _modelError; // non-null if models failed to load
  String? get modelError => _modelError;

  String? _yoloDelegate; // 'GPU' | 'CPU' | null
  String? _midasDelegate;
  String? get yoloDelegate => _yoloDelegate;
  String? get midasDelegate => _midasDelegate;

  // Clockwise rotation applied to detection coords on output (sensor → display).
  // Set by the provider from CameraDescription.sensorOrientation at attach time.
  int rotationDeg = 90;

  // ── Live diagnostics ────────────────────────────────────────────────────
  // All public so the debug panel + clipboard dump can read everything.
  int frameSkip = kFrameSkipStart;
  int lastCycleMs = 0;
  int lastRawCount = 0;
  int lastPreNmsCount = 0;
  int lastPostNmsCount = 0;
  Map<String, dynamic>? lastTopRaw;
  int cameraW = 0, cameraH = 0;
  int uvPixelStride = 0;
  double rgbMeanR = 0, rgbMeanG = 0, rgbMeanB = 0;
  String? lastFrameError;
  int framesIn = 0;       // frames received from camera since start
  int framesProcessed = 0; // results returned from isolate since start
  DateTime _streamStart = DateTime.now();
  double get framesInPerSec =>
      framesIn / (DateTime.now().difference(_streamStart).inMilliseconds / 1000)
          .clamp(0.001, 1e9);
  double get framesProcessedPerSec =>
      framesProcessed /
      (DateTime.now().difference(_streamStart).inMilliseconds / 1000)
          .clamp(0.001, 1e9);

  // Ring buffer of last 20 cycle stats — for clipboard dump.
  final List<Map<String, Object?>> cycleHistory = [];
  static const int _historyCap = 20;

  // Tensor info captured at load — sent from isolate via 'ready'.
  String? yoloInputShape, yoloOutputShape;
  String? midasInputShape, midasOutputShape;

  bool _streamAttached = false;
  bool get streamAttached => _streamAttached;

  Function(DetectionState)? _onResult;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    // Log the risk-weights map once at startup so we can audit class coverage
    // from logcat. The map drives calcPriority() and therefore the announcer's
    // ranking of which obstacle to speak about.
    debugPrint('[PRIORITY] risk weights: $kRiskWeights');

    // Load .tflite asset bytes on the MAIN isolate. Background isolates have
    // no ServicesBinding, so rootBundle.load() — which Interpreter.fromAsset()
    // calls internally — throws "Binding has not yet been initialized" there.
    // The bytes are then handed to the worker via Isolate.spawn args and used
    // with Interpreter.fromBuffer (synchronous, no asset loader needed).
    Uint8List? yoloBytes;
    Uint8List? midasBytes;
    final errs = <String>[];
    try {
      final d = await rootBundle.load('assets/models/yolov8n_float16.tflite');
      yoloBytes = d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
      debugPrint('[PIPE] Loaded YOLO bytes: ${yoloBytes.length} B');
    } catch (e) {
      errs.add('YOLO asset: $e');
      debugPrint('[PIPE] YOLO asset load failed: $e');
    }
    try {
      final d = await rootBundle.load('assets/models/midas_small.tflite');
      midasBytes = d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
      debugPrint('[PIPE] Loaded MiDaS bytes: ${midasBytes.length} B');
    } catch (e) {
      errs.add('MiDaS asset: $e');
      debugPrint('[PIPE] MiDaS asset load failed: $e');
    }
    if (errs.isNotEmpty) _modelError = errs.join('; ');

    _fromIsolate = ReceivePort();
    _isolate = await Isolate.spawn(
      _pipelineIsolateEntry,
      [_fromIsolate!.sendPort, yoloBytes, midasBytes],
      debugName: 'detection_pipeline',
    );

    final completer = Completer<void>();

    _fromIsolate!.listen((msg) {
      if (msg is SendPort) {
        // Handshake — isolate sent us its listen port
        _isolateSendPort = msg;
      } else if (msg is Map) {
        if (msg['type'] == 'ready' && !completer.isCompleted) {
          _yoloDelegate = msg['yoloDelegate'] as String?;
          _midasDelegate = msg['midasDelegate'] as String?;
          yoloInputShape = msg['yoloInputShape'] as String?;
          yoloOutputShape = msg['yoloOutputShape'] as String?;
          midasInputShape = msg['midasInputShape'] as String?;
          midasOutputShape = msg['midasOutputShape'] as String?;
          _modelsReady = (_yoloDelegate != null && _yoloDelegate != 'none') ||
              (_midasDelegate != null && _midasDelegate != 'none');
          debugPrint('[PIPE] Ready — yolo=$_yoloDelegate midas=$_midasDelegate');
          completer.complete();
        } else if (msg['type'] == 'error') {
          _modelError = msg['msg'] as String?;
          debugPrint('[PIPE] Model error: $_modelError');
          if (!completer.isCompleted) completer.complete();
        } else if (msg['type'] == 'frame_error') {
          _busy = false;
          lastFrameError = msg['msg'] as String?;
          debugPrint('[PIPE] Frame error: $lastFrameError');
          notifyListeners();
        } else if (msg['type'] == 'disposed') {
          if (_disposeCompleter != null &&
              !_disposeCompleter!.isCompleted) {
            _disposeCompleter!.complete(Map<String, dynamic>.from(msg));
          }
        }
      } else if (msg is _PipelineResult) {
        _busy = false;
        _handleResult(msg);
      }
    });

    await completer.future;
  }

  void attachCamera(
    CameraController controller,
    void Function(DetectionState) onResult,
  ) {
    _onResult = onResult;
    _streamStart = DateTime.now();
    framesIn = 0;
    framesProcessed = 0;
    controller.startImageStream(_onFrame);
    _streamAttached = true;
    debugPrint('[PIPE] Camera stream attached, skip=$_adaptiveSkip');
  }

  void detachCamera(CameraController controller) {
    controller.stopImageStream();
    _streamAttached = false;
    _onResult = null;
  }

  Completer<Map<String, dynamic>>? _disposeCompleter;
  bool _disposed = false;

  /// Fully release the pipeline: ask the isolate to close both interpreters,
  /// wait (briefly) for its confirmation, then kill the isolate and tear
  /// down ports. Idempotent. Used by the indoor↔outdoor mode switch so the
  /// YOLO + MiDaS interpreters actually free GPU/CPU memory before the other
  /// mode starts. The matching Riverpod provider invalidation is done by the
  /// caller (AppMode switch) since this class has no Ref.
  Future<void> disposePipeline() async {
    if (_disposed) return;
    _disposed = true;

    // Detach the stream callback first so no late frame races teardown.
    _onResult = null;
    _busy = false;
    _streamAttached = false;

    var yoloReleased = false;
    var midasReleased = false;

    if (_isolateSendPort != null) {
      _disposeCompleter = Completer<Map<String, dynamic>>();
      _isolateSendPort!.send('dispose');
      try {
        final ack = await _disposeCompleter!.future
            .timeout(const Duration(milliseconds: 1500));
        yoloReleased = ack['yolo'] == true;
        midasReleased = ack['midas'] == true;
      } on TimeoutException {
        debugPrint('[PIPE] no dispose confirmation in 1.5s — forcing kill');
      }
      _disposeCompleter = null;
    }

    _isolate?.kill(priority: Isolate.immediate);
    _fromIsolate?.close();
    _isolate = null;
    _fromIsolate = null;
    _isolateSendPort = null;

    debugPrint('[PIPE] disposed ('
        'yolo ${yoloReleased ? "released" : "not loaded/forced"}, '
        'midas ${midasReleased ? "released" : "not loaded/forced"}, '
        'isolate killed)');

    dispose(); // ChangeNotifier.dispose
  }

  /// Synchronous best-effort teardown (e.g. Riverpod onDispose). Prefer
  /// disposePipeline() where you can await full release + the log line.
  void stop() {
    // ignore: discarded_futures
    disposePipeline();
  }

  // ── Diagnostic dump — formatted for clipboard / chat paste ─────────────────
  String dumpDiagnostics() {
    final b = StringBuffer();
    b.writeln('=== Smart Nav diagnostics ===');
    b.writeln('time: ${DateTime.now().toIso8601String()}');
    b.writeln('');
    b.writeln('── Models ──');
    b.writeln('  YOLO delegate:  $_yoloDelegate');
    b.writeln('  YOLO input:     $yoloInputShape');
    b.writeln('  YOLO output:    $yoloOutputShape');
    b.writeln('  MiDaS delegate: $_midasDelegate');
    b.writeln('  MiDaS input:    $midasInputShape');
    b.writeln('  MiDaS output:   $midasOutputShape');
    if (_modelError != null) b.writeln('  Model error:    $_modelError');
    b.writeln('');
    b.writeln('── Camera ──');
    b.writeln('  Resolution:     $cameraW x $cameraH');
    b.writeln('  uvPixelStride:  $uvPixelStride (1=planar, 2=NV12)');
    b.writeln('  Stream:         ${_streamAttached ? 'ATTACHED' : 'detached'}');
    b.writeln('  Frames in:      $framesIn (${framesInPerSec.toStringAsFixed(1)} fps)');
    b.writeln('  Frames out:     $framesProcessed '
        '(${framesProcessedPerSec.toStringAsFixed(1)} fps)');
    b.writeln('  Frame skip:     $frameSkip');
    b.writeln('');
    b.writeln('── Last cycle ──');
    b.writeln('  Duration:       $lastCycleMs ms');
    b.writeln('  Raw  (>0.10):   $lastRawCount  / 8400 anchors');
    b.writeln('  After thresh:   $lastPreNmsCount');
    b.writeln('  After NMS:      $lastPostNmsCount');
    if (lastTopRaw != null) {
      final t = lastTopRaw!;
      b.writeln('  Top anchor:     ${t['label']} '
          'conf=${(t['conf'] as double).toStringAsFixed(3)}');
      b.writeln('  Raw coords:     '
          'cx=${(t['rawCx'] as double).toStringAsFixed(3)} '
          'cy=${(t['rawCy'] as double).toStringAsFixed(3)} '
          'w=${(t['rawW'] as double).toStringAsFixed(3)} '
          'h=${(t['rawH'] as double).toStringAsFixed(3)}');
    } else {
      b.writeln('  Top anchor:     (no anchors above 0)');
    }
    b.writeln('  RGB mean (ctr): r=${rgbMeanR.toStringAsFixed(1)} '
        'g=${rgbMeanG.toStringAsFixed(1)} b=${rgbMeanB.toStringAsFixed(1)}');
    if (lastFrameError != null) {
      b.writeln('');
      b.writeln('── Last frame error ──');
      // Trim to first 800 chars to keep clipboard manageable
      final e = lastFrameError!;
      b.writeln(e.length > 800 ? '${e.substring(0, 800)}...(trimmed)' : e);
    }
    b.writeln('');
    b.writeln('── Cycle history (last ${cycleHistory.length}) ──');
    for (final c in cycleHistory.reversed) {
      final top = c['top'] as Map?;
      final topStr = top == null
          ? '(none)'
          : '${top['label']} ${(top['conf'] as double).toStringAsFixed(2)}';
      b.writeln('  ${c['t']}  ${c['ms']}ms  '
          'raw=${c['raw']}  pre=${c['preNms']}  post=${c['postNms']}  top=$topStr');
    }
    return b.toString();
  }

  // ── Frame dispatch ──────────────────────────────────────────────────────────

  // py:1757-1758 — adaptive frame skip
  void _onFrame(CameraImage image) {
    framesIn++;

    // Populate diagnostic fields from the first CameraImage that arrives.
    // This way the panel shows real camera dimensions even if every frame
    // later fails inference. Updates are idempotent — only fire once.
    if (cameraW == 0) {
      cameraW = image.width;
      cameraH = image.height;
      uvPixelStride = image.planes.length > 1
          ? (image.planes[1].bytesPerPixel ?? 1)
          : 1;
      debugPrint('[PIPE] First camera frame: '
          '$cameraW x $cameraH, uvPxStride=$uvPixelStride');
      notifyListeners(); // refresh the debug panel
    }

    _frameCount++;
    if (_frameCount % _adaptiveSkip != 0) return;
    if (_busy || _isolateSendPort == null) return;
    _busy = true;

    // Copy plane bytes immediately — CameraImage must not be held past this call
    final p0 = image.planes[0];
    final p1 = image.planes[1];
    final p2 = image.planes[2];

    _isolateSendPort!.send(_FrameMsg(
      yBytes: Uint8List.fromList(p0.bytes),
      uBytes: Uint8List.fromList(p1.bytes),
      vBytes: Uint8List.fromList(p2.bytes),
      yRowStride: p0.bytesPerRow,
      uvRowStride: p1.bytesPerRow,
      uvPixelStride: p1.bytesPerPixel ?? 1,
      width: image.width,
      height: image.height,
    ));
  }

  // ── Result processing — runs on main isolate ────────────────────────────────

  void _handleResult(_PipelineResult result) {
    framesProcessed++;
    final cycleMs = result.cycleMs;

    // ── Update live diagnostics ────────────────────────────────────────────
    lastCycleMs = cycleMs;
    lastRawCount = result.rawCount;
    lastPreNmsCount = result.preNmsCount;
    lastPostNmsCount = result.postNmsCount;
    lastTopRaw = result.topRaw;
    cameraW = result.frameW;
    cameraH = result.frameH;
    uvPixelStride = result.uvPixelStride;
    rgbMeanR = result.rgbMeanR;
    rgbMeanG = result.rgbMeanG;
    rgbMeanB = result.rgbMeanB;

    cycleHistory.add({
      't': DateTime.now().toIso8601String(),
      'ms': cycleMs,
      'raw': result.rawCount,
      'preNms': result.preNmsCount,
      'postNms': result.postNmsCount,
      'top': result.topRaw,
    });
    if (cycleHistory.length > _historyCap) cycleHistory.removeAt(0);

    // Adaptive skip adjustment — py:1956-1970
    if (cycleMs > kCycleSlowMs) {
      _slowCycles++;
      if (_slowCycles >= 2 && _adaptiveSkip < 9) {
        _adaptiveSkip++;
        _slowCycles = 0;
        debugPrint('[PIPE] Slow ($cycleMs ms) → skip=$_adaptiveSkip');
      }
    } else if (cycleMs < kCycleFastMs) {
      _slowCycles = (_slowCycles - 1).clamp(0, 99);
      if (_slowCycles == 0 && _adaptiveSkip > kFrameSkipStart) {
        _adaptiveSkip--;
        debugPrint('[PIPE] Fast ($cycleMs ms) → skip=$_adaptiveSkip');
      }
    }
    frameSkip = _adaptiveSkip;

    if (_onResult == null) return;

    final boxes = result.boxes;
    final depthFlat = result.depthMap;
    final now = DateTime.now();

    // Build structured detections with depth, position, smoothing
    // py:1860-1891
    final structured = <Map<String, dynamic>>[];
    final imgW = result.frameW;
    final imgH = result.frameH;
    final mScale = result.midasScale;
    final mPadX = result.midasPadX;
    final mPadY = result.midasPadY;
    final midasSize = result.midasSize;

    for (final box in boxes) {
      final label = box['label'] as String;
      final conf = box['conf'] as double;
      // SENSOR-SPACE normalized (post un-letterbox, pre-rotation).
      final sX1 = box['x1'] as double;
      final sY1 = box['y1'] as double;
      final sX2 = box['x2'] as double;
      final sY2 = box['y2'] as double;

      // ── 1. Sample MiDaS depth FIRST, using sensor-space coords ───────────
      // The depth map is in sensor orientation (we feed letterboxed sensor
      // pixels to MiDaS), so depth lookup must NOT be rotated.
      final cxSensor = (sX1 + sX2) / 2;
      final cySensor = (sY1 + sY2) / 2;
      double cxMidasNorm = cxSensor;
      double cyMidasNorm = cySensor;
      if (mScale > 0 && imgW > 0 && imgH > 0 && midasSize > 0) {
        final xPxLb = cxSensor * imgW * mScale + mPadX;
        final yPxLb = cySensor * imgH * mScale + mPadY;
        cxMidasNorm = (xPxLb / midasSize).clamp(0.0, 1.0);
        cyMidasNorm = (yPxLb / midasSize).clamp(0.0, 1.0);
      }
      final rawDepth = sampleDepthPatch(
        depthFlat,
        cxMidasNorm,
        cyMidasNorm,
        mapSize: midasSize > 0 ? midasSize : 256,
      );

      // ── 2. Rotate sensor coords → display coords ──────────────────────────
      // After this step, x/y is what the user sees (overlay, position bands,
      // speech announcements are all display-oriented).
      final rot = rotateBoxNorm(sX1, sY1, sX2, sY2, rotationDeg);
      final dX1 = rot.x1, dY1 = rot.y1, dX2 = rot.x2, dY2 = rot.y2;

      // ── 3. Position band uses DISPLAY-space cx (user-perceived left/right)
      final cxDisplay = (dX1 + dX2) / 2;
      final position = positionBand(cxDisplay);

      final key = '$label:$position';
      final smoothDepth = smoothedDepth(_depthHistory, key, rawDepth);
      final dl = distLabel(smoothDepth);

      final priority = calcPriority(
        label: label,
        position: position,
        distance: smoothDepth,
      );

      structured.add({
        'label': label,
        'conf': conf,
        // Display-oriented coords — consumed by overlay + announcer.
        'x1': dX1, 'y1': dY1, 'x2': dX2, 'y2': dY2,
        // Pre-rotation sensor coords — kept for the [BOX] log only.
        'sX1': sX1, 'sY1': sY1, 'sX2': sX2, 'sY2': sY2,
        // YOLO-space (pre-letterbox + pre-rotation) — for the cyan A/B overlay.
        'yoloX1': box['yoloX1'] as double? ?? 0,
        'yoloY1': box['yoloY1'] as double? ?? 0,
        'yoloX2': box['yoloX2'] as double? ?? 0,
        'yoloY2': box['yoloY2'] as double? ?? 0,
        'position': position,
        'distLabel': dl,
        'distance': smoothDepth,
        'priority': priority,
      });
    }

    // Highest priority obstacle
    Map<String, dynamic>? mainBox;
    if (structured.isNotEmpty) {
      mainBox = structured.reduce(
        (a, b) => (a['priority'] as double) >= (b['priority'] as double) ? a : b,
      );
    }

    // ── TEMP DEBUG: trace the top detection's coordinate chain. ──────────
    // Rate-limited to once per second so logcat stays usable.
    // Strip this block once the alignment is confirmed.
    if (mainBox != null &&
        now.difference(_lastBoxLogTime).inMilliseconds >= kDiagLogIntervalMs) {
      _lastBoxLogTime = now;
      final yoloTarget = result.yoloSize.toDouble();
      final yoloScale = (imgW <= 0 || imgH <= 0)
          ? 0.0
          : math.min(yoloTarget / imgW, yoloTarget / imgH);
      final yoloPadX = (yoloTarget - imgW * yoloScale) / 2.0;
      final yoloPadY = (yoloTarget - imgH * yoloScale) / 2.0;

      double f(Object? v) => v is double ? v : 0.0;
      String fmt(double v, [int p = 3]) => v.toStringAsFixed(p);

      debugPrint('[BOX] top=${mainBox['label']} '
          'conf=${fmt(f(mainBox['conf']), 2)} '
          'rot=$rotationDeg deg  '
          'img=${imgW}x$imgH '
          'yoloLB(scale=${fmt(yoloScale)} '
            'padX=${fmt(yoloPadX, 1)} padY=${fmt(yoloPadY, 1)})');
      debugPrint('[BOX]   yolo=('
          '${fmt(f(mainBox['yoloX1']))}, '
          '${fmt(f(mainBox['yoloY1']))})-('
          '${fmt(f(mainBox['yoloX2']))}, '
          '${fmt(f(mainBox['yoloY2']))})  '
          'w=${fmt(f(mainBox['yoloX2']) - f(mainBox['yoloX1']))} '
          'h=${fmt(f(mainBox['yoloY2']) - f(mainBox['yoloY1']))}');
      debugPrint('[BOX]   sensor=('
          '${fmt(f(mainBox['sX1']))}, '
          '${fmt(f(mainBox['sY1']))})-('
          '${fmt(f(mainBox['sX2']))}, '
          '${fmt(f(mainBox['sY2']))})  '
          'w=${fmt(f(mainBox['sX2']) - f(mainBox['sX1']))} '
          'h=${fmt(f(mainBox['sY2']) - f(mainBox['sY1']))}');
      debugPrint('[BOX]   display=('
          '${fmt(f(mainBox['x1']))}, '
          '${fmt(f(mainBox['y1']))})-('
          '${fmt(f(mainBox['x2']))}, '
          '${fmt(f(mainBox['y2']))})  '
          'w=${fmt(f(mainBox['x2']) - f(mainBox['x1']))} '
          'h=${fmt(f(mainBox['y2']) - f(mainBox['y1']))}');
      debugPrint('[BOX]   midasLB(scale=${fmt(mScale)} '
          'padX=${fmt(mPadX, 1)} padY=${fmt(mPadY, 1)})');
    }

    // Approach detection — py:1901-1909 snapshot every 2 s
    String? approachWarn;
    if (mainBox != null && _snapshotObstacle != null) {
      final snap = _snapshotObstacle!;
      if (snap.label == mainBox['label']) {
        final delta = (mainBox['distance'] as double) - snap.distance;
        if (delta > kApproachDelta) {
          approachWarn = 'Warning! ${snap.label} is getting closer!';
        } else if (delta < -kApproachDelta) {
          approachWarn = '${snap.label} is moving away.';
        }
      }
    }
    if (mainBox != null &&
        now.difference(_lastSnapshotTime).inSeconds >= kSnapshotIntervalS) {
      _snapshotObstacle = Obstacle(
        label: mainBox['label'] as String,
        distance: mainBox['distance'] as double,
        distLabel: mainBox['distLabel'] as String,
        position: mainBox['position'] as String,
      );
      _lastSnapshotTime = now;
    }

    // Smoothed decision — py:1912-1916
    final rawDecision = makeDecision(structured);
    final finalDecision = smoothedDecision(_decisionHistory, rawDecision);

    // Build Detection list for the overlay
    final detectionList = structured.map((d) => Detection(
          label: d['label'] as String,
          x1: d['x1'] as double,
          y1: d['y1'] as double,
          x2: d['x2'] as double,
          y2: d['y2'] as double,
          yoloX1: d['yoloX1'] as double,
          yoloY1: d['yoloY1'] as double,
          yoloX2: d['yoloX2'] as double,
          yoloY2: d['yoloY2'] as double,
          confidence: d['conf'] as double,
          distLabel: d['distLabel'] as String,
          position: d['position'] as String,
          priority: d['priority'] as double,
        )).toList();

    final mainObstacle = mainBox == null
        ? null
        : Obstacle(
            label: mainBox['label'] as String,
            distance: mainBox['distance'] as double,
            distLabel: mainBox['distLabel'] as String,
            position: mainBox['position'] as String,
          );

    // After rotation, the displayed image dims are the swap of the sensor's
    // raw dims for 90°/270°. The overlay uses these for BoxFit.cover math —
    // it must see the display AR, not the sensor AR.
    final swap = isQuarterTurn(rotationDeg);
    final outImgW = swap ? imgH : imgW;
    final outImgH = swap ? imgW : imgH;

    _onResult!(DetectionState(
      detections: detectionList,
      mainObstacle: mainObstacle,
      decision: finalDecision,
      approachWarning: approachWarn,
      imgW: outImgW,
      imgH: outImgH,
      rotationDeg: rotationDeg,
    ));

    // Notify debug panel listeners that diagnostics changed.
    notifyListeners();
  }
}
