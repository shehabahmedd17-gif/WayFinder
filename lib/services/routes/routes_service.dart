// Google Routes API (New) — computeRoutes, WALK mode.
// py:get_walking_route() (lines 682-741).
//
// POST https://routes.googleapis.com/directions/v2:computeRoutes
//   headers: X-Goog-Api-Key, X-Goog-FieldMask, Content-Type
//   body:    {origin, destination, travelMode:'WALK', languageCode:'en'}
//
// Routes (New) returns plain-text navigation instructions, but we still strip
// HTML tags as defense-in-depth (py:727  re.sub(r"<[^>]+>", " ", raw)).
// 10 s timeout, one retry on network failure, then RoutesException.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/api_keys.dart';
import '../../core/constants.dart';
import '../../models/route.dart';
import '../../models/route_step.dart';

class RoutesException implements Exception {
  final String userMessage;
  final Object? cause;
  RoutesException(this.userMessage, [this.cause]);
  @override
  String toString() =>
      'RoutesException($userMessage${cause == null ? "" : " — $cause"})';
}

class RoutesService {
  static const _url =
      'https://routes.googleapis.com/directions/v2:computeRoutes';
  // Mirror py:702-706 field mask, extended with startLocation + totals.
  static const _fieldMask =
      'routes.legs.steps.navigationInstruction,'
      'routes.legs.steps.startLocation,'
      'routes.legs.steps.endLocation,'
      'routes.legs.steps.distanceMeters,'
      'routes.distanceMeters,'
      'routes.duration';

  final http.Client _client;
  RoutesService({http.Client? client}) : _client = client ?? http.Client();

  static String stripHtml(String s) => s
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<Route> computeWalkingRoute({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
  }) async {
    if (!ApiKeys.hasRoutes) {
      debugPrint('[API] key missing for routes — routing blocked');
      throw RoutesException(
          'Walking directions are unavailable. The Routes API key is not configured.');
    }

    final body = jsonEncode({
      'origin': {
        'location': {
          'latLng': {'latitude': originLat, 'longitude': originLng}
        }
      },
      'destination': {
        'location': {
          'latLng': {'latitude': destLat, 'longitude': destLng}
        }
      },
      'travelMode': 'WALK',
      'languageCode': 'en',
    });
    final headers = {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': ApiKeys.routes,
      'X-Goog-FieldMask': _fieldMask,
    };

    Object? lastError;
    for (var attempt = 0; attempt <= kHttpRetries; attempt++) {
      try {
        final resp = await _client
            .post(Uri.parse(_url), headers: headers, body: body)
            .timeout(const Duration(seconds: kRoutesTimeoutSec));

        if (resp.statusCode != 200) {
          throw RoutesException(
            'Routing failed (server said ${resp.statusCode}).',
            resp.body,
          );
        }

        final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
        final routes = (decoded['routes'] as List?) ?? const [];
        if (routes.isEmpty) {
          throw RoutesException('No walking route found to that place.');
        }
        final r0 = routes.first as Map<String, dynamic>;
        final legs = (r0['legs'] as List?) ?? const [];

        final steps = <RouteStep>[];
        for (final leg in legs) {
          final rawSteps = ((leg as Map)['steps'] as List?) ?? const [];
          for (final s in rawSteps) {
            final m = s as Map<String, dynamic>;
            final start = (m['startLocation']?['latLng'] as Map?) ?? const {};
            final end = (m['endLocation']?['latLng'] as Map?) ?? const {};
            final instr = (m['navigationInstruction']?['instructions']
                    as String?) ??
                '';
            steps.add(RouteStep(
              instruction: stripHtml(instr),
              startLat: (start['latitude'] as num?)?.toDouble() ?? 0,
              startLng: (start['longitude'] as num?)?.toDouble() ?? 0,
              endLat: (end['latitude'] as num?)?.toDouble() ?? 0,
              endLng: (end['longitude'] as num?)?.toDouble() ?? 0,
              distanceMeters: (m['distanceMeters'] as num?)?.toInt() ?? 0,
            ));
          }
        }
        if (steps.isEmpty) {
          throw RoutesException('That route has no walkable steps.');
        }

        final route = Route(
          steps: steps,
          totalDistanceMeters: (r0['distanceMeters'] as num?)?.toInt() ?? 0,
          totalDurationSeconds: _parseDuration(r0['duration'] as String?),
        );
        debugPrint('[ROUTES] ${route.steps.length} steps, '
            '${route.totalDistanceMeters} m, '
            '${route.totalDurationSeconds} s');
        return route;
      } on RoutesException {
        rethrow;
      } on TimeoutException catch (e) {
        lastError = e;
        debugPrint('[ROUTES] attempt ${attempt + 1} timed out');
      } catch (e) {
        lastError = e;
        debugPrint('[ROUTES] attempt ${attempt + 1} network error: $e');
      }
    }

    throw RoutesException(
      'Could not reach the routing service. Check your connection.',
      lastError,
    );
  }

  // Routes API returns duration like "1234s".
  static int _parseDuration(String? d) {
    if (d == null) return 0;
    final m = RegExp(r'^(\d+)s$').firstMatch(d.trim());
    return m == null ? 0 : int.parse(m.group(1)!);
  }
}

final routesServiceProvider =
    Provider<RoutesService>((ref) => RoutesService());
