import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/navigation_route.dart';

IconData maneuverIcon(String maneuver) {
  switch (maneuver) {
    case 'TURN_LEFT':
    case 'TURN_SLIGHT_LEFT':
      return Icons.turn_left;
    case 'TURN_RIGHT':
    case 'TURN_SLIGHT_RIGHT':
      return Icons.turn_right;
    case 'TURN_SHARP_LEFT':
      return Icons.turn_sharp_left;
    case 'TURN_SHARP_RIGHT':
      return Icons.turn_sharp_right;
    case 'UTURN_LEFT':
    case 'UTURN_RIGHT':
      return Icons.u_turn_left;
    case 'ROUNDABOUT_LEFT':
    case 'ROUNDABOUT_RIGHT':
      return Icons.roundabout_left;
    case 'MERGE':
    case 'FORK_LEFT':
    case 'FORK_RIGHT':
      return Icons.merge;
    case 'ARRIVE':
    case 'DESTINATION':
      return Icons.flag;
    case 'STRAIGHT':
    default:
      return Icons.straight;
  }
}

String formatMetersAhead(int meters) {
  if (meters >= 1000) {
    return 'In ${(meters / 1000).toStringAsFixed(1)} km';
  }
  if (meters < 50) return 'Now';
  return 'In $meters m';
}

int activeStepIndex(List<NavigationStep> steps, LatLng current) {
  if (steps.isEmpty) return 0;

  var index = 0;
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final dist = Geolocator.distanceBetween(
      current.latitude,
      current.longitude,
      step.end.latitude,
      step.end.longitude,
    );
    if (dist < 45 && i < steps.length - 1) {
      index = i + 1;
      continue;
    }
    index = i;
    break;
  }
  return index.clamp(0, steps.length - 1);
}

int distanceToStepEnd(NavigationStep step, LatLng current) {
  return Geolocator.distanceBetween(
    current.latitude,
    current.longitude,
    step.end.latitude,
    step.end.longitude,
  ).round();
}

/// Remaining trip distance using turn-by-turn steps (more reliable than polyline).
double remainingMetersOnSteps(
  List<NavigationStep> steps,
  int stepIndex,
  LatLng current,
) {
  if (steps.isEmpty) return 0;
  final idx = stepIndex.clamp(0, steps.length - 1);
  var remaining = distanceToStepEnd(steps[idx], current).toDouble();
  for (var i = idx + 1; i < steps.length; i++) {
    remaining += steps[i].distanceMeters;
  }
  return remaining;
}

/// First step worth showing (skip DEPART).
int firstManeuverStepIndex(List<NavigationStep> steps) {
  for (var i = 0; i < steps.length; i++) {
    if (steps[i].maneuver != 'DEPART') return i;
  }
  return 0;
}

/// Distance and step for the maneuver after the immediate upcoming turn.
({NavigationStep step, int distanceMeters})? nextTurnAfterCurrent(
  List<NavigationStep> steps,
  int currentIndex,
  LatLng current,
) {
  if (steps.isEmpty || currentIndex >= steps.length - 1) return null;

  var distance = distanceToStepEnd(steps[currentIndex], current).toDouble();
  NavigationStep? candidate;

  for (var i = currentIndex + 1; i < steps.length; i++) {
    final step = steps[i];
    if (step.maneuver == 'DEPART') {
      distance += step.distanceMeters;
      continue;
    }
    candidate = step;
    break;
  }

  if (candidate == null) return null;
  return (step: candidate, distanceMeters: distance.round());
}

bool hasArrivedAtDestination({
  required LatLng current,
  required LatLng destination,
  required List<NavigationStep> steps,
  required int stepIndex,
}) {
  final toDest = Geolocator.distanceBetween(
    current.latitude,
    current.longitude,
    destination.latitude,
    destination.longitude,
  );
  if (toDest <= 45) return true;
  if (steps.isEmpty) return toDest <= 45;
  final onLastStep = stepIndex >= steps.length - 1;
  final nearLastStep = onLastStep &&
      distanceToStepEnd(steps[stepIndex], current) <= 35;
  return nearLastStep && toDest <= 120;
}
