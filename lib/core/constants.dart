// All tuneable magic numbers live here — never scattered in logic files.
// References to Python source line numbers are noted where non-obvious.

// ── Debug UI master switch ─────────────────────────────────────────────────
// false (production): camera preview + green risk boxes + voice + user
//   controls (PAUSE / VERBOSE / SOS) only. No developer instrumentation:
//   no PAINTER-OK square, no Copy-diag button, no DIAGNOSTICS panel on
//   launch, no gray boxes for non-risk objects, no cyan raw-YOLO overlay.
//   [BOX]/[PERF] logs still emit for field debugging but at half rate.
// true  (development): everything above is visible, logs at full rate.
//
// The diagnostic infrastructure is only HIDDEN, never deleted — flip this
// to true (or triple-tap the screen to reveal the panel) to get it back
// for M6 outdoor-mode testing.
const bool kDebugUI = false;

// [BOX] / [PERF] logcat throttle. Full rate (1 s) in development; halved
// (2 s) in production so field debugging is still possible without spamming.
const int kDiagLogIntervalMs = kDebugUI ? 1000 : 2000;

// ── Announcer per-category cooldowns ───────────────────────────────────────
// The announcer emits exactly ONE category per frame: `obstacle` or `clear`.
// Each has its own cooldown so "path clear" doesn't chirp every cycle when
// nothing is around, while obstacle warnings stay responsive.
//   kObstacleCooldownMs — default obstacle gap. Tunable at runtime via the
//     "faster"/"slower" voice commands (announcer.cooldownSec), so this is
//     just the default seed (== kObstacleCooldown × 1000).
//   kClearCooldownMs — fixed, much longer: only re-announce "path clear"
//     every 10 s of continuous clear, not every frame.
const int kObstacleCooldownMs = 2500;
const int kClearCooldownMs = 10000;

// ── Obstacle detection ─────────────────────────────────────────────────────
// py:79  OBSTACLE_COOLDOWN
const double kObstacleCooldown = 2.5;
// py:80  DANGER_THRESHOLD
const double kDangerThreshold = 0.55;
// py:129 DEPTH_HISTORY_SIZE
const int kDepthHistorySize = 5;
// py:131 decision_history[-3:]
const int kDecisionHistorySize = 3;
// py:1905 approach detection delta
const double kApproachDelta = 0.08;

// Depth thresholds — py:833-837 dist_label()
const double kDepthExtremelyClose = 0.75;
const double kDepthVeryClose = 0.50;
const double kDepthClose = 0.25;

// Min confidence — py:1866-1868
// Per-class minimum confidence thresholds. Bumped above Python values because
// YOLOv8 in real-world indoor scenes leaks low-conf false positives at
// 0.30–0.40 (`hot dog`, `cake`, `airplane`, `teddy bear`, …) when pointed at
// furniture, and those would otherwise reach the announcer.
//
// PRIORITY classes (person, car) use a DISTANCE-AWARE pair:
//   - Big box (close, area > kAreaPriorityNearThreshold): require 0.55 to filter
//     "person taking up half the frame" garbage.
//   - Small box (far, area ≤ threshold): accept 0.40 — a blind user needs early
//     warning about an approaching person well before the model is "sure".
// GENERAL classes use a single threshold.
const double kMinConfPriorityNear = 0.55;
const double kMinConfPriorityFar = 0.40;
const double kMinConfGeneral = 0.45;
// YOLO-normalized [0,1] box-area cutoff that separates "near/big" from "far/small"
// for priority classes. ≈ a person taking up ~32% × ~32% of the frame.
const double kAreaPriorityNearThreshold = 0.10;

// ── Adaptive frame skip — py:1671-1675, 1956-1970 ─────────────────────────
const int kFrameSkipStart = 3;
const double kCycleSlowMs = 400.0; // bump skip above this ms
const double kCycleFastMs = 250.0; // ease skip below this ms

