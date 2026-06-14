// NavigationScreen — indoor_obstacle_mode (Stitch).
// Layout:
//   - WfAppBar (WAYFINDER)
//   - Top status row: amber dot + "Indoor mode" + mic + "Listening for
//     commands" — pinned to surface bg.
//   - MAIN: live camera preview (CameraPreview) with the existing
//     DetectionOverlay (amber-styled inside) drawn on top.
//   - Decision banner: full-width filled amber strip pinned above the
//     bottom-nav, showing the current obstacle decision ("MOVE LEFT",
//     "STOP", "PATH CLEAR") + a matching arrow.
//   - WfBottomNav (Indoor highlighted).
//
// All Stitch debug widgets removed from the production tree — the
// developer DIAGNOSTICS panel, the COPY DIAG button, the PAUSE/SIMPLE
// pills, and the GPS coordinates pill are all gated behind `kDebugUI`
// OR the hidden triple-tap reveal. They are NEVER shown in a release
// build, never on welcome / outdoor screens.

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback, SystemSound, SystemSoundType;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../services/audio/audio_providers.dart';
import '../../services/audio/tts_service.dart';
import '../../services/camera_service.dart';
import '../../services/ml/detection_pipeline.dart';
import '../../services/ml/pipeline_provider.dart';
import '../../state/app_state_notifier.dart';
import '../../state/detection_notifier.dart';
import '../../state/sos_notifier.dart';
import '../../theme/app_theme.dart';
import '../widgets/detection_overlay.dart';
import '../widgets/sos_gesture_wrapper.dart';
import '../widgets/wf_app_bar.dart';
import '../widgets/wf_bottom_nav.dart';

class NavigationScreen extends ConsumerStatefulWidget {
  const NavigationScreen({super.key});

