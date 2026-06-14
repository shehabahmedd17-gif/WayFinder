// Thin wrapper around flutter_tts. Speaks via the Android system TTS engine
// (Google TTS on most devices). Supports barge-in via stopSpeaking().
//
// py: speak(), speak_bg(), stop_speaking(), _tts_interrupt (lines 410-448)
//
// ─── Why a Completer (not just `await _tts.speak()`) ──────────────────────
// `flutter_tts.awaitSpeakCompletion(true)` is supposed to make
// `_tts.speak()` resolve only when the engine has actually finished
// speaking. On some Android TTS engines (including the Google TTS service
// shipped on Snapdragon-685 devices we tested) that contract is silently
// not honoured — `await _tts.speak()` returned in ~2 ms, which left the
// outdoor option-presentation loop firing speak() calls back-to-back, and
// QUEUE_FLUSH dropped every utterance except the last.
//
// Source-of-truth fix: we treat the platform-side `setCompletionHandler` /
// `setCancelHandler` / `setErrorHandler` callbacks as the only reliable
// "speak finished" signal, and gate the Dart-side await on a per-utterance
// `Completer<void>`. If a NEW speak() arrives before the previous one's
// handler fires, we complete the old completer first (matches QUEUE_FLUSH:
// the latest message wins, but the queued caller's await still returns).

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

// Minimal speech surface the ObstacleAnnouncer depends on. Keeping the
// announcer behind this interface means it can be unit-tested with a fake
// (no flutter_tts / no platform channels) — see test/obstacle_announcer_test.
abstract interface class SpeechSink {
  bool get isSpeaking;
  void speakBackground(String text);
  Future<void> stopSpeaking();
}

class TtsService implements SpeechSink {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  bool _speaking = false;
  final Completer<void> _readyCompleter = Completer<void>();

  // Per-utterance completer — set on each speak(), completed by the
  // platform completion/cancel/error handler. See class header.
  Completer<void>? _speakCompleter;

  bool get isReady => _ready;
  @override
  bool get isSpeaking => _speaking;

  // Public initialization. Safe to call multiple times — second call is a no-op.
  Future<void> initialize({
    String language = 'en-US',
    double rate = 0.5,
    double pitch = 1.0,
    double volume = 1.0,
  }) async {
    if (_ready) return;
    try {
      await _tts.setLanguage(language);
      await _tts.setSpeechRate(rate);
      await _tts.setPitch(pitch);
      await _tts.setVolume(volume);

      // QUEUE_FLUSH on Android: a new speak() interrupts current speech.
      // Matches Python's `is_speaking` semantics — the latest message wins.
      // We STILL request awaitSpeakCompletion(true) so well-behaved engines
      // do the right thing; the Completer below catches the engines that
      // silently ignore this call.
      final awsResult = await _tts.awaitSpeakCompletion(true);
      debugPrint('[TTS] awaitSpeakCompletion returned: $awsResult');

      _tts.setStartHandler(() {
        debugPrint('[TTS] start handler fired');
        _speaking = true;
      });
      _tts.setCompletionHandler(() {
        debugPrint('[TTS] completion handler fired');
        _speaking = false;
        _resolveSpeakCompleter();
      });
      _tts.setCancelHandler(() {
        debugPrint('[TTS] cancel handler fired');
        _speaking = false;
        _resolveSpeakCompleter();
      });
      _tts.setErrorHandler((msg) {
        debugPrint('[TTS] error handler: $msg');
        _speaking = false;
        _resolveSpeakCompleter();
      });

      _ready = true;
      if (!_readyCompleter.isCompleted) _readyCompleter.complete();
      debugPrint('[TTS] ready (lang=$language rate=$rate)');
    } catch (e) {
      debugPrint('[TTS] init failed: $e');
      if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    }
  }

  // Internal: resolve the current speak completer (if any). Safe to call
  // multiple times — completes-at-most-once.
  void _resolveSpeakCompleter() {
    final c = _speakCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Blocking speak — awaits engine readiness AND completion-handler
  /// confirmation that the utterance has finished playing. Caller-side
  /// awaits on this future are reliable across Android TTS engine versions
  /// that silently ignore `awaitSpeakCompletion(true)`.
  ///
  /// If a new speak() is invoked while a previous one is still pending,
  /// the previous completer resolves immediately — matches QUEUE_FLUSH +
  /// keeps any awaiting caller unblocked.
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    if (!_ready) await _readyCompleter.future;

    debugPrint('[TTS] $text');

    // Barge-in: resolve any pending wait before queueing the new utterance.
    _resolveSpeakCompleter();

    final completer = Completer<void>();
    _speakCompleter = completer;
    _speaking = true;
    try {
      try {
        await _tts.speak(text);
      } catch (e) {
        debugPrint('[TTS] speak failed: $e');
        _resolveSpeakCompleter();
      }
      // Wait for the platform handler to fire. 30 s timeout is belt-and-
      // braces — utterances are short; if we ever hit this the engine is
      // wedged and the caller would otherwise hang forever.
      await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          debugPrint('[TTS] WARN: speak timed out — completion handler '
              'never fired (engine likely wedged)');
        },
      );
    } finally {
      _speaking = false;
      // Clear the per-utterance completer if it's still the one we set
      // (a newer speak() may have already replaced it).
      if (identical(_speakCompleter, completer)) _speakCompleter = null;
    }
  }

  /// Fire-and-forget — main isolate keeps moving while TTS speaks.
  /// py: speak_bg()
  @override
  void speakBackground(String text) {
    // Don't await; let it run on the event loop.
    // ignore: discarded_futures
    speak(text);
  }

  /// Interrupt any current playback. Used for barge-in on tap.
  /// py: stop_speaking()
  @override
  Future<void> stopSpeaking() async {
    try {
      await _tts.stop();
    } catch (_) {}
    _speaking = false;
    // Cancel handler may not fire after `.stop()` on every engine — unblock
    // any awaiting caller manually.
    _resolveSpeakCompleter();
  }

  // Optional: enumerate available voices for the Settings page (Step 7).
  Future<List<String>> availableVoices() async {
    try {
      final v = await _tts.getVoices;
      if (v is List) return v.map((e) => e.toString()).toList();
    } catch (_) {}
    return [];
  }

  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {}
    _resolveSpeakCompleter();
  }
}

final ttsServiceProvider = Provider<TtsService>((ref) {
  final svc = TtsService();
  // Fire-and-forget init; speak() awaits readiness internally.
  // ignore: discarded_futures
  svc.initialize();
  ref.onDispose(() {
    // ignore: discarded_futures
    svc.dispose();
  });
  return svc;
});
