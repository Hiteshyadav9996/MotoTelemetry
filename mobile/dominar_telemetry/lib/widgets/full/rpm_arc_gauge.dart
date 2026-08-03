import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/dashboard_theme.dart';

/// Curved RPM arc gauge — ported from index.html SVG tachometer.
class RpmArcGauge extends StatefulWidget {
  const RpmArcGauge({
    super.key,
    required this.rpm,
    this.engineTemp = 90,
    this.compact = false,
  });

  final double rpm;
  final double engineTemp;
  final bool compact;

  @override
  State<RpmArcGauge> createState() => _RpmArcGaugeState();
}

class _RpmArcGaugeState extends State<RpmArcGauge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blinkController;

  bool get _isAlert =>
      widget.rpm >= 8500 || (widget.engineTemp < 75 && widget.rpm > 5000);

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 144),
    );
    _syncBlinking();
  }

  @override
  void didUpdateWidget(covariant RpmArcGauge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncBlinking();
  }

  void _syncBlinking() {
    if (_isAlert) {
      if (!_blinkController.isAnimating) {
        _blinkController.repeat();
      }
    } else {
      _blinkController.stop();
    }
  }

  @override
  void dispose() {
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _blinkController,
      builder: (context, _) => CustomPaint(
        painter: _RpmArcPainter(
          rpm: widget.rpm,
          engineTemp: widget.engineTemp,
          compact: widget.compact,
          alertOpacity: _isAlert && _blinkController.value >= 0.5 ? 0.22 : 1,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _RpmArcPainter extends CustomPainter {
  _RpmArcPainter({
    required this.rpm,
    required this.engineTemp,
    required this.compact,
    required this.alertOpacity,
  });

  final double rpm;
  final double engineTemp;
  final bool compact;
  final double alertOpacity;

  bool get _isAlert => rpm >= 8500 || (engineTemp < 75 && rpm > 5000);

  static const _viewW = 896.0;
  static const _viewH = 414.0;
  static const _edgeCenter = 98.0;
  static const _topCenter = 98.0;

  Path _rpmPath(double edgeCenter, double topCenter) {
    return Path()
      ..moveTo(edgeCenter, 370)
      ..lineTo(edgeCenter, 238)
      ..quadraticBezierTo(edgeCenter, topCenter, 268, topCenter)
      ..lineTo(830, topCenter);
  }

  double _redzoneStartForTemp(double temp) => temp < 75 ? 5000 : 9500;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = min(size.width / _viewW, size.height / _viewH);
    canvas.save();
    canvas.scale(scale);
    canvas.translate(0, (size.height / scale - _viewH) / 2);

    final pct = (rpm / 10000).clamp(0.0, 1.0);
    final stroke = 42.0 + pow(pct, 0.78) * 32;
    final pathInset = (stroke - 44) / 2;
    final basePath = _rpmPath(_edgeCenter, _topCenter);
    final activePath =
        _rpmPath(_edgeCenter + pathInset, _topCenter + pathInset);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 44
      ..strokeCap = StrokeCap.butt
      ..color = Colors.white.withValues(alpha: 0.105);

    final redzonePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 44
      ..strokeCap = StrokeCap.butt
      ..color = const Color(0xFFFF3C34).withValues(alpha: 0.18);

    final boundaryPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke + 6
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.round
      ..color = _isAlert
          ? const Color(0xFFFF5A56).withValues(alpha: 0.92 * alertOpacity)
          : Colors.white.withValues(alpha: 0.86);

    final activePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.round;
    if (_isAlert) {
      activePaint.color =
          const Color(0xFFFF302B).withValues(alpha: alertOpacity);
    } else {
      activePaint.shader = ui.Gradient.linear(
        const Offset(0, 370),
        const Offset(830, 98),
        [
          DashboardTheme.rpmLow,
          DashboardTheme.rpmMid,
          const Color(0xFFFF9A1F),
          const Color(0xFFFF5C22),
        ],
        const [0.0, 0.58, 0.78, 1.0],
      );
    }

    final baseMetrics = basePath.computeMetrics().first;
    final baseLength = baseMetrics.length;
    final activeMetrics = activePath.computeMetrics().first;
    final activeLength = activeMetrics.length;
    final activeEnd = activeLength * pct;

    canvas.drawPath(basePath, trackPaint);

    // Red zone segment
    final rzStart = _redzoneStartForTemp(engineTemp) / 10000;
    final rzEnd = 1.0;
    final redStart =
        baseMetrics.getTangentForOffset(baseLength * rzStart)?.position;
    final redEnd =
        baseMetrics.getTangentForOffset(baseLength * rzEnd)?.position;
    if (redStart != null && redEnd != null) {
      canvas.drawPath(
        baseMetrics.extractPath(baseLength * rzStart, baseLength * rzEnd),
        redzonePaint,
      );
    }

    final activeExtract = activeMetrics.extractPath(0, activeEnd);
    // The HTML draws the wider white boundary first and the colored band on
    // top, leaving only a thin bright edge around the active RPM segment.
    canvas.drawPath(
      activeExtract,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke + (_isAlert ? 12 : 6)
        ..strokeCap = StrokeCap.butt
        ..strokeJoin = StrokeJoin.round
        ..color = (_isAlert
                ? const Color(0xFFFF302B)
                : DashboardTheme.rpmColorFor(rpm / 1000))
            .withValues(
          alpha: (_isAlert ? 0.70 : 0.36) * alertOpacity,
        )
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          _isAlert ? 8 : 5,
        ),
    );
    canvas.drawPath(activeExtract, boundaryPaint);
    canvas.drawPath(activeExtract, activePaint);

    // Close the white boundary box at the current RPM leading edge.
    if (pct > 0.005 && activeEnd > 1) {
      _drawActiveCap(
        canvas,
        activeMetrics,
        activeEnd,
        stroke,
        boundaryPaint.color,
      );
    }

    // Ticks and numbers
    _drawTicksAndNumbers(canvas, baseMetrics, baseLength);

    canvas.restore();
  }

  void _drawActiveCap(
    Canvas canvas,
    ui.PathMetric metrics,
    double offset,
    double stroke,
    Color color,
  ) {
    final tangent = metrics.getTangentForOffset(offset);
    if (tangent == null) return;

    final p = tangent.position;
    final dir = tangent.vector;
    final len = dir.distance;
    if (len == 0) return;

    final nx = -dir.dy / len;
    final ny = dir.dx / len;
    final halfW = (stroke + 6) / 2;
    final start = Offset(p.dx - nx * halfW, p.dy - ny * halfW);
    final end = Offset(p.dx + nx * halfW, p.dy + ny * halfW);

    canvas.drawLine(
      start,
      end,
      Paint()
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.butt
        ..color = color,
    );
  }

  void _drawTicksAndNumbers(
      Canvas canvas, ui.PathMetric metrics, double totalLen) {
    final rpmK = (rpm / 1000).clamp(0.0, 10.0);

    for (var halfMark = 1; halfMark < 20; halfMark += 2) {
      final mark = halfMark / 2;
      final pct = mark / 10;
      _drawTick(canvas, metrics, totalLen, pct, mark, rpmK, major: false);
    }

    for (var mark = 0; mark <= 10; mark++) {
      final pct = mark / 10;
      _drawTick(canvas, metrics, totalLen, pct, mark.toDouble(), rpmK,
          major: true);
      _drawNumber(canvas, metrics, totalLen, pct, mark, rpmK);
    }
  }

  void _drawTick(
    Canvas canvas,
    ui.PathMetric metrics,
    double totalLen,
    double pct,
    double mark,
    double rpmK, {
    required bool major,
  }) {
    final tangent = metrics.getTangentForOffset(totalLen * pct);
    if (tangent == null) return;

    final p = tangent.position;
    final dir = tangent.vector;
    final len = dir.distance;
    if (len == 0) return;
    final nx = -dir.dy / len;
    final ny = dir.dx / len;
    final tickLen = major ? 24.0 : 14.0;

    final distance = (rpmK - mark).abs();
    final edgeIntensity =
        _quantize((1 - distance / (major ? 0.9 : 0.55)).clamp(0.0, 1.0));
    final nearGlow =
        _quantize((1 - distance / (major ? 1.35 : 0.85)).clamp(0.0, 1.0));
    final isFilled = mark <= rpmK + 0.02;
    final alpha = isFilled
        ? (major ? 0.68 : 0.52) + edgeIntensity * (major ? 0.28 : 0.26)
        : (major ? 0.16 : 0.11) + nearGlow * (major ? 0.24 : 0.18);
    final width = (major ? 1.25 : 0.85) +
        edgeIntensity * (major ? 0.9 : 0.55) +
        (isFilled ? (major ? 0.2 : 0.12) : 0);

    final paint = Paint()
      ..strokeWidth = width
      ..color = Colors.white.withValues(alpha: alpha);

    final end = Offset(p.dx + nx * tickLen, p.dy + ny * tickLen);
    if (edgeIntensity > 0.02) {
      canvas.drawLine(
        p,
        end,
        Paint()
          ..strokeWidth = width
          ..color = Colors.white.withValues(alpha: 0.20 + edgeIntensity * 0.48)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            3 + edgeIntensity * 7,
          ),
      );
    }
    canvas.drawLine(p, end, paint);
  }

  void _drawNumber(
    Canvas canvas,
    ui.PathMetric metrics,
    double totalLen,
    double pct,
    int mark,
    double rpmK,
  ) {
    final tangent = metrics.getTangentForOffset(totalLen * pct);
    if (tangent == null) return;

    final p = tangent.position;
    final offset = _numberOffset(mark);
    final pos = Offset(p.dx + offset.dx, p.dy + offset.dy);

    final distance = (rpmK - mark).abs();
    final intensity = _quantize((1 - distance).clamp(0.0, 1.0));
    final nearGlow =
        _quantize((1 - distance / 1.35).clamp(0.0, 1.0));
    final isHighlighted = intensity > 0.02;
    final hue = DashboardTheme.rpmHueFor(mark.toDouble());
    final color = _isAlert
        ? const Color(0xFFFF302B).withValues(alpha: alertOpacity)
        : isHighlighted
            ? HSLColor.fromAHSL(1, hue, 0.96, 0.58)
                .toColor()
                .withValues(alpha: 0.42 + intensity * 0.58)
            : DashboardTheme.text.withValues(alpha: 0.26 + nearGlow * 0.18);
    final fontSize = 22.0 + pow(intensity, 1.15) * 44;
    final outlineWidth = _isAlert ? 1.75 : 0.75 + intensity * 1.35;
    final outlineAlpha =
        _isAlert ? 0.9 * alertOpacity : 0.22 + intensity * 0.68;
    final glow = _isAlert ? 14.0 : 6 + intensity * 14;
    final glowAlpha = _isAlert
        ? 0.72 * alertOpacity
        : isHighlighted
            ? 0.28 + intensity * 0.48
            : 0.0;

    TextPainter painterWith(Paint foreground) => TextPainter(
          text: TextSpan(
            text: '$mark',
            style: TextStyle(
              foreground: foreground,
              fontSize: fontSize,
              fontWeight: FontWeight.w900,
              fontStyle: FontStyle.italic,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

    final fillPainter = painterWith(Paint()..color = color);
    final topLeft = Offset(
      pos.dx - fillPainter.width / 2,
      pos.dy - fillPainter.height / 2,
    );
    if (glowAlpha > 0) {
      painterWith(
        Paint()
          ..color = (_isAlert
                  ? const Color(0xFFFF302B)
                  : HSLColor.fromAHSL(1, hue, 1, 0.55).toColor())
              .withValues(alpha: glowAlpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, glow),
      ).paint(canvas, topLeft);
    }
    painterWith(
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = outlineWidth
        ..color = Colors.white.withValues(alpha: outlineAlpha),
    ).paint(canvas, topLeft);
    fillPainter.paint(canvas, topLeft);
  }

  double _quantize(double value) => (value * 20).round() / 20;

  Offset _numberOffset(int mark) {
    switch (mark) {
      case 0:
      case 1:
        return const Offset(-58, 0);
      case 2:
        return const Offset(-54, -28);
      case 3:
        return const Offset(-28, -58);
      default:
        return const Offset(0, -62);
    }
  }

  @override
  bool shouldRepaint(covariant _RpmArcPainter oldDelegate) {
    return oldDelegate.rpm != rpm ||
        oldDelegate.engineTemp != engineTemp ||
        oldDelegate.alertOpacity != alertOpacity;
  }
}
