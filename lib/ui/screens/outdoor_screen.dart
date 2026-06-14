// OutdoorScreen — composite shell that selects a Stitch-faithful sub-view
// based on OutdoorPhase:
//
//   listeningForDestination  → DestinationListeningView
//   searching                → PlaceResultsView (loading state)
//   presentingOptions        → PlaceResultsView
//   awaitingChoice           → PlaceResultsView
//   routing                  → ActiveNavigationView ("Calculating route…")
//   navigating               → ActiveNavigationView
//   arrived                  → ArrivalView
//   idle                     → DestinationListeningView (default)
//
// The shell preserves every voice-first behavior from previous milestones:
//   - WfAppBar (menu / WAYFINDER / settings)
//   - Body GestureDetector with tap-down/up/cancel + 800 ms long-press,
//     wrapping the active sub-view. Tap = push-to-talk, long-press = arm
//     cancel-confirm, second tap while armed = confirm cancel.
//   - Inner GestureDetector on the WAYFINDER wordmark = triple-tap debug
//     text input reveal (always reachable — never blocked by overlays).
//   - LISTENING modal (Stitch listening_modal_overlay) drawn on top via
//     IgnorePointer so taps still reach the body + triple-tap underneath.
//   - WfBottomNav (Outdoor highlighted) drives mode switches.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart'
    show HapticFeedback, SystemSound, SystemSoundType;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../services/audio/tts_service.dart';
import '../../state/navigation_notifier.dart';
import '../../state/sos_notifier.dart';
import '../../theme/app_theme.dart';
import '../widgets/outdoor/active_navigation_view.dart';
import '../widgets/outdoor/arrival_view.dart';
import '../widgets/outdoor/destination_listening_view.dart';
import '../widgets/outdoor/listening_modal.dart';
import '../widgets/outdoor/place_results_view.dart';
import '../widgets/sos_gesture_wrapper.dart';
import '../widgets/wf_app_bar.dart';
import '../widgets/wf_bottom_nav.dart';

class OutdoorScreen extends ConsumerStatefulWidget {
  const OutdoorScreen({super.key});

  @override
  ConsumerState<OutdoorScreen> createState() => _OutdoorScreenState();
}

class _OutdoorScreenState extends ConsumerState<OutdoorScreen> {
  // ── Long-press cancel ──────────────────────────────────────────────────
  DateTime? _pressStart;
  final DateTime _modeEnterTime = DateTime.now();
  bool _cancelArmed = false;
  Timer? _cancelTimer;

  // ── Triple-tap debug input ─────────────────────────────────────────────
  bool _debugRevealed = false;
  final List<DateTime> _wordmarkTaps = [];
  final TextEditingController _textCtrl = TextEditingController();

  // ── Phase-announce live region ────────────────────────────────────────
  OutdoorPhase? _lastAnnouncedPhase;

  @override
  void dispose() {
    _cancelTimer?.cancel();
    _textCtrl.dispose();
    super.dispose();
  }

  // ── Tap / long-press handlers (preserved from previous milestone) ─────
  void _onBodyTapDown(TapDownDetails _) {
    _pressStart = DateTime.now();
  }

  Future<void> _onBodyTapUp(TapUpDetails _) async {
    final start = _pressStart;
    _pressStart = null;
    if (start == null) return;
    final held = DateTime.now().difference(start).inMilliseconds;
    if (held >= kCancelLongPressMs) return; // long-press handled separately

    // SOS abort beats both cancel-confirm and push-to-talk.
    final sos = ref.read(sosProvider);
    if (sos.phase == SosPhase.countdown) {
      await ref.read(sosProvider.notifier).abort();
      return;
    }

    if (_cancelArmed) {
      // Confirm cancel.
      _disarmCancel();
      ref.read(outdoorNavProvider.notifier).cancelNavigation();
      return;
    }
    await _startListening();
  }

  void _onBodyTapCancel() => _pressStart = null;

  void _onLongPress() {
    final now = DateTime.now();
    if (now.difference(_modeEnterTime).inMilliseconds < kModeSwitchGraceMs) {
      debugPrint('[OUTDOOR] long-press ignored (settling grace)');
      return;
    }
    _armCancel();
  }

