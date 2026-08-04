import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:google_navigation_flutter/google_navigation_flutter.dart';
import 'package:http/http.dart' as http;

import '../models/place_suggestion.dart';

class MapsNavigationService {
  MapsNavigationService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('com.dominar/maps');

  final MethodChannel _channel;
  String? _apiKey;

  Future<String?> _getApiKey() async {
    if (_apiKey != null) return _apiKey;
    try {
      final key = await _channel.invokeMethod<String>('getApiKey');
      if (_isUsableKey(key)) {
        _apiKey = key;
      }
    } catch (_) {
      return null;
    }
    return _apiKey;
  }

  bool _isUsableKey(String? key) {
    return key != null &&
        key.startsWith('AIza') &&
        !key.contains('REPLACE') &&
        key.length >= 39;
  }

  String _friendlyApiError(String status, String? message) {
    final detail = (message ?? status).trim();
    if (status == 'REQUEST_DENIED') {
      if (detail.toLowerCase().contains('invalid')) {
        return 'Invalid API key. Paste the full key (39 chars) into '
            'ios/Flutter/Secrets.xcconfig and enable Places + Geocoding APIs.';
      }
      return 'Google denied the request. Enable Places API and Geocoding API. '
          'Set key Application restrictions to None for REST calls.';
    }
    if (status == 'OVER_QUERY_LIMIT') {
      return 'Google Maps quota exceeded. Check billing in Google Cloud.';
    }
    if (status == 'INVALID_REQUEST') {
      return 'Maps search request invalid: $detail';
    }
    if (status == 'ZERO_RESULTS') {
      return 'No results for that place.';
    }
    return detail.isEmpty ? 'Maps search failed ($status).' : detail;
  }

  Future<MapsSearchResult> searchPlaces(
    String query, {
    LatLng? near,
  }) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      return const MapsSearchResult(suggestions: []);
    }

    final key = await _getApiKey();
    if (key == null) {
      return const MapsSearchResult(
        suggestions: [],
        errorMessage:
            'Maps API key missing or incomplete. Open ios/Flutter/Secrets.xcconfig '
            'and paste the full Google key (starts with AIza, about 39 characters).',
      );
    }

    final params = <String, String>{
      'input': trimmed,
      'key': key,
      'components': 'country:in',
    };
    if (near != null) {
      params['location'] = '${near.latitude},${near.longitude}';
      params['radius'] = '50000';
    }

    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/place/autocomplete/json',
      params,
    );
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        return MapsSearchResult(
          suggestions: const [],
          errorMessage: 'Maps network error (${response.statusCode}).',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final status = data['status'] as String? ?? 'UNKNOWN';
      if (status == 'OK') {
        final predictions = data['predictions'] as List<dynamic>? ?? [];
        return MapsSearchResult(
          suggestions: predictions
              .map((item) {
                final map = item as Map<String, dynamic>;
                return PlaceSuggestion(
                  placeId: map['place_id'] as String,
                  description: map['description'] as String,
                );
              })
              .toList(growable: false),
        );
      }
      if (status == 'ZERO_RESULTS') {
        return const MapsSearchResult(suggestions: []);
      }

      return MapsSearchResult(
        suggestions: const [],
        errorMessage: _friendlyApiError(
          status,
          data['error_message'] as String?,
        ),
      );
    } on TimeoutException {
      return const MapsSearchResult(
        suggestions: [],
        errorMessage: 'Search timed out. Check your internet connection.',
      );
    }
  }

  Future<MapsLookupResult> resolvePlace(String placeId) async {
    final key = await _getApiKey();
    if (key == null) {
      return const MapsLookupResult(
        errorMessage: 'Maps API key missing or incomplete.',
      );
    }

    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/place/details/json',
      {
        'place_id': placeId,
        'fields': 'geometry',
        'key': key,
      },
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      return MapsLookupResult(
        errorMessage: 'Maps network error (${response.statusCode}).',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final status = data['status'] as String? ?? 'UNKNOWN';
    if (status != 'OK') {
      return MapsLookupResult(
        errorMessage: _friendlyApiError(
          status,
          data['error_message'] as String?,
        ),
      );
    }

    final location = data['result']?['geometry']?['location'] as Map?;
    if (location == null) {
      return const MapsLookupResult(errorMessage: 'Place has no coordinates.');
    }

    return MapsLookupResult(
      location: LatLng(
        latitude: (location['lat'] as num).toDouble(),
        longitude: (location['lng'] as num).toDouble(),
      ),
    );
  }

  Future<MapsLookupResult> geocodeAddress(String address) async {
    final key = await _getApiKey();
    if (key == null) {
      return const MapsLookupResult(
        errorMessage:
            'Maps API key missing or incomplete. Paste the full key into '
            'ios/Flutter/Secrets.xcconfig.',
      );
    }

    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/geocode/json',
      {
        'address': address,
        'key': key,
        'components': 'country:in',
      },
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      return MapsLookupResult(
        errorMessage: 'Maps network error (${response.statusCode}).',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final status = data['status'] as String? ?? 'UNKNOWN';
    if (status == 'ZERO_RESULTS') {
      return const MapsLookupResult(errorMessage: 'No results for that place.');
    }
    if (status != 'OK') {
      return MapsLookupResult(
        errorMessage: _friendlyApiError(
          status,
          data['error_message'] as String?,
        ),
      );
    }

    final results = data['results'] as List<dynamic>?;
    if (results == null || results.isEmpty) {
      return const MapsLookupResult(errorMessage: 'No results for that place.');
    }

    final location =
        results.first['geometry']?['location'] as Map<String, dynamic>?;
    if (location == null) {
      return const MapsLookupResult(errorMessage: 'No results for that place.');
    }

    return MapsLookupResult(
      location: LatLng(
        latitude: (location['lat'] as num).toDouble(),
        longitude: (location['lng'] as num).toDouble(),
      ),
    );
  }
}