  @override
  ConsumerState<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends ConsumerState<NavigationScreen>
    with WidgetsBindingObserver {
  DateTime? _pressStart;
  final DateTime _modeEnterTime = DateTime.now();

  // Cancel-confirm (long-press → arm; tap-within-3s → confirm; timeout → keep)
  bool _cancelArmed = false;
  Timer? _cancelTimer;

  // Hidden triple-tap on the WAYFINDER wordmark → toggle dev panels.
  bool _debugRevealed = false;
  final List<DateTime> _wordmarkTaps = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _cancelTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (ref.read(appModeProvider) == AppMode.indoor) {
        // ignore: discarded_futures
        ref.read(cameraProvider.notifier).start();
        // ignore: discarded_futures
        ref.read(pipelineProvider.notifier).start();
      }
    }
  }

  void _onTapDown(TapDownDetails _) {
    _pressStart = DateTime.now();
  }

  void _onTapUp(TapUpDetails _) {
    final start = _pressStart;
    _pressStart = null;
    if (start == null) return;
    final held = DateTime.now().difference(start).inMilliseconds;
    if (held >= kCancelLongPressMs) return; // long-press handled separately

    // SOS abort beats everything else.
    final sos = ref.read(sosProvider);
    if (sos.phase == SosPhase.countdown) {
      // ignore: discarded_futures
      ref.read(sosProvider.notifier).abort();
      return;
    }

    if (_cancelArmed) {
      // Confirm cancel → switch back to welcome.
      _disarmCancel();
      // ignore: discarded_futures
      ref.read(appModeProvider.notifier).switchToWelcome();
      return;
    }
    _handleTap();
  }

  void _onLongPress() {
    final now = DateTime.now();
    if (now.difference(_modeEnterTime).inMilliseconds < kModeSwitchGraceMs) {
      debugPrint('[INDOOR] long-press ignored (settling grace)');
      return;
    }
    // SOS countdown wins over cancel arming.
    if (ref.read(sosProvider).phase == SosPhase.countdown) return;
    _armCancel();
  }

  void _armCancel() {
    if (_cancelArmed) {
      _disarmCancel();
      return;
    }
    setState(() => _cancelArmed = true);
    // ignore: discarded_futures
    ref.read(ttsServiceProvider).speak(kPromptIndoorCancelArm);
    // ignore: discarded_futures
    SemanticsService.sendAnnouncement(
        View.of(context), kPromptIndoorCancelArm, TextDirection.ltr);
    _cancelTimer?.cancel();
    _cancelTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_cancelArmed) return;
      _disarmCancel();
      // ignore: discarded_futures
      ref.read(ttsServiceProvider).speak(kPromptIndoorCancelKeep);
    });
  }

  void _disarmCancel() {
    _cancelTimer?.cancel();
    _cancelTimer = null;
    if (mounted && _cancelArmed) setState(() => _cancelArmed = false);
  }

  void _handleTap() {
    // ignore: discarded_futures
    HapticFeedback.lightImpact();
    SystemSound.play(SystemSoundType.click);
    debugPrint('[TAP] indoor push-to-talk (stub)');
  }

  void _onWordmarkTap() {
    final now = DateTime.now();
    _wordmarkTaps.add(now);
    _wordmarkTaps
        .removeWhere((t) => now.difference(t).inMilliseconds > 700);
    if (_wordmarkTaps.length >= 3) {
      _wordmarkTaps.clear();
      setState(() => _debugRevealed = !_debugRevealed);
    }
  }

  Future<void> _copyDiagnostics() async {
    final svc =
        ref.read(pipelineProvider).whenOrNull(data: (v) => v);
    final dump = svc?.dumpDiagnostics() ?? '(pipeline not initialized)';
    await Clipboard.setData(ClipboardData(text: dump));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      duration: Duration(seconds: 2),
      backgroundColor: AppColors.surfaceContainer,
      content: Text('Diagnostics copied to clipboard',
          style: TextStyle(color: AppColors.primaryContainer)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final appMode = ref.watch(appModeProvider);
    final cameraAsync = ref.watch(cameraProvider);
    final detectionState = ref.watch(detectionProvider);
    final pipelineAsync = ref.watch(pipelineProvider);
    // Activate the obstacle announcer.
    ref.watch(obstacleAnnouncerProvider);
    final showDebug = kDebugUI || _debugRevealed;

    final cameraArea = (appMode != AppMode.indoor)
        ? const _WelcomeBackdrop()
        : cameraAsync.when(
            loading: () => const _LoadingView(),
            error: (e, _) => _ErrorView(error: e.toString()),
            data: (controller) {
              if (controller == null || !controller.value.isInitialized) {
                return const _LoadingView();
              }
              return _CameraPreviewFill(controller: controller);
            },
          );

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SosGestureWrapper(
        child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onWordmarkTap,
              child: WfAppBar(
                onTrailing: () => ref
                    .read(ttsServiceProvider)
                    .speak('Settings coming soon.'),
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: _onTapDown,
                onTapUp: _onTapUp,
                onLongPress: _onLongPress,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    cameraArea,
                    // Detection overlay (amber boxes — DetectionOverlay
                    // colors already use amber per existing painter).
                    if (appMode == AppMode.indoor)
                      DetectionOverlay(
                        detections: detectionState.detections,
                        imgW: detectionState.imgW,
                        imgH: detectionState.imgH,
                        showTestRect: showDebug,
                        showRawYoloBoxes:
                            ref.watch(showRawYoloBoxesProvider),
                      ),
                    // Status row (top): "Indoor mode" pill + listening hint.
                    if (appMode == AppMode.indoor)
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: _IndoorStatusBar(),
                      ),
                    // Decision banner — full-width amber strip showing
                    // current obstacle decision (or "PATH CLEAR" in debug).
                    if (appMode == AppMode.indoor)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _DecisionBanner(
                          decision: detectionState.decision,
                          showClear: showDebug,
                        ),
                      ),
                    // ── DEV-only overlays (triple-tap reveal / kDebugUI) ──
                    if (showDebug)
                      Positioned(
                        top: 6,
                        left: 8,
                        child: _CopyDiagButton(onTap: _copyDiagnostics),
                      ),
                    if (showDebug)
                      Positioned(
                        top: 48,
                        right: 8,
                        child: _DiagnosticsPanel(
                          pipelineAsync: pipelineAsync,
                        ),
                      ),
                    // Welcome-mode mode-switch tiles overlay (only shown
                    // when somehow rendering this screen on welcome —
                    // _RootGate now routes welcome to WelcomeScreen so
                    // this is a safety net).
                    if (appMode == AppMode.welcome)
                      const Positioned.fill(child: _ModeFallback()),
                    // Cancel-armed banner — pinned just above the bottom
                    // nav, mirrors the outdoor cancel-confirm UX.
                    if (_cancelArmed)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _IndoorCancelBanner(),
                      ),
                  ],
                ),
              ),
            ),
            const WfBottomNav(active: WfTab.indoor),
          ],
        ),
      ),
      ),
    );
  }
}

