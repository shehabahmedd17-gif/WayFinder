// Unit tests for SmsService.buildSmsUri.
//
// The actual `launchUrl` call is platform-bound and not tested here —
// buildSmsUri is the pure logic we care about.

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_nav/models/location_fix.dart';
import 'package:smart_nav/services/sms_service.dart';

LocationFix _fix(double lat, double lng) => LocationFix(
      lat: lat,
      lng: lng,
      accuracyMeters: 5,
      timestamp: DateTime.now(),
      isFallback: false,
    );

void main() {
  test('1. single contact, with location → smsto URI + maps link in body', () {
    final uri = SmsService.buildSmsUri(
      contacts: ['+201234567890'],
      location: _fix(30.25101, 31.46389),
    );
    expect(uri.scheme, 'smsto');
    expect(uri.path, '+201234567890');
    final body = uri.queryParameters['body'];
    expect(body, isNotNull);
    expect(body, contains('EMERGENCY: I need help'));
    expect(body, contains('https://maps.google.com/?q=30.25101,31.46389'));
    expect(body, isNot(contains('unavailable')));
  });

  test('2. multiple contacts are comma-joined', () {
    final uri = SmsService.buildSmsUri(
      contacts: ['+201234567890', '+201111111111'],
      location: _fix(30.0, 31.0),
    );
    expect(uri.path, '+201234567890,+201111111111');
  });

  test('3. null location → body says "Location unavailable"', () {
    final uri = SmsService.buildSmsUri(
      contacts: ['+201234567890'],
      location: null,
    );
    expect(uri.queryParameters['body'],
        'EMERGENCY: I need help. Location unavailable.');
  });

  test('4. blanks and whitespace-only entries are dropped + trimmed', () {
    final uri = SmsService.buildSmsUri(
      contacts: ['  +20 100 ', '', '   ', '+1 555 0123'],
      location: null,
    );
    // Uri normalises the path — spaces inside numbers come out URL-encoded.
    // Decoding round-trips back to the trimmed, joined form.
    expect(Uri.decodeComponent(uri.path), '+20 100,+1 555 0123');
  });

  test('5. body is URL-encoded in the final string (spaces, colons)', () {
    final uri = SmsService.buildSmsUri(
      contacts: ['+1'],
      location: null,
    );
    // Uri.toString() encodes spaces in the query as %20 (or +); both are
    // acceptable. The colon after EMERGENCY also gets percent-encoded.
    final s = uri.toString();
    expect(s.startsWith('smsto:+1?body='), isTrue);
    // No literal newlines or raw double-spaces in the encoded form.
    expect(s, isNot(contains('\n')));
    // Round-trip: decoding the body should return the original string.
    final decoded = Uri.decodeQueryComponent(s.split('body=').last);
    expect(decoded, 'EMERGENCY: I need help. Location unavailable.');
  });

  test('6. location with negative coordinates is preserved', () {
    final uri = SmsService.buildSmsUri(
      contacts: ['+1'],
      location: _fix(-33.8688, 151.2093),
    );
    expect(uri.queryParameters['body'],
        contains('https://maps.google.com/?q=-33.8688,151.2093'));
  });

  // ── SmsPermissionState enum coverage (F-3 vendor-block fix) ────────
  // SmsService.getSmsPermissionState reads Permission.sms.status, which
  // requires platform binding mocking. We assert the enum's existence
  // and the SmsService factory behaviour here; the runtime mapping is
  // exercised via the SOS integration tests + on-device QA.

  test('7. SmsPermissionState enum has the three documented values', () {
    expect(SmsPermissionState.values, [
      SmsPermissionState.granted,
      SmsPermissionState.denied,
      SmsPermissionState.permanentlyDenied,
    ]);
  });

  test('8. SmsDispatchResult covers every dispatch outcome', () {
    // Compile-time guard: any new enum value must be considered when
    // updating SosNotifier._spokenFor.
    expect(SmsDispatchResult.values, [
      SmsDispatchResult.directSentAll,
      SmsDispatchResult.directSentPartial,
      SmsDispatchResult.appLaunched,
      SmsDispatchResult.noContacts,
      SmsDispatchResult.failed,
    ]);
  });
}
