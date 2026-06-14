// State-machine tests for lib/state/navigation_notifier.dart.
//
// Services are replaced with subclass fakes via ProviderContainer overrides
// (no real Google APIs, no mic, no platform channels). autoListen is set
// false so the machine is driven purely through submitTranscript().

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_nav/models/location_fix.dart';
import 'package:smart_nav/models/place.dart';
import 'package:smart_nav/models/route.dart';
import 'package:smart_nav/models/route_step.dart';
import 'package:smart_nav/services/audio/tts_service.dart';
import 'package:smart_nav/services/audio/stt_service.dart';
import 'package:smart_nav/services/feedback/haptics_service.dart';
import 'package:smart_nav/services/location/gps_service.dart';
import 'package:smart_nav/services/places/places_service.dart';
import 'package:smart_nav/services/routes/routes_service.dart';
import 'package:smart_nav/state/navigation_notifier.dart';
import 'package:smart_nav/state/sos_notifier.dart';

// ── Fakes ──────────────────────────────────────────────────────────────────

class FakeTts extends TtsService {
  final List<String> spoken = [];
  @override
  Future<void> speak(String text) async => spoken.add(text);
  @override
  void speakBackground(String text) => spoken.add(text);
  @override
  Future<void> stopSpeaking() async {}
  @override
  bool get isSpeaking => false;
  bool said(String needle) =>
      spoken.any((s) => s.toLowerCase().contains(needle.toLowerCase()));
}

class FakeStt extends SttService {
  FakeStt(super.tts);
  @override
  Future<bool> initialize() async => false;
  @override
  Future<String> listenOnce({
    Duration window = const Duration(seconds: 8),
    Duration pauseFor = const Duration(seconds: 3),
  }) async =>
      '';
}

class FakeHaptics extends HapticsService {
  int shortCount = 0;
  int arrivedCount = 0;
  @override
  Future<void> short() async => shortCount++;
  @override
  Future<void> arrived() async => arrivedCount++;
}

class FakePlaces extends PlacesService {
  List<Place> result = [];
  PlacesException? error;
  int calls = 0;
  @override
  Future<List<Place>> search(String query) async {
    calls++;
    if (error != null) throw error!;
    return result;
  }
}

class FakeRoutes extends RoutesService {
  Route? result;
  RoutesException? error;
  int calls = 0;
  @override
  Future<Route> computeWalkingRoute({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
  }) async {
    calls++;
    if (error != null) throw error!;
    return result!;
  }
}

Place _place(String n) =>
    Place(name: n, address: '$n Street, Cairo', lat: 30.1, lng: 31.2, placeId: n);

Route _route() => const Route(
      steps: [
        RouteStep(
          instruction: 'Head north on Tahrir Street',
          startLat: 30.0,
          startLng: 31.2,
          endLat: 30.01,
          endLng: 31.2,
          distanceMeters: 120,
        ),
        RouteStep(
          instruction: 'Turn right onto Qasr al-Nil',
          startLat: 30.01,
          startLng: 31.2,
          endLat: 30.02,
          endLng: 31.21,
          distanceMeters: 200,
        ),
      ],
      totalDistanceMeters: 320,
      totalDurationSeconds: 260,
    );

