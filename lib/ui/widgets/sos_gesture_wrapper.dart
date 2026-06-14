// Shared two-finger-tap → SOS detector + countdown overlay.
//
// Wraps every main screen body. The Listener sits ABOVE the screen's
// existing GestureDetector(single tap → push-to-talk, long-press → cancel)
// so single-finger taps fall through unchanged. The Listener tracks the
// active pointer count and fires SosNotifier.startCountdown() once on the
// first frame where the count reaches 2. `_twoFingerFired` debounces
// wobbly multi-touch so we only arm once per gesture.
//
// While the overlay is visible (SosPhase != idle) the underlying screen
// is wrapped in IgnorePointer so the overlay is the ONLY thing that can
// receive taps — fixes the "tap-to-abort sometimes works" bug where the
// body GestureDetector was winning the hit-test arena.
//
// When the SOS phase transitions back to idle (abort or sent → idle), we
// reset `_twoFingerFired` so a fresh two-finger gesture re-arms cleanly.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../state/sos_notifier.dart';
import 'sos_countdown_overlay.dart';

class SosGestureWrapper extends ConsumerStatefulWidget {
  final Widget child;
  const SosGestureWrapper({super.key, required this.child});

  @override
  ConsumerState<SosGestureWrapper> createState() => _SosGestureWrapperState();
}

class _SosGestureWrapperState extends ConsumerState<SosGestureWrapper> {
  int _activePointers = 0;
  bool _twoFingerFired = false;
  final DateTime _mountedAt = DateTime.now();

  bool get _inGrace =>
      DateTime.now().difference(_mountedAt).inMilliseconds < kSosArmGraceMs;

  void _onPointerDown(PointerDownEvent _) {
    _activePointers++;
    if (_activePointers < 2 || _twoFingerFired) return;
    if (_inGrace) {
      debugPrint('[SOS] two-finger ignored — settle grace');
      return;
    }
    final sos = ref.read(sosProvider);
    if (sos.phase != SosPhase.idle) {
      debugPrint('[SOS] two-finger ignored — phase=${sos.phase}');
      return;
    }
    _twoFingerFired = true;
    // ignore: discarded_futures
    ref.read(sosProvider.notifier).startCountdown();
  }

  void _onPointerRelease() {
    if (_activePointers > 0) _activePointers--;
    if (_activePointers == 0) _twoFingerFired = false;
  }

  @override
  Widget build(BuildContext context) {
    // When SOS returns to idle (abort or post-sent reset), force-clear the
    // two-finger flag even if a stray pointer is still held — otherwise the
    // next emergency gesture would be ignored.
    ref.listen<SosState>(sosProvider, (prev, next) {
      if (prev?.phase != SosPhase.idle && next.phase == SosPhase.idle) {
        _twoFingerFired = false;
      }
    });

    final sos = ref.watch(sosProvider);
    final overlayActive = sos.phase != SosPhase.idle;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerUp: (_) => _onPointerRelease(),
      onPointerCancel: (_) => _onPointerRelease(),
      child: Stack(
        children: [
          // IgnorePointer so the body's GestureDetector can't steal the
          // tap from the overlay's abort handler when SOS is active.
          IgnorePointer(
            ignoring: overlayActive,
            child: widget.child,
          ),
          if (overlayActive)
            Positioned.fill(
              child: SosCountdownOverlay(
                state: sos,
                onAbort: () => ref.read(sosProvider.notifier).abort(),
              ),
            ),
        ],
      ),
    );
  }
}
