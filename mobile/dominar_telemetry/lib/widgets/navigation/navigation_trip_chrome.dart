import 'package:flutter/material.dart';

import '../../models/navigation_trip_snapshot.dart';
import '../../theme/dashboard_theme.dart';
import '../../utils/navigation_format.dart';

/// Compact trip bar using Navigation SDK data (ETA, distance, next turn).
/// Needed because native header/footer are often clipped in the narrow map column.
class NavigationTripChrome extends StatelessWidget {
  const NavigationTripChrome({
    super.key,
    required this.trip,
    required this.routeReady,
    required this.navigating,
    required this.onStart,
    required this.onExit,
  });

  final NavigationTripSnapshot trip;
  final bool routeReady;
  final bool navigating;
  final VoidCallback onStart;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (trip.hasTurnBanner)
          Positioned(
            top: 6,
            left: 6,
            right: 6,
            child: _TurnBanner(trip: trip),
          ),
        Positioned(
          left: 6,
          right: 6,
          bottom: 6,
          child: _TripFooter(
            trip: trip,
            routeReady: routeReady,
            navigating: navigating,
            onStart: onStart,
            onExit: onExit,
          ),
        ),
      ],
    );
  }
}

class _TurnBanner extends StatelessWidget {
  const _TurnBanner({required this.trip});

  final NavigationTripSnapshot trip;

  @override
  Widget build(BuildContext context) {
    final distance = formatNavDistance(trip.distanceToTurnMeters!);
    final road = trip.turnRoad?.trim();
    final instruction = trip.turnInstruction?.trim();
    final detail = (instruction?.isNotEmpty == true)
        ? instruction!
        : (road?.isNotEmpty == true ? road! : 'Next turn');

    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(10),
      color: const Color(0xFF1B5E20).withValues(alpha: 0.94),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Text(
              distance,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TripFooter extends StatelessWidget {
  const _TripFooter({
    required this.trip,
    required this.routeReady,
    required this.navigating,
    required this.onStart,
    required this.onExit,
  });

  final NavigationTripSnapshot trip;
  final bool routeReady;
  final bool navigating;
  final VoidCallback onStart;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final timeSeconds = trip.remainingTimeSeconds;
    final distanceMeters = trip.remainingDistanceMeters;
    final hasSummary = trip.hasTripSummary;

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: DashboardTheme.screen2.withValues(alpha: 0.96),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: hasSummary
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          formatNavDuration(timeSeconds!),
                          style: const TextStyle(
                            color: DashboardTheme.text,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${formatNavDistance(distanceMeters!)} · '
                          'Arrive ${formatNavArrivalTime(timeSeconds)}',
                          style: TextStyle(
                            color: DashboardTheme.muted.withValues(alpha: 0.95),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    )
                  : Text(
                      'Calculating route…',
                      style: TextStyle(
                        color: DashboardTheme.muted.withValues(alpha: 0.95),
                        fontSize: 13,
                      ),
                    ),
            ),
            if (routeReady && !navigating)
              FilledButton(
                onPressed: onStart,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1B5E20),
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                child: const Text('Start'),
              ),
            if (navigating)
              TextButton(
                onPressed: onExit,
                style: TextButton.styleFrom(
                  foregroundColor: DashboardTheme.rpmHot,
                ),
                child: const Text('Exit'),
              ),
          ],
        ),
      ),
    );
  }
}