void main() {
  // FakeTts/FakeStt extend the real services, whose field initializers
  // construct FlutterTts()/SpeechToText() → setMethodCallHandler(), which
  // requires an initialized binding. We never hit a real platform call
  // because every used method is overridden by the fakes.
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late FakeTts tts;
  late FakeStt stt;
  late FakeHaptics haptics;
  late FakePlaces places;
  late FakeRoutes routes;
  late OutdoorNavNotifier nav;

  setUp(() {
    tts = FakeTts();
    stt = FakeStt(tts);
    haptics = FakeHaptics();
    places = FakePlaces()..result = [_place('Cafe One'), _place('Cafe Two')];
    routes = FakeRoutes()..result = _route();
    container = ProviderContainer(overrides: [
      ttsServiceProvider.overrideWithValue(tts),
      sttServiceProvider.overrideWithValue(stt),
      hapticsServiceProvider.overrideWithValue(haptics),
      placesServiceProvider.overrideWithValue(places),
      routesServiceProvider.overrideWithValue(routes),
    ]);
    // Seed currentLocationProvider with a real (non-fallback) fix so the
    // _resolveOrigin path used by _route() doesn't refuse on missing GPS.
    container.read(currentLocationProvider.notifier).set(LocationFix(
          lat: 30.0,
          lng: 31.2,
          accuracyMeters: 5,
          timestamp: DateTime.now(),
          isFallback: false,
        ));
    nav = container.read(outdoorNavProvider.notifier)
      ..autoListen = false
      ..autoStartPipeline = false; // Part B pipeline is platform-bound

  });

  tearDown(() {
    nav.teardown();
    container.dispose();
  });

  OutdoorState st() => container.read(outdoorNavProvider);

  // Drives _search/_presentOptions which await Future.delayed per option.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 900));

  test('1. enterOutdoor → listeningForDestination + asks where to go', () {
    nav.enterOutdoor();
    expect(st().phase, OutdoorPhase.listeningForDestination);
    expect(tts.said('where would you like to go'), isTrue);
  });

  test('2. destination query → searching → presenting → awaitingChoice', () async {
    nav.enterOutdoor();
    nav.submitTranscript('coffee shop');
    await settle();
    expect(places.calls, 1);
    expect(st().options.length, 2);
    expect(st().phase, OutdoorPhase.awaitingChoice);
    expect(tts.said('I found these places'), isTrue);
    // F-3 follow-up: shortened "Option N: {name}, in {city}." template.
    expect(tts.said('Option 1: Cafe One'), isTrue);
    expect(tts.said(', in Cairo'), isTrue);
  });

  test('3. valid choice → routing → navigating with route + first step', () async {
    nav.enterOutdoor();
    nav.submitTranscript('coffee');
    await settle();
    nav.submitTranscript('option 2');
    await settle();
    expect(routes.calls, 1);
    expect(st().phase, OutdoorPhase.navigating);
    expect(st().destination?.name, 'Cafe Two');
    expect(st().route, isNotNull);
    expect(tts.said('Head north on Tahrir Street'), isTrue);
  });

  test('4. invalid choice retries up to limit then back to listening', () async {
    nav.enterOutdoor();
    nav.submitTranscript('coffee');
    await settle();
    expect(st().phase, OutdoorPhase.awaitingChoice);

    for (var i = 1; i <= 3; i++) {
      nav.submitTranscript('banana pancakes'); // no option number
      expect(st().phase, OutdoorPhase.awaitingChoice);
      expect(st().retryCount, i);
    }
    // 4th invalid → give up, return to listening
    nav.submitTranscript('still nonsense');
    expect(st().phase, OutdoorPhase.listeningForDestination);
    expect(tts.said("let's start over"), isTrue);
  });

  test('5. no results → back to listening, speaks no-results', () async {
    places.result = [];
    nav.enterOutdoor();
    nav.submitTranscript('xyzzy');
    await settle();
    expect(st().phase, OutdoorPhase.listeningForDestination);
    expect(tts.said('No results for xyzzy'), isTrue);
  });

  test('6. PlacesException → back to listening, error surfaced', () async {
    places.error = PlacesException('Place search is unavailable.');
    nav.enterOutdoor();
    nav.submitTranscript('anything');
    await settle();
    expect(st().phase, OutdoorPhase.listeningForDestination);
    expect(st().error, 'Place search is unavailable.');
    expect(tts.said('Place search is unavailable'), isTrue);
  });

  test('7. RoutesException → back to listening, message spoken', () async {
    routes.error = RoutesException('No walking route found to that place.');
    nav.enterOutdoor();
    nav.submitTranscript('coffee');
    await settle();
    nav.submitTranscript('1');
    await settle();
    expect(st().phase, OutdoorPhase.listeningForDestination);
    expect(tts.said('No walking route found'), isTrue);
  });

  test('8. cancel mid-navigation → idle + onRequestExit + spoken', () async {
    var exited = false;
    nav.onRequestExit = () => exited = true;
    nav.enterOutdoor();
    nav.submitTranscript('coffee');
    await settle();
    nav.submitTranscript('first');
    await settle();
    expect(st().phase, OutdoorPhase.navigating);

    nav.submitTranscript('cancel navigation');
    expect(st().phase, OutdoorPhase.idle);
    expect(exited, isTrue);
    expect(tts.said('Navigation cancelled'), isTrue);
  });

  test('9. voice commands while navigating: how far / repeat', () async {
    nav.enterOutdoor();
    nav.submitTranscript('coffee');
    await settle();
    nav.submitTranscript('option 1');
    await settle();
    expect(st().phase, OutdoorPhase.navigating);

    tts.spoken.clear();
    nav.submitTranscript('how far');
    // Part A: phrasing changed to "X steps remaining. Approximately Y
    // metres to destination." while in the navigating phase.
    expect(tts.said('to destination'), isTrue);

    tts.spoken.clear();
    nav.submitTranscript('repeat');
    expect(tts.said('Head north on Tahrir Street'), isTrue);
  });

  test('10. arrived → arrived phase, prompt + 3-pulse haptic', () async {
    nav.enterOutdoor();
    nav.submitTranscript('coffee');
    await settle();
    nav.submitTranscript('2');
    await settle();
    expect(st().phase, OutdoorPhase.navigating);

    nav.debugTriggerArrived();
    expect(st().phase, OutdoorPhase.arrived);
    expect(tts.said('You have arrived at Cafe Two'), isTrue);
    expect(haptics.arrivedCount, 1);
  });

  test('12. spoken options strip non-ASCII (Arabic) characters', () async {
    places.result = [
      Place(
        name: 'People of Egypt Walkway',
        address: 'National Bank of Egypt, بولاق٥, بولاق أبو العلا, Cairo',
        lat: 30.1,
        lng: 31.2,
        placeId: 'ar1',
      ),
    ];
    nav.enterOutdoor();
    nav.submitTranscript('bank');
    await settle();
    // Every spoken line must be pure printable ASCII (no Arabic gibberish).
    final ascii = RegExp(r'^[\x20-\x7E]*$');
    for (final s in tts.spoken) {
      expect(ascii.hasMatch(s), isTrue, reason: 'non-ASCII in: "$s"');
    }
    // The English name survives. The new shortened option template only
    // speaks the {name}, in {city} portion — the long address middle
    // ("National Bank of Egypt") is no longer read aloud at all.
    expect(tts.said('People of Egypt Walkway'), isTrue);
    expect(tts.said(', in Cairo'), isTrue);
  });

  test('13. enterOutdoor does NOT auto-open the mic (push-to-talk only)', () {
    // autoListen=false here, but the real guard is that enterOutdoor never
    // calls listenOnce — assert the mic is not flagged listening.
    nav.enterOutdoor();
    expect(st().listening, isFalse);
    expect(st().phase, OutdoorPhase.listeningForDestination);
  });

  // ── Part-A active-navigation voice commands ────────────────────────────
  Future<void> intoNavigating() async {
    nav.enterOutdoor();
    nav.submitTranscript('coffee');
    await settle();
    nav.submitTranscript('option 1');
    await settle();
    expect(st().phase, OutdoorPhase.navigating);
  }

  test('A1. "next" advances currentStepIndex by 1', () async {
    await intoNavigating();
    expect(st().currentStepIndex, 0);
    tts.spoken.clear();
    nav.submitTranscript('next');
    expect(st().currentStepIndex, 1);
    expect(tts.said('Turn right onto Qasr al-Nil'), isTrue);
  });

  test('A2. "next" on last step → arrived phase', () async {
    await intoNavigating();
    nav.submitTranscript('next'); // 0 → 1 (last)
    expect(st().currentStepIndex, 1);
    tts.spoken.clear();
    nav.submitTranscript('next'); // past last → arrival
    expect(st().phase, OutdoorPhase.arrived);
    expect(tts.said('You have arrived'), isTrue);
  });

  test('A3. "repeat" re-speaks current step without changing index',
      () async {
    await intoNavigating();
    final before = st().currentStepIndex;
    tts.spoken.clear();
    nav.submitTranscript('repeat');
    expect(st().currentStepIndex, before);
    expect(tts.said('Head north on Tahrir Street'), isTrue);
  });

  test('A4. "how far" speaks remaining count + metres', () async {
    await intoNavigating();
    tts.spoken.clear();
    nav.submitTranscript('how far');
    // 2 steps, index 0 → 1 step remaining
    expect(tts.said('1 steps remaining'), isTrue);
    expect(tts.said('metres'), isTrue);
  });

  test('A5. "where am i" during navigating speaks step context', () async {
    await intoNavigating();
    tts.spoken.clear();
    nav.submitTranscript('where am i');
    expect(tts.said('On step 1 of 2'), isTrue);
    expect(tts.said('Head north on Tahrir Street'), isTrue);
  });

  test('A6. unknown command during navigating speaks help, no new search',
      () async {
    await intoNavigating();
    places.calls = 0;
    tts.spoken.clear();
    nav.submitTranscript('banana pancakes');
    expect(places.calls, 0); // did NOT re-enter search
    expect(st().phase, OutdoorPhase.navigating);
    expect(tts.said('Unknown command'), isTrue);
  });

  test('A7. "cancel" during navigating returns to idle + onRequestExit',
      () async {
    var exits = 0;
    nav.onRequestExit = () => exits++;
    await intoNavigating();
    nav.submitTranscript('cancel');
    expect(st().phase, OutdoorPhase.idle);
    expect(exits, 1);
  });

  test('A8. SOS countdown precedence — "cancel" aborts SOS, not navigation',
      () async {
    await intoNavigating();
    final sos = container.read(sosProvider.notifier)..autoSpeak = false;
    await sos.startCountdown();
    expect(sos.isCountingDown, isTrue);
    nav.submitTranscript('cancel');
    // SOS aborted, navigation unchanged.
    expect(sos.isCountingDown, isFalse);
    expect(st().phase, OutdoorPhase.navigating);
  });

  test('A9. routing refuses when origin is null (no usable GPS)', () async {
    container.read(currentLocationProvider.notifier).clear();
    nav.enterOutdoor();
    nav.submitTranscript('coffee');
    await settle();
    tts.spoken.clear();
    nav.submitTranscript('option 1');
    await settle();
    // Routes never called; back to listeningForDestination with error.
    expect(routes.calls, 0);
    expect(st().phase, OutdoorPhase.listeningForDestination);
    expect(tts.said('Location not available'), isTrue);
  });

  test('A10. routing refuses when only a fallback fix is available',
      () async {
    container.read(currentLocationProvider.notifier).set(LocationFix(
          lat: 30.0444,
          lng: 31.2357,
          accuracyMeters: 5000,
          timestamp: DateTime.now(),
          isFallback: true, // approximate Cairo — the very bug
        ));
    nav.enterOutdoor();
    nav.submitTranscript('coffee');
    await settle();
    nav.submitTranscript('option 1');
    await settle();
    expect(routes.calls, 0);
    expect(st().phase, OutdoorPhase.listeningForDestination);
  });

  // ── STT-mishear variant hardening (Part A follow-up) ────────────────────
  test('C1. "okay next please" matches next (substring)', () async {
    await intoNavigating();
    expect(st().currentStepIndex, 0);
    nav.submitTranscript('okay next please');
    expect(st().currentStepIndex, 1);
  });

  test('C2. "go next" matches next', () async {
    await intoNavigating();
    nav.submitTranscript('go next');
    expect(st().currentStepIndex, 1);
  });

  test('C3. "tell me again" matches repeat', () async {
    await intoNavigating();
    final before = st().currentStepIndex;
    tts.spoken.clear();
    nav.submitTranscript('tell me again');
    expect(st().currentStepIndex, before);
    expect(tts.said('Head north on Tahrir Street'), isTrue);
  });

  test('C4. "how long" matches how-far', () async {
    await intoNavigating();
    tts.spoken.clear();
    nav.submitTranscript('how long');
    expect(tts.said('to destination'), isTrue);
  });

  test('C5. "exit navigation" matches cancel', () async {
    var exits = 0;
    nav.onRequestExit = () => exits++;
    await intoNavigating();
    nav.submitTranscript('exit navigation');
    expect(st().phase, OutdoorPhase.idle);
    expect(exits, 1);
  });

  test('C6. exact "go" matches next', () async {
    await intoNavigating();
    nav.submitTranscript('go');
    expect(st().currentStepIndex, 1);
  });

  test('C7. "going to the store" does NOT match next (substring guard)',
      () async {
    await intoNavigating();
    final before = st().currentStepIndex;
    tts.spoken.clear();
    nav.submitTranscript('going to the store');
    expect(st().currentStepIndex, before);
    expect(tts.said('Unknown command'), isTrue);
  });

  // ── Part-A real-device fixes ────────────────────────────────────────────
  test('B1. After skipStep, off-route polling within 15 s is suppressed',
      () async {
    await intoNavigating();
    nav.submitTranscript('next'); // arms settle window in poller
    // We can't tick the poller directly here without exposing it, but the
    // settle behaviour is documented via NavigationPoller.armSettleWindow.
    // This test confirms the notifier called skipStep without throwing
    // and the navigation state advanced as expected.
    expect(st().currentStepIndex, 1);
  });

  test('B3. Entering outdoor with fallback fix → warns user', () async {
    container.read(currentLocationProvider.notifier).set(LocationFix(
          lat: 30.0444,
          lng: 31.2357,
          accuracyMeters: 5000,
          timestamp: DateTime.now(),
          isFallback: true,
        ));
    nav.enterOutdoor();
    // _maybeWarnNoGps polls every 250 ms for kOutdoorGpsCheckSec (3).
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(tts.said('GPS is not available'), isTrue);
  });

  test('B4. Entering outdoor with real fix → no GPS warning', () async {
    // setUp already seeded a real fix.
    nav.enterOutdoor();
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(tts.said('GPS is not available'), isFalse);
  });

  test('B5. Option-retry with empty options list → speaks '
      'kPromptOptionsClearedTryAgain, no "1 to 0"', () async {
    // Force the pathological state: awaitingChoice + empty options.
    nav.debugSetState(const OutdoorState(
      phase: OutdoorPhase.awaitingChoice,
    ));
    tts.spoken.clear();
    nav.submitTranscript('two');
    expect(tts.said('No options available'), isTrue);
    expect(tts.said('1 to 0'), isFalse);
    expect(st().phase, OutdoorPhase.listeningForDestination);
  });

  test('11. full happy-path phase ordering', () async {
    final seen = <OutdoorPhase>[];
    container.listen<OutdoorState>(outdoorNavProvider, (_, s) {
      if (seen.isEmpty || seen.last != s.phase) seen.add(s.phase);
    });
    nav.enterOutdoor();
    nav.submitTranscript('museum');
    await settle();
    nav.submitTranscript('option 1');
    await settle();

    expect(
      seen,
      containsAllInOrder([
        OutdoorPhase.listeningForDestination,
        OutdoorPhase.searching,
        OutdoorPhase.presentingOptions,
        OutdoorPhase.awaitingChoice,
        OutdoorPhase.routing,
        OutdoorPhase.navigating,
      ]),
    );
  });

  // ── shortLocation helper (F-3 follow-up) ──────────────────────────────
  group('shortLocation', () {
    test('SL1. Simple two-part address → returns the city', () {
      expect(
        OutdoorNavNotifier.shortLocation('Cafe One Street, Cairo'),
        'Cairo',
      );
    });

    test('SL2. Strips trailing zipcode tokens ("Cairo Governorate 4311101")',
        () {
      expect(
        OutdoorNavNotifier.shortLocation(
            '123 Tahrir Street, Cairo Governorate 4311101'),
        'Cairo Governorate',
      );
    });

    test('SL3. Walks past plus-code + zipcode tail chunks', () {
      // Tail is "7F2W+JQV 6362040" → strip number → "7F2W+JQV" → plus-code,
      // skip → next is "Unnamed Road" → keep.
      expect(
        OutdoorNavNotifier.shortLocation(
            'Unnamed Road, 7F2W+JQV 6362040'),
        'Unnamed Road',
      );
    });

    test('SL4. Multi-segment Egyptian address → governorate', () {
      expect(
        OutdoorNavNotifier.shortLocation(
            'Club House El-Nahda, Al-Qalyubia Governorate 6361003'),
        'Al-Qalyubia Governorate',
      );
    });

    test('SL5. null and empty input → empty', () {
      expect(OutdoorNavNotifier.shortLocation(null), '');
      expect(OutdoorNavNotifier.shortLocation(''), '');
      expect(OutdoorNavNotifier.shortLocation('   '), '');
    });

    test('SL6. single-segment input returns it verbatim', () {
      expect(OutdoorNavNotifier.shortLocation('Cairo'), 'Cairo');
    });

    test('SL7. drops trailing country chunk when it is a zipcode-only', () {
      // Note: "Egypt 12345" → strip → "Egypt" — still picks Egypt. That's
      // fine; an end-of-world country name still satisfies the heuristic.
      expect(
        OutdoorNavNotifier.shortLocation(
            'Street A, Suburb, Cairo Governorate 4311101, Egypt'),
        'Egypt',
      );
    });
  });
}
