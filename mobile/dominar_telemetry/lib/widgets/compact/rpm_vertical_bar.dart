import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/dashboard_theme.dart';

/// Straight vertical form of the full dashboard RPM band.
class RpmVerticalBar extends StatefulWidget {
  const RpmVerticalBar({
    super.key,
    required this.rpm,
    required this.engineTemp,
  });

  final double rpm;
  final double engineTemp;

  @override
  State<RpmVerticalBar> createState() => _RpmVerticalBarState();
}

class _RpmVerticalBarState extends State<RpmVerticalBar>
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
  void didUpdateWidget(covariant RpmVerticalBar oldWidget) {
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
        size: Size.infinite,
        painter: _RpmVerticalPainter(
          rpm: widget.rpm,
          engineTemp: widget.engineTemp,
          alertOpacity: _isAlert && _blinkController.value >= 0.5 ? 0.22 : 1,
        ),
      ),
    );
  }
}

class _RpmVerticalPainter extends CustomPainter {
  const _RpmVerticalPainter({
    required this.rpm,
    required this.engineTemp,
    required this.alertOpacity,
  });

  final double rpm;
  final double engineTemp;
  final double alertOpacity;

  // Left edge flush with column — vertical phone-side edge stays parallel.
  static const _leftEdge = 6.0;
  static const _top = 36.0;
  static const _bottom = 378.0;
  static const _bottomWidth = 44.0;
  static const _topWidth = 88.0;

  bool get _isAlert => rpm >= 8500 || (engineTemp < 75 && rpm > 5000);

  double get _barHeight => _bottom - _top;

  /// Interpolation 0 at bottom, 1 at top.
  double _tAtY(double y) => ((_bottom - y) / _barHeight).clamp(0.0, 1.0);

  double _barWidthAtY(double y) =>
      _bottomWidth + (_topWidth - _bottomWidth) * _tAtY(y);

  double _barRightAtY(double y) => _leftEdge + _barWidthAtY(y);

  /// X anchor for scale digits — sits just right of the inclined bar edge.
  double _numberAnchorX(double y, int mark) =>
      _barRightAtY(y) + (mark == 10 ? 12.0 : 8.0);

  double _yAtPct(double pct) => _bottom - pct * _barHeight;

  /// Trapezoid: vertical left edge, angled right edge (wider at top).
  Path _trapezoidPath() => Path()
    ..moveTo(_leftEdge, _bottom)
    ..lineTo(_leftEdge + _bottomWidth, _bottom)
    ..lineTo(_leftEdge + _topWidth, _top)
    ..lineTo(_leftEdge, _top)
    ..close();

  /// Center spine for tick / number Y positions.
  Path _spinePath() {
    final midBottom = _leftEdge + _bottomWidth / 2;
    final midTop = _leftEdge + _topWidth / 2;
    return Path()
      ..moveTo(midBottom, _bottom)
      ..lineTo(midTop, _top);
  }

  void _clipVerticalRange(Canvas canvas, double startPct, double endPct) {
    final yLo = _yAtPct(endPct);
    final yHi = _yAtPct(startPct);
    canvas.clipRect(Rect.fromLTRB(0, yLo, 200, yHi));
  }

  double _redzoneStartForTemp(double temp) => temp < 75 ? 0.5 : 0.95;

  @override
  void paint(Canvas canvas, Size size) {
    final pct = (rpm / 10000).clamp(0.0, 1.0);
    final rpmK = (rpm / 1000).clamp(0.0, 10.0);
    final stroke = 42.0 + pow(pct, 0.78) * 32;
    final barPath = _trapezoidPath();

    // Track — matches arc gauge trackPaint.
    canvas.drawPath(
      barPath,
      Paint()
        ..style = PaintingStyle.fill
        ..color = Colors.white.withValues(alpha: 0.105),
    );

    // Red zone — matches arc gauge redzonePaint.
    final rzStart = _redzoneStartForTemp(engineTemp);
    canvas.save();
    _clipVerticalRange(canvas, rzStart, 1.0);
    canvas.drawPath(
      barPath,
      Paint()
        ..style = PaintingStyle.fill
        ..color = const Color(0xFFFF3C34).withValues(alpha: 0.18),
    );
    canvas.restore();

    // Active fill — glow + boundary + gradient (arc gauge layering).
    canvas.save();
    _clipVerticalRange(canvas, 0.0, pct);
    canvas.drawPath(
      barPath,
      Paint()
        ..style = PaintingStyle.fill
        ..color = (_isAlert
                ? const Color(0xFFFF302B)
                : DashboardTheme.rpmColorFor(rpmK))
            .withValues(
          alpha: (_isAlert ? 0.70 : 0.36) * alertOpacity,
        )
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          _isAlert ? 8 : 5,
        ),
    );

    final activePaint = Paint()..style = PaintingStyle.fill;
    if (_isAlert) {
      activePaint.color =
          const Color(0xFFFF302B).withValues(alpha: alertOpacity);
    } else {
      activePaint.shader = ui.Gradient.linear(
        Offset(_leftEdge, _bottom),
        Offset(_leftEdge, _top),
        const [
          DashboardTheme.rpmLow,
          DashboardTheme.rpmMid,
          Color(0xFFFF9A1F),
          Color(0xFFFF5C22),
        ],
        const [0.0, 0.58, 0.78, 1.0],
      );
    }
    canvas.drawPath(barPath, activePaint);
    canvas.restore();

    // Inclined right-edge guide — numbers sit along this line.
    canvas.drawLine(
      Offset(_leftEdge + _bottomWidth, _bottom),
      Offset(_leftEdge + _topWidth, _top),
      Paint()
        ..strokeWidth = 1.25
        ..color = Colors.white.withValues(alpha: 0.32),
    );

