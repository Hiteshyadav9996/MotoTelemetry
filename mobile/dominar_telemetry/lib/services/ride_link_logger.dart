import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Append-only ride link event log (CSV + JSONL) for SoftAP stall diagnosis.
///
/// Caps at ~2 MB and rotates on demand / per calendar day.
class RideLinkLogger {
  RideLinkLogger({
    this.maxBytes = 2 * 1024 * 1024,
    this.gapThresholdMs = 250,
    Directory? overrideDirectory,
  }) : _overrideDirectory = overrideDirectory;

  static const csvHeader =
      'wall_iso,event,device_ms,arrival_gap_ms,device_gap_ms,packet_age_ms,'
      'status,bridge_url,sse_skipped,sse_dropped,softap_stations,connected,'
      'degraded,burst_packets,packets_received\n';

  final int maxBytes;
  final int gapThresholdMs;
  final Directory? _overrideDirectory;

  File? _csvFile;
  File? _jsonlFile;
  bool _ready = false;
  bool _logging = true;
  Future<void> _queue = Future<void>.value();

  bool get isLogging => _logging;
  String? get csvPath => _csvFile?.path;
  String? get jsonlPath => _jsonlFile?.path;

  Future<void> init() async {
    if (_ready) return;
    final override = _overrideDirectory;
    final Directory logDir;
    if (override != null) {
      logDir = override;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      logDir = Directory(p.join(dir.path, 'ride_logs'));
    }
    if (!await logDir.exists()) {
      await logDir.create(recursive: true);
    }
    final day = _dayStamp(DateTime.now().toUtc());
    _csvFile = File(p.join(logDir.path, 'ride_link_$day.csv'));
    _jsonlFile = File(p.join(logDir.path, 'ride_link_$day.jsonl'));
    if (!await _csvFile!.exists()) {
      await _csvFile!.writeAsString(csvHeader, flush: true);
    }
    _ready = true;
  }

  Future<void> startRideLog() async {
    await init();
    final dir = _csvFile!.parent;
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '');
    _csvFile = File(p.join(dir.path, 'ride_link_$stamp.csv'));
    _jsonlFile = File(p.join(dir.path, 'ride_link_$stamp.jsonl'));
    await _csvFile!.writeAsString(csvHeader, flush: true);
    if (await _jsonlFile!.exists()) {
      await _jsonlFile!.writeAsString('', flush: true);
    }
    _logging = true;
    await logEvent(event: 'ride_log_start');
  }

  void setLogging(bool enabled) => _logging = enabled;

  Future<void> logEvent({
    required String event,
    int? deviceMs,
    int? arrivalGapMs,
    int? deviceGapMs,
    int? packetAgeMs,
    String? status,
    String? bridgeUrl,
    int? sseSkipped,
    int? sseDropped,
    int? softapStations,
    bool? connected,
    bool? degraded,
    int? burstPackets,
    int? packetsReceived,
  }) {
    if (!_logging) return Future<void>.value();
    final row = <String, dynamic>{
      'wall_iso': DateTime.now().toUtc().toIso8601String(),
      'event': event,
      'device_ms': deviceMs,
      'arrival_gap_ms': arrivalGapMs,
      'device_gap_ms': deviceGapMs,
      'packet_age_ms': packetAgeMs,
      'status': status,
      'bridge_url': bridgeUrl,
      'sse_skipped': sseSkipped,
      'sse_dropped': sseDropped,
      'softap_stations': softapStations,
      'connected': connected,
      'degraded': degraded,
      'burst_packets': burstPackets,
      'packets_received': packetsReceived,
    };
    _queue = _queue.then((_) => _append(row));
    return _queue;
  }

  /// Log gap/burst events only when thresholds are crossed.
  Future<void> maybeLogGap({
    required int arrivalGapMs,
    required int deviceGapMs,
    required bool burst,
    int? deviceMs,
    int? packetAgeMs,
    String? status,
    String? bridgeUrl,
    int? sseSkipped,
    int? sseDropped,
    int? softapStations,
    bool? connected,
    bool? degraded,
    int? burstPackets,
    int? packetsReceived,
  }) async {
    if (!_logging) return;
    if (!burst &&
        arrivalGapMs <= gapThresholdMs &&
        deviceGapMs <= gapThresholdMs) {
      return;
    }
    final event = burst
        ? 'burst'
        : (deviceGapMs > arrivalGapMs ? 'device_gap' : 'arrival_gap');
    await logEvent(
      event: event,
      deviceMs: deviceMs,
      arrivalGapMs: arrivalGapMs,
      deviceGapMs: deviceGapMs,
      packetAgeMs: packetAgeMs,
      status: status,
      bridgeUrl: bridgeUrl,
      sseSkipped: sseSkipped,
      sseDropped: sseDropped,
      softapStations: softapStations,
      connected: connected,
      degraded: degraded,
      burstPackets: burstPackets,
      packetsReceived: packetsReceived,
    );
  }

  Future<ShareResult?> shareLog() async {
    await init();
    await _queue;
    final csv = _csvFile;
    if (csv == null || !await csv.exists()) return null;
    return Share.shareXFiles(
      [XFile(csv.path, mimeType: 'text/csv')],
      subject: 'D400 ride link log',
      text: 'Dominar telemetry ride link diagnostics',
    );
  }

  Future<void> _append(Map<String, dynamic> row) async {
    await init();
    await _rotateIfNeeded();
    final csvLine = [
      row['wall_iso'],
      row['event'],
      _csv(row['device_ms']),
      _csv(row['arrival_gap_ms']),
      _csv(row['device_gap_ms']),
      _csv(row['packet_age_ms']),
      _escape(row['status']?.toString()),
      _escape(row['bridge_url']?.toString()),
      _csv(row['sse_skipped']),
      _csv(row['sse_dropped']),
      _csv(row['softap_stations']),
      _csv(row['connected']),
      _csv(row['degraded']),
      _csv(row['burst_packets']),
      _csv(row['packets_received']),
    ].join(',');
    await _csvFile!.writeAsString('$csvLine\n', mode: FileMode.append, flush: true);
    await _jsonlFile!.writeAsString(
      '${jsonEncode(row)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<void> _rotateIfNeeded() async {
    final csv = _csvFile;
    if (csv == null || !await csv.exists()) return;
    final len = await csv.length();
    if (len < maxBytes) return;
    final dir = csv.parent;
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '');
    await csv.rename(p.join(dir.path, 'ride_link_rotated_$stamp.csv'));
    final jsonl = _jsonlFile;
    if (jsonl != null && await jsonl.exists()) {
      await jsonl.rename(p.join(dir.path, 'ride_link_rotated_$stamp.jsonl'));
    }
    _csvFile = File(p.join(dir.path, 'ride_link_${_dayStamp(DateTime.now().toUtc())}.csv'));
    _jsonlFile =
        File(p.join(dir.path, 'ride_link_${_dayStamp(DateTime.now().toUtc())}.jsonl'));
    await _csvFile!.writeAsString(csvHeader, flush: true);
  }

  static String _dayStamp(DateTime utc) {
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    return '$y$m$d';
  }

  static String _csv(Object? value) {
    if (value == null) return '';
    if (value is bool) return value ? '1' : '0';
    return value.toString();
  }

  static String _escape(String? value) {
    if (value == null || value.isEmpty) return '';
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
