// SOS service — implemented in Step 7.
// Three actions in sequence (py:1332-1384 trigger_sos / _send_sos_message):
//
//   1. Vibrate 3 long pulses (500 ms on / 200 ms off) via vibration package.
//   2. TTS: "Calling emergency contact now. Your location is lat, lon."
//   3. Auto-dial via url_launcher tel: URI — opens dialer and starts call
//      on most Android versions (ACTION_CALL requires no CALL_PHONE permission
//      when handed to the system dialer via LaunchMode.externalApplication).
//   4. Pre-fill SMS via url_launcher sms: URI — user or nearby person taps Send.
//      Body includes Google Maps link with GPS coords.
//
// No SEND_SMS / CALL_PHONE manifest permissions needed — both actions hand off
// to the system dialer / messaging app.
//
// Emergency contact is stored in SharedPreferences (default kDefaultEmergencyContact).

import 'package:flutter/foundation.dart';

class SosService {
  Future<void> trigger({
    required double lat,
    required double lon,
    required String emergencyContact,
  }) async {
    final mapsUrl =
        'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
    debugPrint('[SOS] lat=$lat lon=$lon contact=$emergencyContact');
    debugPrint('[SOS] Maps URL: $mapsUrl');

    // TODO Step 7 — implement in order:
    //
    // 1. Vibrate
    //    final v = Vibration();
    //    await v.vibrate(pattern: [0, 500, 200, 500, 200, 500]);
    //
    // 2. TTS announcement (non-blocking)
    //    tts.speakBackground(
    //      'Calling emergency contact now. '
    //      'Your location is ${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}.'
    //    );
    //
    // 3. Auto-dial
    //    await launchUrl(
    //      Uri.parse('tel:$emergencyContact'),
    //      mode: LaunchMode.externalApplication,
    //    );
    //
    // 4. Pre-filled SMS
    //    final body = Uri.encodeComponent(
    //      'EMERGENCY from Smart Nav user. Location: $mapsUrl');
    //    await launchUrl(
    //      Uri.parse('sms:$emergencyContact?body=$body'),
    //      mode: LaunchMode.externalApplication,
    //    );
  }
}
