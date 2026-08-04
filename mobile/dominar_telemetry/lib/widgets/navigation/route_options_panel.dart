import 'package:flutter/material.dart';

import '../../models/navigation_route.dart';
import '../../theme/dashboard_theme.dart';

class RouteOptionsPanel extends StatelessWidget {
  const RouteOptionsPanel({
    super.key,
    required this.routes,
    required this.selectedIndex,
    required this.onSelect,
    required this.onStart,
  });

  final List<RouteResult> routes;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      color: DashboardTheme.screen2.withValues(alpha: 0.97),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${routes.length} motorbike routes',
              style: const TextStyle(
                color: DashboardTheme.muted,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 62,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: routes.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final route = routes[index];
                  final selected = index == selectedIndex;
                  return GestureDetector(
                    onTap: () => onSelect(index),
                    child: Container(
                      width: 168,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: selected
                            ? DashboardTheme.gearRing.withValues(alpha: 0.15)
                            : Colors.black.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: selected
                              ? DashboardTheme.gearRing
                              : Colors.white.withValues(alpha: 0.12),
                          width: selected ? 1.5 : 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Route ${index + 1}',
                            style: TextStyle(
                              color: selected
                                  ? DashboardTheme.gearRing
                                  : DashboardTheme.text,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${route.distanceText} · ${route.durationText}',
                            style: const TextStyle(
                              color: DashboardTheme.text,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            route.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: DashboardTheme.muted.withValues(alpha: 0.9),
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ElevatedButton.icon(
                onPressed: onStart,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF35E36C),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.navigation, size: 18),
                label: const Text(
                  'Start turn-by-turn navigation',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
