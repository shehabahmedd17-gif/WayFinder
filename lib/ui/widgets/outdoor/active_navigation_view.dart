// active_navigation — phase ∈ {routing, navigating}.
// Port of design_reference/.../active_navigation.
//   - TOP BAR: "Step n of N" 18 px amber italic + instruction 24-32 px
//     Inter 700 white (2 lines), 2 px amber bottom border.
//   - MIDDLE: dark gradient placeholder (no live camera/AR layer yet —
//     deviation documented in report).
//   - RIGHT SIDE: vertical stack of 3 control buttons (Pause / Skip /
//     Repeat) — 56 × 56, surface-container-highest bg, outline border.
//   - BOTTOM: remaining-meters chip (amber filled) + GPS pill.
//
// All controls feed back into the existing OutdoorNavNotifier:
//   - Pause   → pausedProvider.toggle()
//   - Skip    → advance current step (best-effort — no notifier helper, so
//               we call a small public hook below)
//   - Repeat  → submitTranscript('repeat')

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/audio/audio_providers.dart';
import '../../../services/camera_service.dart';
import '../../../state/app_state_notifier.dart';
import '../../../state/detection_notifier.dart';
import '../../../state/navigation_notifier.dart';
import '../../../theme/app_theme.dart';
import '../detection_overlay.dart';

class ActiveNavigationView extends ConsumerWidget {
  final OutdoorState state;
  const ActiveNavigationView({super.key, required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stepN = state.currentStepIndex + 1;
    final totalSteps = state.route?.steps.length ?? 0;
    final instr = state.currentInstruction ?? '';
    final paused = ref.watch(pausedProvider);

    // Full-bleed Stack: camera fills the whole area, then the step banner +
    // bottom status bar float on top with semi-transparent dark backdrops
    // so the text reads cleanly against any camera frame. Earlier layout
    // had the banner ABOVE the camera in a Column; cropping happened when
    // a long instruction wrapped to 3 lines.
    return Stack(
      fit: StackFit.expand,
      children: [
        // ── Background: live camera or gradient fallback ──────────────
        Positioned.fill(child: _CameraOrGradient()),
        // ── Detection overlay (amber rounded boxes + pill labels) ─────
        const Positioned.fill(child: _OutdoorObstacleActivator()),
        // ── Top: step banner with dark backdrop ───────────────────────
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _StepBanner(
            stepN: stepN,
            totalSteps: totalSteps,
            instruction: instr,
            routing: state.phase == OutdoorPhase.routing,
          ),
        ),
        // ── "Then:" preview pill (above bottom status bar) ────────────
        if (state.nextInstruction != null)
          Positioned(
            left: AppSpacing.screenPadding,
            right: AppSpacing.screenPadding,
            bottom: 116, // sits clear of the bottom status bar
            child: _NextPreviewPill(text: state.nextInstruction!),
          ),
        // ── Bottom status bar (distance + destination + FOLLOWING) ────
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _BottomStatusBar(
            remainingMeters: state.remainingMeters,
            destinationName: state.destination?.name ?? '—',
          ),
        ),
        // ── DEV-ONLY side controls (Pause / Skip / Repeat) ────────────
        // Hidden in release because WayFinder is voice-first; the user
        // controls navigation via "next" / "repeat" / "cancel". The
        // sighted-helper buttons stay available in debug for QA.
        if (kDebugMode)
          Positioned(
            top: 120, // below the step banner
            right: AppSpacing.screenPadding,
            child: _SideControls(
              paused: paused,
              onPause: () => ref.read(pausedProvider.notifier).toggle(),
              onSkip: () => ref.read(outdoorNavProvider.notifier).skipStep(),
              onRepeat: () => ref
                  .read(outdoorNavProvider.notifier)
                  .submitTranscript('repeat'),
            ),
          ),
      ],
    );
  }
}

