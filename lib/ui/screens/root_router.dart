// Post-splash / post-onboarding root router.
//
// The previous app.dart `_RootGate` was renamed and extracted into this
// dedicated screen so SplashScreen / OnboardingScreen can `pushReplacement`
// onto it without dragging the entire MaterialApp.home setup along.
//
// Behaviour is unchanged from before:
//   AppMode.welcome  → WelcomeScreen
//   AppMode.outdoor  → OutdoorScreen
//   else (indoor/paused) → SplashLoadingShell or NavigationScreen depending
//                          on pipelineProvider's async state.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/ml/pipeline_provider.dart';
import '../../state/app_state_notifier.dart';
import '../../theme/app_theme.dart';
import 'navigation_screen.dart';
import 'outdoor_screen.dart';
import 'welcome_screen.dart';

class RootRouter extends ConsumerWidget {
  const RootRouter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(appModeProvider);

    if (mode == AppMode.welcome) return const WelcomeScreen();
    if (mode == AppMode.outdoor) return const OutdoorScreen();

    final pipelineAsync = ref.watch(pipelineProvider);
    return pipelineAsync.when(
      loading: () => const _PipelineLoading(),
      error: (_, _) => const NavigationScreen(),
      data: (_) => const NavigationScreen(),
    );
  }
}

class _PipelineLoading extends StatelessWidget {
  const _PipelineLoading();
  @override
  Widget build(BuildContext context) => const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: AppColors.primaryContainer),
              SizedBox(height: AppSpacing.elementGap),
              Text('Loading vision models…',
                  style: TextStyle(
                      fontFamily: 'Inter',
                      color: AppColors.onSurfaceVariant,
                      fontSize: 16,
                      fontStyle: FontStyle.italic)),
            ],
          ),
        ),
      );
}
