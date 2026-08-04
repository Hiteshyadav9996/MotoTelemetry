import 'dart:typed_data';

import '../models/telemetry.dart';

/// Decodes Dominar 400 passive CAN frames on the phone (Path B benchmark).
class PassiveDecoder {
  PassiveDecoder({this.rpmPairMaxAgeMs = 160});

  final int rpmPairMaxAgeMs;

  double rpm = 0;
  double speedKph = 0;
  double tpsPct = 0;
  double coolantC = double.nan;
  double iatC = double.nan;
  double mapKpa = double.nan;
  double batteryV = double.nan;
  String gear = 'N';

  int? _last301Ms;
  int? _last302Ms;
  int? _last301B0;
  int? _lastGearMs;

  static const double _rpmScale = 40.0;
  static const double _coolantScale = 0.099314;
  static const double _coolantOffset = 2983.421676;
  static const double _iatScale = 0.095760;
  static const double _iatOffset = 34.038803;
  static const double _speedScale = 118.0;
  static const double _batteryScale = 0.1;

  void ingest({
    required int ms,
    required int id,
    required int dlc,
    required List<int> data,
  }) {
    switch (id) {
      case 0x301:
        if (dlc >= 3) {
          final rawTps = data[2];
          tpsPct = rawTps * 100.0 / 255.0;
          _last301B0 = data[0];
          _last301Ms = ms;
          _publish301Rpm(ms);
        }
        break;
      case 0x302:
        if (dlc >= 7) {
          final coolantRaw =
              (data[0] << 8) | data[1];
          final signedCoolant =
              coolantRaw >= 0x8000 ? coolantRaw - 0x10000 : coolantRaw;
          coolantC = _coolantScale * signedCoolant + _coolantOffset;
          iatC = _iatScale * data[5] + _iatOffset;
          mapKpa = data[6] + 1.0;
          if (dlc >= 8) {
            _last302Ms = ms;
            _publish301Rpm(ms);
          }
        }
        break;
      case 0x447:
        if (dlc >= 6 && data[5] <= 6) {
          _lastGearMs = ms;
          gear = _gearFromRaw(data[5]);
        }
        break;
      case 0x30C:
        if (dlc >= 2) {
          final rawSpeed = (data[0] << 8) | data[1];
          speedKph = rawSpeed / _speedScale;
          _updateGearEstimate();
        }
        break;
      case 0x303:
        if (dlc >= 2) {
          final volts = data[1] * _batteryScale;
          if (volts >= 9.0 && volts <= 16.5) batteryV = volts;
        }
        break;
    }
  }

  void ingestRecord(ByteData data, {int offset = 0}) {
    final ms = data.getUint32(offset, Endian.little);
    final id = data.getUint16(offset + 4, Endian.little);
    final dlc = data.getUint8(offset + 6);
    final bytes = List<int>.generate(8, (i) => data.getUint8(offset + 7 + i));
    ingest(ms: ms, id: id, dlc: dlc, data: bytes);
  }

  Telemetry toTelemetry({
    required int seq,
    required int packetMs,
    int? sseSkipped,
    int? sseDropped,
    int? softapStations,
  }) {
    return Telemetry(
      seq: seq,
      ms: packetMs,
      rpm: rpm,
      speedKph: speedKph,
      gear: gear,
      engineTempC: coolantC.isFinite ? coolantC : null,
      throttlePct: tpsPct,
      mapKpa: mapKpa.isFinite ? mapKpa : null,
      iatC: iatC.isFinite ? iatC : null,
      batteryV: batteryV.isFinite ? batteryV : null,
      sseSkipped: sseSkipped,
      sseDropped: sseDropped,
      softapStations: softapStations,
      connected: true,
      source: 'passive-decode',
    );
  }

  void _publish301Rpm(int ms) {
    if (_last301Ms == null || _last302Ms == null || _last301B0 == null) return;
    if (ms - _last301Ms! > rpmPairMaxAgeMs) return;
    if (ms - _last302Ms! > rpmPairMaxAgeMs) return;
    rpm = _last301B0! * _rpmScale;
  }

  String _gearFromRaw(int raw) {
    switch (raw) {
      case 0:
        return 'N';
      case 1:
        return '1';
      case 2:
        return '2';
      case 3:
        return '3';
      case 4:
        return '4';
      case 5:
        return '5';
      case 6:
        return '6';
      default:
        return gear;
    }
  }

  void _updateGearEstimate() {
    if (_lastGearMs != null && DateTime.now().millisecondsSinceEpoch - _lastGearMs! < 2000) {
      return;
    }
    gear = Telemetry.inferGear(speedKph);
  }
}
