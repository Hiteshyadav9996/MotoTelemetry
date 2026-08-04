import Flutter
import Network
import UIKit
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var mapsConfigured = false
  private var wifiPathMonitor: NWPathMonitor?
  private var wifiMonitorActive = false

  private func isValidMapsApiKey(_ key: String?) -> Bool {
    guard let key = key else { return false }
    return key.hasPrefix("AIza")
      && !key.contains("$(")
      && !key.uppercased().contains("REPLACE")
      && key.count >= 39
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let apiKey = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String,
       isValidMapsApiKey(apiKey) {
      GMSServices.provideAPIKey(apiKey)
      mapsConfigured = true
    } else {
      NSLog(
        "Google Maps is disabled: add GOOGLE_MAPS_API_KEY to "
          + "ios/Flutter/Secrets.xcconfig"
      )
    }

    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let mapsChannel = FlutterMethodChannel(
        name: "com.dominar/maps",
        binaryMessenger: controller.binaryMessenger
      )
      mapsChannel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "isConfigured":
          result(self?.mapsConfigured ?? false)
        case "getApiKey":
          if self?.isValidMapsApiKey(
            Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String
          ) == true {
            result(Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String)
          } else {
            result(nil)
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let wifiChannel = FlutterMethodChannel(
        name: "com.dominar.dominar_telemetry/wifi_guard",
        binaryMessenger: controller.binaryMessenger
      )
      wifiChannel.setMethodCallHandler { [weak self] call, result in
        self?.handleWifiGuard(call: call, result: result)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func handleWifiGuard(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pinSoftAp":
      // No Hotspot Configuration entitlement on the team profile — monitor Wi‑Fi
      // reachability only. The rider must join D400Telemetry manually in Settings.
      startWifiPathMonitor()
      result(true)
    case "unpinSoftAp":
      stopWifiPathMonitor()
      result(nil)
    case "getCurrentSsid":
      // Reading SSID requires Access WiFi Information + location; not provisioned.
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startWifiPathMonitor() {
    if wifiMonitorActive { return }
    wifiMonitorActive = true
    wifiPathMonitor?.cancel()
    let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    monitor.pathUpdateHandler = { path in
      if path.status != .satisfied {
        NSLog("Dominar WiFi guard: phone left Wi‑Fi — join D400Telemetry manually")
      }
    }
    monitor.start(queue: DispatchQueue(label: "com.dominar.wifi-guard"))
    wifiPathMonitor = monitor
  }

  private func stopWifiPathMonitor() {
    wifiMonitorActive = false
    wifiPathMonitor?.cancel()
    wifiPathMonitor = nil
  }
}
