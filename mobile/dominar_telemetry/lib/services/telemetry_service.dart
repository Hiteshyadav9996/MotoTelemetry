import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

import '../models/telemetry.dart';
import 'ride_link_logger.dart';

/// Connects to the ESP32 passive-only bridge via Server-Sent Events (/events).
/// Falls back to animated demo telemetry when the bridge is unreachable.
class TelemetryService extends ChangeNotifier {
  TelemetryService({RideLinkLogger? linkLogger})
      : _linkLogger = linkLogger ?? RideLinkLogger();

  static const defaultBridgeUrl = 'http://192.168.4.1';
  static const fallbackBridgeUrl = 'http://d400telemetry.local';
  static const bridgeUrlKey = 'bridge_url';

  /// The bridge stamps a packet every 50 ms.
  static const expectedPacketIntervalMs = 50;

  /// Packets landing closer together than this were released from a buffer
  /// rather than produced live.
  static const _burstArrivalGapMs = 8;

  /// Match the HTML dashboard mobile throttle; 50ms ≈ 30 fps — snappier than
  /// 50ms while still coalescing bursts from the 20 Hz SSE stream.
  static const uiFrameMs = 50;

  /// Soft-warn: UI still shows last values but status turns amber.
  static const staleDegradeMs = 1000;

  /// Hard cut: tear down the socket and reconnect instead of waiting on TCP.
  static const staleReconnectMs = 2500;

  static const connectTimeout = Duration(seconds: 2);

  final RideLinkLogger _linkLogger;
  RideLinkLogger get linkLogger => _linkLogger;

  Telemetry _telemetry = Telemetry.demo(elapsed: 0, seq: 0);
  Telemetry get telemetry => _telemetry;

  String _bridgeUrl = defaultBridgeUrl;
  String get bridgeUrl => _bridgeUrl;
  String _activeBridgeUrl = defaultBridgeUrl;

  bool _connected = false;
  bool get connected => _connected;

  bool _degraded = false;
  bool get degraded => _degraded;

  String _status = 'Starting…';
  String get status => _status;

  http.Client? _client;
  StreamSubscription<String>? _sseSub;
  Timer? _demoTimer;
  Timer? _reconnectTimer;
  Timer? _watchdogTimer;
  Timer? _uiCoalesceTimer;
  int _demoSeq = 0;
  final Stopwatch _demoClock = Stopwatch()..start();
  bool _disposed = false;
  bool _connecting = false;

  // Comparing wall-clock arrival against the `ms` the bridge stamped into each
  // packet separates the two possible stalls: a large arrival gap paired with a
  // normal device gap means the Wi-Fi link buffered and replayed a burst, while
  // both gaps growing together means the ESP32 itself stopped producing.
  final Stopwatch _arrivalClock = Stopwatch()..start();
  int? _lastArrivalMs;
  int? _lastDeviceMs;
  int _maxArrivalGapMs = 0;
  int _maxDeviceGapMs = 0;
  int _burstPackets = 0;
  int _packetsReceived = 0;
  int? _lastSseSkipped;
  int? _lastSseDropped;

  /// Milliseconds since the last packet landed, or null before the first one.
  int? get packetAgeMs {
    final last = _lastArrivalMs;
    if (last == null) return null;
    return _arrivalClock.elapsedMilliseconds - last;
  }

  /// Largest wall-clock gap between two consecutive packets this session.
  int get maxArrivalGapMs => _maxArrivalGapMs;

  /// Largest gap between two consecutive packets' own `ms` timestamps.
  int get maxDeviceGapMs => _maxDeviceGapMs;

  /// Packets that arrived back-to-back after a stall, i.e. buffered by the link.
  int get burstPackets => _burstPackets;

  int get packetsReceived => _packetsReceived;

  int? get sseSkipped => _telemetry.sseSkipped ?? _lastSseSkipped;
  int? get sseDropped => _telemetry.sseDropped ?? _lastSseDropped;
  int? get softapStations => _telemetry.softapStations;