  void _armCancel() {
    if (_cancelArmed) {
      _disarmCancel();
      return;
    }
    setState(() => _cancelArmed = true);
    // ignore: discarded_futures
    ref.read(ttsServiceProvider).speak(kPromptCancelArm);
    // ignore: discarded_futures
    SemanticsService.sendAnnouncement(
        View.of(context), kPromptCancelArm, TextDirection.ltr);
    _cancelTimer?.cancel();
    _cancelTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_cancelArmed) return;
      _disarmCancel();
      // ignore: discarded_futures
      ref.read(ttsServiceProvider).speak(kPromptCancelKeep);
    });
  }

  void _disarmCancel() {
    _cancelTimer?.cancel();
    _cancelTimer = null;
    if (mounted && _cancelArmed) setState(() => _cancelArmed = false);
  }

  // ── Push-to-talk ───────────────────────────────────────────────────────
  Future<void> _startListening() async {
    final tts = ref.read(ttsServiceProvider);
    if (tts.isSpeaking) {
      debugPrint('[TAP] ignored — TTS still speaking');
      return;
    }
    // ignore: discarded_futures
    HapticFeedback.lightImpact();
    SystemSound.play(SystemSoundType.click);
    await ref.read(outdoorNavProvider.notifier).startListening();
  }

  // ── Triple-tap on the WAYFINDER wordmark ──────────────────────────────
  void _onWordmarkTap() {
    final now = DateTime.now();
    _wordmarkTaps.add(now);
    _wordmarkTaps
        .removeWhere((t) => now.difference(t).inMilliseconds > 700);
    if (_wordmarkTaps.length >= 3) {
      _wordmarkTaps.clear();
      setState(() => _debugRevealed = !_debugRevealed);
    }
  }

  void _sendTyped() {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    ref.read(outdoorNavProvider.notifier).submitTranscript(text);
    _textCtrl.clear();
    if (!kDebugUI) setState(() => _debugRevealed = false);
  }

  // ── Phase → live region status string ─────────────────────────────────
  String _statusFor(OutdoorState s) {
    switch (s.phase) {
      case OutdoorPhase.idle:
        return 'Ready';
      case OutdoorPhase.listeningForDestination:
        return 'Listening for destination';
      case OutdoorPhase.searching:
        return 'Searching for ${s.query}';
      case OutdoorPhase.presentingOptions:
        return 'Found ${s.options.length} places';
      case OutdoorPhase.awaitingChoice:
        return 'Say a number from 1 to ${s.options.length}';
      case OutdoorPhase.listeningForChoice:
        return 'Listening for your choice';
      case OutdoorPhase.routing:
        return 'Calculating route';
      case OutdoorPhase.navigating:
        return 'Walking to ${s.destination?.name ?? "destination"}';
      case OutdoorPhase.arrived:
        return 'You have arrived';
    }
  }

  Widget _phaseView(OutdoorState s) {
    switch (s.phase) {
      case OutdoorPhase.idle:
      case OutdoorPhase.listeningForDestination:
        return const DestinationListeningView();
      case OutdoorPhase.searching:
      case OutdoorPhase.presentingOptions:
      case OutdoorPhase.awaitingChoice:
        return PlaceResultsView(
          state: s,
          onPickIndex: (n) => ref
              .read(outdoorNavProvider.notifier)
              .submitTranscript('option $n'),
        );
      case OutdoorPhase.listeningForChoice:
        // Standalone full-screen listening view — the option cards from
        // the awaitingChoice phase are NOT rendered behind this. The
        // earlier Stack-overlay implementation let them bleed through.
        return const ListeningModal();
      case OutdoorPhase.routing:
      case OutdoorPhase.navigating:
        return ActiveNavigationView(state: s);
      case OutdoorPhase.arrived:
        return ArrivalView(
          destinationName: s.destination?.name ?? '—',
          destinationAddress: s.destination?.address ?? '',
          onGoElsewhere: () => ref
              .read(outdoorNavProvider.notifier)
              .submitTranscript('search again'),
          onDone: () =>
              ref.read(outdoorNavProvider.notifier).cancelNavigation(),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(outdoorNavProvider);

    // Announce phase changes to TalkBack.
    if (_lastAnnouncedPhase != s.phase) {
      _lastAnnouncedPhase = s.phase;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // ignore: discarded_futures
        SemanticsService.sendAnnouncement(
            View.of(context), _statusFor(s), TextDirection.ltr);
      });
    }

    final showDebugInput = _debugRevealed || kDebugUI;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SosGestureWrapper(
        child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── Top app bar — wordmark hosts the triple-tap detector ────
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onWordmarkTap,
              child: WfAppBar(
                onTrailing: () =>
                    ref.read(ttsServiceProvider).speak('Settings coming soon.'),
              ),
            ),
            // ── Body + LISTENING overlay + bottom-nav ───────────────────
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: _onBodyTapDown,
                    onTapUp: _onBodyTapUp,
                    onTapCancel: _onBodyTapCancel,
                    onLongPress: _onLongPress,
                    child: _phaseView(s),
                  ),
                  // The LISTENING UI used to overlay here; it now lives
                  // inside _phaseView as a standalone phase (Stitch
                  // listening_modal_overlay) so the option cards can't
                  // bleed through behind it.
                  // Cancel-armed banner pinned just above the nav.
                  if (_cancelArmed)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _CancelBanner(),
                    ),
                ],
              ),
            ),
            if (showDebugInput)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.screenPadding,
                    4,
                    AppSpacing.screenPadding,
                    AppSpacing.elementGap),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        textField: true,
                        label: 'Type instead of speaking',
                        child: TextField(
                          controller: _textCtrl,
                          style:
                              const TextStyle(color: AppColors.onSurface),
                          onSubmitted: (_) => _sendTyped(),
                          decoration: const InputDecoration(
                            hintText: 'Type a destination, option, or command…',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Semantics(
                      button: true,
                      label: 'Send typed input',
                      child: ElevatedButton(
                        onPressed: _sendTyped,
                        child: const Text('Send'),
                      ),
                    ),
                  ],
                ),
              ),
            const WfBottomNav(active: WfTab.outdoor),
          ],
        ),
      ),
      ),
    );
  }
}

class _CancelBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.errorContainer,
        border: Border.all(color: AppColors.error, width: 2),
      ),
      padding: const EdgeInsets.all(14),
      child: const Text(
        'Cancel navigation?\nTap to confirm · wait 3 seconds to keep going',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'Inter',
          color: AppColors.onErrorContainer,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
