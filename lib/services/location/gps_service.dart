// GPS resolution for outdoor mode. py:255-328 behaviour:
//   try a real fix → if none, fall back to Cairo and flag it.
//
// Permission is requested ON FIRST OUTDOOR ENTRY (when start() is called),
// never at app launch — start() is only invoked by the outdoor state machine.
//
// Fallback (LocationFix.isFallback = true) is emitted when:
//   • OS location services are disabled, OR
//   • permission denied after kGpsPermissionMaxPrompts prompts, OR
//   • no real fix within kGpsFixTimeoutSec of stream start.
// A later real fix always replaces an earlier fallback.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/constants.dart';
import '../../models/location_fix.dart';

class GpsService {
  StreamSubscription<Position>? _sub;
  Timer? _fixTimeout;
  bool _running = false;
  void Function(LocationFix)? _onFix;

  bool get isRunning => _running;

  LocationFix _fallback() => LocationFix(
        lat: kGpsFallbackLat,
        lng: kGpsFallbackLng,
        accuracyMeters: kGpsFallbackAccuracyM,
        timestamp: DateTime.now(),
        isFallback: true,
      );

  /// Begin resolving location. [onFix] is called with every update
  /// (fallback first if needed, then real fixes as they arrive).
  Future<void> start({required void Function(LocationFix) onFix}) async {
    if (_running) return;
    _running = true;
    _onFix = onFix;

    // 1. OS-level location services.
    final servicesOn = await Geolocator.isLocationServiceEnabled();
    if (!servicesOn) {
      debugPrint('[GPS] location services disabled → fallback (Cairo)');
      _emit(_fallback());
      return;
    }

    // 2. Permission via permission_handler, up to N prompts.
    var status = await Permission.locationWhenInUse.status;
    var prompts = 0;
    while (!status.isGranted && prompts < kGpsPermissionMaxPrompts) {
      prompts++;
      status = await Permission.locationWhenInUse.request();
      if (status.isPermanentlyDenied) break;
    }
    if (!status.isGranted) {
      debugPrint('[GPS] permission not granted after $prompts prompt(s) '
          '($status) → fallback (Cairo)');
      _emit(_fallback());
      return;
    }

    // 3. Position stream + no-fix timeout.
    _fixTimeout = Timer(Duration(seconds: kGpsFixTimeoutSec), () {
      debugPrint('[GPS] no fix within ${kGpsFixTimeoutSec}s '
          '→ fallback (Cairo); still listening for a real fix');
      _emit(_fallback());
    });

    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    );
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      (pos) {
        _fixTimeout?.cancel();
        _fixTimeout = null;
        _emit(LocationFix(
          lat: pos.latitude,
          lng: pos.longitude,
          accuracyMeters: pos.accuracy,
          timestamp: pos.timestamp,
          isFallback: false,
        ));
      },
      onError: (Object e) {
        debugPrint('[GPS] stream error: $e → fallback (Cairo)');
        _emit(_fallback());
      },
      cancelOnError: false,
    );

    debugPrint('[GPS] started (high accuracy stream)');
  }

  void _emit(LocationFix fix) {
    debugPrint('[GPS] fix: $fix');
    _onFix?.call(fix);
  }

  /// One-shot location fetch used by SOS. Returns null on any failure —
  /// permission denied, timeout, or platform error. Does not affect the
  /// streaming subscription used by outdoor navigation.
  Future<LocationFix?> getOneShot({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      // Quick permission probe — if denied, bail without prompting (SOS
      // shouldn't pop a system dialog mid-emergency).
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        debugPrint('[GPS] one-shot: permission denied');
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(timeout);
      return LocationFix(
        lat: pos.latitude,
        lng: pos.longitude,
        accuracyMeters: pos.accuracy,
        timestamp: pos.timestamp,
        isFallback: false,
      );
    } catch (e) {
      debugPrint('[GPS] one-shot failed: $e');
      return null;
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _fixTimeout?.cancel();
    _fixTimeout = null;
    _running = false;
    _onFix = null;
    debugPrint('[GPS] stopped');
  }
}

// Singleton service; outdoor state machine owns its start()/stop() lifecycle.
final gpsServiceProvider = Provider<GpsService>((ref) {
  final svc = GpsService();
  ref.onDispose(() {
    // ignore: discarded_futures
    svc.stop();
  });
  return svc;
});

// Latest resolved location. Null until the first fix/fallback is emitted.
// The state machine wires GpsService.start(onFix: set) on outdoor entry.
class LocationNotifier extends Notifier<LocationFix?> {
  @override
  LocationFix? build() => null;

  void set(LocationFix fix) => state = fix;
  void clear() => state = null;
}

final currentLocationProvider =
    NotifierProvider<LocationNotifier, LocationFix?>(LocationNotifier.new);
