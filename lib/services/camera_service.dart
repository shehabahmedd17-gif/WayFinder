import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

// Wraps CameraController lifecycle.
// ML pipeline (Step 2) will call startImageStream() on the exposed controller.
class CameraService {
  CameraController? _controller;
  // The clockwise rotation (in degrees) needed to map a sensor-space coord
  // onto the display. Captured from CameraDescription at init time; default
  // 90° matches the back camera on essentially every Android phone.
  int _sensorOrientation = 90;

  CameraController? get controller => _controller;
  bool get isInitialized => _controller?.value.isInitialized ?? false;
  int get sensorOrientation => _sensorOrientation;

  Future<void> initialize() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      throw Exception('Camera permission denied');
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) throw Exception('No cameras available on device');

    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _sensorOrientation = camera.sensorOrientation;

    // medium (720×480, 3:2) is preferred over high (1280×720, 16:9) because:
    // 1. YOLO downscales to 640×640 internally — source resolution above 720p
    //    doesn't help accuracy, just costs more memory + conversion time.
    // 2. Lower res = faster YUV→RGB conversion on the isolate
    //    (~40% less per-frame copy work; YUV at 720×480 is ~520 kB vs 1.4 MB
    //    at 1280×720).
    // 3. 3:2 aspect ratio crops less under BoxFit.cover on portrait phones,
    //    avoiding the visible zoom-in artifact we hit when this was set to
    //    high — the wider 16:9 stream lost most of its width to centre-crop.
    _controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420, // required for ML pipeline
    );

    await _controller!.initialize();

    // Lock to portrait so frame geometry matches model expectations.
    await _controller!.lockCaptureOrientation();

    debugPrint('[CAM] Initialized: '
        '${_controller!.value.previewSize?.width.toInt()}×'
        '${_controller!.value.previewSize?.height.toInt()}  '
        'sensorOrientation=$_sensorOrientation°');
  }

  // Hard stop: halt the image stream AND release the controller so the camera
  // sensor + GPU/CPU work fully stop in outdoor mode. py: cap.release().
  Future<void> stop() async {
    final c = _controller;
    _controller = null;
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) {
        await c.stopImageStream();
      }
    } catch (e) {
      debugPrint('[CAM] stopImageStream error (ignored): $e');
    }
    try {
      await c.dispose();
      debugPrint('[CAM] camera controller closed');
    } catch (e) {
      debugPrint('[CAM] controller dispose error (ignored): $e');
    }
    debugPrint('[CAM] disposed');
  }

  Future<void> dispose() async => stop();
}

// Singleton service — shared across providers.
final cameraServiceProvider = Provider<CameraService>((ref) {
  final service = CameraService();
  ref.onDispose(() {
    // ignore: discarded_futures
    service.stop();
  });
  return service;
});

// AsyncNotifier holding the CameraController. EXPLICIT lifecycle: build()
// does NOT auto-start and does NOT watch appModeProvider (watching it caused a
// CircularDependencyError when AppStateNotifier read the pipeline during a
// mode flip). AppStateNotifier drives start()/stop() directly so the
// indoor↔outdoor sequence is linear and debuggable.
class CameraInitNotifier extends AsyncNotifier<CameraController?> {
  bool _busy = false;

  @override
  Future<CameraController?> build() async => null; // idle until start()

  /// Initialize the camera. Idempotent; never rethrows.
  Future<void> start() async {
    final svc = ref.read(cameraServiceProvider);
    if (svc.isInitialized) {
      state = AsyncData(svc.controller);
      return;
    }
    if (_busy) return;
    _busy = true;
    state = const AsyncValue.loading();
    try {
      await svc.initialize();
      state = AsyncData(svc.controller);
    } catch (e, st) {
      debugPrint('[CAM] start failed: $e');
      state = AsyncError(e, st);
    } finally {
      _busy = false;
    }
  }

  /// Release the controller. Idempotent; never rethrows.
  Future<void> stop() async {
    try {
      await ref.read(cameraServiceProvider).stop();
    } catch (e) {
      debugPrint('[CAM] stop error (ignored): $e');
    }
    state = const AsyncData(null);
  }
}

final cameraProvider =
    AsyncNotifierProvider<CameraInitNotifier, CameraController?>(
  CameraInitNotifier.new,
);

// Clockwise rotation (degrees) needed to map sensor-space coords → display
// orientation. Read from CameraDescription.sensorOrientation by the service.
// Watched by the pipeline so it can rotate detection outputs before they hit
// the overlay / announcer.
final displayRotationProvider = Provider<int>((ref) {
  // Watch the camera service singleton; cameraProvider's AsyncNotifier sets
  // sensorOrientation as a side effect of initialize().
  final svc = ref.watch(cameraServiceProvider);
  // Also watch cameraProvider so we rebuild after initialize() finishes.
  ref.watch(cameraProvider);
  return svc.sensorOrientation;
});
