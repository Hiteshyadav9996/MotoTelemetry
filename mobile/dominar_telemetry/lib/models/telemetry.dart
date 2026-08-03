import 'dart:math';
import 'dart:typed_data';

class Telemetry {
  Telemetry({
    this.seq = 0,
    this.ms = 0,
    this.rpm = 0,
    this.speedKph = 0,
    this.gear = 'N',
    this.odometerKm,
    this.engineTempC,
    this.throttlePct = 0,
    this.mapKpa,
    this.iatC,
    this.batteryV,
    this.tripCount = 2,
    this.trip1DistanceKm = 0,
    this.trip1Seconds = 0,
    this.trip1Kmpl = 0,
    this.trip2DistanceKm = 0,
    this.trip2Seconds = 0,
    this.trip2Kmpl = 0,
    this.sseSkipped,
    this.sseDropped,
    this.softapStations,
    this.connected = false,
    this.source = 'demo',
  });

  final int seq;
  final int ms;
  final double rpm;
  final double speedKph;
  final String gear;
  final double? odometerKm;
  final double? engineTempC;
  final double throttlePct;
  final double? mapKpa;
  final double? iatC;
  final double? batteryV;
  final int tripCount;
  final double trip1DistanceKm;
  final int trip1Seconds;
  final double trip1Kmpl;
  final double trip2DistanceKm;
  final int trip2Seconds;
  final double trip2Kmpl;
  final int? sseSkipped;
  final int? sseDropped;
  final int? softapStations;
  final bool connected;
  final String source;

  double get displaySpeed => speedKph;
  double get displayCoolant => engineTempC ?? double.nan;

  static Telemetry fromJson(Map<String, dynamic> json) {
    double d(dynamic v, [double fallback = 0]) {
      if (v == null) return fallback;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? fallback;
    }

    double? opt(dynamic v) {
      if (v == null) return null;
      if (v is num && v.isFinite) return v.toDouble();
      final parsed = double.tryParse(v.toString());
      return parsed?.isFinite == true ? parsed : null;
    }

    return Telemetry(
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      ms: (json['ms'] as num?)?.toInt() ?? 0,
      rpm: d(json['rpm']),
      speedKph: d(json['speed_kph'] ?? json['speed']),
      gear: (json['gear'] ?? 'N').toString().toUpperCase(),
      odometerKm: opt(json['odometer_km'] ?? json['odo_km']),
      engineTempC: opt(json['engine_temp_c'] ?? json['coolant_c'] ?? json['coolant']),
      throttlePct: d(json['tps_pct'] ?? json['tps'] ?? json['throttle_pct'] ?? json['throttle']),
      mapKpa: opt(json['map_kpa'] ?? json['map']),
      iatC: opt(json['iat_c'] ?? json['iat']),
      batteryV: opt(json['battery_v'] ?? json['vbatt']),
      tripCount: (json['trip_count'] as num?)?.toInt() ?? 2,
      trip1DistanceKm: d(json['trip1_distance_km']),
      trip1Seconds: (json['trip1_seconds'] as num?)?.toInt() ?? 0,
      trip1Kmpl: d(json['trip1_kmpl']),
      trip2DistanceKm: d(json['trip2_distance_km']),
      trip2Seconds: (json['trip2_seconds'] as num?)?.toInt() ?? 0,
      trip2Kmpl: d(json['trip2_kmpl']),
      sseSkipped: (json['sse_skipped'] as num?)?.toInt(),
      sseDropped: (json['sse_dropped'] as num?)?.toInt(),
      softapStations: (json['softap_stations'] as num?)?.toInt(),
      connected: true,
      source: 'esp32',
    );
  }

  /// Path C: hex-encoded packed binary (`binhex:` SSE prefix).
  static Telemetry? fromBinaryHex(String hex) {
    if (hex.length < 156) return null;
    final bytes = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return fromBinary(Uint8List.fromList(bytes));
  }

  static Telemetry? fromBinary(Uint8List bytes) {
    if (bytes.length < 78) return null;
    final data = ByteData.sublistView(bytes);
    if (data.getUint8(0) != 0x44) return null; // 'D'

    double f(int offset) => data.getFloat32(offset, Endian.little);

    final gearChar = String.fromCharCode(data.getUint8(16));
    return Telemetry(
      seq: data.getUint16(2, Endian.little),
      ms: data.getUint32(4, Endian.little),
      rpm: f(8),
      speedKph: f(12),
      gear: gearChar.toUpperCase(),
      odometerKm: f(18),
      engineTempC: f(22),
      throttlePct: f(26),
      mapKpa: f(30),
      iatC: f(34),
      batteryV: f(38),
      trip1DistanceKm: f(42),
      trip1Seconds: data.getUint32(46, Endian.little),
      trip1Kmpl: f(50),
      trip2DistanceKm: f(54),
      trip2Seconds: data.getUint32(58, Endian.little),
      trip2Kmpl: f(62),
      sseSkipped: data.getUint32(66, Endian.little),
      sseDropped: data.getUint32(70, Endian.little),
      softapStations: data.getUint8(74),
      connected: true,
      source: 'esp32-binary',
    );
  }

  static String inferGear(double speed) {
    if (speed < 3) return 'N';
    if (speed < 23) return '1';
    if (speed < 43) return '2';
    if (speed < 68) return '3';
    if (speed < 94) return '4';
    if (speed < 125) return '5';
    return '6';
  }

  static Telemetry demo({required double elapsed, required int seq}) {
    double triangle(double t, double period) {
      final phase = (t % period) / period;
      final linear = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
      return (linear + 0.75 * sin(2 * pi * linear) / (2 * pi)).clamp(0.0, 1.0);
    }

    final sweep = triangle(elapsed, 2.4);
    final tempPhase = (elapsed / 5).floor() % 2;
    final rpm = sweep * 10000;
    final speed = sweep * 168;
    final throttlePhase = triangle(elapsed + 0.8, 3.7);
    final throttle = (4 + pow(throttlePhase, 1.6) * 92).clamp(0.0, 100.0);
    final demoDistance = (elapsed * 0.038) % 240;
    final demoSeconds = (elapsed * 12).floor() % 360000;

    return Telemetry(
      seq: seq,
      ms: (elapsed * 1000).round(),
      rpm: rpm,
      speedKph: speed,
      gear: inferGear(speed),
      odometerKm: 53988 + elapsed * 0.01,
      engineTempC: tempPhase == 0 ? 70 : 80,
      throttlePct: throttle.toDouble(),
      mapKpa: (28 + throttle * 0.65 + rpm / 900).clamp(20.0, 105.0).toDouble(),
      iatC: 30.5 + sin(elapsed * 0.45) * 2.0,
      batteryV: 14.1 + sin(elapsed * 0.8) * 0.08,
      tripCount: 2,
      trip1DistanceKm: demoDistance,
      trip1Seconds: demoSeconds,
      trip1Kmpl: 20.1 + sin(elapsed * 0.3) * 1.5,
      trip2DistanceKm: (demoDistance * 0.42) % 120,
      trip2Seconds: (demoSeconds * 0.54).floor(),
      trip2Kmpl: 22.4 + sin(elapsed * 0.22) * 1.2,
      connected: false,
      source: 'demo',
    );
  }
}
