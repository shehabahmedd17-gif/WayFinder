// Step C — voice-first welcome flow.
//
// Mirrors the push-to-talk pattern from outdoor_screen but with a small,
// welcome-specific command vocabulary: outdoor / indoor / settings / help.
// The notifier owns its own STT/TTS lifecycle but never auto-opens the
// mic — the welcome screen drives `startListening()` on a body tap, same
// as outdoor mode.
//
// Tile taps on the welcome screen STILL work — they call the same
// onSwitchOutdoor / onSwitchIndoor callbacks AppMode injects below.
// If the user taps a tile while STT is active, [startListening] is no-op
// but the tile callback is invoked directly; the in-flight STT session
// (if any) is cancelled by `cancelListening()`.
//
// Tests: drive the notifier directly via a fake TTS + STT, override
// callbacks to record intent. autoListen=false in tests means no real
// platform calls.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show HapticFeedback, SystemSound, SystemSoundType;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../services/audio/stt_service.dart';
import '../services/audio/tts_service.dart';

enum WelcomePhase {
  greeting, // TTS speaking the greeting on first mount
  idle, // ready — a tap will open the mic
  listening, // STT session in progress
  processing, // got a transcript, dispatching
}

class WelcomeState {
  final WelcomePhase phase;
  final String? lastHeard;
  const WelcomeState({this.phase = WelcomePhase.greeting, this.lastHeard});

  WelcomeState copyWith({WelcomePhase? phase, String? lastHeard}) =>
      WelcomeState(
        phase: phase ?? this.phase,
        lastHeard: lastHeard ?? this.lastHeard,
      );
}

class WelcomeNotifier extends Notifier<WelcomeState> {
  // Tests set false so no real platform haptic/sound/STT is invoked.
  bool autoListen = true;

  // Wired by the welcome screen (which has access to the AppMode notifier).
  void Function()? onSwitchOutdoor;
  void Function()? onSwitchIndoor;
  void Function()? onOpenSettings;

  bool _initialized = false;

  @override
  WelcomeState build() => const WelcomeState();

  TtsService get _tts => ref.read(ttsServiceProvider);
  SttService get _stt => ref.read(sttServiceProvider);

  /// First call: speak the greeting + go idle. Subsequent calls (which
  /// happen on every welcome screen re-mount after a mode flip) delegate
  /// to [reset] so the screen always lands in a clean idle state with the
  /// greeting re-spoken — fixes the "stuck on processing after return from
  /// outdoor cancel" bug.
  Future<void> initialize() async {
    if (_initialized) {
      await reset();
      return;
    }
    _initialized = true;
    state = state.copyWith(phase: WelcomePhase.greeting);
    if (autoListen) {
      await _tts.speak(kPromptWelcomeGreeting);
    }
    state = state.copyWith(phase: WelcomePhase.idle);
  }

  /// Explicitly clear stale state (e.g. after the user cancels outdoor /
  /// indoor mode and returns to the welcome menu). Cancels any in-flight
  /// STT, flips to greeting → speaks the prompt → goes idle.
  ///
  /// Debounced — if a reset is already in progress (phase == greeting) we
  /// skip, so the double-fire from AppStateNotifier._returnToWelcome +
  /// WelcomeScreen.didChangeDependencies doesn't replay the greeting twice.
  Future<void> reset() async {
    if (state.phase == WelcomePhase.greeting) {
      debugPrint('[WELCOME] reset already in progress, skipping');
      return;
    }
    debugPrint('[WELCOME] reset called (was: ${state.phase})');
    if (state.phase == WelcomePhase.listening) {
      try {
        await _stt.stop();
      } catch (_) {}
    }
    state = const WelcomeState(phase: WelcomePhase.greeting);
    if (autoListen) {
      await _tts.speak(kPromptWelcomeGreeting);
    }
    state = state.copyWith(phase: WelcomePhase.idle);
  }

  /// Push-to-talk: open the mic for ONE utterance and dispatch the result.
  Future<void> startListening() async {
    if (state.phase == WelcomePhase.listening ||
        state.phase == WelcomePhase.processing) {
      return; // session already in flight
    }
    if (_tts.isSpeaking) {
      debugPrint('[WELCOME] tap ignored — TTS still speaking');
      return;
    }
    state = state.copyWith(phase: WelcomePhase.listening);
    if (autoListen) {
      // ignore: discarded_futures
      HapticFeedback.lightImpact();
      SystemSound.play(SystemSoundType.click);
    }
    final heard = autoListen ? await _stt.listenOnce() : '';
    await _handleResult(heard);
  }

