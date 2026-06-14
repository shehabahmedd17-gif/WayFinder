// Thin vibration wrapper. py: vibrate pulses around turn/arrival/SOS.
//
// Behind a provider so navigation_notifier_test can override it with a
// no-op fake (the real Vibration plugin throws MissingPluginException under
// flutter_test). All calls are best-effort: a device with no vibrator, or a
// test harness, simply does nothing.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vibration/vibration.dart';

class HapticsService {
  Future<bool> _hasVibrator() async {
    try {
      return await Vibration.hasVibrator();
    } catch (_) {
      return false;
    }
  }

  /// One short pulse — fired just before a turn-instruction announcement.
  Future<void> short() async {
    try {
      if (await _hasVibrator()) Vibration.vibrate(duration: 120);
    } catch (e) {
      debugPrint('[HAPTIC] short failed: $e');
    }
  }

  /// Three long pulses — "you have arrived".
  Future<void> arrived() async {
    try {
      if (await _hasVibrator()) {
        Vibration.vibrate(pattern: [0, 500, 250, 500, 250, 500]);
      }
    } catch (e) {
      debugPrint('[HAPTIC] arrived failed: $e');
    }
  }
}

final hapticsServiceProvider =
    Provider<HapticsService>((ref) => HapticsService());
