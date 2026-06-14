// Outdoor navigation state machine. py:run_destination_select →
// _present_options_and_choose → get_walking_route → navigation_poller
// (lines 1013-1240), restructured as an explicit phase enum.
//
// Testability seam: submitTranscript(String) is the SINGLE entry point for
// STT results, the debug text input, and unit tests. The notifier never
// blocks a test on a real mic — when autoListen is false (tests set this),
// no STT loop is pumped and the test drives the machine purely through
// submitTranscript().

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/constants.dart';
import '../models/location_fix.dart';
import '../models/place.dart';
import '../models/route.dart';
import '../services/audio/stt_service.dart';
import '../services/audio/tts_service.dart';
import '../services/camera_service.dart';
import '../services/feedback/haptics_service.dart';
import '../services/location/gps_service.dart';
import '../services/ml/pipeline_provider.dart';
import '../services/places/option_parser.dart';
import '../services/places/places_service.dart';
import '../services/routes/navigation_poller.dart';
import '../services/routes/routes_service.dart';
import 'sos_notifier.dart';

enum OutdoorPhase {
  idle,
  listeningForDestination,
  searching,
  presentingOptions,
  awaitingChoice,
  // Standalone "WHAT IS YOUR COMMAND?" screen rendered during the option
  // choice push-to-talk. Modelled as its own phase (not an overlay on
  // awaitingChoice) so the options list cannot bleed through behind the
  // listening view.
  listeningForChoice,
  routing,
  navigating,
  arrived,
}

class OutdoorState {
  final OutdoorPhase phase;
  final String query;
  final List<Place> options;
  final Place? destination;
  final Route? route;
  final int currentStepIndex;
  final int remainingMeters;
  final int retryCount;
  final String? error; // user-facing message for the UI
  final bool listening; // mic is open for this push-to-talk session

  const OutdoorState({
    this.phase = OutdoorPhase.idle,
    this.query = '',
    this.options = const [],
    this.destination,
    this.route,
    this.currentStepIndex = 0,
    this.remainingMeters = 0,
    this.retryCount = 0,
    this.error,
    this.listening = false,
  });

  OutdoorState copyWith({
    OutdoorPhase? phase,
    String? query,
    List<Place>? options,
    Place? destination,
    Route? route,
    int? currentStepIndex,
    int? remainingMeters,
    int? retryCount,
    String? error,
    bool clearError = false,
    bool? listening,
  }) {
    return OutdoorState(
      phase: phase ?? this.phase,
      query: query ?? this.query,
      options: options ?? this.options,
      destination: destination ?? this.destination,
      route: route ?? this.route,
      currentStepIndex: currentStepIndex ?? this.currentStepIndex,
      remainingMeters: remainingMeters ?? this.remainingMeters,
      retryCount: retryCount ?? this.retryCount,
      error: clearError ? null : (error ?? this.error),
      listening: listening ?? this.listening,
    );
  }

  String? get currentInstruction =>
      (route != null && currentStepIndex < route!.steps.length)
          ? route!.steps[currentStepIndex].instruction
          : null;

  String? get nextInstruction =>
      (route != null && currentStepIndex + 1 < route!.steps.length)
          ? route!.steps[currentStepIndex + 1].instruction
          : null;
}

class OutdoorNavNotifier extends Notifier<OutdoorState> {
  NavigationPoller? _poller;
  Timer? _arrivedTimer;

  // Set false by tests so no STT loop is pumped. Set by the AppMode wiring
  // to return to the mode menu when navigation is cancelled / completed.
  bool autoListen = true;
  void Function()? onRequestExit;

  // Guard: while we are reading options aloud, ignore stray phase-changing
  // transcripts (a partial recognition could otherwise restart the search and
  // truncate the option list). `cancel` still goes through.
  bool _isReadingOptions = false;
  bool get isReadingOptions => _isReadingOptions;

  @override
  OutdoorState build() => const OutdoorState();

  // ── Service accessors ────────────────────────────────────────────────────
  TtsService get _tts => ref.read(ttsServiceProvider);
  SttService get _stt => ref.read(sttServiceProvider);
  PlacesService get _places => ref.read(placesServiceProvider);
  RoutesService get _routes => ref.read(routesServiceProvider);
  HapticsService get _haptics => ref.read(hapticsServiceProvider);
  GpsService get _gps => ref.read(gpsServiceProvider);

