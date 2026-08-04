import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../models/navigation_route.dart';
import '../models/place_suggestion.dart';
import '../utils/polyline_decoder.dart';

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
      return 'Google denied the request. Enable Places API, Geocoding API, '
          'Routes API, and Directions API. Set key Application restrictions to None.';
    }
    if (status == 'OVER_QUERY_LIMIT') {
      return 'Google Maps quota exceeded. Check billing in Google Cloud.';
    }
    if (status == 'INVALID_REQUEST') {
      return 'Maps search request invalid: $detail';
    }
    if (status == 'ZERO_RESULTS') {
      return 'No route found to this destination.';
    }
    return detail.isEmpty ? 'Maps search failed ($status).' : detail;
  }

  String _formatDistance(int meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
    return '$meters m';
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '< 1 min';
    if (seconds < 3600) return '${(seconds / 60).round()} min';
    final hours = seconds ~/ 3600;
    final mins = ((seconds % 3600) / 60).round();
    if (mins == 0) return '$hours hr';
    return '$hours hr $mins min';
  }

  int _parseRoutesDuration(String? duration) {
    if (duration == null || duration.isEmpty) return 0;
    return int.tryParse(duration.replaceAll('s', '')) ?? 0;
  }

  Map<String, dynamic> _routesLocation(LatLng point) => {
        'location': {
          'latLng': {
            'latitude': point.latitude,
            'longitude': point.longitude,
          },
        },
      };

  LatLng? _latLngFromRoutesLocation(dynamic value) {
    if (value is! Map) return null;
    final latLng = value['latLng'];
    if (latLng is! Map) return null;
    return LatLng(
      (latLng['latitude'] as num).toDouble(),
      (latLng['longitude'] as num).toDouble(),
    );
  }

  List<NavigationStep> _parseSteps(Map<String, dynamic> route) {
    final legs = route['legs'] as List<dynamic>? ?? [];
    if (legs.isEmpty) return const [];

    final rawSteps =
        (legs.first as Map<String, dynamic>)['steps'] as List<dynamic>? ?? [];
    final steps = <NavigationStep>[];

    for (final raw in rawSteps) {
      final step = raw as Map<String, dynamic>;
      final nav = step['navigationInstruction'] as Map<String, dynamic>?;
      final end = _latLngFromRoutesLocation(step['endLocation']);
      if (nav == null || end == null) continue;

      final instruction = (nav['instructions'] as String? ?? '').trim();
      if (instruction.isEmpty) continue;

      steps.add(
        NavigationStep(
          instruction: instruction,
          maneuver: nav['maneuver'] as String? ?? 'STRAIGHT',
          distanceMeters: (step['distanceMeters'] as num?)?.toInt() ?? 0,
          end: end,
        ),
      );
    }
    return steps;
  }

  RouteResult? _parseRouteJson({
    required Map<String, dynamic> route,
    required int index,
    required LatLng destination,
    required String destinationName,
    required String travelModeLabel,
  }) {
    final distanceMeters = (route['distanceMeters'] as num?)?.toInt() ?? 0;
    final durationSeconds = _parseRoutesDuration(route['duration'] as String?);
    final encoded = route['polyline']?['encodedPolyline'] as String?;
    if (encoded == null || encoded.isEmpty || distanceMeters <= 0) return null;

    final description = (route['description'] as String? ?? '').trim();
    return RouteResult(
      id: 'route-$index',
      points: decodePolyline(encoded),
      distanceText: _formatDistance(distanceMeters),
      durationText: _formatDuration(durationSeconds),
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
      destination: destination,
      destinationName: destinationName,
      description: description.isEmpty ? 'Route ${index + 1}' : description,
      steps: _parseSteps(route),
      travelModeLabel: travelModeLabel,
    );
  }

  static const _routesFieldMask =
      'routes.description,routes.distanceMeters,routes.duration,'
      'routes.staticDuration,routes.polyline.encodedPolyline,routes.routeLabels,'
      'routes.legs.steps.navigationInstruction,routes.legs.steps.distanceMeters,'
      'routes.legs.steps.endLocation';

  static const _etaFieldMask =
      'routes.distanceMeters,routes.duration,routes.staticDuration';

  Future<RouteOptionsResult> _fetchRouteOptions({
    required LatLng origin,
    required LatLng destination,
    required String destinationName,
    required String travelMode,
    required String travelModeLabel,
    required bool alternatives,
    bool trafficAware = false,
  }) async {
    final key = await _getApiKey();
    if (key == null) {
      return const RouteOptionsResult(
        routes: [],
        errorMessage: 'Maps API key missing or incomplete.',
      );
    }

    final uri =
        Uri.https('routes.googleapis.com', '/directions/v2:computeRoutes');
    final body = <String, dynamic>{
      'origin': _routesLocation(origin),
      'destination': _routesLocation(destination),
      'travelMode': travelMode,
      'computeAlternativeRoutes': alternatives,
      'languageCode': 'en-IN',
    };
    if (trafficAware) {
      body['routingPreference'] = 'TRAFFIC_AWARE_OPTIMAL';
    }

    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': key,
        'X-Goog-FieldMask': _routesFieldMask,
      },
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final message = data['error']?['message'] as String? ??
          'Routes API error (${response.statusCode}). Enable Routes API.';
      return RouteOptionsResult(routes: const [], errorMessage: message);
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final routesJson = data['routes'] as List<dynamic>? ?? [];
    final routes = <RouteResult>[];

    for (var i = 0; i < routesJson.length; i++) {
      final parsed = _parseRouteJson(
        route: routesJson[i] as Map<String, dynamic>,
        index: i,
        destination: destination,
        destinationName: destinationName,
        travelModeLabel: travelModeLabel,
      );
      if (parsed != null) routes.add(parsed);
    }

    return RouteOptionsResult(routes: routes);
  }

  Future<RouteResult?> _fetchLegacyDirections({
    required LatLng origin,
    required LatLng destination,
    required String destinationName,
    required String travelModeLabel,
  }) async {
    final key = await _getApiKey();
    if (key == null) return null;

    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/directions/json',
      {
        'origin': '${origin.latitude},${origin.longitude}',
        'destination': '${destination.latitude},${destination.longitude}',
        'mode': 'driving',
        'key': key,
      },
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final status = data['status'] as String? ?? 'UNKNOWN';
    if (status != 'OK') {
      if (status == 'ZERO_RESULTS') return null;
      return RouteResult(
        id: 'legacy-error',
        points: const [],
        distanceText: '',
        durationText: '',
        distanceMeters: 0,
        durationSeconds: 0,
        destination: destination,
        destinationName: destinationName,
        description: '',
        steps: const [],
        travelModeLabel: travelModeLabel,
        errorMessage: _friendlyApiError(
          status,
          data['error_message'] as String?,
        ),
      );
    }

    final routes = data['routes'] as List<dynamic>?;
    if (routes == null || routes.isEmpty) return null;

    final route = routes.first as Map<String, dynamic>;
    final legs = route['legs'] as List<dynamic>?;
    if (legs == null || legs.isEmpty) return null;

    final leg = legs.first as Map<String, dynamic>;
    final distanceText = leg['distance']?['text'] as String? ?? '';
    final durationText = leg['duration']?['text'] as String? ?? '';
    final distanceMeters = (leg['distance']?['value'] as num?)?.toInt() ?? 0;
    final durationSeconds = (leg['duration']?['value'] as num?)?.toInt() ?? 0;

    final overview = route['overview_polyline']?['points'] as String?;
    if (overview == null || overview.isEmpty) return null;

    return RouteResult(
      id: 'legacy-0',
      points: decodePolyline(overview),
      distanceText: distanceText,
      durationText: durationText,
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
      destination: destination,
      destinationName: destinationName,
      description: 'Fastest driving route',
      steps: const [],
      travelModeLabel: travelModeLabel,
    );
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
    final response = await http.get(uri);
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
    final response = await http.get(uri);
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
        (location['lat'] as num).toDouble(),
        (location['lng'] as num).toDouble(),
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
    final response = await http.get(uri);
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
        (location['lat'] as num).toDouble(),
        (location['lng'] as num).toDouble(),
      ),
    );
  }

  Future<RouteOptionsResult> getMotorbikeRouteOptions({
    required LatLng origin,
    required LatLng destination,
    required String destinationName,
    bool trafficAware = false,
    bool alternatives = true,
  }) async {
    final motorOptions = await _fetchRouteOptions(
      origin: origin,
      destination: destination,
      destinationName: destinationName,
      travelMode: 'TWO_WHEELER',
      travelModeLabel: 'motorbike',
      alternatives: alternatives,
      trafficAware: trafficAware,
    );
    if (motorOptions.routes.isNotEmpty) return motorOptions;
    if (motorOptions.errorMessage != null) return motorOptions;

    final driveOptions = await _fetchRouteOptions(
      origin: origin,
      destination: destination,
      destinationName: destinationName,
      travelMode: 'DRIVE',
      travelModeLabel: 'driving',
      alternatives: alternatives,
      trafficAware: trafficAware,
    );
    if (driveOptions.routes.isNotEmpty) return driveOptions;
    if (driveOptions.errorMessage != null) return driveOptions;

    final legacy = await _fetchLegacyDirections(
      origin: origin,
      destination: destination,
      destinationName: destinationName,
      travelModeLabel: 'driving',
    );
    if (legacy != null &&
        legacy.errorMessage == null &&
        legacy.points.isNotEmpty) {
      return RouteOptionsResult(routes: [legacy]);
    }

    return RouteOptionsResult(
      routes: const [],
      errorMessage: legacy?.errorMessage ??
          'No route found. Enable Routes API in Google Cloud Console.',
    );
  }

  /// Current traffic-aware ETA from [origin] to [destination]. Used while
  /// navigating to refresh arrival time the way Google Maps does.
  Future<TrafficEtaResult?> fetchTrafficAwareEta({
    required LatLng origin,
    required LatLng destination,
  }) async {
    for (final mode in ['TWO_WHEELER', 'DRIVE']) {
      final result = await _fetchTrafficEtaLeg(
        origin: origin,
        destination: destination,
        travelMode: mode,
      );
      if (result != null) return result;
    }
    return null;
  }

  Future<TrafficEtaResult?> _fetchTrafficEtaLeg({
    required LatLng origin,
    required LatLng destination,
    required String travelMode,
  }) async {
    final key = await _getApiKey();
    if (key == null) return null;

    final uri =
        Uri.https('routes.googleapis.com', '/directions/v2:computeRoutes');
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': key,
        'X-Goog-FieldMask': _etaFieldMask,
      },
      body: jsonEncode({
        'origin': _routesLocation(origin),
        'destination': _routesLocation(destination),
        'travelMode': travelMode,
        'routingPreference': 'TRAFFIC_AWARE_OPTIMAL',
        'computeAlternativeRoutes': false,
        'languageCode': 'en-IN',
      }),
    );

    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final routes = data['routes'] as List<dynamic>? ?? [];
    if (routes.isEmpty) return null;

    final route = routes.first as Map<String, dynamic>;
    final distanceMeters = (route['distanceMeters'] as num?)?.toInt() ?? 0;
    final durationSeconds = _parseRoutesDuration(route['duration'] as String?);
    if (distanceMeters <= 0 || durationSeconds <= 0) return null;

    final staticDuration =
        _parseRoutesDuration(route['staticDuration'] as String?);

    return TrafficEtaResult(
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
      staticDurationSeconds: staticDuration > 0 ? staticDuration : null,
    );
  }
}