// ── MiDaS input size — py:361 ─────────────────────────────────────────────
// YOLOv8n input size. Matches the bundled `yolov8n_float16.tflite`, which
// was exported with `imgsz=640`. The runtime reads the actual size from
// `interpreter.getInputTensor(0).shape[1]` at load and uses that — this
// constant is purely documentation of what the bundled file currently is.
//
// IMPORTANT — runtime resize is NOT viable. (Verified on Snapdragon 685 +
// Adreno A610 + GpuDelegateV2 on 2026-05-15.) We tried calling
// `interpreter.resizeInputTensor(0, [1, 416, 416, 3])` after load to halve
// inference cost. The Dart-level `resizeInputTensor` returned cleanly, but
// the subsequent `allocateTensors()` crashed the process with
//     SIGSEGV in libtensorflowlite_jni.so at TfLiteInterpreterAllocateTensors
// because YOLOv8 exports static input dims into intermediate CONCATENATION
// nodes (`tflite/kernels/concatenation.cc:211 t->dims->data[d] != ...
// (26 != 40) — Node 236 (CONCATENATION) failed to prepare`). The failure
// leaves the interpreter in a partially-freed state that the next call
// dereferences. Not catchable from Dart.
//
// To actually use 416, re-export the model with `imgsz=416` (see README)
// and replace `assets/models/yolov8n_float16.tflite` with the new file.
// The pipeline reads input size and anchor count from the loaded tensor,
// so no code change is needed when the new file is bundled.
const int kYoloInputSize = 640;

// MiDaS-small input size. Native value from the bundled model is 256.
//
// We previously tried to call `interpreter.resizeInputTensor(192)` at runtime
// to halve MiDaS cost, but that flips the TFLite graph from static-sized to
// dynamic-sized — and `TfLiteGpuDelegateV2` only supports static-sized graphs,
// so YOLO's GPU delegate then refused to attach and fell back to XNNPACK CPU
// (~3 s YOLO inference, 4–8 s cycle). Keeping MiDaS at its native 256 is much
// faster overall because YOLO @ GPU ≈ 40 ms ≪ YOLO @ CPU ≈ 3 s.
//
// To use 192 we'd need a separately-exported `midas_small_192.tflite` with a
// baked-in static [1, 3, 192, 192] input shape — deferred.
const int kMidasInputSize = 256;

// ── VAD — py:455-459 ──────────────────────────────────────────────────────
const int kVadFrameMs = 30;
const double kVadStartRms = 0.012;
const int kVadEndSilenceMs = 500;
const double kVadMaxRecordSec = 8.0;
const double kVadMinRecordSec = 0.4;
const int kSampleRate = 16000;

// ── Navigation poller — py:1158-1162 ──────────────────────────────────────
const double kPollIntervalS = 2.5;
const double kTurnNowM = 15.0;
const double kArriveM = 20.0;
const double kHalfwayReminderM = 80.0;

// ── Tap / SOS — py:94 LONG_PRESS_MS ──────────────────────────────────────
const int kLongPressMs = 700;

// ── Push-to-talk (STT is OFF by default; activated only by a tap) ─────────
// One STT session per tap: stop after kSttWindowSec OR ~1 s of trailing
// silence. The mic NEVER auto-opens — this is what prevents the TTS→mic echo
// loop (the app hearing its own spoken prompts).
// Hard cap on a single push-to-talk listen session. Bumped 5 → 8 because
// some users (and Egyptian-accented English destinations like "El Mosheer
// Ahmed Ismail Street") legitimately take >5 s to say.
const int kSttWindowSec = 8;
// Trailing silence after speech that finalizes the utterance. 1 s was clipping
// users mid-phrase; 3 s lets a sentence breathe while staying inside the
// listenFor cap.
const Duration kSttPauseFor = Duration(seconds: 3);
// Outdoor navigation is noisy (traffic, wind) — give the engine more time
// to absorb noise-affected speech without aborting prematurely.
const int kSttNavWindowSec = 10;
const Duration kSttNavPauseFor = Duration(seconds: 4);
const String kPromptMicDenied =
    'Microphone access is required. Please enable it in Settings.';
const String kPromptSttUnavailable =
    'Speech recognition not available on this device.';
const String kPromptDidntCatch = "I didn't catch that. Tap to try again.";

// Cancel-confirm long-press (outdoor). Tightened well above Flutter's ~500 ms
// default so just gripping the phone doesn't arm cancel, and ignored for the
// first kModeSwitchGraceMs after entering a mode while the user settles the
// phone in their hand.
const int kCancelLongPressMs = 800;
const int kModeSwitchGraceMs = 2000;

// ── GPS fallback — py:76-77 ───────────────────────────────────────────────
const double kFallbackLat = 30.0444; // Cairo
const double kFallbackLon = 31.2357;

// ── Camera resolution — py:1657-1658 ──────────────────────────────────────
const int kCameraWidth = 640;
const int kCameraHeight = 480;