  // ── GPS-lost watcher (Part A) ───────────────────────────────────────────
  Timer? _gpsWatcherTimer;
  DateTime? _lastRealFixTime;
  bool _gpsLostAnnounced = false;
  // Test/instrumentation hook.
  bool get isGpsLostAnnounced => _gpsLostAnnounced;
  // Bumped each time we cancel/teardown so any in-flight async warning
  // loop (e.g. _maybeWarnNoGps) bails immediately.
  int _epoch = 0;

  // Part B — outdoor obstacle pipeline lifecycle. Tests set false to skip
  // touching the platform plugins; otherwise navigating phase brings up
  // the same camera + ML pipeline that indoor mode uses.
  bool autoStartPipeline = true;
  bool _pipelineStarted = false;
  bool get isPipelineActive => _pipelineStarted;

  void _say(String s) {
    // Fire-and-forget; barge-in handled by TTS itself.
    // ignore: discarded_futures
    _tts.speak(s);
  }

  // ── Entry ────────────────────────────────────────────────────────────────
  /// Called by the AppMode switch after GPS has been started. Speaks the
  /// prompt ONCE and then goes silent — STT is never auto-started (that caused
  /// the TTS→mic echo loop). The user taps the screen to talk; the outdoor
  /// screen calls [startListening].
  ///
  /// Also checks for a real GPS fix and warns the user UP FRONT if only the
  /// Cairo fallback is available — this saves a wasted Places search +
  /// option selection that would later be rejected for "Location not
  /// available."
  void enterOutdoor() {
    state = const OutdoorState(phase: OutdoorPhase.listeningForDestination);
    _say(kPromptAskDestination); // py:1017
    // ignore: discarded_futures
    _maybeWarnNoGps();
  }

