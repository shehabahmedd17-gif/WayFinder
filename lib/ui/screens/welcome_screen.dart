// home_mode_select — voice-first welcome (Step C).
//
// Behavior:
//   1. On mount, WelcomeNotifier auto-speaks the greeting once.
//   2. Tap anywhere → push-to-talk STT (welcome-specific vocabulary:
//      outdoor / indoor / settings / help). See welcome_notifier.dart.
//   3. Tile taps STILL work — they cancel any in-flight STT and call
//      the same mode-switch callbacks as the voice match.
//   4. Triple-tap the WAYFINDER wordmark → debug text input.
//
// Visual layout (unchanged from the previous Stitch rebuild):
//   - 56 px header: WAYFINDER (left) + settings gear (right)
//   - Two huge stacked mode tiles (Expanded each)
//   - Footer: "Or tap anywhere and speak" caption + 72 px mic ring,
//     which now pulses amber when phase==listening.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../services/audio/tts_service.dart';
import '../../state/app_state_notifier.dart';
import '../../state/sos_notifier.dart';
import '../../state/welcome_notifier.dart';
import '../../theme/app_theme.dart';
import '../widgets/sos_gesture_wrapper.dart';
import 'settings_screen.dart';

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  bool _debugRevealed = false;
  final List<DateTime> _taps = [];
  final TextEditingController _textCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Wire the WelcomeNotifier callbacks to the existing AppMode switch,
    // then kick off the greeting + idle transition. Defers one frame so
    // the provider is fully built before we read it.
    //
    // `initialize()` is idempotent — second call from a re-mount delegates
    // to `reset()` so the user always lands in idle phase with a fresh
    // greeting after returning from outdoor/indoor.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final w = ref.read(welcomeProvider.notifier);
      final app = ref.read(appModeProvider.notifier);
      w
        ..onSwitchOutdoor = () {
          // ignore: discarded_futures
          app.switchToOutdoor();
        }
        ..onSwitchIndoor = () {
          // ignore: discarded_futures
          app.switchToIndoor();
        }
        ..onOpenSettings = _openSettings;
      await w.initialize();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Defense-in-depth: if we somehow end up on the welcome screen with a
    // stale phase (e.g. AppStateNotifier failed to call reset() during a
    // return path we didn't think of), self-heal here. Only `processing`
    // is stale — `idle`, `greeting`, and `listening` are all in-flight
    // legitimate states.
    final wState = ref.read(welcomeProvider);
    if (wState.phase == WelcomePhase.processing) {
      debugPrint(
          '[WELCOME] screen mounted with stale phase=${wState.phase} — resetting');
      // ignore: discarded_futures
      ref.read(welcomeProvider.notifier).reset();
    }
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  void _onWordmarkTap() {
    final now = DateTime.now();
    _taps.add(now);
    _taps.removeWhere((t) => now.difference(t).inMilliseconds > 700);
    if (_taps.length >= 3) {
      _taps.clear();
      setState(() => _debugRevealed = !_debugRevealed);
    }
  }

  Future<void> _onBodyTap() async {
    // Voice "cancel" during SOS countdown should abort SOS, not the mic.
    // The SOS overlay also catches tap-anywhere → abort, but we belt-and-
    // braces it here for any path that reaches _onBodyTap first.
    final sos = ref.read(sosProvider);
    if (sos.phase == SosPhase.countdown) {
      await ref.read(sosProvider.notifier).abort();
      return;
    }
    // Push-to-talk: open the mic for ONE utterance. Welcome-specific
    // commands are matched inside WelcomeNotifier.
    await ref.read(welcomeProvider.notifier).startListening();
  }

  void _onSettings() => _openSettings();

  void _openSettings() {
    // Spoken cue first (TTS barge-in is fine if greeting still playing).
    // ignore: discarded_futures
    ref.read(ttsServiceProvider).speak(kPromptSettingsOpening);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    // VOICE-FIRST WELCOME SCREEN
    //
    // Primary user is blind. The OUTDOOR and INDOOR tiles are VISUAL-ONLY
    // indicators showing which modes exist — they are NOT tappable buttons.
    // The entire screen body is a single push-to-talk surface: any tap
    // activates STT, and the user speaks "outdoor" or "indoor" to switch
    // modes.
    //
    // This design prioritizes consistency (any tap = voice) over
    // sighted-user convenience (no direct-tap shortcut to switch modes).
    // The trade-off is intentional given the target user — a blind user
    // cannot reliably distinguish a tile from empty space, so giving
    // tiles their own gesture would lead to wrong-mode entries.
    //
    // Sighted users who want a direct tap shortcut can use the triple-tap
    // debug input on the WAYFINDER wordmark to type "outdoor" or "indoor".
    final showDebug = _debugRevealed || kDebugUI;
    final wState = ref.watch(welcomeProvider);
    final isListening = wState.phase == WelcomePhase.listening;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SosGestureWrapper(
        child: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onBodyTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(onWordmarkTap: _onWordmarkTap, onSettings: _onSettings),
                const SizedBox(height: AppSpacing.elementGap),
                // Two equally-sized VISUAL-ONLY mode indicators. No
                // GestureDetector / InkWell / Button — taps pass straight
                // through to the body GestureDetector above (push-to-talk).
                Expanded(
                  child: _ModeTile(
                    label: 'OUTDOOR',
                    icon: Icons.explore,
                    filled: true,
                    semanticHint:
                        'Outdoor mode — say outdoor to activate',
                  ),
                ),
                const SizedBox(height: AppSpacing.elementGap),
                Expanded(
                  child: _ModeTile(
                    label: 'INDOOR',
                    icon: Icons.home_work,
                    filled: false,
                    semanticHint:
                        'Indoor mode — say indoor to activate',
                  ),
                ),
                const SizedBox(height: AppSpacing.stackMargin),
                _Footer(
                  showDebug: showDebug,
                  isListening: isListening,
                  textCtrl: _textCtrl,
                  onTypedSubmit: (text) => ref
                      .read(welcomeProvider.notifier)
                      .submitTranscript(text),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onWordmarkTap;
  final VoidCallback onSettings;
  const _Header({required this.onWordmarkTap, required this.onSettings});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppSpacing.touchTargetMin,
      child: Row(
        children: [
          // Triple-tap target = the wordmark itself.
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onWordmarkTap,
              child: Semantics(
                header: true,
                label: kAppName,
                child: Text(
                  kAppName.toUpperCase(),
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 32,
                    height: 40 / 32,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.32,
                    color: AppColors.onSurface,
                  ),
                ),
              ),
            ),
          ),
          Semantics(
            button: true,
            label: 'Settings',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                onTap: onSettings,
                child: const SizedBox(
                  width: AppSpacing.touchTargetMin,
                  height: AppSpacing.touchTargetMin,
                  child: Icon(Icons.settings,
                      color: AppColors.primaryContainer, size: 32),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// VISUAL-ONLY mode indicator. No GestureDetector / Material / InkWell —
// taps pass through to the parent body GestureDetector (push-to-talk).
//
// Semantics: marked as `header` with a hint label that tells screen-reader
// users which voice command activates this mode. Not focusable as a
// button — the only interactive control on this screen is the body itself.
class _ModeTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool filled;
  final String semanticHint;
  const _ModeTile({
    required this.label,
    required this.icon,
    required this.filled,
    required this.semanticHint,
  });

  @override
  Widget build(BuildContext context) {
    final bg = filled ? AppColors.primaryContainer : AppColors.surfaceContainer;
    final fg = filled ? AppColors.onPrimaryFixed : AppColors.primaryContainer;
    return Semantics(
      // Header role — describes a section, not a button. The screen-reader
      // will read the hint but won't tell the user this is tappable, which
      // matches reality (taps anywhere → mic).
      header: true,
      label: semanticHint,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: filled
              ? null
              : Border.all(
                  color: AppColors.primaryContainer, width: 2),
        ),
        child: Stack(
          children: [
            // Centered icon + label
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(child: Icon(icon, color: fg, size: 64)),
                  const SizedBox(height: 16),
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      color: fg,
                      fontSize: 40,
                      height: 48 / 40,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                ],
              ),
            ),
            // Top-right voice badge — small mic glyph telling sighted
            // users this tile is voice-activated, not tap-activated.
            Positioned(
              top: 12,
              right: 12,
              child: ExcludeSemantics(
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fg.withValues(alpha: 0.12),
                    border: Border.all(
                        color: fg.withValues(alpha: 0.50), width: 1.5),
                  ),
                  child: Icon(Icons.mic, color: fg, size: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final bool showDebug;
  final bool isListening;
  final TextEditingController textCtrl;
  final void Function(String) onTypedSubmit;
  const _Footer({
    required this.showDebug,
    required this.isListening,
    required this.textCtrl,
    required this.onTypedSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final caption =
        isListening ? 'Listening…' : 'Or tap anywhere and speak';
    final captionColor =
        isListening ? AppColors.primaryContainer : AppColors.onSurface;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          label: caption,
          child: Text(
            caption,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              color: captionColor,
              fontSize: 18,
              height: 28 / 18,
              fontWeight: isListening ? FontWeight.w800 : FontWeight.w400,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.elementGap),
        Center(
          child: _MicRing(active: isListening),
        ),
        if (showDebug) ...[
          const SizedBox(height: AppSpacing.elementGap),
          _DebugInputRow(textCtrl: textCtrl, onSubmit: onTypedSubmit),
        ],
      ],
    );
  }
}

// 96 px mic ring — the SOLE interactive visual cue on this screen (now
// that tiles are visual-only). When `active` (STT listening), the border
// + glyph go solid amber with a soft glow. The real input affordance is
// the body's HitTestBehavior.opaque GestureDetector that wraps the entire
// screen, so this widget is decorative.
class _MicRing extends StatelessWidget {
  final bool active;
  const _MicRing({required this.active});

  @override
  Widget build(BuildContext context) {
    final borderAlpha = active ? 1.0 : 0.40;
    final iconAlpha = active ? 1.0 : 0.70;
    return ExcludeSemantics(
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: AppColors.primaryContainer.withValues(alpha: borderAlpha),
            width: active ? 4 : 2,
          ),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: AppColors.primaryContainer.withValues(alpha: 0.40),
                    blurRadius: 32,
                    spreadRadius: 6,
                  ),
                ]
              : null,
        ),
        child: Icon(
          Icons.mic,
          color: AppColors.primaryContainer.withValues(alpha: iconAlpha),
          size: 44,
        ),
      ),
    );
  }
}

class _DebugInputRow extends StatelessWidget {
  final TextEditingController textCtrl;
  final void Function(String) onSubmit;
  const _DebugInputRow({required this.textCtrl, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    void submit() {
      final v = textCtrl.text.trim();
      if (v.isEmpty) return;
      onSubmit(v);
      textCtrl.clear();
    }

    return Row(
      children: [
        Expanded(
          child: Semantics(
            textField: true,
            label: 'Type instead of speaking',
            child: TextField(
              controller: textCtrl,
              style: const TextStyle(color: AppColors.onSurface),
              onSubmitted: (_) => submit(),
              decoration: const InputDecoration(
                hintText: 'Type outdoor, indoor, or help…',
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Semantics(
          button: true,
          label: 'Send typed input',
          child: ElevatedButton(
            onPressed: submit,
            child: const Text('Send'),
          ),
        ),
      ],
    );
  }
}