// ── Approach snapshot interval — py:1908 ──────────────────────────────────
const double kSnapshotIntervalS = 2.0;

// ── Priority weights — py:624-630, expanded for outdoor / indoor coverage ─
// Bands:
//   High (2.5–3.0): moving / dangerous obstacles — life-safety alerts
//   Medium (1.5–2.0): static fixtures a blind user could hit at walking speed
//   Default (1.0): anything else via `kRiskWeights[label] ?? 1.0` fallback
// Increasing weight here directly increases calcPriority(), making the
// announcer more likely to speak about that class.
const Map<String, double> kRiskWeights = {
  // ── High risk (≥ 2.5) — moving / heavy / safety-critical ────────────────
  // These also pass kOutdoorObstacleRiskThreshold and trigger HIGH-priority
  // TTS during outdoor navigation.
  'person': 3.0,
  'car': 3.0,
  'bus': 3.0,
  'truck': 3.0,
  'train': 3.0,
  'bear': 3.0,
  'motorcycle': 2.5,
  'bicycle': 2.5,
  'dog': 2.5,
  'elephant': 2.5,

  // ── Medium-high (1.8–2.0) — large vehicles / animals ────────────────────
  'boat': 2.0,
  'airplane': 2.0,
  'horse': 2.0,
  'cow': 2.0,
  'fire hydrant': 1.8,
  'couch': 1.8,
  'bed': 1.8,
  'refrigerator': 1.8,

  // ── Medium (1.3–1.5) — large fixtures + smaller animals ─────────────────
  'chair': 1.5,
  'bench': 1.5,
  'table': 1.5,
  'dining table': 1.5,
  'potted plant': 1.5,
  'stop sign': 1.5,
  'traffic light': 1.5,
  'tv': 1.5,
  'oven': 1.5,
  'toilet': 1.5,
  'suitcase': 1.5,
  'skateboard': 1.5,
  'sheep': 1.5,
  'zebra': 1.5,
  'giraffe': 1.5,
  'parking meter': 1.5,
  'sink': 1.3,
  'microwave': 1.3,

  // ── Low (1.0) — small handheld / explicit low-risk ──────────────────────
  'laptop': 1.2,
  'bottle': 1.0,
  'cat': 1.0,
  'clock': 1.0,
  'vase': 1.0,
  'scissors': 1.0,
  'knife': 1.0,
  'umbrella': 1.0,
  'skis': 1.0,
  'snowboard': 1.0,
  'baseball bat': 1.0,
  'surfboard': 1.0,

  // ── Lowest (0.5–0.8) — generally low-impact but useful for "what's
  //    around" + indoor verbose mode ─────────────────────────────────────
  'mouse': 0.8,
  'keyboard': 0.8,
  'cell phone': 0.8,
  'cup': 0.8,
  'wine glass': 0.8,
  'fork': 0.8,
  'spoon': 0.8,
  'bowl': 0.8,
  'book': 0.8,
  'teddy bear': 0.8,
  'hair drier': 0.8,
  'bird': 0.8,
  'backpack': 0.8,
  'handbag': 0.8,
  'sports ball': 0.8,
  'baseball glove': 0.8,
  'tennis racket': 0.8,
  'toothbrush': 0.5,
  'tie': 0.5,
  'frisbee': 0.5,
  'kite': 0.5,
  'banana': 0.5,
  'apple': 0.5,
  'sandwich': 0.5,
  'orange': 0.5,
  'broccoli': 0.5,
  'carrot': 0.5,
  'hot dog': 0.5,
  'pizza': 0.5,
  'donut': 0.5,
  'cake': 0.5,
};
const Map<String, double> kZoneWeights = {
  'ahead': 3,
  'on left': 1.5,
  'on right': 1.5,
};

// ── Voice variant sets — py:965-970 ───────────────────────────────────────
const Set<String> kOutdoorVariants = {
  'outdoor',
  'outdoors',
  'outside',
  'out door',
  'art door',
  'outer',
  'out doors',
};
const Set<String> kIndoorVariants = {
  'indoor',
  'indoors',
  'inside',
  'in door',
  'endure',
  'en door',
  'and door',
  'on door',
  'undoor',
  'indoor mode',
  'in doors',
  'and or',
  'in do',
  'indo',
};

