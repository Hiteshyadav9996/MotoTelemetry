import 'dart:io';

import 'package:dominar_telemetry/models/telemetry.dart';
import 'package:dominar_telemetry/services/ride_link_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Telemetry parses firmware SSE skip counters', () {
    final t = Telemetry.fromJson({
      'seq': 9,
      'ms': 1234,
      'rpm': 1000,
      'speed_kph': 0,
      'sse_skipped': 17,
      'sse_dropped': 2,
      'softap_stations': 1,
    });
    expect(t.sseSkipped, 17);
    expect(t.sseDropped, 2);
    expect(t.softapStations, 1);
  });

  test('RideLinkLogger writes CSV/JSONL gap and burst events', () async {
    final dir = await Directory.systemTemp.createTemp('ride_link_');
    addTearDown(() => dir.delete(recursive: true));

    final logger = RideLinkLogger(
      overrideDirectory: dir,
      gapThresholdMs: 250,
    );
    await logger.init();
    await logger.logEvent(
      event: 'connect',
      bridgeUrl: 'http://192.168.4.1',
      connected: true,
      sseSkipped: 0,
      sseDropped: 0,
      softapStations: 1,
    );
    await logger.maybeLogGap(
      arrivalGapMs: 80,
      deviceGapMs: 50,
      burst: false,
      sseSkipped: 0,
    );
    await logger.maybeLogGap(
      arrivalGapMs: 400,
      deviceGapMs: 50,
      burst: false,
      deviceMs: 2000,
      sseSkipped: 3,
      bridgeUrl: 'http://192.168.4.1',
    );
    await logger.maybeLogGap(
      arrivalGapMs: 4,
      deviceGapMs: 200,
      burst: true,
      deviceMs: 2200,
      sseSkipped: 3,
      burstPackets: 1,
    );

    final csv = await File(logger.csvPath!).readAsString();
    expect(csv, contains(RideLinkLogger.csvHeader.trim()));
    expect(csv, contains('connect'));
    expect(csv, contains('arrival_gap'));
    expect(csv, contains('burst'));
    expect(csv.split('\n').where((l) => l.contains(',80,')).isEmpty, isTrue);

    final jsonl = await File(logger.jsonlPath!).readAsString();
    expect(jsonl, contains('"event":"arrival_gap"'));
    expect(jsonl, contains('"event":"burst"'));
  });

  test('Start ride log rotates to a fresh CSV', () async {
    final dir = await Directory.systemTemp.createTemp('ride_link_start_');
    addTearDown(() => dir.delete(recursive: true));

    final logger = RideLinkLogger(overrideDirectory: dir);
    await logger.init();
    await logger.logEvent(event: 'connect');
    final firstPath = logger.csvPath!;
    await logger.startRideLog();
    expect(logger.csvPath, isNot(firstPath));
    final csv = await File(logger.csvPath!).readAsString();
    expect(csv, contains('ride_log_start'));
  });
}