  /// Compact readout so the stall can be diagnosed on the bike without a laptop.
  String get linkDiagnostics {
    if (_packetsReceived == 0) return 'no packets yet';
    final age = packetAgeMs ?? 0;
    final skip = sseSkipped;
    final drop = sseDropped;
    final fw = (skip == null && drop == null)
        ? ''
        : ' · sse skip ${skip ?? '—'} drop ${drop ?? '—'}';
    return '${age}ms · link gap ${_maxArrivalGapMs}ms · '
        'esp gap ${_maxDeviceGapMs}ms · burst $_burstPackets$fw';
  }

  void _resetLinkStats() {
    _lastArrivalMs = null;
    _lastDeviceMs = null;
    _maxArrivalGapMs = 0;
    _maxDeviceGapMs = 0;
    _burstPackets = 0;
    _packetsReceived = 0;
    _degraded = false;
  }

  Map<String, dynamic> _linkContext() => {
        'deviceMs': _lastDeviceMs,
        'packetAgeMs': packetAgeMs,
        'status': _status,
        'bridgeUrl': _activeBridgeUrl,
        'sseSkipped': sseSkipped,
        'sseDropped': sseDropped,
        'softapStations': softapStations,
        'connected': _connected,
        'degraded': _degraded,
        'burstPackets': _burstPackets,
        'packetsReceived': _packetsReceived,
      };

  void _logLink(String event, {int? arrivalGapMs, int? deviceGapMs}) {
    final ctx = _linkContext();
    unawaited(_linkLogger.logEvent(
      event: event,
      deviceMs: ctx['deviceMs'] as int?,
      arrivalGapMs: arrivalGapMs,
      deviceGapMs: deviceGapMs,
      packetAgeMs: ctx['packetAgeMs'] as int?,
      status: ctx['status'] as String?,
      bridgeUrl: ctx['bridgeUrl'] as String?,
      sseSkipped: ctx['sseSkipped'] as int?,
      sseDropped: ctx['sseDropped'] as int?,
      softapStations: ctx['softapStations'] as int?,
      connected: ctx['connected'] as bool?,
      degraded: ctx['degraded'] as bool?,
      burstPackets: ctx['burstPackets'] as int?,
      packetsReceived: ctx['packetsReceived'] as int?,
    ));
  }

  void _recordArrival(int deviceMs) {
    final arrivalMs = _arrivalClock.elapsedMilliseconds;
    final previousArrivalMs = _lastArrivalMs;
    final previousDeviceMs = _lastDeviceMs;
    _lastArrivalMs = arrivalMs;
    _lastDeviceMs = deviceMs;
    _packetsReceived += 1;
    if (previousArrivalMs == null || previousDeviceMs == null) return;

    final arrivalGap = arrivalMs - previousArrivalMs;
    // The bridge reboots reset its millis(), so ignore backwards device time.
    final deviceGap = deviceMs - previousDeviceMs;
    if (arrivalGap > _maxArrivalGapMs) _maxArrivalGapMs = arrivalGap;
    if (deviceGap > 0 && deviceGap > _maxDeviceGapMs) {
      _maxDeviceGapMs = deviceGap;
    }
    final burst = arrivalGap <= _burstArrivalGapMs &&
        deviceGap >= expectedPacketIntervalMs * 2;
    if (burst) {
      _burstPackets += 1;
    }
    final positiveDeviceGap = deviceGap > 0 ? deviceGap : 0;
    unawaited(_linkLogger.maybeLogGap(
      arrivalGapMs: arrivalGap,
      deviceGapMs: positiveDeviceGap,
      burst: burst,
      deviceMs: deviceMs,
      packetAgeMs: 0,
      status: _status,
      bridgeUrl: _activeBridgeUrl,
      sseSkipped: sseSkipped,
      sseDropped: sseDropped,
      softapStations: softapStations,
      connected: _connected,
      degraded: _degraded,
      burstPackets: _burstPackets,
      packetsReceived: _packetsReceived,
    ));
  }

