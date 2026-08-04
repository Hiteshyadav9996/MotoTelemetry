# Dominar 400 Flutter Telemetry App

Native iPhone app that replaces the browser dashboard. Connects to your ESP32 passive-only bridge over Wi-Fi and provides two swipeable landscape views:

1. **Full** — complete dashboard (RPM arc, speed, gear, throttle, trip, aux metrics) matching `firmware/esp32_wifi_can_bridge/data/index.html`
2. **Nav** — left half compact cluster (vertical RPM bar, speed, gear, trip/odo swipe) + right half Google Maps

## Prerequisites

- Flutter SDK 3.2+ ([install guide](https://docs.flutter.dev/get-started/install))
- Xcode (for iPhone XR builds)
- Google Maps API key with **Maps SDK for iOS** enabled

## First-time setup

Flutter SDK is at `~/Downloads/flutter`. Add to your shell profile:

```bash
export PATH="$HOME/Downloads/flutter/bin:$PATH"
```

Then bootstrap the project (already done once — safe to re-run):

```bash
cd mobile/dominar_telemetry
./setup.sh
flutter pub get
```

**Status:** platform folders generated, iOS permissions patched, Google Maps configuration wired, code compiles and tests pass.

### Google Maps API key

1. Create a key in [Google Cloud Console](https://console.cloud.google.com/)
2. Enable these APIs (APIs & Services → Library):
   - **Maps SDK for iOS** (map tiles)
   - **Places API** (destination search suggestions)
   - **Routes API** (motorbike / two-wheeler route line)
   - **Directions API** (fallback car route)
   - **Geocoding API** (fallback address lookup)
3. Under Credentials → your key → **API restrictions**, allow the four APIs above.
   For search/routing HTTP calls from the app, set **Application restrictions** to
   **None** (or create a second key with API-only restrictions). An iOS-bundle-only
   key works for map tiles but often blocks Places/Directions REST calls.
4. Copy the local secrets template:

```bash
cp ios/Flutter/Secrets.xcconfig.example ios/Flutter/Secrets.xcconfig
```

5. Put the key in the ignored `ios/Flutter/Secrets.xcconfig` file:

```text
GOOGLE_MAPS_API_KEY=AIza_YOUR_REAL_IOS_KEY
```

6. Delete the app from the iPhone, then run `flutter clean`,
   `flutter pub get`, and `flutter run` so the native key is embedded again.

On the **Nav** page (swipe from full dashboard): use the **Search destination…**
bar on the map, pick a place, and a **motorbike route** (Google `TWO_WHEELER` mode) is drawn.
Tap the target button (bottom-right) to recenter on your position.

### Connect to the bike

1. Join the ESP32 AP: **D400Telemetry** (password: `dominar400`)
2. Bridge default URL: `http://192.168.4.1`
3. Tap the status chip (top-left) to change the bridge URL if needed

Telemetry streams via **Server-Sent Events** from `/events` — same protocol as the web dashboard.

## Run on iPhone XR

Requires **Xcode** (App Store) and **CocoaPods**:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
sudo gem install cocoapods   # one-time

cd mobile/dominar_telemetry
export PATH="$HOME/Downloads/flutter/bin:$PATH"
cd ios && pod install && cd ..
flutter devices                # confirm iPhone is listed
flutter run -d <your-iphone-id>
```

Landscape orientation is locked automatically. Swipe left/right to switch between Full and Nav views.

## Architecture

```
ESP32 (passive-only)          Flutter app
─────────────────────         ─────────────────────────────
CAN bus → decode              TelemetryService (SSE /events)
       → /events SSE    ───►  ├─ FullDashboard (Page 0)
       → /telemetry.json       └─ SplitNavigationView (Page 1)
                                    ├─ CompactDashboard (50%)
                                    └─ GoogleMap (50%)
```

## Demo mode

When the bridge is offline, the app plays the same animated demo telemetry as the web UI so you can develop the layout without the bike connected.

## Trip gestures (Full view)

- **Swipe** trip card left/right → switch Trip 1 / Trip 2
- **Long-press** trip card → reset current trip (calls `/trip/reset?slot=N`)

## Trip gestures (Compact / Nav view)

- **Swipe** trip readout → cycle Trip 1 → Trip 2 → Odometer
