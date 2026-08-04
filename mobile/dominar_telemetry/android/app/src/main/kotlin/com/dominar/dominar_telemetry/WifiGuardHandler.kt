package com.dominar.dominar_telemetry

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class WifiGuardHandler(private val context: Context) {
    private val connectivity =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var pinnedNetwork: Network? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pinSoftAp" -> pinSoftAp(call, result)
            "unpinSoftAp" -> {
                unpinSoftAp()
                result.success(null)
            }
            "getCurrentSsid" -> result.success(getCurrentSsid())
            else -> result.notImplemented()
        }
    }

    private fun pinSoftAp(call: MethodCall, result: MethodChannel.Result) {
        val ssid = call.argument<String>("ssid")
        val password = call.argument<String>("password")
        if (ssid.isNullOrEmpty() || password.isNullOrEmpty()) {
            result.success(false)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(false)
            return
        }

        unpinSoftAp()

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(password)
            .build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        val callback = object : ConnectivityManager.NetworkCallback() {
            private var finished = false

            private fun finish(value: Boolean) {
                if (finished) return
                finished = true
                result.success(value)
            }

            override fun onAvailable(network: Network) {
                pinnedNetwork = network
                connectivity.bindProcessToNetwork(network)
                finish(true)
            }

            override fun onUnavailable() {
                finish(false)
            }

            override fun onLost(network: Network) {
                if (pinnedNetwork == network) {
                    pinnedNetwork = null
                    connectivity.bindProcessToNetwork(null)
                }
            }
        }

        networkCallback = callback
        connectivity.requestNetwork(request, callback)
    }

    fun unpinSoftAp() {
        networkCallback?.let { connectivity.unregisterNetworkCallback(it) }
        networkCallback = null
        pinnedNetwork = null
        connectivity.bindProcessToNetwork(null)
    }

    private fun getCurrentSsid(): String? {
        val network = pinnedNetwork ?: connectivity.activeNetwork ?: return null
        val caps = connectivity.getNetworkCapabilities(network) ?: return null
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return null

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val wifiInfo = caps.transportInfo as? WifiInfo
            return normalizeSsid(wifiInfo?.ssid)
        }

        @Suppress("DEPRECATION")
        val wifiManager =
            context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        return normalizeSsid(wifiManager.connectionInfo?.ssid)
    }

    private fun normalizeSsid(raw: String?): String? {
        if (raw.isNullOrEmpty() || raw == "<unknown ssid>") return null
        return raw.trim('"')
    }
}