// ── Top step banner ─────────────────────────────────────────────────────
class _StepBanner extends StatelessWidget {
  final int stepN;
  final int totalSteps;
  final String instruction;
  final bool routing;
  const _StepBanner({
    required this.stepN,
    required this.totalSteps,
    required this.instruction,
    required this.routing,
  });

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(16),
        ),
        border: const Border(
          bottom: BorderSide(color: AppColors.primaryContainer, width: 2),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        topInset + 16,
        AppSpacing.screenPadding,
        16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            routing ? 'Calculating route…' : 'Step $stepN of $totalSteps',
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 18,
              height: 24 / 18,
              fontWeight: FontWeight.w800,
              fontStyle: FontStyle.italic,
              letterSpacing: 1.0,
              color: AppColors.primaryContainer,
            ),
          ),
          const SizedBox(height: 4),
          Semantics(
            liveRegion: true,
            label: instruction.isEmpty
                ? 'Awaiting directions'
                : 'Now: $instruction',
            child: Text(
              instruction.isEmpty ? '—' : instruction,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 26,
                height: 32 / 26,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── "Then:" preview pill ────────────────────────────────────────────────
class _NextPreviewPill extends StatelessWidget {
  final String text;
  const _NextPreviewPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        'Then: $text',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 18,
          height: 22 / 18,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

// ── Bottom status bar (distance + destination + FOLLOWING) ──────────────
class _BottomStatusBar extends StatelessWidget {
  final int remainingMeters;
  final String destinationName;
  const _BottomStatusBar({
    required this.remainingMeters,
    required this.destinationName,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(16),
        ),
        border: const Border(
          top: BorderSide(color: AppColors.primaryContainer, width: 2),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenPadding, 14, AppSpacing.screenPadding, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // LEFT — distance + destination name. The destination name is
          // wrapped in Expanded so it ellipsizes instead of overflowing
          // the FOLLOWING chip (the "RIGHT OVERFLOWED BY 28 PIXELS" fix).
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  liveRegion: true,
                  label: '$remainingMeters meters remaining',
                  child: Text(
                    '$remainingMeters m',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 36,
                      height: 1.0,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryContainer,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  destinationName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // RIGHT — FOLLOWING chip (intrinsic width, never overflows now
          // because Expanded above absorbs all remaining space).
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.primaryContainer,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: Icon(Icons.navigation,
                      color: AppColors.onPrimaryContainer, size: 20),
                ),
                SizedBox(width: 6),
                Text(
                  'FOLLOWING',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    color: AppColors.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SideControls extends StatelessWidget {
  final bool paused;
  final VoidCallback onPause;
  final VoidCallback onSkip;
  final VoidCallback onRepeat;
  const _SideControls({
    required this.paused,
    required this.onPause,
    required this.onSkip,
    required this.onRepeat,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _btn(paused ? Icons.play_arrow : Icons.pause,
            paused ? 'Resume' : 'Pause', onPause),
        const SizedBox(height: AppSpacing.elementGap),
        _btn(Icons.skip_next, 'Skip step', onSkip),
        const SizedBox(height: AppSpacing.elementGap),
        _btn(Icons.replay, 'Repeat instruction', onRepeat),
      ],
    );
  }

  Widget _btn(IconData icon, String label, VoidCallback onTap) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: AppColors.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: const BorderSide(color: AppColors.outline, width: 2),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: onTap,
          child: SizedBox(
            width: AppSpacing.touchTargetMin,
            height: AppSpacing.touchTargetMin,
            child: Icon(icon, color: AppColors.onSurface, size: 28),
          ),
        ),
      ),
    );
  }
}

// Live camera preview during outdoor navigation. Shows the gradient
// placeholder while the camera is loading, in error, or not yet started
// (routing phase, permission denied) — so the UI never goes blank.
class _CameraOrGradient extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cameraAsync = ref.watch(cameraProvider);
    final detection = ref.watch(detectionProvider);
    return cameraAsync.when(
      loading: () => const _Gradient(),
      error: (_, _) => const _Gradient(),
      data: (controller) {
        if (controller == null || !controller.value.isInitialized) {
          return const _Gradient();
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            _CameraFill(controller: controller),
            DetectionOverlay(
              detections: detection.detections,
              imgW: detection.imgW,
              imgH: detection.imgH,
            ),
          ],
        );
      },
    );
  }
}

class _CameraFill extends StatelessWidget {
  final CameraController controller;
  const _CameraFill({required this.controller});
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

class _Gradient extends StatelessWidget {
  const _Gradient();
  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.surfaceContainerLowest,
              AppColors.surface,
              AppColors.surfaceContainerLowest,
            ],
          ),
        ),
      );
}

// Side-effect widget that activates the outdoor obstacle dispatcher
// (which sets up the detectionProvider listener via ref.listen the first
// time it's read). Rendered as SizedBox.shrink so it takes no space.
class _OutdoorObstacleActivator extends ConsumerWidget {
  const _OutdoorObstacleActivator();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(outdoorObstacleDispatcherProvider);
    return const SizedBox.shrink();
  }
}