  // Wait up to kOutdoorGpsCheckSec for a real (non-fallback) fix; if none
  // arrives, speak kPromptOutdoorNoGps once. Bails immediately if the
  // notifier is cancelled/torn down (epoch changes).
  Future<void> _maybeWarnNoGps() async {
    final epoch = _epoch;
    final deadline =
        DateTime.now().add(Duration(seconds: kOutdoorGpsCheckSec));
    while (DateTime.now().isBefore(deadline)) {
      if (_epoch != epoch) return; // teardown / cancel
      final fix = ref.read(currentLocationProvider);
      if (fix != null && !fix.isFallback) {
        debugPrint('[OUTDOOR] real GPS fix present on enter — no warning');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (_epoch != epoch) return;
    if (state.phase == OutdoorPhase.idle) return;
    debugPrint('[OUTDOOR] no real GPS fix on enter — warning user');
    _say(kPromptOutdoorNoGps);
  }

  /// Push-to-talk: open the mic for ONE utterance and feed the result through
  /// [submitTranscript]. Triggered by a screen tap (cue + haptic played by the
  /// UI). Refuses to start while TTS is still speaking — otherwise the mic
  /// would record the app's own voice. No-op in tests (autoListen=false).
  Future<void> startListening() async {
    if (!autoListen) return;
    if (state.listening) return; // already in a session
    if (_tts.isSpeaking) {
      debugPrint('[STT] tap ignored — TTS still speaking');
      return;
    }
    if (_isReadingOptions) {
      debugPrint('[STT] tap ignored — still reading options');
      return;
    }
    // Phase-aware: when the user taps during awaitingChoice we promote to
    // listeningForChoice so the UI can render a STANDALONE listening view
    // (no option cards bleeding through). Other phases keep the existing
    // listening flag, which their dedicated views already drive.
    final wasAwaitingChoice = state.phase == OutdoorPhase.awaitingChoice;
    if (wasAwaitingChoice) {
      debugPrint(
          '[OUTDOOR] phase transition: awaitingChoice → listeningForChoice');
      state = state.copyWith(
        phase: OutdoorPhase.listeningForChoice,
        listening: true,
      );
    } else {
      state = state.copyWith(listening: true);
    }
    String heard = '';
    try {
      // During navigation the user is outside in traffic noise — give the
      // STT engine more time to absorb noise-affected speech before
      // aborting. Other phases use the default tighter window.
      final isNav = state.phase == OutdoorPhase.navigating;
      heard = await _stt.listenOnce(
        window: Duration(
            seconds: isNav ? kSttNavWindowSec : kSttWindowSec),
        pauseFor: isNav ? kSttNavPauseFor : kSttPauseFor,
      );
    } finally {
      state = state.copyWith(listening: false);
    }
    final t = heard.trim();
    if (t.isEmpty) {
      if (wasAwaitingChoice) {
        debugPrint(
            '[OUTDOOR] phase transition: listeningForChoice → awaitingChoice '
            '(empty / timeout)');
        state = state.copyWith(phase: OutdoorPhase.awaitingChoice);
      }
      _say(kPromptDidntCatch);
      return;
    }
    if (wasAwaitingChoice) {
      // submitTranscript may move us into routing/listeningForDestination
      // on its own — only fall back to awaitingChoice if it doesn't.
      submitTranscript(t);
      if (state.phase == OutdoorPhase.listeningForChoice) {
        debugPrint(
            '[OUTDOOR] phase transition: listeningForChoice → awaitingChoice '
            '(no phase change in dispatcher)');
        state = state.copyWith(phase: OutdoorPhase.awaitingChoice);
      }
      return;
    }
    submitTranscript(t);
  }

  // ── THE single input seam ────────────────────────────────────────────────
  void submitTranscript(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    final lc = text.toLowerCase();

    // Global voice commands — valid in any phase (py:1391-1485 handle_command).
    // `cancel` is always honored, even while options are being read.
    if (_matchAny(lc, _kNavCancelVariants)) {
      // SOS countdown abort precedes outdoor cancel — a user saying "cancel"
      // during a countdown almost certainly means the alert, not the trip.
      final sos = ref.read(sosProvider.notifier);
      if (sos.isCountingDown) {
        // ignore: discarded_futures
        sos.abort();
        return;
      }
      _cancel();
      return;
    }
    if (_isReadingOptions) {
      debugPrint('[NAV] ignoring transcript "$text" — reading options');
      return;
    }
    // ── Active-navigation voice commands ────────────────────────────────
    // Take precedence over destination-search re-entry. Vocabularies are
    // hardened against real-device STT mishears (Part-A follow-up):
    // accept common substring variants the engine produces under traffic
    // noise + non-American accents.
    if (state.phase == OutdoorPhase.navigating) {
      debugPrint('[NAV] matching against: "$lc"');
      // 'go' must be exact-only — "going to the store" must not advance.
      if (lc == 'go' || _matchAny(lc, _kNavNextVariants)) {
        debugPrint('[STEP] manual advance requested');
        skipStep();
        return;
      }
      if (_matchAny(lc, _kNavRepeatVariants)) {
        _repeat();
        return;
      }
      if (_matchAny(lc, _kNavHowFarVariants)) {
        _howFar();
        return;
      }
      if (_matchAny(lc, _kNavWhereVariants)) {
        _whereAmI();
        return;
      }
      // Unknown command during navigation — don't treat as new search.
      debugPrint('[NAV] unrecognized navigation command: "$lc"');
      _say(kPromptNavUnknownCmd);
      return;
    }

    // ── Global voice commands (other phases) ────────────────────────────
    if (_matches(lc, ['repeat', 'say again', 'again'])) {
      _repeat();
      return;
    }
    if (_matches(lc, ['how far', 'how far is it', 'distance left'])) {
      _howFar();
      return;
    }
    if (_matches(lc, ['where am i', 'where are we', "where's"])) {
      _whereAmI();
      return;
    }

    switch (state.phase) {
      case OutdoorPhase.listeningForDestination:
      case OutdoorPhase.idle:
        state = state.copyWith(query: text, clearError: true);
        _search();
      case OutdoorPhase.awaitingChoice:
      case OutdoorPhase.listeningForChoice:
        // _handleChoice will either route (→ routing) or retry (→
        // awaitingChoice). The startListening wrapper resets the phase
        // back to awaitingChoice if neither happened.
        _handleChoice(text);
      case OutdoorPhase.arrived:
        // After arrival, treat any input as a new destination request.
        state = state.copyWith(
          phase: OutdoorPhase.listeningForDestination,
          query: text,
        );
        _search();
      case OutdoorPhase.navigating:
      case OutdoorPhase.searching:
      case OutdoorPhase.presentingOptions:
      case OutdoorPhase.routing:
        // Busy / handled above; ignore stray input.
        break;
    }
  }

  // ── Navigation voice-command vocabularies ──────────────────────────────
  // Expanded with common STT mishears observed on real devices (Snapdragon
  // 685 + en_US STT under traffic noise / non-American accents). Match
  // strategy: substring contains (see _matchAny). The single exception is
  // bare 'go' — that's handled exact-only at the call site so phrases
  // like "going to the store" don't false-positive advance.
  static const _kNavNextVariants = <String>[
    'next', 'skip', 'next step', 'continue',
    'next one', 'go next', 'forward', 'move on',
    'okay next', 'ok next', 'proceed', 'done',
  ];
  static const _kNavRepeatVariants = <String>[
    'repeat', 'say again', 'again', 'what',
    'come again', 'one more', 'one more time', 'pardon',
    'say that', 'say that again', 'tell me again', 'tell again',
  ];
  static const _kNavHowFarVariants = <String>[
    'how far', 'how far is it', 'distance left', 'distance',
    'how much', 'remaining',
    'far', 'how long', 'how many', 'left',
    'remaining distance', 'how much left',
  ];
  static const _kNavWhereVariants = <String>[
    'where am i', 'where are we', "where's", 'where',
    'location', 'current',
    'current step', 'which step', 'what step', 'step number',
    'my location', 'present location',
  ];
  static const _kNavCancelVariants = <String>[
    'cancel', 'stop', 'exit', 'cancel navigation',
    'end', 'finish', 'quit', 'abort',
    'stop navigation', 'exit navigation',
  ];

  bool _matchAny(String transcript, List<String> variants) {
    final t = transcript.toLowerCase().trim();
    if (t.isEmpty) return false;
    for (final v in variants) {
      if (t == v) {
        debugPrint('[NAV] matched "$transcript" via variant "$v"');
        return true;
      }
      if (t.contains(v)) {
        debugPrint('[NAV] matched "$transcript" via variant "$v"');
        return true;
      }
    }
    return false;
  }

  bool _matches(String lc, List<String> phrases) =>
      phrases.any((p) => lc == p || lc.contains(p));

  // ── searching ────────────────────────────────────────────────────────────
  Future<void> _search() async {
    state = state.copyWith(phase: OutdoorPhase.searching);
    _say(kPromptSearching.replaceAll('{q}', state.query));
    try {
      final results = await _places.search(state.query);
      if (results.isEmpty) {
        _say(kPromptNoResults.replaceAll('{q}', state.query));
        state = state.copyWith(phase: OutdoorPhase.listeningForDestination);
        return;
      }
      state = state.copyWith(options: results);
      await _presentOptions();
    } on PlacesException catch (e) {
      debugPrint('[NAV] places error: $e');
      _say(e.userMessage);
      state = state.copyWith(
        phase: OutdoorPhase.listeningForDestination,
        error: e.userMessage,
      );
    }
  }

  // ── presentingOptions ────────────────────────────────────────────────────
  // Reads each option fully (awaits TTS engine completion). The `_say`
  // fire-and-forget pattern was dropping every option except the last on
  // Android because QUEUE_FLUSH interrupted the previous utterance before
  // it could speak — fixed by `await _tts.speak(...)` here.
  Future<void> _presentOptions() async {
    state = state.copyWith(phase: OutdoorPhase.presentingOptions);
    _isReadingOptions = true;
    try {
      // 250 ms buffers between utterances cover Android TTS engines that
      // fire the completion handler slightly before audio drain finishes —
      // without this the next speak() can clip the tail of the previous.
      const buffer = Duration(milliseconds: 250);
      await _tts.speak(kPromptOptionsLeadIn);
      await Future<void>.delayed(buffer);
      for (var i = 0; i < state.options.length; i++) {
        // Phase may have been changed by `cancel` while we were awaiting TTS.
        if (state.phase == OutdoorPhase.idle) return;
        final p = state.options[i];
        // ASCII-clean name + address so the en-US TTS engine doesn't read
        // Arabic characters as gibberish. The visual UI keeps the full
        // multilingual text — this cleaning is TTS-only.
        debugPrint(
            '[OPTIONS] speaking ${i + 1}/${state.options.length}: ${p.name}');
        final cleanName = _ttsCleanAddress(p.name);
        final city = _ttsCleanAddress(_shortLocation(p.address));
        final phrase = city.isEmpty
            ? kPromptOptionItemNoCity
                .replaceAll('{i}', '${i + 1}')
                .replaceAll('{name}', cleanName)
            : kPromptOptionItem
                .replaceAll('{i}', '${i + 1}')
                .replaceAll('{name}', cleanName)
                .replaceAll('{city}', city);
        await _tts.speak(phrase);
        await Future<void>.delayed(buffer);
      }
      if (state.phase == OutdoorPhase.idle) return;
      await _tts.speak(kPromptOptionsHowTo);
      state = state.copyWith(phase: OutdoorPhase.awaitingChoice, retryCount: 0);
    } finally {
      _isReadingOptions = false;
    }
  }

  // Pull a human-meaningful city / governorate chunk out of a Google
  // Places formattedAddress for the spoken options list. The full address
  // (e.g. "Unnamed Road, 7F2W+JQV 6362040") takes 9–12 s to read aloud;
  // we want ~3 s per option, so we walk comma-separated parts from the
  // LAST one backwards and accept the first one that, after stripping
  // trailing numeric (zip-code) tokens, is non-empty AND isn't a plus
  // code / pure number. Walking from the end usually lands on the city
  // or governorate rather than the street.
  //
  // Examples:
  //   "Cafe One Street, Cairo"
  //     → last = "Cairo" → "Cairo" ✓
  //   "123 Tahrir Street, Cairo Governorate 4311101"
  //     → last = "Cairo Governorate 4311101" → strip → "Cairo Governorate" ✓
  //   "Unnamed Road, 7F2W+JQV 6362040"
  //     → last = "7F2W+JQV 6362040" → strip → "7F2W+JQV" (plus-code, skip)
  //     → prev = "Unnamed Road" → "Unnamed Road" (fallback)
  //   "Club House El-Nahda, Al-Qalyubia Governorate 6361003"
  //     → last → "Al-Qalyubia Governorate" ✓
  @visibleForTesting
  static String shortLocation(String? address) {
    if (address == null) return '';
    final parts = address
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    final plusCode = RegExp(r'^[A-Z0-9]+\+[A-Z0-9]+$');
    final pureNumber = RegExp(r'^\d+$');
    // Walk last → first.
    for (var i = parts.length - 1; i >= 0; i--) {
      final raw = parts[i];
      final tokens = raw.split(RegExp(r'\s+'));
      while (tokens.isNotEmpty && pureNumber.hasMatch(tokens.last)) {
        tokens.removeLast();
      }
      final cleaned = tokens.join(' ').trim();
      if (cleaned.isEmpty) continue;
      if (plusCode.hasMatch(cleaned)) continue;
      if (pureNumber.hasMatch(cleaned)) continue;
      return cleaned;
    }
    return parts.last; // every chunk was junk — fall back to raw last.
  }

  String _shortLocation(String? address) => shortLocation(address);

  // Strip non-ASCII (e.g. Arabic) characters before speaking a place name /
  // address, then tidy stray whitespace and dangling commas left behind.
  // CRITICAL ISSUE 2 fix — applied ONLY to TTS, never to the visual text.
  String _ttsCleanAddress(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
    return cleaned
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r',\s*,'), ',')
        .replaceAll(RegExp(r'^\s*,|,\s*$'), '')
        .trim();
  }

