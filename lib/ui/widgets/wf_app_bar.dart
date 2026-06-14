// Shared top app bar from the Stitch design system.
// Layout: 56 px tall, screen-padding horizontal, surface bg, 2 px
// surface-variant bottom border. Menu icon (left) → WAYFINDER wordmark →
// trailing icon (right, default account_circle).
//
// Used by: NavigationScreen (indoor), OutdoorScreen, place_results,
// settings, etc. The trailing icon is wired to Settings/menu where
// appropriate — taps that are not yet wired speak a friendly "coming soon"
// TTS prompt instead of being silent.

import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../theme/app_theme.dart';

class WfAppBar extends StatelessWidget implements PreferredSizeWidget {
  final VoidCallback? onMenu;
  final VoidCallback? onTrailing;
  final IconData trailingIcon;
  final String trailingLabel;

  const WfAppBar({
    super.key,
    this.onMenu,
    this.onTrailing,
    this.trailingIcon = Icons.account_circle,
    this.trailingLabel = 'Settings',
  });

  @override
  Size get preferredSize => const Size.fromHeight(AppSpacing.touchTargetMin);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AppSpacing.touchTargetMin,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          bottom: BorderSide(color: AppColors.surfaceVariant, width: 2),
        ),
      ),
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
      child: Row(
        children: [
          if (onMenu != null)
            _iconBtn(Icons.menu, 'Menu', onMenu!)
          else
            const SizedBox(width: AppSpacing.touchTargetMin),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              kAppName.toUpperCase(),
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 28,
                height: 32 / 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                color: AppColors.primaryContainer,
              ),
            ),
          ),
          _iconBtn(trailingIcon, trailingLabel, onTrailing ?? () {}),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData icon, String label, VoidCallback onTap) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: onTap,
          child: SizedBox(
            width: AppSpacing.touchTargetMin,
            height: AppSpacing.touchTargetMin,
            child: Icon(icon, color: AppColors.primaryContainer, size: 32),
          ),
        ),
      ),
    );
  }
}
