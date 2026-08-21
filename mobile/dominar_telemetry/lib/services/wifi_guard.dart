import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Optional SoftAP pin. Wired USB Ethernet is the default path; pinning is off
/// so the phone can use another hotspot (or cellular) for maps.
///
/// Android: can bind a dedicated Wi‑Fi network (no internet route).
/// iOS: cannot auto-join SoftAP without the Hotspot Configuration entitlement.
class WifiGuard {
  WifiGuard({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.dominar.dominar_telemetry/wifi_guard';
  static const softApSsid = 'D400Telemetry';
  static const softApPass = 'dominar400';

  final MethodChannel _channel;
  Timer? _watchTimer;
  void Function(String foreignSsid)? onSsidDrift;

  /// Pin the process to [softApSsid]. Returns false when unsupported or denied.
  Future<bool> pinSoftAp() async {
    if (kIsWeb) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('pinSoftAp', {
        'ssid': softApSsid,
        'password': softApPass,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> unpinSoftAp() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('unpinSoftAp');
    } catch (_) {}
  }

  Future<String?> currentSsid() async {
    if (kIsWeb) return null;
    try {
      return await _channel.invokeMethod<String>('getCurrentSsid');
    } catch (_) {
      return null;
    }
  }

  /// Re-pin when the phone joins a different SSID while the app is foreground.
  void startWatching({required bool Function() shouldWatch}) {
    _watchTimer?.cancel();
    _watchTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!shouldWatch()) return;
      final ssid = await currentSsid();
      if (ssid == null || ssid.isEmpty) return;
      if (ssid == softApSsid) return;
      onSsidDrift?.call(ssid);
      await pinSoftAp();
    });
  }

  void stopWatching() {
    _watchTimer?.cancel();
    _watchTimer = null;
  }

  Future<void> dispose() async {
    stopWatching();
    await unpinSoftAp();
  }
}
