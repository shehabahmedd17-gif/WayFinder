// Google Places API (New) — Text Search.
// py:search_places() (lines 636-676).
//
// POST https://places.googleapis.com/v1/places:searchText
//   headers: X-Goog-Api-Key, X-Goog-FieldMask, Content-Type
//   body:    {textQuery, languageCode:'en', regionCode:'EG', maxResultCount}
//
// " Egypt" is appended to every query to bias toward Egyptian results
// (py:646  textQuery = f"{query} Egypt"). At most kPlacesMaxResults (4)
// results are returned. 10 s timeout, one retry on network failure, then a
// PlacesException carrying a user-friendly message.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/api_keys.dart';
import '../../core/constants.dart';
import '../../models/place.dart';

class PlacesException implements Exception {
  final String userMessage; // safe to speak / show to the user
  final Object? cause;
  PlacesException(this.userMessage, [this.cause]);
  @override
  String toString() => 'PlacesException($userMessage${cause == null ? "" : " — $cause"})';
}

class PlacesService {
  static const _url = 'https://places.googleapis.com/v1/places:searchText';
  static const _fieldMask =
      'places.displayName,places.formattedAddress,places.location,places.id';

  final http.Client _client;
  PlacesService({http.Client? client}) : _client = client ?? http.Client();

  Future<List<Place>> search(String query) async {
    if (!ApiKeys.hasPlaces) {
      debugPrint('[API] key missing for places — search blocked');
      throw PlacesException(
          'Place search is unavailable. The Places API key is not configured.');
    }

    final body = jsonEncode({
      'textQuery': '$query Egypt', // py:646
      'languageCode': 'en',
      'regionCode': 'EG',
      'maxResultCount': kPlacesMaxResults,
    });
    final headers = {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': ApiKeys.places,
      'X-Goog-FieldMask': _fieldMask,
    };

    Object? lastError;
    for (var attempt = 0; attempt <= kHttpRetries; attempt++) {
      try {
        final resp = await _client
            .post(Uri.parse(_url), headers: headers, body: body)
            .timeout(const Duration(seconds: kPlacesTimeoutSec));

        if (resp.statusCode != 200) {
          // 4xx (bad key, quota) won't get better on retry → fail fast.
          throw PlacesException(
            'Place search failed (server said ${resp.statusCode}).',
            resp.body,
          );
        }

        final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
        final raw = (decoded['places'] as List?) ?? const [];
        final places = <Place>[];
        for (final p in raw.take(kPlacesMaxResults)) {
          final m = p as Map<String, dynamic>;
          final loc = (m['location'] as Map?) ?? const {};
          places.add(Place(
            name: (m['displayName']?['text'] as String?)?.trim() ??
                'Unknown place',
            address: (m['formattedAddress'] as String?)?.trim() ?? '',
            lat: (loc['latitude'] as num?)?.toDouble() ?? 0,
            lng: (loc['longitude'] as num?)?.toDouble() ?? 0,
            placeId: (m['id'] as String?) ?? '',
          ));
        }
        debugPrint('[PLACES] "$query" → ${places.length} result(s)');
        return places;
      } on PlacesException {
        rethrow; // already user-friendly; don't retry server rejections
      } on TimeoutException catch (e) {
        lastError = e;
        debugPrint('[PLACES] attempt ${attempt + 1} timed out');
      } catch (e) {
        lastError = e;
        debugPrint('[PLACES] attempt ${attempt + 1} network error: $e');
      }
    }

    throw PlacesException(
      'Could not reach the place search service. Check your connection.',
      lastError,
    );
  }
}

final placesServiceProvider = Provider<PlacesService>((ref) => PlacesService());