// ── Indoor status bar ───────────────────────────────────────────────────
class _IndoorStatusBar extends StatelessWidget {
  const _IndoorStatusBar();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface.withValues(alpha: 0.78),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenPadding, vertical: 12),
      child: Semantics(
        liveRegion: true,
        label: 'Indoor mode, listening for commands',
        child: const Row(
          children: [
            // Pulse dot
            ExcludeSemantics(
              child: _AmberDot(),
            ),
            SizedBox(width: 8),
            Text(
              'Indoor mode',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 20,
                height: 24 / 20,
                fontWeight: FontWeight.w800,
                color: AppColors.primaryContainer,
              ),
            ),
            SizedBox(width: 12),
            // Trailing "mic + Listening" group — right-aligned and
            // ellipsis-clipped so the status row never overflows on
            // narrow screens (Redmi Note 10 has ~393 px logical width).
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ExcludeSemantics(
                    child: Icon(Icons.mic,
                        color: AppColors.onSurface, size: 20),
                  ),
                  SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Listening',
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      maxLines: 1,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 16,
                        color: AppColors.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AmberDot extends StatelessWidget {
  const _AmberDot();
  @override
  Widget build(BuildContext context) => Container(
        width: 12,
        height: 12,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.primaryContainer,
        ),
      );
}

// ── Decision banner ────────────────────────────────────────────────────
class _DecisionBanner extends StatelessWidget {
  final String decision; // "move left" | "move right" | "stop" | "path clear"
  final bool showClear;
  const _DecisionBanner({required this.decision, required this.showClear});

  @override
  Widget build(BuildContext context) {
    final isClear = decision == 'path clear';
    if (isClear && !showClear) return const SizedBox.shrink();

    final color = switch (decision) {
      'stop' => AppColors.errorContainer,
      'move left' || 'move right' => AppColors.primaryContainer,
      _ => AppColors.surfaceContainer,
    };
    final fg = switch (decision) {
      'stop' => AppColors.onErrorContainer,
      'move left' || 'move right' => AppColors.onPrimaryContainer,
      _ => AppColors.onSurfaceVariant,
    };
    final arrow = switch (decision) {
      'move left' => Icons.arrow_back,
      'move right' => Icons.arrow_forward,
      'stop' => Icons.front_hand,
      _ => Icons.check_circle_outline,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenPadding, 0, AppSpacing.screenPadding, 8),
      child: Semantics(
        liveRegion: true,
        label: 'Decision: $decision',
        child: Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: fg, width: 4),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 12, spreadRadius: 1),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                decision.toUpperCase(),
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 22,
                  letterSpacing: 2.0,
                  fontWeight: FontWeight.w800,
                  color: fg,
                ),
              ),
              ExcludeSemantics(child: Icon(arrow, color: fg, size: 36)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Backdrops ──────────────────────────────────────────────────────────
class _WelcomeBackdrop extends StatelessWidget {
  const _WelcomeBackdrop();
  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: AppColors.background,
        child: SizedBox.expand(),
      );
}

