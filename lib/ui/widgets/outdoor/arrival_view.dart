// arrival_screen — phase=arrived view.
// Port of design_reference/.../arrival_screen.
//   - 120 px filled amber check-circle with soft glow.
//   - "You've arrived" — 48 px Inter 700 white.
//   - Destination card: surface-container bg, 2 px 30 %-amber border,
//     DESTINATION label + place name (amber 24 px) + pin icon + address.
//   - Visualization placeholder: 192 px surface-container-high block
//     with 2 px outline border (Stitch shows a real photo here; we use a
//     subtle gradient — documented as a deviation).
//   - Footer: two stacked buttons
//       "Go somewhere else" — filled amber, 56 px, → onGoElsewhere
//       "Done"              — outlined amber, 56 px → onDone

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

class ArrivalView extends StatelessWidget {
  final String destinationName;
  final String destinationAddress;
  final VoidCallback onGoElsewhere;
  final VoidCallback onDone;

  const ArrivalView({
    super.key,
    required this.destinationName,
    required this.destinationAddress,
    required this.onGoElsewhere,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenPadding,
          vertical: AppSpacing.stackMargin),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Success icon ─────────────────────────────────────────────
          Center(
            child: ExcludeSemantics(
              child: Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primaryContainer
                          .withValues(alpha: 0.30),
                      blurRadius: 60,
                      spreadRadius: 6,
                    ),
                  ],
                ),
                child: const Icon(Icons.check_circle,
                    color: AppColors.primaryContainer, size: 140),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.stackMargin),
          // ── Heading ──────────────────────────────────────────────────
          Semantics(
            liveRegion: true,
            label: 'You have arrived',
            child: const Text(
              "You've arrived",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 48,
                height: 56 / 48,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.96,
                color: AppColors.onSurface,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.elementGap),
          // ── Destination card ─────────────────────────────────────────
          _DestinationCard(
            name: destinationName,
            address: destinationAddress,
          ),
          // ── Visualization placeholder (deviation: no photo bundled) ──
          const SizedBox(height: AppSpacing.stackMargin),
          Container(
            height: 192,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(
                  color: AppColors.surfaceVariant, width: 2),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.surfaceContainerHighest,
                  AppColors.surfaceContainerLow,
                ],
              ),
            ),
            child: const Center(
              child: ExcludeSemantics(
                child: Icon(Icons.place,
                    color: AppColors.primaryContainer, size: 64),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.stackMargin),
          // ── Buttons ──────────────────────────────────────────────────
          Semantics(
            button: true,
            label: 'Go somewhere else',
            child: SizedBox(
              height: AppSpacing.touchTargetMin,
              child: ElevatedButton(
                onPressed: onGoElsewhere,
                child: const Text('Go somewhere else'),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.elementGap),
          Semantics(
            button: true,
            label: 'Done',
            child: SizedBox(
              height: AppSpacing.touchTargetMin,
              child: OutlinedButton(
                onPressed: onDone,
                child: const Text('Done'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DestinationCard extends StatelessWidget {
  final String name;
  final String address;
  const _DestinationCard({required this.name, required this.address});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: AppColors.primaryContainer.withValues(alpha: 0.30),
          width: 2,
        ),
      ),
      child: Column(
        children: [
          const Text(
            'DESTINATION',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: 2.0,
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            name,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 28,
              height: 34 / 28,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryContainer,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const ExcludeSemantics(
                child: Icon(Icons.location_on,
                    color: AppColors.onSurfaceVariant, size: 24),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  address,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 18,
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