// ── Wake words — py:1491-1496 ─────────────────────────────────────────────
const List<String> kWakeWords = [
  'hey', 'navigate', 'pause', 'resume', 'stop', 'quiet', 'silence',
  'indoor', 'outdoor', 'inside', 'outside', 'help', 'what', 'describe',
  'back', 'next', 'repeat', 'verbose', 'simple', 'faster', 'slower',
  'continue', 'cancel', 'exit', 'surroundings', 'around', 'mode',
];

// ── Voice strings ─────────────────────────────────────────────────────────
// Canonical brand spelling — camelCase, capital W and F. UI wordmarks that
// want all-caps should call `.toUpperCase()` on this constant rather than
// hardcoding the cased form, so any rename touches one place.
const String kAppName = 'WayFinder';
const String kWelcomeMsg =
    'WayFinder ready. '
    'Tap anywhere on the screen to talk, long-press for emergency. '
    'I will now ask you to choose a mode.';

// ── Settings preferences (Step F-2) ───────────────────────────────────────
const String kPrefEmergencyContacts = 'emergency_contacts'; // List<String>
const String kPrefEmergencyPhone = 'emergency_phone';       // single
const String kPrefAppLanguage = 'app_language';             // BCP-47 tag
const String kPrefPreciseLocation = 'precise_location';     // bool
const String kDefaultAppLanguage = 'en-US';
const String kPromptSettingsOpening = 'Opening settings.';
const String kPromptEmergencyPhoneSaved = 'Emergency phone saved.';
const String kPromptAppLanguageSaved = 'App language saved.';
const String kPromptSmsStatusEnabled = 'SMS auto-send is enabled.';
const String kPromptSmsStatusOpenSettings =
    'Opening app settings. Please enable SMS permission to send '
    'emergency alerts automatically.';
const String kPromptSmsBlockedSession =
    'SMS access is blocked by your phone security. Emergency alerts '
    'will open the messages app instead.';

// ── Splash + onboarding (Step F-1) ────────────────────────────────────────
const String kPrefHasSeenOnboarding = 'has_seen_onboarding';
const Duration kSplashDuration = Duration(seconds: 3);
// Each TTS line is spoken automatically on page entry; phrasing intentionally
// describes WayFinder's *actual* gestures (two-finger SOS, not long-press —
// that's a Stitch artifact we adapt away from).
const String kPromptOnboardingTalk =
    'Talk to navigate. Just speak — say outdoor, indoor, or your destination. '
    'Our AI-driven voice core guides you with high-precision feedback.';
const String kPromptOnboardingPath =
    'See the path ahead. Your camera detects obstacles in real time and warns you.';
const String kPromptOnboardingHelp =
    'Help is one press away. Place two fingers anywhere on the screen to send '
    'your location to your emergency contact.';

// ── Voice-first welcome prompts (Step C) ──────────────────────────────────
// Voice-first phrasing: "then say" implies a two-step interaction (tap to
// activate the mic, THEN speak the command) — primary user is blind and
// must understand that any tap = voice activation. Mentions SOS once for
// discoverability (only spoken on first welcome / after reset).
const String kPromptWelcomeGreeting =
    'Welcome to WayFinder. Tap anywhere and say outdoor or indoor. '
    'For emergency, tap with two fingers anywhere.';
const String kPromptWelcomeHelp =
    'WayFinder helps you navigate. Say outdoor for street navigation, '
    'or indoor for obstacle detection. Tap anywhere on the screen to speak. '
    'For an emergency alert, tap the screen with two fingers at the same time.';
const String kPromptWelcomeUnknown =
    'I did not understand. Say outdoor, indoor, or help.';
const String kPromptWelcomeSwitchOutdoor = 'Switching to outdoor mode.';
const String kPromptWelcomeSwitchIndoor = 'Switching to indoor mode.';
const String kPromptWelcomeSettingsComingSoon = 'Settings coming soon.';

// ── Outdoor obstacle filter (Part B) ──────────────────────────────────────
// Only LIVE / vehicle-class obstacles (kRiskWeights >= 2.5) qualify for
// outdoor announcements. Chairs / plants / bins (risk 1.0–1.8) are
// suppressed entirely — they're rarely path-blocking in a street scenario
// and the chatter would mask navigation TTS.
const double kOutdoorObstacleRiskThreshold = 2.5;
// Normalized proximity score (1.0 = directly in front, 0.0 = far). Only
// announce things that are CLOSE enough to matter while walking. Loosely
// "close" + "very close" + "extremely close" map to >= ~0.5.
const double kOutdoorObstacleProximityThreshold = 0.5;
// Prompts for the camera-permission flow at navigation start.
const String kPromptCameraPermNeeded =
    'Camera permission is needed for obstacle detection during '
    'navigation. Please allow the camera.';
