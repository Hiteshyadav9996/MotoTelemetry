#!/usr/bin/env bash
# Bootstrap platform folders and iOS permissions for dominar_telemetry.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# Prefer Flutter in Downloads if not on PATH
if ! command -v flutter >/dev/null 2>&1; then
  if [[ -x "$HOME/Downloads/flutter/bin/flutter" ]]; then
    export PATH="$HOME/Downloads/flutter/bin:$PATH"
  else
    echo "Flutter SDK not found. Install from https://docs.flutter.dev/get-started/install"
    exit 1
  fi
fi

echo "Using $(flutter --version | head -1)"

echo "→ flutter create (platform folders)"
flutter create . --org com.dominar --project-name dominar_telemetry

echo "→ flutter pub get"
flutter pub get

PLIST="ios/Runner/Info.plist"
if [[ -f "$PLIST" ]]; then
  echo "→ Patch Info.plist for location + local network"
  /usr/libexec/PlistBuddy -c "Add :NSLocationWhenInUseUsageDescription string 'Show your position on the navigation map while riding.'" "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :NSLocalNetworkUsageDescription string 'Receive live telemetry from the Dominar ESP32 bridge on the bike Wi-Fi network.'" "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :io.flutter.embedded_views_preview bool true" "$PLIST" 2>/dev/null || true
fi

echo ""
echo "Done. Next steps:"
echo "  1. cp ios/Flutter/Secrets.xcconfig.example ios/Flutter/Secrets.xcconfig"
echo "  2. Add a valid Maps SDK for iOS key to Secrets.xcconfig"
echo "  3. Connect iPhone with internet access, then run: flutter run"