  /// Same dispatch seam as outdoor.submitTranscript — usable for both the
  /// STT result and the triple-tap debug text input.
  Future<void> submitTranscript(String raw) => _handleResult(raw);

  /// Tile tap path: cancel any in-flight STT and let the tile callback
  /// run directly. Called by the welcome screen tile onTap handlers.
  Future<void> cancelListening() async {
    if (state.phase == WelcomePhase.listening) {
      // ignore: discarded_futures
      _stt.stop();
    }
    state = state.copyWith(phase: WelcomePhase.idle);
  }

  // ── command dispatch ────────────────────────────────────────────────────
  // Vocabularies are tuned to common STT mishearings observed on real
  // Snapdragon-685 devices with ar_EG system locale + en_US STT (Step F-2
  // follow-up). Matching precedence: settings → help → outdoor → indoor →
  // unknown — settings has the most unique phoneme so it goes first and
  // shields it from a hypothetical future collision.
  static const _kOutdoorVariants = <String>[
    'outdoor', 'outside', 'navigation', 'navigate',
    'out door', // space-separated mishear
    'auto door', // STT mishear
  ];
  static const _kIndoorVariants = <String>[
    'indoor', 'inside', 'obstacle', 'obstacles',
    'in door', // space-separated mishear
    'indore', // city Indore — same phoneme
    'andre', // common mishear
  ];
  static const _kSettingsVariants = <String>[
    'settings', 'setting', 'sittings', 'sitting',
    'options', 'preferences',
    'menu', 'configure',
  ];
  static const _kHelpVariants = <String>[
    'help', 'how do i', 'how to', "what's this", 'instructions',
    'instruction', 'guide', 'tutorial',
  ];

  Future<void> _handleResult(String raw) async {
    final t = raw.toLowerCase().trim();
    state = state.copyWith(phase: WelcomePhase.processing, lastHeard: t);
    debugPrint('[WELCOME] matching against: "$t"');

    if (t.isEmpty) {
      if (autoListen) await _tts.speak(kPromptDidntCatch);
      state = state.copyWith(phase: WelcomePhase.idle);
      return;
    }

    // 1. Settings — unique phoneme, checked first so a future shared word
    //    couldn't accidentally swallow it.
    if (_matches(t, _kSettingsVariants)) {
      debugPrint('[WELCOME] matched settings: "$t"');
      onOpenSettings?.call();
      state = state.copyWith(phase: WelcomePhase.idle);
      return;
    }
    // 2. Help.
    if (_matches(t, _kHelpVariants)) {
      debugPrint('[WELCOME] matched help: "$t"');
      if (autoListen) await _tts.speak(kPromptWelcomeHelp);
      state = state.copyWith(phase: WelcomePhase.idle);
      return;
    }
    // 3. Outdoor.
    if (_matches(t, _kOutdoorVariants)) {
      debugPrint('[WELCOME] matched outdoor: "$t"');
      if (autoListen) await _tts.speak(kPromptWelcomeSwitchOutdoor);
      onSwitchOutdoor?.call();
      // Leave phase=processing — the mode flip will tear down this screen.
      return;
    }
    // 4. Indoor — includes a special-case for the truncated "ind" result:
    //    only match on EXACT equality to avoid false positives like
    //    "indictment" or "industrial".
    if (t == 'ind' || _matches(t, _kIndoorVariants)) {
      debugPrint('[WELCOME] matched indoor: "$t"');
      if (autoListen) await _tts.speak(kPromptWelcomeSwitchIndoor);
      onSwitchIndoor?.call();
      return;
    }

    debugPrint('[WELCOME] unknown command: "$t"');
    if (autoListen) await _tts.speak(kPromptWelcomeUnknown);
    state = state.copyWith(phase: WelcomePhase.idle);
  }

  bool _matches(String lc, List<String> phrases) =>
      phrases.any((p) => lc == p || lc.contains(p));
}

final welcomeProvider =
    NotifierProvider<WelcomeNotifier, WelcomeState>(WelcomeNotifier.new);
