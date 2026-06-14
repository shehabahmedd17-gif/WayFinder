# WayFinder 🧭

Voice-first navigation assistant for the visually impaired —
built with Flutter, on-device AI, and accessibility-first design.

## Overview

WayFinder helps blind and visually impaired users navigate the
world through voice commands and AI-powered obstacle detection.
The app runs entirely on-device — no cloud dependency, full
privacy, works offline.

Key features:
- Voice-first interaction (push-to-talk STT)
- Outdoor GPS turn-by-turn navigation via Google Routes API
- Indoor obstacle detection with YOLOv8n + MiDaS on-device
- Emergency SOS: two-finger gesture sends location SMS
- Accessibility-first UI: large tap zones, audio feedback

## Tech Stack

- Framework: Flutter (Android target)
- Language: Dart 3.x with null safety
- State: Riverpod (StateNotifier)
- Object detection: YOLOv8n (TFLite, GPU delegate)
- Depth estimation: MiDaS small (TFLite, XNNPACK 4-thread)
- Navigation: Google Places + Routes APIs
- Voice: flutter_tts + speech_to_text
- SMS: another_telephony + url_launcher fallback

## Setup

Prerequisites:
- Flutter SDK 3.x
- Android SDK 21+
- A physical Android device (camera + GPS required)

Installation:

    git clone <this-repo-url>
    cd wayfinder
    flutter pub get

Create api_keys.txt in the project root with your Google Maps
Platform keys (one per line):

    PLACES_API_KEY=YOUR_KEY_HERE
    ROUTES_API_KEY=YOUR_KEY_HERE
    GEOCODING_API_KEY=YOUR_KEY_HERE

Never commit api_keys.txt — it is in .gitignore.

Build:

    powershell -ExecutionPolicy Bypass -File .\build.ps1

Install build\app\outputs\flutter-apk\app-debug.apk on your device.

## Architecture

- TTS Priority Coordinator: HIGH (obstacles) preempts MEDIUM
  (steps) preempts LOW (status)
- Mode Switch Lock: mutex prevents camera disposal races during
  rapid mode switching
- Phase-based State Machine: outdoor flow uses dedicated phases,
  not Stack overlays
- Vendor-aware SMS: detects MIUI/Samsung blocks, falls back to
  launcher
- Adaptive Frame Skipping: pipeline self-tunes based on cycle time

## Testing

    flutter test
    flutter analyze

Status: 192 tests passing, 0 analyzer issues.

## Known Limitations

- YOLOv8n only recognizes 80 COCO classes — objects not in COCO
  (fans, ACs, mirrors) are misclassified to nearest visual match.
- Pipeline cycle is 7-8 seconds on mid-range devices. Adaptive
  skip compensates.
- STT requires en_US locale. Variant matching mitigates Egyptian-
  accent mishears.

## License

Academic / educational use. Not licensed for commercial deployment.

---

Graduation project — accessibility-first software design with
modern on-device AI.
