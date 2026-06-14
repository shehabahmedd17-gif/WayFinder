import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../state/app_state_notifier.dart';
import '../../state/navigation_notifier.dart';

// Top overlay: "INDOOR" / "OUTDOOR · NAVIGATING" + outdoor step progress.
// py: status_label + step_label overlays (lines 1622-1647, 1731-1746).
class StatusBar extends ConsumerWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(appModeProvider);
    final outdoor = ref.watch(outdoorNavProvider);

    final modeLabel = mode.name.toUpperCase();
    final phaseLabel = mode == AppMode.outdoor
        ? ' · ${outdoor.phase.name.toUpperCase()}'
        : '';

    String? stepText;
    if (mode == AppMode.outdoor &&
        outdoor.route != null &&
        outdoor.currentInstruction != null) {
      final n = outdoor.route!.steps.length;
      stepText = 'Step ${outdoor.currentStepIndex + 1}/$n: '
          '${outdoor.currentInstruction}';
    }

    return Container(
      color: Colors.black.withValues(alpha: 0.65),
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 4,
        bottom: 6,
        left: 12,
        right: 12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$modeLabel$phaseLabel',
            style: const TextStyle(
              color: Colors.amber,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          if (stepText != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                stepText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