  // ── awaitingChoice ───────────────────────────────────────────────────────
  void _handleChoice(String text) {
    // Defensive: if we ever reach here with an empty options list (a
    // cancel-while-presenting race left the phase at awaitingChoice with
    // options cleared), redirect to a fresh search instead of speaking
    // the "1 to 0" nonsense.
    if (state.options.isEmpty) {
      debugPrint('[NAV] _handleChoice called with 0 options — '
          'redirecting to fresh search prompt');
      state = state.copyWith(phase: OutdoorPhase.listeningForDestination);
      _say(kPromptOptionsClearedTryAgain);
      return;
    }
    final lc = text.toLowerCase();
    if (_matches(lc, ['search again', 'try again', 'different', 'new search'])) {
      state = state.copyWith(phase: OutdoorPhase.listeningForDestination);
      _say(kPromptAskDestination);
      return;
    }

    final n = extractOptionNumber(text); // inChoiceContext: true (default)
    if (n != null && n >= 1 && n <= state.options.length) {
      _route(state.options[n - 1]);
      return;
    }

    final retries = state.retryCount + 1;
    if (retries > kOptionMaxRetries) {
      _say(kPromptChoiceGiveUp);
      state = state.copyWith(
        phase: OutdoorPhase.listeningForDestination,
        retryCount: 0,
      );
      _say(kPromptAskDestination);
      return;
    }
    state = state.copyWith(retryCount: retries);
    _say(kPromptChoiceRetry.replaceAll('{n}', '${state.options.length}'));
  }

