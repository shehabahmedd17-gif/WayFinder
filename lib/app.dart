// App shell. The launch flow is:
//
//   SplashScreen (3 s, branded — assets/images/wayfinder_logo.png)
//     → reads prefs.hasSeenOnboarding
//     → first launch: OnboardingScreen (3 pages, TTS-narrated)
//                     → on Skip / Get Started: prefs.setOnboardingSeen()
//                     → RootRouter
//     → returning user: RootRouter directly
//
//   RootRouter then routes between WelcomeScreen / OutdoorScreen /
//   NavigationScreen based on the existing AppMode state machine.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/constants.dart';
import 'theme/app_theme.dart';
import 'ui/screens/splash_screen.dart';

class SmartNavApp extends ConsumerWidget {
  const SmartNavApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      // WayFinder design system (see lib/theme/app_theme.dart) — Safety Amber
      // primary, charcoal containers on true-black background, Inter type.
      theme: AppTheme.dark(),
      home: const SplashScreen(),
    );
  }
}