    // Bright boundary at active fill top — arc gauge boundaryPaint equivalent.
    if (pct > 0.005) {
      final rpmY = _yAtPct(pct);
      final right = _barRightAtY(rpmY);
      canvas.drawLine(
        Offset(_leftEdge, rpmY),
        Offset(right, rpmY),
        Paint()
          ..strokeWidth = stroke / 12 + 2
          ..strokeCap = StrokeCap.butt
          ..color = _isAlert
              ? const Color(0xFFFF5A56).withValues(alpha: 0.92 * alertOpacity)
              : Colors.white.withValues(alpha: 0.86),
      );
    }

    // Dim white needle line at current RPM — spans bar to scale numbers.
    if (pct > 0.005) {
      final rpmY = _yAtPct(pct);
      canvas.drawLine(
        Offset(_leftEdge, rpmY),
        Offset(_barRightAtY(rpmY) + 36, rpmY),
        Paint()
          ..strokeWidth = 1.5
          ..color = Colors.white.withValues(alpha: 0.38),
      );
    }

    final spineMetric = _spinePath().computeMetrics().first;
    final spineLen = spineMetric.length;

    // Dash ticks clipped inside the bar fill (matches arc gauge screenshot).
    canvas.save();
    canvas.clipPath(barPath);
    _drawTicks(canvas, spineMetric, spineLen, rpmK);
    canvas.restore();

    _drawNumbers(canvas, spineMetric, spineLen, rpmK);
  }

  void _drawTicks(
    Canvas canvas,
    ui.PathMetric metric,
    double totalLength,
    double rpmK,
  ) {
    for (var halfMark = 1; halfMark < 20; halfMark += 2) {
      _drawTick(
        canvas,
        metric,
        totalLength,
        halfMark / 20,
        halfMark / 2,
        rpmK,
        major: false,
      );
    }
    for (var mark = 0; mark <= 10; mark++) {
      _drawTick(
        canvas,
        metric,
        totalLength,
        mark / 10,
        mark.toDouble(),
        rpmK,
        major: true,
      );
    }
  }

  void _drawNumbers(
    Canvas canvas,
    ui.PathMetric metric,
    double totalLength,
    double rpmK,
  ) {
    for (var mark = 0; mark <= 10; mark++) {
      _drawNumber(canvas, metric, totalLength, mark, rpmK);
    }
  }

  void _drawTick(
    Canvas canvas,
    ui.PathMetric metric,
    double totalLength,
    double pct,
    double mark,
    double rpmK, {
    required bool major,
  }) {
    final tangent = metric.getTangentForOffset(totalLength * pct);
    if (tangent == null) return;

    final y = tangent.position.dy;
    final barRight = _barRightAtY(y);
    final innerLeft = _leftEdge + 8;
    final innerRight = barRight - 8;
    final span = innerRight - innerLeft;
    final dashLen = major ? span * 0.62 : span * 0.38;
    final midX = (innerLeft + innerRight) / 2;

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

    final start = Offset(midX - dashLen / 2, y);
    final end = Offset(midX + dashLen / 2, y);

    if (edgeIntensity > 0.02) {
      canvas.drawLine(
        start,
        end,
        Paint()
          ..strokeWidth = width
          ..color =
              Colors.white.withValues(alpha: 0.20 + edgeIntensity * 0.48)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            3 + edgeIntensity * 7,
          ),
      );
    }
    canvas.drawLine(
      start,
      end,
      Paint()
        ..strokeWidth = width
        ..color = Colors.white.withValues(alpha: alpha),
    );
  }

  void _drawNumber(
    Canvas canvas,
    ui.PathMetric metric,
    double totalLength,
    int mark,
    double rpmK,
  ) {
    final tangent = metric.getTangentForOffset(totalLength * mark / 10);
    if (tangent == null) return;

    final y = tangent.position.dy;
    final anchorX = _numberAnchorX(y, mark);

    final activeMark = _activeRpmMark(rpmK);
    final isActive = mark == activeMark;
    final distance = (rpmK - mark).abs();
    final intensity = isActive ? 1.0 : 0.0;
    final nearGlow =
        isActive ? 0.0 : _quantize((1 - distance / 1.35).clamp(0.0, 1.0));
    final isHighlighted = isActive;
    final hue = DashboardTheme.rpmHueFor(mark.toDouble());
    final color = _isAlert
        ? const Color(0xFFFF302B).withValues(alpha: alertOpacity)
        : isHighlighted
            ? HSLColor.fromAHSL(1, hue, 0.96, 0.58)
                .toColor()
                .withValues(alpha: 0.42 + intensity * 0.58)
            : DashboardTheme.text.withValues(alpha: 0.26 + nearGlow * 0.18);
    final fontSize = isActive ? 66.0 : 22.0 + nearGlow * 12;
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
      anchorX,
      y - fillPainter.height / 2,
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

  /// Single highlighted thousand-digit with 500 RPM handoff (e.g. 2 until 2500, 3 from 2501).
  int _activeRpmMark(double rpmK) {
    final rpmVal = rpmK * 1000;
    if (rpmVal <= 500) return 0;
    return (((rpmVal - 501) / 1000).floor() + 1).clamp(0, 10);
  }

  @override
  bool shouldRepaint(covariant _RpmVerticalPainter oldDelegate) =>
      oldDelegate.rpm != rpm ||
      oldDelegate.engineTemp != engineTemp ||
      oldDelegate.alertOpacity != alertOpacity;
}
