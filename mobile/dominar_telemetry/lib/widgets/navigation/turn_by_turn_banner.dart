import 'package:flutter/material.dart';

import '../../models/navigation_route.dart';
import '../../theme/dashboard_theme.dart';
import '../../utils/navigation_maneuvers.dart';

class TurnByTurnBanner extends StatelessWidget {
  const TurnByTurnBanner({
    super.key,
    required this.step,
    required this.distanceMeters,
    required this.onStop,
  });

  final NavigationStep step;
  final int distanceMeters;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      color: DashboardTheme.screen2.withValues(alpha: 0.96),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 112),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(
                maneuverIcon(step.maneuver),
                color: DashboardTheme.gearRing,
                size: 48,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatMetersAhead(distanceMeters),
                      style: const TextStyle(
                        color: DashboardTheme.rpmMid,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      step.instruction,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: DashboardTheme.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onStop,
                icon: const Icon(Icons.close, size: 28),
                color: DashboardTheme.muted,
                tooltip: 'Stop navigation',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
