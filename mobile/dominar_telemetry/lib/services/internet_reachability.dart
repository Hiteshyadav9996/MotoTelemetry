import 'dart:async';

import 'package:http/http.dart' as http;

/// Quick check that the phone can reach Google (cellular or home Wi‑Fi).
/// The ESP32 D400Telemetry AP has no internet — routes fail without cellular.
class InternetReachability {
  static const _probeUrls = [
    'https://www.google.com/generate_204',
    'https://maps.googleapis.com/maps/api/staticmap?center=0,0&zoom=1&size=1x1',
  ];

  static Future<bool> canReachGoogle({Duration timeout = const Duration(seconds: 5)}) async {
    for (final url in _probeUrls) {
      try {
        final response = await http.head(Uri.parse(url)).timeout(timeout);
        if (response.statusCode >= 200 && response.statusCode < 500) {
          return true;
        }
      } catch (_) {
        // Try next probe.
      }
    }
    return false;
  }
}
