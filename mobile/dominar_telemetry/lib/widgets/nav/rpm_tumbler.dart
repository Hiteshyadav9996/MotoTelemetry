import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/dashboard_theme.dart';

const _kHighlightLineHeight = 2.5;

/// Read-only dual-column RPM drum: large thousands digit + uniform hundreds.
class RpmTumbler extends StatelessWidget {
  const RpmTumbler({super.key, required this.rpm});

  final double rpm;

  static const _itemHeight = 76.0;
  static const _selectionHeight = 96.0;
  static const _thousandCenterSize = 64.0;
  static const _hundredCenterSize = 22.0;

  @override
  Widget build(BuildContext context) {
    final rpmK = (rpm / 1000).clamp(0.0, 10.0);
    final hundredK = ((rpm % 1000) / 100).clamp(0.0, 9.999);

    return ColoredBox(
      color: DashboardTheme.screen,
      child: Column(
        children: [
          const SizedBox(height: 16),
          Text(
            'RPM',
            style: TextStyle(
              color: DashboardTheme.muted.withValues(alpha: 0.85),
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
          Text(
            '×1000',
            style: TextStyle(
              color: DashboardTheme.muted.withValues(alpha: 0.55),
              fontSize: 8,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final centerY = constraints.maxHeight / 2;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 8, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 5,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                for (var mark = 0; mark <= 10; mark++)
                                  _DrumRow(
                                    label: '$mark',
                                    index: mark.toDouble(),
                                    activeIndex: rpmK,
                                    centerY: centerY,
                                    itemHeight: _itemHeight,
                                    hueSeed: mark.toDouble(),
                                    isThousands: true,
                                    centerFontSize: _thousandCenterSize,
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            flex: 6,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                for (var mark = 0; mark <= 9; mark++)
                                  _DrumRow(
                                    label: (mark * 100)
                                        .toString()
                                        .padLeft(3, '0'),
                                    index: mark.toDouble(),
                                    activeIndex: hundredK,
                                    centerY: centerY,
                                    itemHeight: _itemHeight,
                                    hueSeed: rpmK,
                                    isThousands: false,
                                    centerFontSize: _hundredCenterSize,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    _FixedHighlightFrame(
                      centerY: centerY,
                      selectionHeight: _selectionHeight,
                    ),
                    // Drum fade — top/bottom only, not side overlay.
                    const _DrumEdgeFade(alignment: Alignment.topCenter),
                    const _DrumEdgeFade(alignment: Alignment.bottomCenter),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _DrumEdgeFade extends StatelessWidget {
  const _DrumEdgeFade({required this.alignment});

  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: alignment == Alignment.topCenter
                  ? Alignment.topCenter
                  : Alignment.bottomCenter,
              end: alignment == Alignment.topCenter
                  ? Alignment.bottomCenter
                  : Alignment.topCenter,
              colors: [
                DashboardTheme.screen,
                DashboardTheme.screen.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FixedHighlightFrame extends StatelessWidget {
  const _FixedHighlightFrame({
    required this.centerY,
    required this.selectionHeight,
  });

  final double centerY;
  final double selectionHeight;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 10,
      right: 8,
      top: centerY - selectionHeight / 2,
      height: selectionHeight,
      child: Row(
        children: [
          const Expanded(flex: 5, child: _ColumnHighlightBars()),
          const SizedBox(width: 6),
          const Expanded(flex: 6, child: _ColumnHighlightBars()),
        ],
      ),
    );
  }
}

class _ColumnHighlightBars extends StatelessWidget {
  const _ColumnHighlightBars();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _HighlightLine(),
        const Spacer(),
        const _HighlightLine(),
      ],
    );
  }
}

class _HighlightLine extends StatelessWidget {
  const _HighlightLine();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _kHighlightLineHeight,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: DashboardTheme.rpmHot,
        borderRadius: BorderRadius.circular(1.5),
        boxShadow: [
          BoxShadow(
            color: DashboardTheme.rpmHot.withValues(alpha: 0.45),
            blurRadius: 8,
            spreadRadius: 0.5,
          ),
        ],
      ),
    );
  }
}

class _DrumRow extends StatelessWidget {
  const _DrumRow({
    required this.label,
    required this.index,
    required this.activeIndex,
    required this.centerY,
    required this.itemHeight,
    required this.hueSeed,
    required this.isThousands,
    required this.centerFontSize,
  });

  final String label;
  final double index;
  final double activeIndex;
  final double centerY;
  final double itemHeight;
  final double hueSeed;
  final bool isThousands;
  final double centerFontSize;

  @override
  Widget build(BuildContext context) {
    final distance = (index - activeIndex).abs();
    final y = centerY + (index - activeIndex) * itemHeight;
    final isCenter = distance < 0.45;
    final blurSigma = isCenter ? 0.0 : (distance * 3.0).clamp(1.5, 7.0);
    final opacity = isCenter ? 1.0 : (0.5 - distance * 0.1).clamp(0.18, 0.4);
    final offSize = isThousands ? 28.0 : 16.0;
    final fontSize = isCenter
        ? centerFontSize
        : (offSize - distance * (isThousands ? 2.0 : 1.2));
    final hue = DashboardTheme.rpmHueFor(hueSeed);
    final color = isCenter
        ? DashboardTheme.text
        : HSLColor.fromAHSL(1, hue, 0.82, 0.52).toColor();

    Widget labelWidget = Text(
      label,
      style: TextStyle(
        color: color.withValues(alpha: opacity),
        fontSize: fontSize.clamp(isThousands ? 18.0 : 13.0, centerFontSize),
        fontWeight: FontWeight.w900,
        fontStyle: FontStyle.italic,
        height: isThousands ? 1.0 : 1.1,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );

    if (!isCenter && blurSigma > 0) {
      labelWidget = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: labelWidget,
      );
    }

    final rowHeight = isCenter && isThousands
        ? math.max(itemHeight, centerFontSize + 12)
        : itemHeight;

    return Positioned(
      left: 0,
      right: 0,
      top: y - rowHeight / 2,
      height: rowHeight,
      child: Align(
        alignment: isThousands ? Alignment.center : Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(left: isThousands ? 0 : 2),
          child: isCenter && isThousands
              ? FittedBox(
                  fit: BoxFit.scaleDown,
                  child: labelWidget,
                )
              : labelWidget,
        ),
      ),
    );
  }
}
