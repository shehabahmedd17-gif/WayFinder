// splash_screen — port of design_reference/.../splash_screen/code.html.
// Layout:
//   - Centered WayFinder logo (asset, ~192 px) with a soft amber halo.
//   - "WayFinder" wordmark — 48 px Inter 700 white.
//   - "NAVIGATE WITH CONFIDENCE" — 20 px Inter 800 amber, wide tracking.
//   - Footer: 40 % filled amber progress bar + pulsing visibility icon +
//     "Loading vision models…" italic caption.
//
// Auto-advance after kSplashDuration (3 s):
//   - If first launch (prefs.hasSeenOnboarding == false) → OnboardingScreen
//   - Otherwise → ModeRouter (the existing welcome/outdoor/indoor router)
// Uses Navigator.pushReplacement so back-stack stays clean.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../services/preferences_service.dart';
import '../../theme/app_theme.dart';
import 'onboarding_screen.dart';
import 'root_router.dart';

class SplashScreen extends ConsumerStatefulWidget {
  final String message;
  const SplashScreen({super.key, this.message = 'Loading vision models…'});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  Timer? _advanceTimer;
  bool _advanced = false;

  @override
  void initState() {
    super.initState();
    _advanceTimer = Timer(kSplashDuration, _advance);
  }

  @override
  void dispose() {
    _advanceTimer?.cancel();
    super.dispose();
  }

  Future<void> _advance() async {
    if (_advanced || !mounted) return;
    _advanced = true;
    final prefs = ref.read(preferencesServiceProvider);
    final seen = await prefs.hasSeenOnboarding();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            seen ? const RootRouter() : const OnboardingScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
          child: Column(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ExcludeSemantics(
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primaryContainer
                                  .withValues(alpha: 0.25),
                              blurRadius: 60,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                        child: Image.asset(
                          'assets/images/wayfinder_logo.png',
                          width: 192,
                          height: 192,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.stackMargin),
                    Semantics(
                      header: true,
                      label: kAppName,
                      child: const Text(
                        kAppName,
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
                    const Text(
                      'NAVIGATE WITH CONFIDENCE',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 20,
                        height: 24 / 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 3.0,
                        color: AppColors.primaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.screenPadding),
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.full),
                      child: Stack(
                        children: [
                          Container(
                              height: 4, color: AppColors.surfaceContainerHigh),
                          FractionallySizedBox(
                            widthFactor: 0.40,
                            child: Container(
                              height: 4,
                              color: AppColors.primaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.elementGap),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const ExcludeSemantics(
                          child: Icon(Icons.visibility,
                              color: AppColors.primaryContainer, size: 24),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          widget.message,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 16,
                            fontStyle: FontStyle.italic,
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