  // ── routing ──────────────────────────────────────────────────────────────
  Future<void> _route(Place dest) async {
    state = state.copyWith(phase: OutdoorPhase.routing, destination: dest);
    _say(kPromptRouting.replaceAll('{d}', _ttsCleanAddress(dest.name)));

    // Origin resolution: cached → one-shot → fail. Silently falling back to
    // Cairo (Tahrir 30.0444, 31.2357 = kGpsFallback*) was the
    // "every route starts from Tahrir" bug — we now refuse to route until
    // we have a REAL fix.
    final origin = await _resolveOrigin();
    if (origin == null) {
      debugPrint('[ROUTES] no GPS — refusing routing');
      _say(kPromptNoGpsForRouting);
      state = state.copyWith(
        phase: OutdoorPhase.listeningForDestination,
        error: kPromptNoGpsForRouting,
      );
      return;
    }
    debugPrint('[ROUTES] using origin: ${origin.lat}, ${origin.lng} '
        '(accuracy=${origin.accuracyMeters}m)');

    try {
      final route = await _routes.computeWalkingRoute(
        originLat: origin.lat,
        originLng: origin.lng,
        destLat: dest.lat,
        destLng: dest.lng,
      );
      state = state.copyWith(
        phase: OutdoorPhase.navigating,
        route: route,
        currentStepIndex: 0,
        remainingMeters: route.totalDistanceMeters,
      );
      if (route.steps.isNotEmpty) {
        _say(kPromptNavStep
            .replaceAll('{i}', '1')
            .replaceAll('{n}', '${route.steps.length}')
            .replaceAll('{instr}', route.steps.first.instruction));
      }
      _startPoller(route);
      _startGpsWatcher();
      // Spin up the camera + obstacle pipeline on top of the existing
      // outdoor experience. Permission denial degrades to audio-only
      // navigation rather than failing the route.
      // ignore: discarded_futures
      _startObstaclePipeline();
    } on RoutesException catch (e) {
      debugPrint('[NAV] routes error: $e');
      _say(e.userMessage);
      state = state.copyWith(
        phase: OutdoorPhase.listeningForDestination,
        error: e.userMessage,
      );
    }
  }

