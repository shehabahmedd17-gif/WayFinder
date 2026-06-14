// WayFinder design system, ported from
// design_reference/stitch_wayfinder_accessibility_assistant/wayfinder_design_system/DESIGN.md
//
// The Stitch palette is a Material-3 dark scheme tuned for blind / low-vision
// users: a near-black surface, true-black background, Safety Amber as the
// primary action color (high visibility + caution association), and a small
// cyan accent for informational callouts. Reds are reserved exclusively for
// hazards and SOS.
//
// All numeric design tokens (spacing, radius, touch-target, typography) live
// here as `const` so individual widgets never hardcode them.

import 'package:flutter/material.dart';

class AppColors {
  // Tonal layers (level 0 = background, level 1+ = container surfaces).
  // Stitch token "background" is #131313 — dark grey, not pure black; this
  // matches the screen.pngs and avoids the OLED-bleed look the user flagged.
  static const Color background = Color(0xFF131313);
  static const Color surface = Color(0xFF131313); // Stitch token "surface"
  static const Color surfaceContainerLowest = Color(0xFF0E0E0E);
  static const Color surfaceContainerLow = Color(0xFF1C1B1B);
  // Card surface used in place_results / settings / permissions Stitch
  // HTMLs (bg-[#1A1A1A]) — slightly lighter than the default container token.
  static const Color cardSurface = Color(0xFF1A1A1A);
  static const Color surfaceContainer = Color(0xFF20201F);
  static const Color surfaceContainerHigh = Color(0xFF2A2A2A);
  static const Color surfaceContainerHighest = Color(0xFF353535);
  static const Color surfaceVariant = Color(0xFF353535);
  static const Color surfaceBright = Color(0xFF393939);

  // Foreground
  static const Color onSurface = Color(0xFFE5E2E1);
  static const Color onSurfaceVariant = Color(0xFFD4C5AB);
  static const Color outline = Color(0xFF9C8F78);
  static const Color outlineVariant = Color(0xFF4F4632);

  // Primary — Safety Amber (#FFC107). Used for actions, focus, "FOLLOWING"
  // status pills, and the live LISTENING banner.
  static const Color primary = Color(0xFFFFE4AF);
  static const Color onPrimary = Color(0xFF3F2E00);
  static const Color primaryContainer = Color(0xFFFFC107);
  static const Color onPrimaryContainer = Color(0xFF6D5100);
  static const Color primaryFixed = Color(0xFFFFDF9E);
  static const Color primaryFixedDim = Color(0xFFFABD00);
  static const Color onPrimaryFixed = Color(0xFF261A00);

  // Secondary — Cyan. Informational callouts only.
  static const Color secondary = Color(0xFFBDF4FF);
  static const Color onSecondary = Color(0xFF00363D);
  static const Color secondaryContainer = Color(0xFF00E3FD);
  static const Color onSecondaryContainer = Color(0xFF00616D);

  // Tertiary / Error — Reserved exclusively for hazards & SOS.
  static const Color tertiary = Color(0xFFFFE0DC);
  static const Color tertiaryContainer = Color(0xFFFFBAB1);
  static const Color error = Color(0xFFFFB4AB);
  static const Color onError = Color(0xFF690005);
  static const Color errorContainer = Color(0xFF93000A);
  static const Color onErrorContainer = Color(0xFFFFDAD6);
}

// Spacing — Stitch tokens (24/16/32/56)
class AppSpacing {
  static const double screenPadding = 24;
  static const double elementGap = 16;
  static const double stackMargin = 32;
  // Hit areas — DESIGN.md mandates >= 56 px for blind-touch locatability.
  static const double touchTargetMin = 56;
}

// Radius scale from Stitch tailwind config inside each code.html:
//   DEFAULT 4px, lg 8px, xl 12px (cards, mode tiles), 2xl 16px (large cards),
//   full 9999px (pills, mic ring).
class AppRadius {
  static const double sm = 4;
  static const double md = 8; // Stitch "lg"
  static const double lg = 12; // Stitch "xl" — cards / buttons / tiles
  static const double xl = 16; // Stitch "2xl" — large bento cards
  static const double xxl = 24;
  static const double full = 9999;
}