const String kPromptCameraPermDenied =
    'Continuing without obstacle detection. You can enable the camera '
    'permission in settings.';

// ── SOS / emergency ───────────────────────────────────────────────────────
const String kDefaultEmergencyContact = '+201000000000';
const int kSosCountdownSeconds = 3;
// Grace window after a mode flip (and after SOS sent → idle) during which
// a stray two-finger touch is ignored. Reuses kModeSwitchGraceMs so a user
// settling the phone in their hand right after a mode change doesn't
// accidentally arm an SOS countdown.
const int kSosArmGraceMs = kModeSwitchGraceMs;
const String kPromptSosStart = 'Emergency alert in 3.';
const String kPromptSosCancelled = 'Emergency alert cancelled.';
// Sent prompt: coordinates are captured silently into SosState (used by SMS
// dispatch in a later step) but never spoken — reading digit strings is
// useless for a blind user.
const String kPromptSosSent = 'Emergency alert sent. Help is on the way.';
const String kPromptSosSentPartial =
    'Emergency alert sent to some contacts. Help is on the way.';
const String kPromptSosLaunchedApp =
    'Opening messages app. Please confirm send.';
const String kPromptSosFailed =
    'Could not send emergency alert. Please call for help directly.';
const String kPromptSosNoContact =
    'No emergency contact configured. Please add a contact in settings.';
// SMS body templates — placeholders are substituted in SmsService.
const String kSosSmsBodyWithLocation =
    'EMERGENCY: I need help. My location: {maps}';
const String kSosSmsBodyNoLocation =
    'EMERGENCY: I need help. Location unavailable.';

// ── Cancel-confirm prompts (outdoor + indoor) ─────────────────────────────
// Wording is uniform across both modes: tap to confirm, do nothing (3 s
// timeout) to keep going. The long-press is the ARMING gesture, so we no
// longer mention it as a "keep going" path — that was the old back-out
// pattern and is no longer wired.
const String kPromptCancelArm =
    'Cancel navigation? Tap to confirm, or do nothing to keep going.';
const String kPromptCancelKeep = 'Keeping navigation active.';

// ── Indoor cancel-confirm ─────────────────────────────────────────────────
const String kPromptIndoorCancelArm =
    'Cancel indoor mode? Tap to confirm, or do nothing to keep going.';
const String kPromptIndoorCancelKeep = 'Keeping indoor mode active.';
const String kPromptIndoorCancelled = 'Indoor mode cancelled.';

// ── Max Places results — py:648 ───────────────────────────────────────────
const int kPlacesMaxResults = 4;

// ── Option parser retry limit — py:944 ────────────────────────────────────
const int kModeSelectRetries = 5;

// ═══════════════════════════════════════════════════════════════════════════
//  M6 — Outdoor mode (GPS + Places + Routes + navigation state machine)
// ═══════════════════════════════════════════════════════════════════════════

// ── GPS resolution (gps_service) — py:255-328 behaviour ───────────────────
const double kGpsFallbackLat = kFallbackLat; // Cairo (reuse indoor fallback)
const double kGpsFallbackLng = kFallbackLon;
const int kGpsFixTimeoutSec = 15; // no real fix in 15 s → emit fallback
const int kGpsPermissionMaxPrompts = 2; // denied twice → fallback
const double kGpsFallbackAccuracyM = 5000.0; // huge accuracy ⇒ "approximate"

// ── Places / Routes networking ────────────────────────────────────────────
const int kPlacesTimeoutSec = 10;
const int kRoutesTimeoutSec = 10;
const int kHttpRetries = 1; // retry once on network failure, then throw

// ── Outdoor navigation state machine ──────────────────────────────────────
const int kNavPollIntervalSec = 2; // NavigationPoller Timer.periodic
// Within this many metres of the current step's end → auto-advance. Bumped
// 10 → 15 (Part A) to better match real Android GPS noise; the step still
// fires earlier than the user would notice anyway.
const double kStepAdvanceMeters = 15.0;
// Alias kept for the Part-A spec naming.
const double kStepAdvanceThresholdMeters = kStepAdvanceMeters;
const Duration kStepPollInterval = Duration(seconds: kNavPollIntervalSec);
// Seconds without a real GPS fix before we announce "Lost GPS signal".
const int kGpsLostThresholdSec = 10;
const double kRouteDeviationMeters = 50.0; // > 50 m off segment → re-route
const int kRouteDeviationPolls = 2; // for this many consecutive polls
const int kArrivedDwellSec = 5; // hold "arrived" then return to idle
const int kOptionMaxRetries = 3; // bad choice → re-prompt up to 3×
const int kOptionPauseMs = 350; // gap between spoken option utterances
const int kModeSwitchTimeoutSec = 10; // switch hung guard