  // Returns the live origin fix, or null when there's no usable real fix.
  // A non-null result with isFallback=true is treated the same as null
  // (the user is being navigated from "approximate Cairo" instead of
  // where they actually are, which is precisely the bug we're fixing).
  Future<LocationFix?> _resolveOrigin() async {
    final cached = ref.read(currentLocationProvider);
    if (cached != null && !cached.isFallback) {
      debugPrint('[ROUTES] origin from cached fix');
      return cached;
    }
    debugPrint('[ROUTES] no usable cached fix — requesting one-shot');
    final fresh = await _gps.getOneShot();
    if (fresh != null && !fresh.isFallback) {
      // Promote the fresh fix into currentLocationProvider so subsequent
      // pollers / where-am-I queries see it.
      ref.read(currentLocationProvider.notifier).set(fresh);
      return fresh;
    }
    return null;
  }

  // ── navigating ───────────────────────────────────────────────────────────
  void _startPoller(Route route) {
    _poller?.stop();
    _poller = NavigationPoller(
      route: route,
      routes: _routes,
      tts: _tts,
      haptics: _haptics,
      getLocation: () => ref.read(currentLocationProvider),
      onArrived: _arrived,
      onStep: (i) => state = state.copyWith(
        currentStepIndex: i,
        remainingMeters: _poller?.remainingMeters ?? state.remainingMeters,
      ),
      onReroute: (r) => state = state.copyWith(
        route: r,
        currentStepIndex: 0,
        remainingMeters: r.totalDistanceMeters,
      ),
    );
    _poller!.start();
  }

