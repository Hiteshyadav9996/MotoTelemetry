import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../models/telemetry.dart';
import '../../theme/dashboard_theme.dart';
import 'rpm_arc_gauge.dart';

/// Full landscape dashboard — port of firmware/data/index.html.
class FullDashboard extends StatefulWidget {
  const FullDashboard({
    super.key,
    required this.telemetry,
    this.onTripReset,
  });

  final Telemetry telemetry;
  final Future<bool> Function(int slot)? onTripReset;

  @override
  State<FullDashboard> createState() => _FullDashboardState();
}

class _FullDashboardState extends State<FullDashboard> {
  int _tripIndex = 1;
  int? _resetToastSlot;

  @override
  Widget build(BuildContext context) {
    final t = widget.telemetry;
    final engineTemp = t.engineTempC ?? 90;
    final safeRight = MediaQuery.paddingOf(context).right;
    final rpmLabelRight = math.max(42.0, safeRight + 22);
    final readoutRight = math.max(22.0, safeRight + 14);

    return LayoutBuilder(
      builder: (context, constraints) {
        final fillsPhone = constraints.maxWidth <= 920;
        return CustomPaint(
          painter: const _OuterBackgroundPainter(),
          child: Center(
            child: FittedBox(
              fit: BoxFit.contain,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(fillsPhone ? 0 : 28),
                child: Container(
                  width: 896,
                  height: 414,
                  decoration: BoxDecoration(
                    border: fillsPhone
                        ? null
                        : Border.all(
                            color: Colors.white.withValues(alpha: 0.14),
                          ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const CustomPaint(painter: _FrameBackgroundPainter()),
                      // RPM arc
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: RpmArcGauge(
                            rpm: t.rpm,
                            engineTemp: engineTemp,
                          ),
                        ),
                      ),

                      // RPM label
                      Positioned(
                        right: rpmLabelRight,
                        top: 138,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              'RPM',
                              style: const TextStyle(
                                color: Color(0xD1F5F3EA),
                                fontSize: 13,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.2,
                              ),
                            ),
                            Text(
                              'x1000',
                              style: const TextStyle(
                                color: DashboardTheme.rpmMid,
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Throttle gauge
                      Positioned(
                        left: 178,
                        bottom: 34,
                        child: _ThrottleGauge(throttle: t.throttlePct),
                      ),

                      // Aux metrics
                      Positioned(
                        left: 240,
                        bottom: 34,
                        child: _AuxMetrics(
                          mapKpa: t.mapKpa,
                          iatC: t.iatC,
                          batteryV: t.batteryV,
                        ),
                      ),

                      // Trip card
                      Positioned(
                        left: 382,
                        bottom: 34,
                        child: _TripCard(
                          tripIndex: _tripIndex,
                          telemetry: t,
                          onSwipe: (dir) {
                            setState(() {
                              final count = t.tripCount.clamp(1, 2);
                              _tripIndex = dir > 0
                                  ? (_tripIndex >= count ? 1 : _tripIndex + 1)
                                  : (_tripIndex <= 1 ? count : _tripIndex - 1);
                            });
                          },
                          onLongPress: () async {
                            final slot = _tripIndex;
                            final ok =
                                await widget.onTripReset?.call(slot) ?? false;
                            if (!mounted) return;
                            final alertValue = ok ? slot : -slot;
                            setState(() => _resetToastSlot = alertValue);
                            Future.delayed(const Duration(milliseconds: 2400),
                                () {
                              if (mounted && _resetToastSlot == alertValue) {
                                setState(() => _resetToastSlot = null);
                              }
                            });
                          },
                        ),
                      ),

                      // Speed + gear + temp + odometer
                      Positioned(
                        right: readoutRight,
                        top: 188,
                        child: _DriveReadout(telemetry: t),
                      ),

                      // Reset toast
                      if (_resetToastSlot != null)
                        Center(
                          child: ResetAlertOverlay(
                            slot: _resetToastSlot!.abs(),
                            success: _resetToastSlot! > 0,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class ResetAlertOverlay extends StatelessWidget {
  const ResetAlertOverlay({
    super.key,
    required this.slot,
    required this.success,
  });

  final int slot;
  final bool success;

  @override
  Widget build(BuildContext context) {
    final color = success ? const Color(0xFF35E36C) : const Color(0xFFFF302B);
    return IgnorePointer(
      child: Container(
        // 540 × 210 is approximately 30% of the 896 × 414 dashboard.
        width: 540,
        height: 210,
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
        decoration: BoxDecoration(
          color: const Color(0xFF070A0D).withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color, width: 4),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.48),
              blurRadius: 34,
              spreadRadius: 4,
            ),
            const BoxShadow(
              color: Colors.black87,
              blurRadius: 28,
              spreadRadius: 10,
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              success ? Icons.check_circle_rounded : Icons.error_rounded,
              color: color,
              size: 78,
            ),
            const SizedBox(width: 28),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  'TRIP $slot\n${success ? 'RESET DONE' : 'RESET FAILED'}',
                  style: TextStyle(
                    color: color,
                    fontSize: 42,
                    fontWeight: FontWeight.w900,
                    height: 1.02,
                    letterSpacing: 1.8,
                    shadows: [
                      Shadow(
                        color: color.withValues(alpha: 0.55),
                        blurRadius: 18,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OuterBackgroundPainter extends CustomPainter {
  const _OuterBackgroundPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = DashboardTheme.bg,
    );
    final leftCenter = Offset(size.width * 0.12, size.height * 0.18);
    final rightCenter = Offset(size.width * 0.92, size.height * 0.20);
    canvas.drawCircle(
      leftCenter,
      352,
      Paint()
        ..shader = RadialGradient(
          colors: [
            DashboardTheme.rpmMid.withValues(alpha: 0.14),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: leftCenter, radius: 352)),
    );
    canvas.drawCircle(
      rightCenter,
      384,
      Paint()
        ..shader = RadialGradient(
          colors: [
            DashboardTheme.rpmHot.withValues(alpha: 0.08),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: rightCenter, radius: 384)),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _FrameBackgroundPainter extends CustomPainter {
  const _FrameBackgroundPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            DashboardTheme.screen2,
            DashboardTheme.screen,
            DashboardTheme.bg,
          ],
          stops: [0, 0.42, 1],
        ).createShader(rect),
    );

    canvas.drawCircle(
      const Offset(108, 74),
      255,
      Paint()
        ..shader = RadialGradient(
          colors: [
            DashboardTheme.rpmMid.withValues(alpha: 0.14),
            Colors.transparent,
          ],
        ).createShader(
          Rect.fromCircle(center: const Offset(108, 74), radius: 255),
        ),
    );
    canvas.drawCircle(
      const Offset(824, 82),
      275,
      Paint()
        ..shader = RadialGradient(
          colors: [
            DashboardTheme.rpmHot.withValues(alpha: 0.08),
            Colors.transparent,
          ],
        ).createShader(
          Rect.fromCircle(center: const Offset(824, 82), radius: 275),
        ),
    );

    final sheen = Path()
      ..moveTo(478, 0)
      ..lineTo(628, 0)
      ..lineTo(522, size.height)
      ..lineTo(372, size.height)
      ..close();
    canvas.drawPath(
      sheen,
      Paint()..color = Colors.white.withValues(alpha: 0.04),
    );

    final stripePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.012)
      ..strokeWidth = 1;
    for (double x = 1; x < size.width; x += 5) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), stripePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DriveReadout extends StatelessWidget {
  const _DriveReadout({required this.telemetry});

  final Telemetry telemetry;

  @override
  Widget build(BuildContext context) {
    final speed = telemetry.displaySpeed.clamp(0, 299).round();
    final gear = telemetry.gear.toUpperCase();
    final isNeutral = gear == 'N';
    final temp = telemetry.engineTempC;
    final odo = telemetry.odometerKm;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Gear
        SizedBox(
          width: 64,
          height: 72,
          child: Align(
            alignment: Alignment.topCenter,
            child: _HeavyDisplayText(
              text: gear,
              strokeWidth: 1.4,
              style: TextStyle(
                color: isNeutral
                    ? const Color(0xFF47E878)
                    : DashboardTheme.text.withValues(alpha: 0.78),
                fontSize: 58,
                fontWeight: FontWeight.w900,
                height: 1.0,
                shadows: isNeutral
                    ? [
                        Shadow(
                          color:
                              const Color(0xFF47E878).withValues(alpha: 0.42),
                          blurRadius: 18,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
        ),
        const SizedBox(width: 18),
        // Speed column
        SizedBox(
          width: 250,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 88,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.bottomRight,
                        child: _HeavyDisplayText(
                          text: '$speed',
                          alignment: Alignment.centerRight,
                          strokeWidth: 1.8,
                          style: const TextStyle(
                            color: Color(0xFFF7F4EA),
                            fontSize: 112,
                            fontWeight: FontWeight.w900,
                            fontStyle: FontStyle.italic,
                            height: 0.78,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'km/h',
                    style: TextStyle(
                      color: DashboardTheme.text.withValues(alpha: 0.74),
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 34),
              _EngineTempGauge(tempC: temp, odometerKm: odo),
            ],
          ),
        ),
      ],
    );
  }
}

class _HeavyDisplayText extends StatelessWidget {
  const _HeavyDisplayText({
    required this.text,
    required this.style,
    required this.strokeWidth,
    this.alignment = Alignment.center,
  });

  final String text;
  final TextStyle style;
  final double strokeWidth;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final color = style.color ?? DashboardTheme.text;
    return Stack(
      alignment: alignment,
      children: [
        Text(
          text,
          textAlign: TextAlign.right,
          maxLines: 1,
          softWrap: false,
          style: style.copyWith(
            color: null,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..strokeJoin = StrokeJoin.round
              ..color = color,
          ),
        ),
        Text(
          text,
          textAlign: TextAlign.right,
          maxLines: 1,
          softWrap: false,
          style: style,
        ),
      ],
    );
  }
}

class _EngineTempGauge extends StatelessWidget {
  const _EngineTempGauge({this.tempC, this.odometerKm});

  final double? tempC;
  final double? odometerKm;

  Color _colorFor(double temp) {
    const blue = Color(0xFF28A9FF);
    const green = Color(0xFF35E36C);
    const orange = Color(0xFFFF9A1F);
    const red = Color(0xFFFF332D);
    if (temp <= 60) return blue;
    if (temp <= 90) {
      return Color.lerp(blue, green, (temp - 60) / 30)!;
    }
    if (temp <= 100) {
      return Color.lerp(green, orange, (temp - 90) / 10)!;
    }
    if (temp <= 120) {
      return Color.lerp(orange, red, (temp - 100) / 20)!;
    }
    return red;
  }

  @override
  Widget build(BuildContext context) {
    final hasTemp = tempC != null;
    final gaugeTemp = (tempC ?? 75).clamp(40.0, 140.0);
    final pct = ((gaugeTemp - 60) / 60).clamp(0.0, 1.0);
    final color = _colorFor(gaugeTemp);

    return SizedBox(
      width: 220,
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                Icons.device_thermostat,
                size: 24,
                color: Colors.white.withValues(alpha: 0.9),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 18,
                  child: Stack(
                    children: [
                      ColoredBox(
                        color: Colors.white.withValues(alpha: 0.12),
                        child: const SizedBox.expand(),
                      ),
                      FractionallySizedBox(
                        widthFactor: pct,
                        alignment: Alignment.centerLeft,
                        child: ColoredBox(
                          color: color,
                          child: const SizedBox.expand(),
                        ),
                      ),
                      for (final position in const [0.0, 0.25, 0.5, 0.75, 1.0])
                        Align(
                          alignment: Alignment(position * 2 - 1, 0),
                          child: Container(
                            width: 1,
                            height: 12,
                            color: Colors.white.withValues(alpha: 0.72),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: 34),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  hasTemp ? '${tempC!.toStringAsFixed(1)} C' : '-- C',
                  style: TextStyle(
                    color: color,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    height: 1,
                    shadows: [
                      Shadow(
                        color: color.withValues(alpha: 0.36),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 32),
                Text(
                  odometerKm != null
                      ? '${odometerKm!.toStringAsFixed(1)} km'
                      : '-- km',
                  style: const TextStyle(
                    color: Color(0xFFF7F4EA),
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    fontStyle: FontStyle.italic,
                    height: 1,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ThrottleGauge extends StatelessWidget {
  const _ThrottleGauge({required this.throttle});

  final double throttle;

  @override
  Widget build(BuildContext context) {
    final pct = throttle.clamp(0, 100);
    return SizedBox(
      width: 54,
      height: 168,
      child: Column(
        children: [
          SvgPicture.asset(
            'assets/throttle_icon.svg',
            width: 48,
            height: 28,
            colorFilter: ColorFilter.mode(
              DashboardTheme.text.withValues(alpha: 0.92),
              BlendMode.srcIn,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SizedBox(
              width: 10,
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  ColoredBox(
                    color: Colors.white.withValues(alpha: 0.18),
                    child: const SizedBox.expand(),
                  ),
                  FractionallySizedBox(
                    heightFactor: pct / 100,
                    alignment: Alignment.bottomCenter,
                    child: const ColoredBox(
                      color: DashboardTheme.throttle,
                      child: SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${pct.round()}%',
            style: TextStyle(
              color: DashboardTheme.text.withValues(alpha: 0.86),
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _AuxMetrics extends StatelessWidget {
  const _AuxMetrics({this.mapKpa, this.iatC, this.batteryV});

  final double? mapKpa;
  final double? iatC;
  final double? batteryV;

  String _fmt(double? v, int dec, String unit) {
    if (v == null) return '--';
    return dec > 0 ? '${v.toStringAsFixed(dec)} $unit' : '${v.round()} $unit';
  }

  @override
  Widget build(BuildContext context) {
    final rows = [
      ('MAP', _fmt(mapKpa, 0, 'kPa')),
      ('IAT', _fmt(iatC, 1, 'C')),
      ('BAT', _fmt(batteryV, 1, 'V')),
    ];

    return SizedBox(
      width: 132,
      child: Column(
        children: [
          for (var index = 0; index < rows.length; index++)
            Container(
              height: 34,
              margin: EdgeInsets.only(bottom: index == rows.length - 1 ? 0 : 6),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.055),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    rows[index].$1,
                    style: TextStyle(
                      color: DashboardTheme.muted.withValues(alpha: 0.96),
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      height: 1,
                      letterSpacing: 1.2,
                    ),
                  ),
                  Text(
                    rows[index].$2,
                    style: TextStyle(
                      color: DashboardTheme.text.withValues(alpha: 0.92),
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TripCard extends StatelessWidget {
  const _TripCard({
    required this.tripIndex,
    required this.telemetry,
    required this.onSwipe,
    required this.onLongPress,
  });

  final int tripIndex;
  final Telemetry telemetry;
  final ValueChanged<int> onSwipe;
  final VoidCallback onLongPress;

  String _formatTime(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')} hh:mm';
  }

  @override
  Widget build(BuildContext context) {
    final slot = tripIndex.clamp(1, 2);
    final distance =
        slot == 1 ? telemetry.trip1DistanceKm : telemetry.trip2DistanceKm;
    final seconds = slot == 1 ? telemetry.trip1Seconds : telemetry.trip2Seconds;
    final kmpl = slot == 1 ? telemetry.trip1Kmpl : telemetry.trip2Kmpl;

    return GestureDetector(
      onHorizontalDragEnd: (d) {
        if (d.primaryVelocity == null) return;
        if (d.primaryVelocity!.abs() > 200) {
          onSwipe(d.primaryVelocity! > 0 ? 1 : -1);
        }
      },
      onLongPress: onLongPress,
      child: Container(
        width: 200,
        height: 96,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
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
            SizedBox(
              width: 38,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'TRIP',
                    style: TextStyle(
                      color: DashboardTheme.muted.withValues(alpha: 0.98),
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      height: 1,
                      letterSpacing: 1.08,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$slot',
                    style: const TextStyle(
                      color: Color(0xFFF7F4EA),
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      fontStyle: FontStyle.italic,
                      height: 0.76,
                      shadows: [
                        Shadow(color: Color(0x2EFFFFFF), blurRadius: 12),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        distance.toStringAsFixed(1),
                        style: const TextStyle(
                          color: Color(0xFFF7F4EA),
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          fontStyle: FontStyle.italic,
                          height: 1.18,
                          shadows: [
                            Shadow(color: Color(0x2EFFFFFF), blurRadius: 12),
                          ],
                        ),
                      ),
                      Text(
                        ' km',
                        style: TextStyle(
                          color: DashboardTheme.muted.withValues(alpha: 0.62),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          height: 1.18,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _formatTime(seconds),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: Color(0xFFF5F3EA),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      fontStyle: FontStyle.italic,
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${kmpl.round()} kmpl',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: Color(0xFFF5F3EA),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      fontStyle: FontStyle.italic,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