// Inter — Stitch design uses Inter Bold 700 for headings, 400 for body. We
// fall back to the system font (Roboto on Android) so we don't have to bundle
// a webfont; the size/weight scale is preserved.
class AppText {
  static const String _family = 'Inter';

  static const TextStyle headlineLg = TextStyle(
    fontFamily: _family,
    fontSize: 48,
    height: 56 / 48,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.02 * 48,
    color: AppColors.onSurface,
  );
  static const TextStyle headlineMd = TextStyle(
    fontFamily: _family,
    fontSize: 32,
    height: 40 / 32,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.01 * 32,
    color: AppColors.onSurface,
  );
  static const TextStyle bodyLg = TextStyle(
    fontFamily: _family,
    fontSize: 24,
    height: 32 / 24,
    fontWeight: FontWeight.w400,
    color: AppColors.onSurface,
  );
  static const TextStyle bodyMd = TextStyle(
    fontFamily: _family,
    fontSize: 18,
    height: 28 / 18,
    fontWeight: FontWeight.w400,
    color: AppColors.onSurface,
  );
  static const TextStyle labelLg = TextStyle(
    fontFamily: _family,
    fontSize: 20,
    height: 24 / 20,
    fontWeight: FontWeight.w700,
    color: AppColors.onSurface,
  );
}

class AppTheme {
  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: AppColors.primaryContainer,
      onPrimary: AppColors.onPrimaryContainer,
      primaryContainer: AppColors.primaryContainer,
      onPrimaryContainer: AppColors.onPrimaryContainer,
      secondary: AppColors.secondaryContainer,
      onSecondary: AppColors.onSecondaryContainer,
      secondaryContainer: AppColors.secondaryContainer,
      onSecondaryContainer: AppColors.onSecondaryContainer,
      tertiary: AppColors.tertiaryContainer,
      onTertiary: Color(0xFF690003),
      error: AppColors.errorContainer,
      onError: AppColors.onErrorContainer,
      surface: AppColors.surface,
      onSurface: AppColors.onSurface,
      surfaceContainerHighest: AppColors.surfaceContainerHighest,
      onSurfaceVariant: AppColors.onSurfaceVariant,
      outline: AppColors.outline,
      outlineVariant: AppColors.outlineVariant,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.background,
      canvasColor: AppColors.background,
      textTheme: const TextTheme(
        displayLarge: AppText.headlineLg,
        headlineLarge: AppText.headlineLg,
        headlineMedium: AppText.headlineMd,
        titleLarge: AppText.headlineMd,
        bodyLarge: AppText.bodyLg,
        bodyMedium: AppText.bodyMd,
        labelLarge: AppText.labelLg,
      ),
      iconTheme: const IconThemeData(
        color: AppColors.onSurface,
        size: 32,
      ),
    );

    return base.copyWith(
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size.fromHeight(AppSpacing.touchTargetMin),
          backgroundColor: AppColors.primaryContainer,
          foregroundColor: AppColors.onPrimaryContainer,
          textStyle: AppText.labelLg.copyWith(color: AppColors.onPrimaryContainer),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(AppSpacing.touchTargetMin),
          foregroundColor: AppColors.primaryContainer,
          side: const BorderSide(color: AppColors.primaryContainer, width: 2),
          textStyle: AppText.labelLg.copyWith(color: AppColors.primaryContainer),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: const BorderSide(color: AppColors.surfaceVariant, width: 2),
        ),
        margin: EdgeInsets.zero,
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceContainer,
        labelStyle: AppText.bodyMd,
        hintStyle: AppText.bodyMd.copyWith(
            color: AppColors.onSurfaceVariant.withValues(alpha: 0.6)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: const BorderSide(color: AppColors.outline, width: 2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: const BorderSide(color: AppColors.primaryContainer, width: 2),
        ),
      ),
    );
  }
}
