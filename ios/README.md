# iOS SwiftUI skeleton

Create a new **iOS App** project in Xcode, choose SwiftUI, then copy these files into the project:

- `DominarTelemetryApp.swift`
- `Telemetry.swift`
- `UDPReceiver.swift`
- `TelemetryView.swift`

In your app target's Info.plist, add:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app receives telemetry from the motorcycle bridge on the local Wi-Fi network.</string>
```

Connect the iPhone XR to the ESP32 Wi-Fi AP (`D400Telemetry` by default). Run the app. It listens for UDP JSON packets on port `4210`.

For a quick UI test without the bike, keep using the laptop simulator and browser dashboard. The Swift app is for the phone integration stage.
