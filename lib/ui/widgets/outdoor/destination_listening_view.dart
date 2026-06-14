// destination_listening — phase=listeningForDestination view.
// Port of design_reference/.../destination_listening.
//   Top:    "Where would you like to go?" — 32 px Inter 700 on-surface
//   Center: WfListeningRings (outlined amber) + "listening for your
//           destination…" caption in italic amber 20 px
//   Bottom: "Tap to cancel" — 18 px on-surface-variant
//
// The whole body is the existing tap-anywhere push-to-talk surface; the
// "Tap to cancel" caption is informational (tap anywhere body cancels via
// the outdoor screen's cancel-armed sequence).

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../wf_listening_rings.dart';

class DestinationListeningView extends StatelessWidget {
  const DestinationListeningView({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 48),
          Semantics(
            liveRegion: true,
            label: 'Where would you like to go?',
            child: const Text(
              'Where would you like to go?',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 32,
                height: 40 / 32,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.32,
                color: AppColors.onSurface,
              ),
            ),
          ),
          const Spacer(),
          const Center(child: WfListeningRings(size: 280)),
          const SizedBox(height: AppSpacing.stackMargin),
          const Text(
            'listening for your destination…',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 20,
              height: 28 / 20,
              fontStyle: FontStyle.italic,
              color: AppColors.primaryContainer,
            ),
          ),
          const Spacer(),
          const Padding(
            padding: EdgeInsets.only(bottom: 24),
            child: Text(
              'Tap to cancel',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 18,
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
