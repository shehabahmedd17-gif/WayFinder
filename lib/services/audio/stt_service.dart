// Speech-to-text via the speech_to_text package (7.x).
// py: listen() (lines 574-593) — fixed-window record then transcribe.
//
// Push-to-talk only: the mic is opened EXACTLY when the user taps, never
// auto-started. The OutdoorNavNotifier additionally refuses to open the mic
// while TTS is still speaking, so the engine never hears the app's own voice.
//
// Initialization happens lazily on the first listenOnce(). It performs:
//   1. permission_handler check for RECORD_AUDIO (logged loudly when denied)
//   2. speech_to_text engine init
//   3. Locale enumeration — pick en_US if available, else first 'en_*',
//      else fall back to system default.
// Each diagnostic is logged with the `[STT]` / `[MIC]` prefix so logcat can
// be filtered when reproducing capture failures on real devices.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';

import '../../core/constants.dart';
import 'tts_service.dart';

class SttService {
  final stt.SpeechToText _stt = stt.SpeechToText();
  final TtsService _tts;
  bool _available = false;
  bool _initTried = false;
  bool _listening = false;
  String? _localeId; // resolved during initialize()

  SttService(this._tts);

  bool get isAvailable => _available;
  bool get isListening => _listening;
  String? get resolvedLocale => _localeId;

  /// Idempotent. Requests RECORD_AUDIO once, initializes the engine, and
  /// resolves the best available English locale.
  Future<bool> initialize() async {
    if (_initTried && _available) return true;
    _initTried = true;

    // ── 1. Mic permission ──────────────────────────────────────────────
    final micStatus = await Permission.microphone.status;
    debugPrint('[MIC] permission status: $micStatus');
    if (!micStatus.isGranted) {
      final requested = await Permission.microphone.request();
      debugPrint('[MIC] permission after request: $requested');
      if (!requested.isGranted) {
        debugPrint('[MIC] denied — STT unavailable');
        // ignore: discarded_futures
        _tts.speak(kPromptMicDenied);
        _available = false;
        return false;
      }
    }

    // ── 2. Engine init ─────────────────────────────────────────────────
    try {
      _available = await _stt.initialize(
        onError: (e) => debugPrint('[STT] error: ${e.errorMsg}'),
        onStatus: (s) => debugPrint('[STT] status: $s'),
      );
    } catch (e) {
      debugPrint('[STT] init failed: $e');
      _available = false;
    }
    if (!_available) {
      debugPrint('[STT] engine unavailable on this device');
      // ignore: discarded_futures
      _tts.speak(kPromptSttUnavailable);
      return false;
    }

    // ── 3. Locale resolution ──────────────────────────────────────────
    try {
      final system = await _stt.systemLocale();
      final locales = await _stt.locales();
      final localeIds = locales.map((l) => l.localeId).toList(growable: false);
      debugPrint(
          '[STT] systemLocale=${system?.localeId} available=${localeIds.length} '
          'sample=${localeIds.take(8).toList()}');

      bool hasExact(String id) => localeIds.contains(id);
      String? firstWherePrefix(String prefix) =>
          localeIds.where((id) => id.startsWith(prefix)).firstOrNull;

      if (hasExact('en_US')) {
        _localeId = 'en_US';
      } else if (hasExact('en-US')) {
        _localeId = 'en-US';
      } else if (firstWherePrefix('en_') != null) {
        _localeId = firstWherePrefix('en_');
      } else if (firstWherePrefix('en-') != null) {
        _localeId = firstWherePrefix('en-');
      } else {
        _localeId = system?.localeId; // last resort: device default
        debugPrint('[STT] WARN no English locale on device — using $_localeId');
      }
      debugPrint('[STT] using locale: $_localeId');
    } catch (e) {
      debugPrint('[STT] locale enumeration failed: $e — defaulting to en_US');
      _localeId = 'en_US';
    }

    debugPrint('[STT] initialized (available=$_available, locale=$_localeId)');
    return _available;
  }

  /// Listen for a single utterance (push-to-talk: caller invokes this on a
  /// user tap, never automatically). Returns the recognized words, or '' on
  /// timeout / unavailable / error. Stops after [window] OR [kSttPauseFor] of
  /// trailing silence after speech, whichever comes first.
  Future<String> listenOnce({
    Duration window = const Duration(seconds: kSttWindowSec),
    Duration pauseFor = kSttPauseFor,
  }) async {
    if (!_available && !await initialize()) return '';

    debugPrint('[STT] listening '
        '(window=${window.inSeconds}s, pauseFor=${pauseFor.inSeconds}s, '
        'locale=$_localeId)');

    final completer = Completer<String>();
    String lastPartial = '';
    _listening = true;

    void onResult(SpeechRecognitionResult r) {
      if (!r.finalResult) {
        lastPartial = r.recognizedWords;
        debugPrint('[STT] partial: "$lastPartial"');
      } else {
        debugPrint('[STT] final: "${r.recognizedWords}"');
        if (!completer.isCompleted) completer.complete(r.recognizedWords);
      }
    }

    try {
      await _stt.listen(
        onResult: onResult,
        listenFor: window,
        pauseFor: pauseFor,
        localeId: _localeId,
        listenOptions: stt.SpeechListenOptions(
          // partialResults=true so we can see what the engine is picking up
          // in logcat while the user speaks. The notifier still only acts on
          // the final result.
          partialResults: true,
          cancelOnError: true,
          listenMode: stt.ListenMode.confirmation,
        ),
      );
    } catch (e) {
      debugPrint('[STT] listen failed: $e');
      _listening = false;
      return '';
    }

    // Engine should auto-finalize via pauseFor; this is the belt-and-braces
    // timeout in case the platform never delivers a final result. If we time
    // out but have a partial, salvage it.
    final result = await completer.future.timeout(
      window + const Duration(seconds: 2),
      onTimeout: () => lastPartial,
    );
    _listening = false;
    await _stt.stop();
    final cleaned = result.trim();
    debugPrint('[STT] heard: "${cleaned.isEmpty ? "(nothing)" : cleaned}"');
    return cleaned;
  }

  Future<void> stop() async {
    _listening = false;
    try {
      await _stt.stop();
    } catch (_) {}
  }
}

final sttServiceProvider = Provider<SttService>((ref) {
  final svc = SttService(ref.read(ttsServiceProvider));
  ref.onDispose(() {
    // ignore: discarded_futures
    svc.stop();
  });
  return svc;
});