class _ModeFallback extends ConsumerWidget {
  const _ModeFallback();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Should be unreachable — _RootGate routes welcome to WelcomeScreen.
    return const ColoredBox(color: AppColors.background);
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();
  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppColors.primaryContainer),
            SizedBox(height: 16),
            Text('Starting camera…',
                style: TextStyle(
                    fontFamily: 'Inter',
                    color: AppColors.onSurfaceVariant,
                    fontSize: 14)),
          ],
        ),
      );
}

class _ErrorView extends StatelessWidget {
  final String error;
  const _ErrorView({required this.error});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Camera error:\n$error',
              style: const TextStyle(
                  fontFamily: 'Inter',
                  color: AppColors.errorContainer,
                  fontSize: 15),
              textAlign: TextAlign.center),
        ),
      );
}

class _CameraPreviewFill extends StatelessWidget {
  final CameraController controller;
  const _CameraPreviewFill({required this.controller});
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final scale = size.aspectRatio * controller.value.aspectRatio;
    return Transform.scale(
      scale: scale < 1 ? 1 / scale : scale,
      child: Center(child: CameraPreview(controller)),
    );
  }
}

// ── DEV-only overlays (production-hidden) ──────────────────────────────
class _CopyDiagButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CopyDiagButton({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
                color: AppColors.primaryContainer.withValues(alpha: 0.6)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.copy_all,
                  color: AppColors.primaryContainer, size: 14),
              SizedBox(width: 4),
              Text('Copy diag',
                  style: TextStyle(
                      fontFamily: 'Inter',
                      color: AppColors.primaryContainer,
                      fontSize: 11,
                      fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiagnosticsPanel extends ConsumerWidget {
  final AsyncValue<DetectionPipelineService?> pipelineAsync;
  const _DiagnosticsPanel({required this.pipelineAsync});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return pipelineAsync.when(
      loading: () => _shell('Loading models…'),
      error: (e, _) => _shell('Pipeline error:\n$e', isError: true),
      data: (svc) {
        if (svc == null) return _shell('Camera not ready');
        return ListenableBuilder(
          listenable: svc,
          builder: (_, _) => _body(svc),
        );
      },
    );
  }

  Widget _shell(String text, {bool isError = false}) => Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
              color: isError
                  ? AppColors.errorContainer
                  : AppColors.onSurfaceVariant),
        ),
        child: Text(text,
            style: TextStyle(
                color: isError
                    ? AppColors.error
                    : AppColors.onSurfaceVariant,
                fontSize: 11)),
      );

  Widget _body(DetectionPipelineService svc) {
    final lines = <String>[
      'YOLO  ${svc.yoloDelegate ?? "?"}',
      'MiDaS ${svc.midasDelegate ?? "?"}',
      'Cycle ${svc.lastCycleMs}ms  skip=${svc.frameSkip}',
      'RGB ctr r=${svc.rgbMeanR.toStringAsFixed(0)} '
          'g=${svc.rgbMeanG.toStringAsFixed(0)} '
          'b=${svc.rgbMeanB.toStringAsFixed(0)}',
      if (svc.lastFrameError != null) 'ERR: ${svc.lastFrameError}',
    ];
    return Container(
      constraints: const BoxConstraints(maxWidth: 290),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
            color: svc.modelsReady
                ? AppColors.primaryContainer
                : AppColors.errorContainer),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('DIAGNOSTICS',
              style: TextStyle(
                  fontFamily: 'Inter',
                  color: AppColors.primaryContainer,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.0)),
          const SizedBox(height: 4),
          for (final l in lines)
            Text(l,
                style: const TextStyle(
                    color: AppColors.onSurface, fontSize: 10)),
        ],
      ),
    );
  }
}

// Cancel-confirm banner for the indoor long-press → return-to-welcome flow.
// Mirrors the outdoor _CancelBanner styling.
class _IndoorCancelBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.errorContainer,
        border: Border.all(color: AppColors.error, width: 2),
      ),
      padding: const EdgeInsets.all(14),
      child: const Text(
        'Cancel indoor mode?\nTap to confirm · wait 3 seconds to keep going',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'Inter',
          color: AppColors.onErrorContainer,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
