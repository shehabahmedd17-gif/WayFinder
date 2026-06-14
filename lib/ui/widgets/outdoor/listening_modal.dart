// listening_modal_overlay — full-screen STT-active modal.
// Port of design_reference/.../listening_modal_overlay.
//   - 90% black backdrop
//   - Top:    "WHAT IS YOUR COMMAND?" 32 px Inter 800 white + 4×60 amber bar
//   - Center: filled amber WfListeningRings (280 px) with concentric outline
//             rings around the amber disc.
//   - Below:  "LISTENING…" 32 px Inter 800 amber, "Waiting for voice
//             input" 16 px italic on-surface-variant
//   - Bottom: surface-container "Speak now" hint pill (56 px tall, full-width,
//             2 px outline border).
//
// The widget is wrapped in IgnorePointer by its caller so taps fall through
// to the underlying screen — the triple-tap debug input MUST remain
// reachable while listening.

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../wf_listening_rings.dart';

class ListeningModal extends StatelessWidget {
  const ListeningModal({super.key});

  @override
  Widget build(BuildContext context) {
    // Fully opaque background — this widget is rendered as a phase
    // REPLACEMENT (not a translucent overlay) so nothing must bleed
    // through from behind.
    return ColoredBox(
      color: AppColors.background,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenPadding, vertical: 48),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                liveRegion: true,
                label: 'Listening — speak now',
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'WHAT IS YOUR COMMAND?',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 32,
                        height: 40 / 32,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.32,
                        color: AppColors.onSurface,
                      ),
                    ),
                    SizedBox(height: AppSpacing.elementGap),
                    SizedBox(
                      height: 4,
                      width: 60,
                      child: ColoredBox(
                          color: AppColors.primaryContainer),
                    ),
                  ],
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const WfListeningRings(size: 280, filled: true, micIconSize: 96),
                  const SizedBox(height: AppSpacing.stackMargin),
                  const Text(
                    'LISTENING…',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 32,
                      height: 40 / 32,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 4.0,
                      color: AppColors.primaryContainer,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Waiting for voice input',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 16,
                      fontStyle: FontStyle.italic,
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              Container(
                height: AppSpacing.touchTargetMin,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(
                      color: AppColors.onSurfaceVariant, width: 2),
                ),
                child: const Text(
                  'Speak now',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    color: AppColors.onSurface,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
