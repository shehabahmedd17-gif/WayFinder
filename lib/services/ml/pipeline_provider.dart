// Riverpod provider that initializes the detection pipeline and binds it to
// the camera stream. Watched by NavigationScreen to trigger activation.
//
// Lifecycle:
//   build() — waits for camera ready → initializes pipeline → attaches stream
//   ref.onDispose() — stops pipeline + stream

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/camera_service.dart';
import '../../state/detection_notifier.dart';
import 'detection_pipeline.dart';

// EXPLICIT lifecycle. build() does NOT auto-start and does NOT watch
// appModeProvider — watching it caused a CircularDependencyError when
// AppStateNotifier read this provider during a mode flip. AppStateNotifier
// calls start()/stop() directly so indoor↔outdoor teardown/spin-up is linear.
class PipelineNotifier extends AsyncNotifier<DetectionPipelineService?> {
  DetectionPipelineService? _service;
  bool _busy = false;

  @override
  Future<DetectionPipelineService?> build() async => null; // idle until start()

  /// Load YOLO + MiDaS and attach the camera stream. Idempotent; never
  /// rethrows (a failure here must not take down the mode switch).
  Future<void> start() async {
    if (_busy || _service != null) return;
    _busy = true;
    state = const AsyncValue.loading();
    try {
      // Camera controller comes straight from the singleton service — it was
      // started by AppStateNotifier just before this call.
      final controller = ref.read(cameraServiceProvider).controller;
      if (controller == null || !controller.value.isInitialized) {
        debugPrint('[PIPE] camera not ready — pipeline not started');
        state = const AsyncData(null);
        return;
      }

      final pipeline = DetectionPipelineService();
      await pipeline.initialize();
      pipeline.rotationDeg = ref.read(displayRotationProvider);
      debugPrint('[PIPE] Rotation set: ${pipeline.rotationDeg}°');

      if (pipeline.modelsReady) {
        // Re-check the controller — model load took ~7 s and a competing
        // mode switch may have disposed it in the meantime. Calling
        // startImageStream() on a disposed controller throws
        // CameraException; bailing here is graceful.
        final stillValid = ref.read(cameraServiceProvider).controller;
        if (stillValid == null || !stillValid.value.isInitialized) {
          debugPrint('[PIPE] camera disposed during model load — '
              'aborting attachCamera');
          await pipeline.disposePipeline();
          state = const AsyncData(null);
          return;
        }
        try {
          pipeline.attachCamera(
            stillValid,
            (s) => ref.read(detectionProvider.notifier).update(s),
          );
        } catch (e) {
          debugPrint('[PIPE] attachCamera failed: $e (likely disposed) — '
              'discarding pipeline');
          await pipeline.disposePipeline();
          state = const AsyncData(null);
          return;
        }
      } else {
        debugPrint('[PIPE] Models not ready (${pipeline.modelError}). '
            'Place yolov8n_float16.tflite + midas_small.tflite in assets/models/.');
      }
      _service = pipeline;
      state = AsyncData(pipeline);
    } catch (e, st) {
      debugPrint('[PIPE] start failed: $e');
      state = AsyncError(e, st);
    } finally {
      _busy = false;
    }
  }

  /// Detach the stream + release the isolate/interpreters. Idempotent.
  Future<void> stop() async {
    final svc = _service;
    _service = null;
    if (svc == null) {
      state = const AsyncData(null);
      return;
    }
    try {
      final controller = ref.read(cameraServiceProvider).controller;
      if (controller != null) {
        try {
          if (controller.value.isStreamingImages) {
            svc.detachCamera(controller);
          }
        } catch (_) {}
      }
      await svc.disposePipeline();
    } catch (e) {
      debugPrint('[PIPE] stop error (ignored): $e');
    }
    state = const AsyncData(null);
  }
}

final pipelineProvider =
    AsyncNotifierProvider<PipelineNotifier, DetectionPipelineService?>(
  PipelineNotifier.new,
);

// Convenience provider: is the pipeline running with loaded models?
final pipelineReadyProvider = Provider<bool>((ref) {
  final async = ref.watch(pipelineProvider);
  return async.whenOrNull(data: (p) => p?.modelsReady ?? false) ?? false;
});

// Status string for status bar / debug
final pipelineStatusProvider = Provider<String>((ref) {
  final async = ref.watch(pipelineProvider);
  return async.when(
    loading: () => 'Loading models…',
    error: (e, _) => 'Pipeline error: $e',
    data: (p) {
      if (p == null) return 'Camera not ready';
      if (!p.modelsReady) {
        return p.modelError != null
            ? 'Models missing: ${p.modelError}'
            : 'Models missing';
      }
      // Detection active — show delegate so it's easy to verify GPU vs CPU
      final yd = p.yoloDelegate ?? '?';
      final md = p.midasDelegate ?? '?';
      return 'Models loaded (yolo=$yd midas=$md)';
    },
  );
});

// Expose camera controller for convenience (used by NavigationScreen)
final activeCameraProvider = FutureProvider<CameraController?>((ref) async {
  return ref.watch(cameraProvider.future);
});
