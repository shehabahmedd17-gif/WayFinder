// Bottom navigation shell from the updated Stitch design (v2).
// 3 tabs — Outdoor / Indoor / Settings — with the active tab highlighted
// in filled amber, others in on-surface-variant. The earlier "Detect"
// tab was removed in v2 because obstacle detection is now a sub-mode of
// Indoor and never needs its own tab.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../services/audio/tts_service.dart';
import '../../state/app_state_notifier.dart';
import '../../theme/app_theme.dart';
import '../screens/settings_screen.dart';

enum WfTab { outdoor, indoor, settings }

class WfBottomNav extends ConsumerWidget {
  final WfTab active;
  final VoidCallback? onSettings;
  const WfBottomNav({super.key, required this.active, this.onSettings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void openSettings() {
      // ignore: discarded_futures
      ref.read(ttsServiceProvider).speak(kPromptSettingsOpening);
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(color: AppColors.surfaceVariant, width: 2),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _tab(WfTab.outdoor, Icons.explore, 'Outdoor', () {
              if (active != WfTab.outdoor) {
                // ignore: discarded_futures
                ref.read(appModeProvider.notifier).switchToOutdoor();
              }
            }),
            _tab(WfTab.indoor, Icons.home_work, 'Indoor', () {
              if (active != WfTab.indoor) {
                // ignore: discarded_futures
                ref.read(appModeProvider.notifier).switchToIndoor();
              }
            }),
            _tab(WfTab.settings, Icons.settings, 'Settings',
                onSettings ?? openSettings),
          ],
        ),
      ),
    );
  }

  Widget _tab(WfTab id, IconData icon, String label, VoidCallback onTap) {
    final isActive = id == active;
    final fg = isActive
        ? AppColors.onPrimaryContainer
        : AppColors.onSurfaceVariant;
    final bg = isActive ? AppColors.primaryContainer : Colors.transparent;

    return Expanded(
      child: Semantics(
        button: true,
        selected: isActive,
        label: label,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Material(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              onTap: onTap,
              child: SizedBox(
                height: 72,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ExcludeSemantics(child: Icon(icon, color: fg, size: 28)),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        color: fg,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