  void _notifyTelemetryUi() {
    if (_disposed) return;
    if (_uiCoalesceTimer?.isActive ?? false) return;
    _uiCoalesceTimer = Timer(
      const Duration(milliseconds: uiFrameMs),
      () {
        _uiCoalesceTimer = null;
        if (!_disposed) notifyListeners();
      },
    );
  }

  void _notifyImmediate() {
    _uiCoalesceTimer?.cancel();
    _uiCoalesceTimer = null;
    if (!_disposed) notifyListeners();
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_disposed) return;
      _checkStale();
    });
  }

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void _checkStale() {
    if (!_connected || _disposed || _connecting) return;
    final age = packetAgeMs;
    if (age == null) return;

    if (age >= staleReconnectMs) {
      _status = 'Stale · ${age}ms · reconnecting';
      _degraded = true;
      _notifyImmediate();
      _logLink('stale_reconnect');
      unawaited(connect());
      return;
    }

    if (age >= staleDegradeMs) {
      final next = 'Degraded · ${age}ms · $linkDiagnostics';
      if (!_degraded || _status != next) {
        final entered = !_degraded;
        _degraded = true;
        _status = next;
        _notifyImmediate();
        if (entered) _logLink('degrade_enter');
      }
      return;
    }

    if (_degraded) {
      _degraded = false;
      _status = 'Live · $_activeBridgeUrl';
      _notifyImmediate();
      _logLink('degrade_exit');
      return;
    }
  }

  void _refreshLiveStatus() {
    if (_degraded) return;
    _status = 'Live · $_activeBridgeUrl';
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(bridgeUrlKey);
    // AP-only firmware: prefer 192.168.4.1; migrate old hotspot/mDNS default.
    if (saved == null ||
        saved == 'http://d400telemetry.local' ||
        saved == fallbackBridgeUrl) {
      _bridgeUrl = defaultBridgeUrl;
    } else {
      _bridgeUrl = saved;
    }
    await _linkLogger.init();
    _startWatchdog();
    await connect();
  }

  Future<void> setBridgeUrl(String url) async {
    final normalized = url.trim().replaceAll(RegExp(r'/+$'), '');
    _bridgeUrl = normalized.isEmpty ? defaultBridgeUrl : normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(bridgeUrlKey, _bridgeUrl);
    // Gap statistics describe one bridge; pointing at another invalidates them.
    _resetLinkStats();
    _logLink('bridge_url_change');
    await connect();
  }

  Future<void> startRideLog() async {
    await _linkLogger.startRideLog();
    _notifyImmediate();
  }

  Future<ShareResult?> shareRideLinkLog() => _linkLogger.shareLog();

  List<String> _connectCandidates() {
    final candidates = <String>[];
    void add(String url) {
      if (!candidates.contains(url)) candidates.add(url);
    }

    add(_bridgeUrl);
    add(defaultBridgeUrl);
    add(fallbackBridgeUrl);
    return candidates;
  }

  Future<void> connect() async {
    if (_disposed) return;
    if (_connecting) return;
    _connecting = true;
    try {
      await _disconnectSse();
      _logLink('connect_attempt');

      for (final candidate in _connectCandidates()) {
        if (_disposed) return;
        _status = 'Connecting to $candidate…';
        _notifyImmediate();
        if (await _connectTo(candidate)) return;
      }

      _connected = false;
      _degraded = false;
      _status = 'Demo mode · bridge offline';
      _notifyImmediate();
      _logLink('demo_fallback');
      _startDemo();
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  Future<bool> _connectTo(String baseUrl) async {
    final client = http.Client();
    final uri = Uri.parse('$baseUrl/events');

    try {
      final request = http.Request('GET', uri);
      request.headers['Accept'] = 'text/event-stream';
      request.headers['Cache-Control'] = 'no-cache';

      final response = await client.send(request).timeout(connectTimeout);
      if (response.statusCode != 200) {
        client.close();
        return false;
      }

      _client = client;
      _activeBridgeUrl = baseUrl;
      _connected = true;
      _degraded = false;
      _refreshLiveStatus();
      _stopDemo();
      _notifyImmediate();
      _logLink('connect');

      final buffer = StringBuffer();
      _sseSub = response.stream.transform(utf8.decoder).listen(
        (chunk) {
          buffer.write(chunk);
          var content = buffer.toString();
          var boundary = content.indexOf('\n\n');
          while (boundary >= 0) {
            final block = content.substring(0, boundary);
            content = content.substring(boundary + 2);
            _parseSseBlock(block);
            boundary = content.indexOf('\n\n');
          }
          buffer
            ..clear()
            ..write(content);
        },
        onError: (_) {
          _logLink('disconnect_error');
          _scheduleReconnect();
        },
        onDone: () {
          _logLink('disconnect_done');
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
      return true;
    } catch (_) {
      client.close();
      return false;
    }
  }

  void _parseSseBlock(String block) {
    for (final line in block.split('\n')) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trimLeft();
      if (payload.isEmpty) continue;
      try {
        final json = jsonDecode(payload) as Map<String, dynamic>;
        _telemetry = Telemetry.fromJson(json);
        if (_telemetry.sseSkipped != null) {
          _lastSseSkipped = _telemetry.sseSkipped;
        }
        if (_telemetry.sseDropped != null) {
          _lastSseDropped = _telemetry.sseDropped;
        }
        _recordArrival(_telemetry.ms);
        if (_degraded) {
          _degraded = false;
          _refreshLiveStatus();
          _logLink('degrade_exit');
        }
        _notifyTelemetryUi();
      } catch (_) {
        // Ignore malformed packets.
      }
    }
  }

  void _startDemo() {
    _demoTimer ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_connected || _disposed) return;
      _demoSeq += 1;
      final elapsed = _demoClock.elapsedMilliseconds / 1000.0;
      _telemetry = Telemetry.demo(elapsed: elapsed, seq: _demoSeq);
      _notifyTelemetryUi();
    });
  }

  void _stopDemo() {
    _demoTimer?.cancel();
    _demoTimer = null;
  }

  void _scheduleReconnect() {
    if (_disposed || _connecting) return;
    _connected = false;
    _degraded = false;
    _status = 'Reconnecting…';
    _notifyImmediate();
    _startDemo();

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), connect);
  }

  Future<void> _disconnectSse() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _sseSub?.cancel();
    _sseSub = null;
    _client?.close();
    _client = null;
  }

  Future<bool> resetTrip(int slot) async {
    final resetBaseUrl = _activeBridgeUrl;
    var resetSucceeded = false;

    // Drop the SSE client briefly so a single-socket ESP32 path can accept the
    // reset request without racing the stream writer.
    await _disconnectSse();
    _status = 'Resetting Trip $slot…';
    _notifyImmediate();
    await Future<void>.delayed(const Duration(milliseconds: 250));

    try {
      final uri = Uri.parse('$resetBaseUrl/trip/reset?slot=$slot');
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final res = await http.get(uri).timeout(connectTimeout);
          if (res.statusCode == 200) {
            final json = jsonDecode(res.body) as Map<String, dynamic>;
            resetSucceeded = json['ok'] == true;
          }
          break;
        } catch (_) {
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
      }
    } finally {
      if (!_disposed) unawaited(connect());
    }
    return resetSucceeded;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopDemo();
    _stopWatchdog();
    _uiCoalesceTimer?.cancel();
    _reconnectTimer?.cancel();
    _disconnectSse();
    super.dispose();
  }
}
