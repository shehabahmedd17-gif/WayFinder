// sos_countdown_overlay — full-screen red modal driven by SosNotifier.
// Port of design_reference/.../sos_countdown_overlay.
//
//   - errorContainer red (#93000A) bg
//   - Top: "SENDING EMERGENCY ALERT" + subtitle (live region)
//   - Center: huge countdown digit during phase=countdown,
//             "SENDING…" during phase=sending,
//             "ALERT SENT" + location during phase=sent.
//   - Bottom: amber-filled Cancel button + caption.
//
// The entire overlay is wrapped in a GestureDetector whose onTap also
// aborts — so a sighted or panicking user can tap ANYWHERE to cancel
// during the countdown. Once we move past `countdown` (sending / sent),
// tap-to-abort is suppressed.

import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../state/sos_notifier.dart';
import '../../theme/app_theme.dart';

class SosCountdownOverlay extends StatelessWidget {
  final SosState state;
  final VoidCallback onAbort;

  const SosCountdownOverlay({
    super.key,
    required this.state,
    required this.onAbort,
  });

  bool get _canAbort => state.phase == SosPhase.countdown;

  @override
  Widget build(BuildContext context) {
    // Belt-and-braces tap detection. The Listener catches pointer-down
    // directly (cheaper, fires earlier than tap recognition); the inner
    // GestureDetector handles the normal onTap path. Either reaching abort
    // is fine — both log so logcat shows which one fired.
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        if (_canAbort) {
          debugPrint('[SOS] overlay pointer-down → abort');
          onAbort();
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _canAbort
            ? () {
                debugPrint('[SOS] overlay onTap → abort');
                onAbort();
              }
            : null,
      child: Material(
        color: AppColors.errorContainer,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(state: state),
                Expanded(child: Center(child: _CenterDisplay(state: state))),
                _Footer(canAbort: _canAbort, onAbort: onAbort),
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
  final SosState state;
  const _Header({required this.state});

  String _liveLabel() {
    switch (state.phase) {
      case SosPhase.countdown:
        return 'Sending emergency alert in ${state.countdownValue} seconds. '
            'Tap anywhere to abort.';
      case SosPhase.sending:
        return 'Sending emergency alert now.';
      case SosPhase.sent:
        // Coordinates intentionally NOT spoken — kPromptSosSent matches
        // what the TTS engine reads aloud.
        return kPromptSosSent;
      case SosPhase.idle:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: _liveLabel(),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'SENDING EMERGENCY ALERT',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 36,
              height: 44 / 36,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
              color: Colors.white,
            ),
          ),
          SizedBox(height: AppSpacing.elementGap),
          Text(
            'First responders will be notified immediately.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 20,
              height: 28 / 20,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _CenterDisplay extends StatelessWidget {
  final SosState state;
  const _CenterDisplay({required this.state});

  @override
  Widget build(BuildContext context) {
    switch (state.phase) {
      case SosPhase.countdown:
        return Text(
          '${state.countdownValue}',
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 200,
            height: 1.0,
            fontWeight: FontWeight.w900,
            color: Colors.white,
          ),
        );
      case SosPhase.sending:
        return const Text(
          'SENDING…',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 56,
            fontWeight: FontWeight.w900,
            letterSpacing: 2.0,
            color: Colors.white,
          ),
        );
      case SosPhase.sent:
        // Coordinates are captured silently into state for SMS dispatch
        // later; we don't surface them on screen either, since the only
        // user of the visual is a sighted helper who'd see "Help is on
        // the way" as confirmation enough.
        return const Text(
          'ALERT SENT',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 56,
            fontWeight: FontWeight.w900,
            letterSpacing: 2.0,
            color: Colors.white,
          ),
        );
      case SosPhase.idle:
        return const SizedBox.shrink();
    }
  }
}

class _Footer extends StatelessWidget {
  final bool canAbort;
  final VoidCallback onAbort;
  const _Footer({required this.canAbort, required this.onAbort});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: canAbort,
          label: canAbort
              ? 'Cancel emergency alert'
              : 'Emergency alert in progress',
          child: SizedBox(
            height: AppSpacing.touchTargetMin,
            child: ElevatedButton(
              onPressed: canAbort ? onAbort : null,
              style: ElevatedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  side: const BorderSide(color: Colors.white, width: 4),
                ),
              ),
              child: const Text(
                'Cancel',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          canAbort ? 'TAP ANYWHERE TO ABORT' : 'PLEASE WAIT',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 16,
            letterSpacing: 3.0,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}
