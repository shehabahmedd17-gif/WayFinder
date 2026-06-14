// First-launch onboarding — 3 pages, each TTS-narrated on entry.
//
// Visual port of design_reference/v2/.../onboarding_*. Each page has the
// same skeleton:
//   - Header: WAYFINDER wordmark + "Skip" link (top-right)
//   - Hero card: square surface-container with 2 px amber border + Material
//     icon at 120 px
//   - Text card: surface-container with title + description
//   - Footer: page indicator (3 dots; active is amber pill) + Next button
//     ("GET STARTED" on page 3)
//
// Behaviour:
//   - PageView.onPageChanged → _tts.stopSpeaking() + _tts.speak(prompt)
//   - PopScope blocks back nav (no escape hatches during onboarding)
//   - SOS gesture wrapper is intentionally NOT used — onboarding is meant
//     to teach the user the SOS gesture; firing it from the SOS-explanation
//     page would be confusing.
//   - Skip and Get Started both set prefs.setOnboardingSeen() and
//     pushReplacement to RootRouter.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../services/audio/tts_service.dart';
import '../../services/preferences_service.dart';
import '../../services/sms_service.dart';
import '../../theme/app_theme.dart';
import 'root_router.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final PageController _controller = PageController();
  int _page = 0;
  bool _exiting = false;

  static const _pages = <_OnboardingPageData>[
    _OnboardingPageData(
      icon: Icons.hearing,
      title: 'Talk to navigate',
      body: 'Just speak — say outdoor, indoor, or your destination. '
          'Our AI-driven voice core guides you with high-precision feedback.',
      tts: kPromptOnboardingTalk,
    ),
    _OnboardingPageData(
      icon: Icons.camera_alt,
      title: 'See the path ahead',
      body: 'Your camera detects obstacles in real time and warns you.',
      tts: kPromptOnboardingPath,
    ),
    _OnboardingPageData(
      icon: Icons.report_problem,
      iconColor: AppColors.error,
      title: 'Help is one press away',
      body: 'Place two fingers anywhere on the screen to send your '
          'location to your emergency contact.',
      tts: kPromptOnboardingHelp,
    ),
  ];

  @override
  void initState() {
    super.initState();
    // Speak the first page after the first frame so the TtsService is
    // initialised by the time we call it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _speakCurrent());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _speakCurrent() async {
    final tts = ref.read(ttsServiceProvider);
    await tts.stopSpeaking(); // cancel any in-flight TTS from prev page
    if (!mounted) return;
    // ignore: discarded_futures
    tts.speak(_pages[_page].tts);
  }

  void _onPageChanged(int page) {
    setState(() => _page = page);
    // ignore: discarded_futures
    _speakCurrent();
    // SOS page (index 2) — request SEND_SMS permission while the user is
    // already being told about the gesture. If denied, SOS still works
    // (falls back to the SMS composer); we just don't get the silent path.
    if (page == 2) {
      // ignore: discarded_futures
      _requestSmsPermission();
    }
  }

  Future<void> _requestSmsPermission() async {
    final sms = ref.read(smsServiceProvider);
    final granted = await sms.requestSendSmsPermission();
    if (granted) {
      debugPrint('[SOS] SEND_SMS permission granted');
      return;
    }
    // Distinguish a plain Android denial from a vendor-block path —
    // useful for diagnosing MIUI / Samsung / EMUI behaviour from logcat.
    final after = await sms.getSmsPermissionState();
    if (after == SmsPermissionState.permanentlyDenied) {
      debugPrint(
          '[SOS] onboarding SMS request blocked by vendor security');
    } else {
      debugPrint(
          '[SOS] SEND_SMS permission denied — will use SMS app fallback');
    }
  }

  Future<void> _next() async {
    if (_page < _pages.length - 1) {
      await _controller.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    } else {
      await _finish();
    }
  }

  Future<void> _skip() async {
    await _finish();
  }

  Future<void> _finish() async {
    if (_exiting) return;
    _exiting = true;
    // ignore: discarded_futures
    ref.read(ttsServiceProvider).stopSpeaking();
    await ref.read(preferencesServiceProvider).setOnboardingSeen();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const RootRouter()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Block back navigation during onboarding — no escape hatches.
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Column(
            children: [
              _Header(onSkip: _skip),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _pages.length,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (_, i) => _OnboardingPage(data: _pages[i]),
                ),
              ),
              _Footer(
                pageCount: _pages.length,
                currentPage: _page,
                isLast: _page == _pages.length - 1,
                onNext: _next,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Header (wordmark + Skip) ───────────────────────────────────────────
class _Header extends StatelessWidget {
  final VoidCallback onSkip;
  const _Header({required this.onSkip});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenPadding, vertical: 8),
      child: SizedBox(
        height: AppSpacing.touchTargetMin,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
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
            Semantics(
              button: true,
              label: 'Skip onboarding',
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  onTap: onSkip,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    child: Text(
                      'Skip',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 20,
                        height: 24 / 20,
                        fontWeight: FontWeight.w700,
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Page ───────────────────────────────────────────────────────────────
class _OnboardingPage extends StatelessWidget {
  final _OnboardingPageData data;
  const _OnboardingPage({required this.data});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenPadding,
          vertical: AppSpacing.elementGap),
      child: Column(
        children: [
          // Hero illustration card — square, amber border.
          Expanded(
            child: AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(AppRadius.xxl),
                  border: Border.all(
                      color: AppColors.primaryContainer, width: 2),
                ),
                child: Center(
                  child: ExcludeSemantics(
                    child: Icon(
                      data.icon,
                      size: 120,
                      color: data.iconColor ?? AppColors.primaryContainer,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.stackMargin),
          // Text card.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainer,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: AppColors.surfaceVariant, width: 2),
            ),
            child: Semantics(
              liveRegion: true,
              label: '${data.title}. ${data.body}',
              child: Column(
                children: [
                  Text(
                    data.title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 32,
                      height: 40 / 32,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.32,
                      color: AppColors.onSurface,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.elementGap),
                  Text(
                    data.body,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 18,
                      height: 28 / 18,
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Footer (dots + Next/Get Started) ───────────────────────────────────
class _Footer extends StatelessWidget {
  final int pageCount;
  final int currentPage;
  final bool isLast;
  final VoidCallback onNext;
  const _Footer({
    required this.pageCount,
    required this.currentPage,
    required this.isLast,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenPadding,
          AppSpacing.elementGap,
          AppSpacing.screenPadding,
          AppSpacing.stackMargin),
      child: Column(
        children: [
          _PageDots(count: pageCount, current: currentPage),
          const SizedBox(height: AppSpacing.elementGap),
          Semantics(
            button: true,
            label: isLast ? 'Get Started' : 'Next',
            child: SizedBox(
              width: double.infinity,
              height: AppSpacing.touchTargetMin,
              child: ElevatedButton(
                onPressed: onNext,
                child: Text(
                  isLast ? 'GET STARTED' : 'NEXT',
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.0,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PageDots extends StatelessWidget {
  final int count;
  final int current;
  const _PageDots({required this.count, required this.current});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++) ...[
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: i == current ? 32 : 12,
              height: 12,
              decoration: BoxDecoration(
                color: i == current
                    ? AppColors.primaryContainer
                    : AppColors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
            ),
            if (i < count - 1) const SizedBox(width: 12),
          ],
        ],
      ),
    );
  }
}

// ── Page data ──────────────────────────────────────────────────────────
class _OnboardingPageData {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String body;
  final String tts;
  const _OnboardingPageData({
    required this.icon,
    this.iconColor,
    required this.title,
    required this.body,
    required this.tts,
  });
}