// ── Outdoor TTS prompts ───────────────────────────────────────────────────
// Wording taken verbatim from Rahaf_strials_egypt.py where it exists; the
// rest resolved per the M6 plan (documented in the milestone summary).
// {placeholders} are filled at runtime.
const String kPromptAskDestination = 'Where would you like to go?'; // py:1017
const String kPromptSearching = 'Searching for {q}.';
// py:1056 lead-in was "I found these."; M6 adds the "{name} on {address}"
// per-option phrasing requested in the spec.
const String kPromptOptionsLeadIn = 'I found these places.';
// Shortened from the verbose "Option N: {name} on {full address}." form —
// reading the full Egypt-style address (Unnamed Road, 7F2W+JQV 6362040)
// took 9–12 s per option. The {city} placeholder is filled by
// _shortLocation() in navigation_notifier, which strips plus-codes and
// zipcodes to pick a human-meaningful chunk (e.g. "Obour", "Cairo
// Governorate"). When no usable chunk is found we omit the city clause
// entirely via kPromptOptionItemNoCity.
const String kPromptOptionItem = 'Option {i}: {name}, in {city}.';
const String kPromptOptionItemNoCity = 'Option {i}: {name}.';
const String kPromptOptionsHowTo =
    'Say the option number, or say search again for different places.';
const String kPromptChoiceRetry =
    'Which option? Say a number from 1 to {n}, or say search again.';
const String kPromptChoiceGiveUp = "Let's start over.";
const String kPromptRouting = 'Routing to {d}.'; // py:1119 "Navigating to {x}."
const String kPromptArrived = 'You have arrived at {d}.'; // py:1210
// Active-navigation voice commands (Part A).
const String kPromptNavUnknownCmd =
    'Unknown command. Say next, repeat, how far, where am I, or cancel.';
const String kPromptNoGpsForRouting =
    'Location not available. Please go outside to get a GPS signal.';
// Spoken on outdoor-mode entry when the only fix we have is the fallback
// (Cairo) — gives the user a heads-up BEFORE they search/choose a place.
const String kPromptOutdoorNoGps =
    'GPS is not available. Please enable location services in your '
    'phone settings, then tap to search.';
// Defensive prompt when option-retry would otherwise say "1 to 0".
const String kPromptOptionsClearedTryAgain =
    'No options available. Tap and say a destination.';
// After a manual "next", ignore off-route polling for this long so the
// Step-N TTS isn't cancelled by an immediate re-route while the user
// is still standing still listening to the new instruction.
const Duration kManualAdvanceSettleDuration = Duration(seconds: 15);
// Seconds to wait for the first real GPS fix when entering outdoor mode
// before warning the user.
const int kOutdoorGpsCheckSec = 3;
const String kPromptGpsLost =
    'Lost GPS signal. Manual navigation only — say next when ready for '
    'the next step.';
const String kPromptGpsRestored = 'GPS restored.';
// "On step X of Y. Current instruction: ...".
const String kPromptNavWhereAmI =
    'On step {i} of {n}. Current instruction: {instr}.';
// "X steps remaining. Approximately Y metres to destination."
const String kPromptNavRemaining =
    '{steps} steps remaining. Approximately {meters} metres to destination.';
// "Step X of Y. {instruction}."
const String kPromptNavStep = 'Step {i} of {n}. {instr}.';
const String kPromptRerouting = 'Re-routing.';
const String kPromptNoResults =
    'No results for {q}. Try a different place.'; // py:1032
const String kPromptCancelled = 'Navigation cancelled.';
const String kPromptRemainingDistance = '{d} to your destination.';
const String kPromptLocationFix =
    'You are near {lat}, {lng}.'; // "Where am I?" fallback (no geocoding)
const String kPromptApproxLocation = 'Using approximate location.';

// ── Mode-switch button labels ─────────────────────────────────────────────
const String kSwitchToOutdoorLabel = 'Switch to Outdoor';
const String kSwitchToIndoorLabel = 'Switch to Indoor';
