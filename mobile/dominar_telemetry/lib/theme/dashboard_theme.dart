import 'package:flutter/material.dart';

/// Colors and styling ported from firmware/esp32_wifi_can_bridge/data/index.html
class DashboardTheme {
  static const bg = Color(0xFF050608);
  static const screen = Color(0xFF080D13);
  static const screen2 = Color(0xFF121A23);
  static const text = Color(0xFFF5F3EA);
  static const muted = Color(0xFF828B96);
  static const rpmLow = Color(0xFF8C6208);
  static const rpmMid = Color(0xFFD99916);
  static const rpmHot = Color(0xFFFF6A1F);
  static const throttle = Color(0xFF47E6B1);
  static const gearRing = Color(0xFF5EB8FF);

  static const rpmGradient = LinearGradient(
    begin: Alignment.bottomLeft,
    end: Alignment.topRight,
    colors: [rpmLow, rpmMid, Color(0xFFFF9A1F), Color(0xFFFF5C22)],
    stops: [0.0, 0.58, 0.78, 1.0],
  );

  static BoxDecoration screenBackground = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        screen2,
        screen,
        bg,
      ],
      stops: const [0.0, 0.42, 1.0],
    ),
  );

  static BoxDecoration phoneFrameDecoration = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        screen2,
        screen,
        bg,
      ],
      stops: const [0.0, 0.42, 1.0],
    ),
    border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
    borderRadius: BorderRadius.circular(28),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.58),
        blurRadius: 80,
        offset: const Offset(0, 24),
      ),
    ],
  );

  static double rpmHueFor(double rpmK) {
    return 42 - (rpmK / 10).clamp(0.0, 1.0) * 20;
  }

  static Color rpmColorFor(double rpmK) {
    final hue = rpmHueFor(rpmK);
    return HSLColor.fromAHSL(1, hue, 0.96, 0.58).toColor();
  }
}
