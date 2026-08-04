import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Shortest distance from [current] to any segment of [routePoints], in meters.
double distanceToRouteMeters(LatLng current, List<LatLng> routePoints) {
  return _nearestRouteProjection(current, routePoints, 0).distanceMeters;
}

bool isOffRoute(
  LatLng current,
  List<LatLng> routePoints, {
  double thresholdMeters = 100,
  int fromSegmentIndex = 0,
}) {
  return _nearestRouteProjection(current, routePoints, fromSegmentIndex)
          .distanceMeters >
      thresholdMeters;
}

/// Projects [current] onto the nearest route segment (searching forward from
/// [fromSegmentIndex]) and returns snap metadata for marker placement and
/// traveled/remaining polyline splitting.
({
  LatLng snapped,
  double distanceMeters,
  int segmentIndex,
  double segmentT,
  double remainingMeters,
}) trackPositionOnRoute(
  LatLng current,
  List<LatLng> routePoints,
  int fromSegmentIndex,
) {
  if (routePoints.length < 2) {
    return (
      snapped: current,
      distanceMeters: double.infinity,
      segmentIndex: 0,
      segmentT: 0,
      remainingMeters: 0,
    );
  }

  final projection =
      _nearestRouteProjection(current, routePoints, fromSegmentIndex);
  var segIndex = projection.segmentIndex;
  var segT = projection.segmentT;

  if (segT >= 0.92 && segIndex < routePoints.length - 2) {
    segIndex += 1;
    segT = 0;
  }

  final start = routePoints[segIndex];
  final end = routePoints[segIndex + 1];
  final segmentMeters = Geolocator.distanceBetween(
    start.latitude,
    start.longitude,
    end.latitude,
    end.longitude,
  );

  var remaining = segmentMeters * (1 - segT);
  for (var j = segIndex + 1; j < routePoints.length - 1; j++) {
    remaining += Geolocator.distanceBetween(
      routePoints[j].latitude,
      routePoints[j].longitude,
      routePoints[j + 1].latitude,
      routePoints[j + 1].longitude,
    );
  }

  return (
    snapped: projection.snapped,
    distanceMeters: projection.distanceMeters,
    segmentIndex: segIndex,
    segmentT: segT,
    remainingMeters: remaining.clamp(0, double.infinity),
  );
}

({
  LatLng snapped,
  double distanceMeters,
  int segmentIndex,
  double segmentT,
}) _nearestRouteProjection(
  LatLng current,
  List<LatLng> routePoints,
  int fromSegmentIndex,
) {
  if (routePoints.isEmpty) {
    return (
      snapped: current,
      distanceMeters: double.infinity,
      segmentIndex: 0,
      segmentT: 0,
    );
  }
  if (routePoints.length == 1) {
    final dist = Geolocator.distanceBetween(
      current.latitude,
      current.longitude,
      routePoints.first.latitude,
      routePoints.first.longitude,
    );
    return (
      snapped: routePoints.first,
      distanceMeters: dist,
      segmentIndex: 0,
      segmentT: 0,
    );
  }

  var bestDist = double.infinity;
  var bestSnapped = current;
  var bestSeg = fromSegmentIndex.clamp(0, routePoints.length - 2);
  var bestT = 0.0;

  final searchFrom = math.max(0, fromSegmentIndex.clamp(0, routePoints.length - 2) - 1);
  for (var i = searchFrom; i < routePoints.length - 1; i++) {
    final start = routePoints[i];
    final end = routePoints[i + 1];
    final t = _projectOntoSegment(current, start, end);
    final projLat = start.latitude + t * (end.latitude - start.latitude);
    final projLng = start.longitude + t * (end.longitude - start.longitude);
    final snapped = LatLng(projLat, projLng);
    final dist = Geolocator.distanceBetween(
      current.latitude,
      current.longitude,
      projLat,
      projLng,
    );
    if (dist < bestDist) {
      bestDist = dist;
      bestSnapped = snapped;
      bestSeg = i;
      bestT = t;
    }
  }

  return (
    snapped: bestSnapped,
    distanceMeters: bestDist,
    segmentIndex: bestSeg,
    segmentT: bestT,
  );
}

