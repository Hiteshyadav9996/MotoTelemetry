import 'package:flutter/material.dart';

import '../../models/navigation_route.dart';
import '../../theme/dashboard_theme.dart';
import '../../utils/navigation_maneuvers.dart';

/// Compact top banner for nav-dashboard: immediate turn + optional following turn.
class CompactTurnBanner extends StatelessWidget {
  const CompactTurnBanner({
    super.key,
    required this.step,
    required this.distanceMeters,
    this.thenLabel,
  });

  final NavigationStep step;
  final int distanceMeters;
  final String? thenLabel;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(10),
      color: DashboardTheme.screen2.withValues(alpha: 0.94),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  maneuverIcon(step.maneuver),
                  color: DashboardTheme.gearRing,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${formatMetersAhead(distanceMeters)} · ${step.instruction}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: DashboardTheme.text,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
            if (thenLabel != null) ...[
              const SizedBox(height: 3),
              Text(
                thenLabel!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: DashboardTheme.muted.withValues(alpha: 0.95),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