  // ── arrived ──────────────────────────────────────────────────────────────
  void _arrived() {
    _poller?.stop();
    _stopGpsWatcher();
    // ignore: discarded_futures
    _stopObstaclePipeline();
    state = state.copyWith(phase: OutdoorPhase.arrived);
    final name = _ttsCleanAddress(state.destination?.name ?? 'your destination');
    _say(kPromptArrived.replaceAll('{d}', name));
    // ignore: discarded_futures
    _haptics.arrived();
    _arrivedTimer?.cancel();
    _arrivedTimer = Timer(const Duration(seconds: kArrivedDwellSec), () {
      if (state.phase == OutdoorPhase.arrived) _cancel(speak: false);
    });
  }

  @visibleForTesting
  void debugTriggerArrived() => _arrived();

  /// Test-only seam — lets tests construct pathological states like
  /// (phase=awaitingChoice, options=[]) that the natural state machine
  /// won't reach but real-device race conditions occasionally do.
  @visibleForTesting
  // ignore: invalid_use_of_protected_member
  void debugSetState(OutdoorState s) => state = s;

  // Manual skip — used by the Stitch active_navigation "Skip" side button
  // AND by the "next" voice command (Part A). Bumps the poller's step
  // index, syncs the visible state, and speaks the new instruction. If
  // we're already on the last step, treat as arrived.
  void skipStep() {
    final route = state.route;
    if (route == null) return;
    final next = (_poller?.stepIndex ?? state.currentStepIndex) + 1;
    if (next >= route.steps.length) {
      _arrived();
      return;
    }
    if (_poller != null) {
      _poller!.stepIndex = next;
      // Suppress off-route re-route during the next 15 s so the user can
      // listen to "Step N of M. …" without having it cancelled by a
      // re-route firing while they stand still.
      _poller!.armSettleWindow(kManualAdvanceSettleDuration);
    }
    state = state.copyWith(
      currentStepIndex: next,
      remainingMeters: _poller?.remainingMeters ?? state.remainingMeters,
    );
    debugPrint('[STEP] advancing to ${next + 1}/${route.steps.length}');
    _say(kPromptNavStep
        .replaceAll('{i}', '${next + 1}')
        .replaceAll('{n}', '${route.steps.length}')
        .replaceAll('{instr}', route.steps[next].instruction));
  }

  // ── GPS-lost watcher ────────────────────────────────────────────────────
  // Polls currentLocationProvider on the same cadence as the navigation
  // poller. After kGpsLostThresholdSec without a real (non-fallback) fix,
  // speaks kPromptGpsLost ONCE; speaks kPromptGpsRestored ONCE when a
  // real fix returns.
  void _startGpsWatcher() {
    _gpsWatcherTimer?.cancel();
    _lastRealFixTime = DateTime.now();
    _gpsLostAnnounced = false;
    _gpsWatcherTimer = Timer.periodic(kStepPollInterval, (_) {
      final fix = ref.read(currentLocationProvider);
      final now = DateTime.now();
      if (fix != null && !fix.isFallback) {
        _lastRealFixTime = now;
        if (_gpsLostAnnounced) {
          debugPrint('[GPS] restored');
          _gpsLostAnnounced = false;
          _say(kPromptGpsRestored);
        }
        return;
      }
      // No real fix on this tick. Speak the lost prompt at most once.
      final last = _lastRealFixTime;
      if (!_gpsLostAnnounced &&
          last != null &&
          now.difference(last).inSeconds >= kGpsLostThresholdSec) {
        debugPrint('[GPS] lost — speaking warning (once)');
        _gpsLostAnnounced = true;
        _say(kPromptGpsLost);
      }
    });
  }

  void _stopGpsWatcher() {
    _gpsWatcherTimer?.cancel();
    _gpsWatcherTimer = null;
    _lastRealFixTime = null;
    _gpsLostAnnounced = false;
  }

  // ── Obstacle pipeline lifecycle (Part B) ────────────────────────────────
  Future<void> _startObstaclePipeline() async {
    if (!autoStartPipeline) return;
    if (_pipelineStarted) return;
    // Camera permission first — if denied, navigation continues without
    // obstacle detection.
    final perm = await Permission.camera.status;
    if (!perm.isGranted) {
      _say(kPromptCameraPermNeeded);
      final granted = await Permission.camera.request();
      if (!granted.isGranted) {
        debugPrint('[OUTDOOR] camera denied — navigation without obstacles');
        _say(kPromptCameraPermDenied);
        return;
      }
    }
    debugPrint('[OUTDOOR] starting obstacle pipeline');
    try {
      await ref.read(cameraProvider.notifier).start();
      await ref.read(pipelineProvider.notifier).start();
      _pipelineStarted = true;
    } catch (e) {
      debugPrint('[OUTDOOR] pipeline start failed: $e');
    }
  }

