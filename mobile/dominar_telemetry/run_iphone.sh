#!/usr/bin/env bash
# One-time iPhone setup + run helper for dominar_telemetry.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

export PATH="$HOME/Downloads/flutter/bin:$PATH"

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter not found at ~/Downloads/flutter. Download and extract Flutter 3.27+ first."
  exit 1
fi

echo "=== Step 1: Accept Xcode license (requires password) ==="
echo "Run once if flutter doctor shows an unsigned Xcode license:"
echo "  sudo xcodebuild -license accept"
echo "  sudo xcodebuild -runFirstLaunch"
echo ""

if ! xcodebuild -checkFirstLaunchStatus 2>/dev/null; then
  echo "Xcode first-launch components are not ready yet."
  echo "Open Xcode once, or run: sudo xcodebuild -runFirstLaunch"
  echo ""
fi

if ! command -v pod >/dev/null 2>&1; then
  echo "=== Step 2: Install CocoaPods ==="
  if command -v brew >/dev/null 2>&1; then
    echo "Installing via Homebrew..."
    brew install cocoapods
  else
    echo "Install CocoaPods: https://guides.cocoapods.org/using/getting-started.html"
    exit 1
  fi
fi

echo "=== Step 3: Fetch dependencies ==="
flutter pub get
cd ios && pod install && cd ..

echo ""
echo "=== Step 4: Connect iPhone XR via USB, trust this Mac ==="
flutter devices

echo ""
echo "=== Step 5: Run on iPhone ==="
echo "Join D400Telemetry Wi-Fi on the phone, then:"
echo "  flutter run"
echo ""
echo "Preview in Chrome (demo mode, no bike):"
echo "  flutter run -d chrome"
