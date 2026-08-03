import 'package:flutter/material.dart';

import '../../models/telemetry.dart';
import '../../theme/dashboard_theme.dart';

enum NavTripView { trip1, trip2, odometer }

/// Right-side speed, gear, and trip readout for the navigation dashboard.
class NavDriveReadout extends StatefulWidget {
  const NavDriveReadout({super.key, required this.telemetry});

  final Telemetry telemetry;

  @override
  State<NavDriveReadout> createState() => _NavDriveReadoutState();
}

class _NavDriveReadoutState extends State<NavDriveReadout> {
  NavTripView _tripView = NavTripView.trip1;

  void _cycleTripView(int direction) {
    setState(() {
      final values = NavTripView.values;
      var idx = values.indexOf(_tripView) + direction;
      if (idx >= values.length) idx = 0;
      if (idx < 0) idx = values.length - 1;
      _tripView = values[idx];
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.telemetry;
    final speed = t.displaySpeed.clamp(0, 299).round();
    final gear = t.gear.toUpperCase();
    final isNeutral = gear == 'N';

    return ColoredBox(
      color: DashboardTheme.screen,
      child: Column(
        children: [
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'SPEED',
                      style: TextStyle(
                        color: DashboardTheme.muted.withValues(alpha: 0.75),
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        _HeavyNavText(
                          text: '$speed',
                          strokeWidth: 1.8,
                          style: const TextStyle(
                            color: Color(0xFFF7F4EA),
                            fontSize: 108,
                            fontWeight: FontWeight.w900,
                            fontStyle: FontStyle.italic,
                            height: 0.78,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'km/h',
                          style: TextStyle(
                            color: DashboardTheme.text.withValues(alpha: 0.62),
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: _HeavyNavText(
                text: gear,
                strokeWidth: 1.5,
                style: TextStyle(
                  color: isNeutral
                      ? const Color(0xFF47E878)
                      : DashboardTheme.text.withValues(alpha: 0.88),
                  fontSize: 80,
                  fontWeight: FontWeight.w900,
                  height: 0.9,
                  shadows: isNeutral
                      ? const [
                          Shadow(
                            color: Color(0x6B47E878),
                            blurRadius: 18,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: GestureDetector(
              onHorizontalDragEnd: (d) {
                if (d.primaryVelocity == null) return;
                if (d.primaryVelocity!.abs() > 150) {
                  _cycleTripView(d.primaryVelocity! > 0 ? 1 : -1);
                }
              },
              child: _TripReadout(view: _tripView, telemetry: t),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeavyNavText extends StatelessWidget {
  const _HeavyNavText({
    required this.text,
    required this.style,
    required this.strokeWidth,
  });

  final String text;
  final TextStyle style;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final color = style.color ?? DashboardTheme.text;
    return Stack(
      alignment: Alignment.center,
      children: [
        Text(
          text,
          style: style.copyWith(
            color: null,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..strokeJoin = StrokeJoin.round
              ..color = color,
          ),
        ),
        Text(text, style: style),
      ],
    );
  }
}

class _TripReadout extends StatelessWidget {
  const _TripReadout({required this.view, required this.telemetry});

  final NavTripView view;
  final Telemetry telemetry;

  @override
  Widget build(BuildContext context) {
    late String label;
    late String value;
    late String unit;

    switch (view) {
      case NavTripView.trip1:
        label = 'TRIP 1';
        value = telemetry.trip1DistanceKm.toStringAsFixed(1);
        unit = 'km';
      case NavTripView.trip2:
        label = 'TRIP 2';
        value = telemetry.trip2DistanceKm.toStringAsFixed(1);
        unit = 'km';
      case NavTripView.odometer:
        label = 'ODO';
        if (telemetry.odometerKm != null) {
          value = telemetry.odometerKm!.toStringAsFixed(1);
          unit = 'km';
        } else {
          value = '--';
          unit = 'km';
        }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: DashboardTheme.muted.withValues(alpha: 0.9),
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.1,
              ),
            ),
            const Spacer(),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    color: Color(0xFFF7F4EA),
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic,
                    height: 1,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  ' $unit',
                  style: TextStyle(
                    color: DashboardTheme.muted.withValues(alpha: 0.55),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
