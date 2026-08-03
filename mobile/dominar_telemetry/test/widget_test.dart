import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dominar_telemetry/models/telemetry.dart';
import 'package:dominar_telemetry/widgets/compact/compact_dashboard.dart';
import 'package:dominar_telemetry/widgets/full/full_dashboard.dart';
import 'package:dominar_telemetry/widgets/full/rpm_arc_gauge.dart';
import 'package:dominar_telemetry/widgets/nav/nav_dashboard_view.dart';
import 'package:dominar_telemetry/widgets/compact/rpm_vertical_bar.dart';
import 'package:dominar_telemetry/widgets/navigation/map_navigation_panel.dart';

void main() {
  test('Telemetry parses ESP32 JSON', () {
    final t = Telemetry.fromJson({
      'seq': 1,
      'rpm': 3500.0,
      'speed_kph': 62.0,
      'gear': '4',
      'odometer_km': 53988.5,
      'trip_count': 2,
      'trip1_distance_km': 12.3,
    });

    expect(t.rpm, 3500.0);
    expect(t.speedKph, 62.0);
    expect(t.gear, '4');
    expect(t.odometerKm, 53988.5);
    expect(t.trip1DistanceKm, 12.3);
  });

  testWidgets('cold-engine RPM limit animation renders', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 896,
          height: 414,
          child: RpmArcGauge(rpm: 6000, engineTemp: 70),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 72));
    await tester.pump(const Duration(milliseconds: 72));
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact 448x414 dashboard renders without overflow',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 448,
          height: 414,
          child: CompactDashboard(
            telemetry: Telemetry(
              rpm: 6500,
              speedKph: 128,
              gear: '5',
              engineTempC: 80,
              trip1DistanceKm: 123.4,
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('RPM vertical bar renders at 3500 RPM without overflow',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 168,
          height: 414,
          child: RpmVerticalBar(rpm: 3500, engineTemp: 90),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(RpmVerticalBar), findsOneWidget);
  });

  testWidgets('RPM vertical bar renders at 1200 RPM without overflow',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 168,
          height: 414,
          child: RpmVerticalBar(rpm: 1200, engineTemp: 90),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('RPM vertical bar renders at 2800 RPM without overflow',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 168,
          height: 414,
          child: RpmVerticalBar(rpm: 2800, engineTemp: 90),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('RPM vertical bar renders at large text scale without overflow',
      (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: MaterialApp(
          home: SizedBox(
            width: 168,
            height: 414,
            child: RpmVerticalBar(rpm: 3500, engineTemp: 90),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('nav dashboard 896x414 renders without overflow', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 896,
          height: 414,
          child: NavDashboardView(
            telemetry: Telemetry(
              rpm: 3500,
              speedKph: 168,
              gear: '4',
              engineTempC: 80,
              trip1DistanceKm: 24.5,
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('SPEED'), findsOneWidget);
    expect(find.text('168'), findsWidgets);
    expect(find.text('4'), findsWidgets);
  });

  testWidgets('full-width route banner fits varied distance and time values',
      (tester) async {
    const values = [
      ('0 m left', '< 1 min left'),
      ('999 m left', '59 min left'),
      ('999.9 km left', '23 hr 59 min left'),
      ('Arrived', ''),
    ];

    for (final (distance, duration) in values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 380,
              height: 54,
              child: RouteProgressBar(
                progress: 0.57,
                distanceLabel: distance,
                durationLabel: duration,
                arrivalTimeLabel: '3:42 PM',
                onExit: () {},
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text(distance), findsOneWidget);
      if (duration.isNotEmpty) {
        expect(find.text(duration), findsOneWidget);
      }
    }
  });

  testWidgets('half-width route banner fits varied distance and time values',
      (tester) async {
    const values = [
      ('0 m left', '< 1 min left'),
      ('999 m left', '59 min left'),
      ('999.9 km left', '23 hr 59 min left'),
      ('Arrived', ''),
    ];

    for (final (distance, duration) in values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 180,
              height: 54,
              child: RouteProgressBar(
                progress: 0.57,
                distanceLabel: distance,
                durationLabel: duration,
                arrivalTimeLabel: '3:42 PM',
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text(distance), findsOneWidget);
      if (duration.isNotEmpty) {
        expect(find.text(duration), findsOneWidget);
      }
    }
  });

  testWidgets('large trip reset alerts fit success and failure messages',
      (tester) async {
    for (final success in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ResetAlertOverlay(slot: 2, success: success),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(
        find.text(success ? 'TRIP 2\nRESET DONE' : 'TRIP 2\nRESET FAILED'),
        findsOneWidget,
      );
    }
  });
}