  Future<void> _stopObstaclePipeline() async {
    if (!_pipelineStarted) return;
    _pipelineStarted = false;
    debugPrint('[OUTDOOR] stopping obstacle pipeline');
    try {
      await ref.read(pipelineProvider.notifier).stop();
      await ref.read(cameraProvider.notifier).stop();
    } catch (e) {
      debugPrint('[OUTDOOR] pipeline stop error (ignored): $e');
    }
  }

  // ── voice commands ───────────────────────────────────────────────────────
  void _repeat() {
    final route = state.route;
    final i = state.currentStepIndex;
    if (state.phase == OutdoorPhase.navigating &&
        route != null &&
        i < route.steps.length) {
      _say(kPromptNavStep
          .replaceAll('{i}', '${i + 1}')
          .replaceAll('{n}', '${route.steps.length}')
          .replaceAll('{instr}', route.steps[i].instruction));
      return;
    }
    final instr = state.currentInstruction;
    if (instr != null) _say(instr);
  }

  void _howFar() {
    final route = state.route;
    if (state.phase == OutdoorPhase.navigating && route != null) {
      final remainingSteps =
          (route.steps.length - state.currentStepIndex - 1).clamp(0, 9999);
      final m = _poller?.remainingMeters ?? state.remainingMeters;
      _say(kPromptNavRemaining
          .replaceAll('{steps}', '$remainingSteps')
          .replaceAll('{meters}', '$m'));
      return;
    }
    final m = _poller?.remainingMeters ?? state.remainingMeters;
    final phrase = m >= 1000
        ? '${(m / 1000).toStringAsFixed(1)} kilometers'
        : '$m meters';
    _say(kPromptRemainingDistance.replaceAll('{d}', phrase));
  }

  void _whereAmI() {
    // During active navigation, the spec says: "On step X of Y. Current
    // instruction: ...". Outside navigation we keep the old behaviour
    // (raw coords + approximate-location flag).
    final route = state.route;
    if (state.phase == OutdoorPhase.navigating && route != null) {
      final i = state.currentStepIndex;
      _say(kPromptNavWhereAmI
          .replaceAll('{i}', '${i + 1}')
          .replaceAll('{n}', '${route.steps.length}')
          .replaceAll('{instr}', route.steps[i].instruction));
      return;
    }
    final loc = ref.read(currentLocationProvider);
    final lat = (loc?.lat ?? kGpsFallbackLat).toStringAsFixed(4);
    final lng = (loc?.lng ?? kGpsFallbackLng).toStringAsFixed(4);
    _say(kPromptLocationFix
        .replaceAll('{lat}', lat)
        .replaceAll('{lng}', lng));
    if (loc?.isFallback ?? true) _say(kPromptApproxLocation);
  }

  // ── cancel / exit ────────────────────────────────────────────────────────
  void _cancel({bool speak = true}) {
    _epoch++;
    _poller?.stop();
    _poller = null;
    _arrivedTimer?.cancel();
    _arrivedTimer = null;
    _stopGpsWatcher();
    // ignore: discarded_futures
    _stopObstaclePipeline();
    if (speak) _say(kPromptCancelled);
    state = const OutdoorState(); // back to idle
    onRequestExit?.call(); // AppMode → welcome
  }

  /// Public cancel used by the outdoor screen long-press.
  void cancelNavigation() => _cancel();

  /// Called by the AppMode switch when leaving outdoor mode.
  void teardown() {
    _epoch++;
    _poller?.stop();
    _poller = null;
    _arrivedTimer?.cancel();
    _arrivedTimer = null;
    _stopGpsWatcher();
    // ignore: discarded_futures
    _stopObstaclePipeline();
    state = const OutdoorState();
  }
}

final outdoorNavProvider =
    NotifierProvider<OutdoorNavNotifier, OutdoorState>(OutdoorNavNotifier.new);
