package com.dominar.dominar_telemetry

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var wifiGuard: WifiGuardHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val handler = WifiGuardHandler(applicationContext)
        wifiGuard = handler
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dominar.dominar_telemetry/wifi_guard",
        ).setMethodCallHandler { call, result -> handler.handle(call, result) }
    }

    override fun onDestroy() {
        wifiGuard?.unpinSoftAp()
        wifiGuard = null
        super.onDestroy()
    }
}