/// Remaining distance along [routePoints] from [current], advancing from
/// [fromSegmentIndex] monotonically so parallel road geometry cannot snap
/// the estimate to the destination end at navigation start.
({double remainingMeters, int segmentIndex}) remainingMetersOnRouteTracked(
  LatLng current,
  List<LatLng> routePoints,
  int fromSegmentIndex,
) {
  final tracked = trackPositionOnRoute(current, routePoints, fromSegmentIndex);
  return (
    remainingMeters: tracked.remainingMeters,
    segmentIndex: tracked.segmentIndex,
  );
}

/// Meters remaining along [routePoints] from [current] to the destination.
double remainingMetersOnRoute(LatLng current, List<LatLng> routePoints) {
  if (routePoints.length < 2) return 0;

  var bestRemaining = double.infinity;

  for (var i = 0; i < routePoints.length - 1; i++) {
    final start = routePoints[i];
    final end = routePoints[i + 1];
    final segmentMeters = Geolocator.distanceBetween(
      start.latitude,
      start.longitude,
      end.latitude,
      end.longitude,
    );

    final t = _projectOntoSegment(current, start, end);
    var remaining = segmentMeters * (1 - t);

    for (var j = i + 1; j < routePoints.length - 1; j++) {
      remaining += Geolocator.distanceBetween(
        routePoints[j].latitude,
        routePoints[j].longitude,
        routePoints[j + 1].latitude,
        routePoints[j + 1].longitude,
      );
    }

    if (remaining < bestRemaining) {
      bestRemaining = remaining;
    }
  }

  if (bestRemaining.isInfinite) {
    return Geolocator.distanceBetween(
      current.latitude,
      current.longitude,
      routePoints.last.latitude,
      routePoints.last.longitude,
    );
  }

  return bestRemaining.clamp(0, double.infinity);
}

double _projectOntoSegment(LatLng point, LatLng start, LatLng end) {
  final dx = end.longitude - start.longitude;
  final dy = end.latitude - start.latitude;
  if (dx == 0 && dy == 0) return 0;

  final px = point.longitude - start.longitude;
  final py = point.latitude - start.latitude;
  final t = ((px * dx) + (py * dy)) / ((dx * dx) + (dy * dy));
  return t.clamp(0.0, 1.0);
}

String formatDistanceLeft(double meters) {
  if (meters >= 1000) {
    return '${(meters / 1000).toStringAsFixed(1)} km left';
  }
  return '${meters.round()} m left';
}

String formatDurationLeft(int seconds) {
  if (seconds < 60) return '< 1 min left';
  if (seconds < 3600) return '${(seconds / 60).round()} min left';
  final hours = seconds ~/ 3600;
  final mins = ((seconds % 3600) / 60).round();
  if (mins == 0) return '$hours hr left';
  return '$hours hr $mins min left';
}

/// Clock time when navigation is expected to finish (e.g. "3:42 PM").
String formatArrivalTime(int remainingSeconds) {
  final arrival = DateTime.now().add(Duration(seconds: remainingSeconds));
  final hour = arrival.hour > 12
      ? arrival.hour - 12
      : (arrival.hour == 0 ? 12 : arrival.hour);
  final minute = arrival.minute.toString().padLeft(2, '0');
  final period = arrival.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $period';
}

/// Builds traveled + remaining polylines split at the snapped position.
({List<LatLng> traveled, List<LatLng> remaining}) splitRouteAtProgress(
  List<LatLng> routePoints,
  int segmentIndex,
  LatLng snapped,
) {
  if (routePoints.length < 2) {
    return (traveled: const [], remaining: routePoints);
  }

  final seg = segmentIndex.clamp(0, routePoints.length - 2);
  final traveled = <LatLng>[
    for (var i = 0; i <= seg; i++) routePoints[i],
    snapped,
  ];
  final remaining = <LatLng>[
    snapped,
    for (var i = seg + 1; i < routePoints.length; i++) routePoints[i],
  ];
  return (traveled: traveled, remaining: remaining);
}
