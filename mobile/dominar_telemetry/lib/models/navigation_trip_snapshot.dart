import 'package:google_navigation_flutter/google_navigation_flutter.dart';

/// Live trip readout sourced from Navigation SDK listeners/APIs.
class NavigationTripSnapshot {
  const NavigationTripSnapshot({
    this.remainingTimeSeconds,
    this.remainingDistanceMeters,
    this.distanceToTurnMeters,
    this.turnInstruction,
    this.turnRoad,
    this.guidanceActive = false,
  });

  final int? remainingTimeSeconds;
  final int? remainingDistanceMeters;
  final int? distanceToTurnMeters;
  final String? turnInstruction;
  final String? turnRoad;
  final bool guidanceActive;

  bool get hasTripSummary =>
      remainingTimeSeconds != null && remainingDistanceMeters != null;

  bool get hasTurnBanner =>
      guidanceActive &&
      distanceToTurnMeters != null &&
      (turnInstruction != null || turnRoad != null);

  NavigationTripSnapshot copyWith({
    int? remainingTimeSeconds,
    int? remainingDistanceMeters,
    int? distanceToTurnMeters,
    String? turnInstruction,
    String? turnRoad,
    bool? guidanceActive,
  }) {
    return NavigationTripSnapshot(
      remainingTimeSeconds: remainingTimeSeconds ?? this.remainingTimeSeconds,
      remainingDistanceMeters:
          remainingDistanceMeters ?? this.remainingDistanceMeters,
      distanceToTurnMeters: distanceToTurnMeters ?? this.distanceToTurnMeters,
      turnInstruction: turnInstruction ?? this.turnInstruction,
      turnRoad: turnRoad ?? this.turnRoad,
      guidanceActive: guidanceActive ?? this.guidanceActive,
    );
  }
}
