package com.example.capstone_monitor

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "capstone/connectivity")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sdk" -> result.success(Build.VERSION.SDK_INT)
                    "wifiSettings" -> {
                        startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                        result.success(null)
                    }
                    "collectorIpv4" -> {
                        val manager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
                        val network = manager.activeNetwork
                        val caps = manager.getNetworkCapabilities(network)
                        val lan = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true ||
                            caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true
                        val address = if (lan) manager.getLinkProperties(network)?.linkAddresses
                            ?.map { it.address }?.firstOrNull { it is java.net.Inet4Address && !it.isLoopbackAddress }
                            ?.hostAddress else null
                        result.success(address)
                    }
                    "network" -> {
                        val manager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
                        val caps = manager.getNetworkCapabilities(manager.activeNetwork)
                        result.success(when {
                            caps == null -> "No active network"
                            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
                            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
                            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "Mobile data"
                            else -> "Other network"
                        })
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
