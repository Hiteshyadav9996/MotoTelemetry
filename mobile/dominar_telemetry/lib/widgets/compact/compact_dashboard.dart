import 'package:flutter/material.dart';

import '../../models/telemetry.dart';
import '../../theme/dashboard_theme.dart';
import 'rpm_vertical_bar.dart';

enum CompactTripView { trip1, trip2, odometer }

/// Compact left-half dashboard for the navigation split view.
class CompactDashboard extends StatefulWidget {
  const CompactDashboard({super.key, required this.telemetry});

  final Telemetry telemetry;

  @override
  State<CompactDashboard> createState() => _CompactDashboardState();
}

class _CompactDashboardState extends State<CompactDashboard> {
  CompactTripView _tripView = CompactTripView.trip1;

  void _cycleTripView(int direction) {
    setState(() {
      final values = CompactTripView.values;
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

    return LayoutBuilder(
      builder: (context, constraints) => FittedBox(
        fit: BoxFit.fill,
        child: Container(
          width: 448,
          height: 414,
          decoration: DashboardTheme.screenBackground,
          child: Row(
            children: [
              // Roughly 30% of the left panel. Stroke widths and motion match
              // the full dashboard RPM band; only the path is straight.
              SizedBox(
                width: 134,
                child: RpmVerticalBar(
                  rpm: t.rpm,
                  engineTemp: t.engineTempC ?? 90,
                ),
              ),
              Expanded(
                child: Column(
                  children: [
                    // 50% — speed is the dominant readout.
                    Expanded(
                      flex: 5,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                _HeavyCompactText(
                                  text: '$speed',
                                  strokeWidth: 1.8,
                                  style: const TextStyle(
                                    color: Color(0xFFF7F4EA),
                                    fontSize: 112,
                                    fontWeight: FontWeight.w900,
                                    fontStyle: FontStyle.italic,
                                    height: 0.78,
                                    fontFeatures: [
                                      FontFeature.tabularFigures()
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  'km/h',
                                  style: TextStyle(
                                    color: DashboardTheme.text
                                        .withValues(alpha: 0.74),
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    // 30% — large plain gear, matching the full dashboard.
                    Expanded(
                      flex: 3,
                      child: Center(
                        child: _HeavyCompactText(
                          text: gear,
                          strokeWidth: 1.5,
                          style: TextStyle(
                            color: isNeutral
                                ? const Color(0xFF47E878)
                                : DashboardTheme.text.withValues(alpha: 0.86),
                            fontSize: 84,
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

                    // 20% — swipe Trip 1 → Trip 2 → Odometer.
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeavyCompactText extends StatelessWidget {
  const _HeavyCompactText({
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

  final CompactTripView view;
  final Telemetry telemetry;

  @override
  Widget build(BuildContext context) {
    late String label;
    late String value;

    switch (view) {
      case CompactTripView.trip1:
        label = 'TRIP 1';
        value = '${telemetry.trip1DistanceKm.toStringAsFixed(1)} km';
      case CompactTripView.trip2:
        label = 'TRIP 2';
        value = '${telemetry.trip2DistanceKm.toStringAsFixed(1)} km';
      case CompactTripView.odometer:
        label = 'ODO';
        value = telemetry.odometerKm != null
            ? '${telemetry.odometerKm!.toStringAsFixed(1)} km'
            : '-- km';
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        border: Border.all(color: Colors.white.withValues(alpha: 0.13)),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
          ),
        ],
      ),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              color: DashboardTheme.muted.withValues(alpha: 0.98),
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Color(0xFFF7F4EA),
                fontSize: 24,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                fontFeatures: [FontFeature.tabularFigures()],
                shadows: [
                  Shadow(color: Color(0x2EFFFFFF), blurRadius: 12),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
