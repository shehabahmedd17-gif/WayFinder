// Concentric amber rings + centered mic icon — the visual hero of
// destination_listening and listening_modal_overlay. Optional `filled`
// param swaps the inner ring for a filled amber disc with a black mic
// glyph (matches listening_modal_overlay/screen.png).
//
// The whole widget is decorative — wrapped in ExcludeSemantics so a
// screen reader doesn't read a meaningless "image" announcement.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

class WfListeningRings extends StatelessWidget {
  final double size;
  final bool filled; // true = amber disc + black mic; false = outlined rings
  final double micIconSize;

  const WfListeningRings({
    super.key,
    this.size = 280,
    this.filled = false,
    this.micIconSize = 64,
  });

  @override
  Widget build(BuildContext context) {
    final amber = AppColors.primaryContainer;
    final ring1 = size;
    final ring2 = size * 0.86;
    final ring3 = size * 0.72;
    final core = size * (filled ? 0.62 : 0.36);

    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Outer soft glow (filled mode only)
            if (filled)
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: amber.withValues(alpha: 0.30),
                      blurRadius: 60,
                      spreadRadius: 10,
                    ),
                  ],
                ),
              ),
            _ring(ring1, amber.withValues(alpha: 0.20), 6),
            _ring(ring2, amber.withValues(alpha: 0.40), 4),
            _ring(ring3, amber.withValues(alpha: 0.55), 3),
            // Center: filled amber disc OR small amber-tinted disc
            Container(
              width: core,
              height: core,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled ? amber : amber.withValues(alpha: 0.10),
                border: filled
                    ? Border.all(color: AppColors.background, width: 8)
                    : Border.all(color: amber, width: 2),
              ),
              child: Center(
                child: Icon(
                  Icons.mic,
                  size: micIconSize,
                  color: filled ? Colors.black : amber,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ring(double d, Color color, double width) => Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: width),
        ),
      );
}
