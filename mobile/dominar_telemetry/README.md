# Dominar 400 Flutter Telemetry App

Native iPhone app that replaces the browser dashboard. Connects to your ESP32 passive-only bridge over Wi-Fi and provides two swipeable landscape views:

1. **Full** — complete dashboard (RPM arc, speed, gear, throttle, trip, aux metrics) matching `firmware/esp32_wifi_can_bridge/data/index.html`
2. **Nav** — three-column layout: vertical RPM bar | Google Navigation map | speed/gear/trip readout

Navigation uses Google's **Navigation SDK** with built-in turn-by-turn UI (same engine as Google Maps mobile), motorbike routing, voice guidance, lane guidance, and traffic-aware rerouting.

## Prerequisites

- Flutter SDK 3.2+ ([install guide](https://docs.flutter.dev/get-started/install))
- Xcode (for iPhone builds)
- iOS 16.0+ on device
- Google Maps API key with **Navigation SDK for iOS** enabled

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

**Status:** platform folders generated, iOS permissions patched, Google Navigation SDK wired, code compiles and tests pass.

### Google Maps / Navigation API key

1. Create a key in [Google Cloud Console](https://console.cloud.google.com/)
2. Enable these APIs (APIs & Services → Library):
   - **Navigation SDK for iOS** (turn-by-turn navigation — required)
   - **Maps SDK for iOS** (map tiles)
   - **Places API** (destination search suggestions)
   - **Geocoding API** (address lookup fallback)
3. Under Credentials → your key → **API restrictions**, allow the four APIs above.
   For search HTTP calls from the app, set **Application restrictions** to
   **None** (or create a second key with API-only restrictions). An iOS-bundle-only
   key works for map tiles but often blocks Places REST calls.
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

### Troubleshooting route calculation

**Yellow circle on the map** — GPS is still acquiring a fix. Go outdoors; wait for a solid blue dot before searching for a route.

**"Network error while calculating route"** — common causes:

1. **No internet on the telemetry link** — USB Ethernet and `D400Telemetry` Wi-Fi have no WAN. Route calculation needs cellular or another phone’s hotspot. On USB NCM, join that hotspot *and* keep Ethernet Router blank if Maps still fails.
2. **Billing not linked** — Navigation SDK requires a billing account on the Google Cloud project (free tier still needs a card on file).
3. **Wrong API key restriction** — For the native map + routing key, set **Application restrictions → iOS apps** with bundle ID `com.hitesh.dominarTelemetry`. Under **API restrictions**, allow only:
   - Navigation SDK
   - Maps SDK for iOS
   - Places API
   - Geocoding API  
   You do **not** need Directions API or Routes API for the Navigation SDK (those are REST-only).
4. **Key not in the app** — Confirm `ios/Flutter/Secrets.xcconfig` exists with a real `GOOGLE_MAPS_API_KEY=AIza...` (not the example placeholder).

Check denied requests: Google Cloud Console → **APIs & Services → Metrics** (filter Navigation SDK / Maps SDK for iOS).

**First navigation use:** The app shows Google's Navigation Terms & Conditions dialog. You must accept once before turn-by-turn guidance works.

On the **Nav** page (swipe from full dashboard): use the **Search destination…**
bar, pick a place, tap **Start**, and Google Navigation takes over with built-in
motorbike routing (`TWO_WHEELER` mode), voice prompts, and traffic rerouting.
Tap the fullscreen button during navigation for a Google Maps–style full-width view.

### Connect to the bike

1. Plug ESP32 USB-C into the Lightning camera adapter (USB NCM) **or** join **D400Telemetry** (password: `dominar400`) for Wi-Fi firmware
2. Bridge default URL: `http://192.168.5.1` (USB). Wi-Fi fallback: `http://192.168.4.1`
3. Tap the status chip (top-left) to change the bridge URL if needed

Telemetry streams via **Server-Sent Events** from `/events` — same protocol as the web dashboard.

## Run on iPhone

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
       → /telemetry.json       └─ NavDashboardView (Page 1)
                                    ├─ RpmVerticalBar
                                    ├─ GoogleMapsNavigationView (Navigation SDK)
                                    └─ NavDriveReadout
```

## Demo mode

When the bridge is offline, the app plays the same animated demo telemetry as the web UI so you can develop the layout without the bike connected.

## Trip gestures (Full view)

- **Swipe** trip card left/right → switch Trip 1 / Trip 2
- **Long-press** trip card → reset current trip (calls `/trip/reset?slot=N`)

## Trip gestures (Compact / Nav view)

- **Swipe** trip readout → cycle Trip 1 → Trip 2 → Odometer
