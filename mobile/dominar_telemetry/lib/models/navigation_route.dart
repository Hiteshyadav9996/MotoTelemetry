import 'package:google_maps_flutter/google_maps_flutter.dart';

class NavigationStep {
  const NavigationStep({
    required this.instruction,
    required this.maneuver,
    required this.distanceMeters,
    required this.end,
  });

  final String instruction;
  final String maneuver;
  final int distanceMeters;
  final LatLng end;
}

class RouteResult {
  const RouteResult({
    required this.id,
    required this.points,
    required this.distanceText,
    required this.durationText,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.destination,
    required this.destinationName,
    required this.description,
    required this.steps,
    this.errorMessage,
    this.travelModeLabel = 'motorbike',
  });

  final String id;
  final List<LatLng> points;
  final String distanceText;
  final String durationText;
  final int distanceMeters;
  final int durationSeconds;
  final LatLng destination;
  final String destinationName;
  final String description;
  final List<NavigationStep> steps;
  final String? errorMessage;
  final String travelModeLabel;

  NavigationStep? get currentManeuverStep {
    for (final step in steps) {
      if (step.maneuver != 'DEPART') return step;
    }
    return steps.isNotEmpty ? steps.first : null;
  }
}

class RouteOptionsResult {
  const RouteOptionsResult({
    required this.routes,
    this.errorMessage,
  });

  final List<RouteResult> routes;
  final String? errorMessage;
}

/// Live ETA from Google Routes with current traffic conditions.
class TrafficEtaResult {
  const TrafficEtaResult({
    required this.distanceMeters,
    required this.durationSeconds,
    this.staticDurationSeconds,
  });

  final int distanceMeters;
  final int durationSeconds;
  final int? staticDurationSeconds;
}
