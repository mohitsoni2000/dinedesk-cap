package com.command.crew

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// local_auth requires a FragmentActivity host.
class MainActivity : FlutterFragmentActivity() {
    private var networkBinder: NetworkBinder? = null
    private var lowLatencyLock: WifiManager.WifiLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Lets Dart classify the device tier so ambient effects can switch off
        // on low-RAM hardware. Read once per install and cached on the Dart
        // side — this handler is not on any hot path.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "crew/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "deviceTier") {
                    val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val info = ActivityManager.MemoryInfo()
                    am.getMemoryInfo(info)
                    result.success(
                        mapOf(
                            "isLowRamDevice" to am.isLowRamDevice,
                            "totalMemMb" to (info.totalMem / (1024 * 1024)).toInt()
                        )
                    )
                } else {
                    result.notImplemented()
                }
            }

        // Opens this app's own settings page, so the "allow camera access"
        // dead end on the pairing screen can offer a button instead of only
        // an instruction. iOS gets there through the `app-settings:` URL and
        // needs no channel; Android has no URL for it.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "crew/settings")
            .setMethodCallHandler { call, result ->
                if (call.method == "openAppSettings") {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.fromParts("package", packageName, null)
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                } else {
                    result.notImplemented()
                }
            }

        // Network resilience: process-wide Wi-Fi binding, foreground Wi-Fi lock
        // and the keep-alive foreground service. See NetworkBinder.kt and
        // NetworkKeepAliveService.kt for the why.
        val binder = NetworkBinder(this).also { networkBinder = it }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "crew/network/events")
            .setStreamHandler(binder)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "crew/network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bindWifi" -> binder.bindWifi(result)
                    "unbind" -> {
                        binder.unbind()
                        result.success(null)
                    }
                    "setLowLatencyLock" ->
                        result.success(setLowLatencyLock(call.arguments as? Boolean ?: false))
                    "startKeepAlive" -> {
                        val intent = Intent(this, NetworkKeepAliveService::class.java)
                            .setAction(NetworkKeepAliveService.ACTION_START)
                            .putExtra(
                                NetworkKeepAliveService.EXTRA_RESTAURANT,
                                call.argument<String>("restaurant")
                            )
                        result.success(startKeepAliveService(intent))
                    }
                    "stopKeepAlive" -> result.success(stopKeepAliveService())
                    "isIgnoringBatteryOptimizations" ->
                        result.success(isIgnoringBatteryOptimizations())
                    "requestIgnoreBatteryOptimizations" ->
                        result.success(openBatteryOptimizationSettings())
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        setLowLatencyLock(false)
        // Releases the callback and process binding; the next process start
        // re-binds from Dart.
        networkBinder?.unbind()
        super.onDestroy()
    }

    /**
     * Foreground-only Wi-Fi lock. API 29+ uses LOW_LATENCY (non-deprecated, but
     * only engages with the app foregrounded and screen on, which is exactly
     * when this is held); older versions use HIGH_PERF.
     */
    private fun setLowLatencyLock(enable: Boolean): Boolean = try {
        if (enable) {
            if (lowLatencyLock == null) {
                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE)
                    as WifiManager
                @Suppress("DEPRECATION")
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                lowLatencyLock = wifi.createWifiLock(mode, "crew:wifi-foreground")
                    .apply { setReferenceCounted(false) }
            }
            lowLatencyLock?.takeUnless { it.isHeld }?.acquire()
        } else {
            lowLatencyLock?.takeIf { it.isHeld }?.release()
        }
        true
    } catch (err: Exception) {
        false
    }

    private fun startKeepAliveService(intent: Intent): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        true
    } catch (err: Exception) {
        // Android 12+ throws when the app is judged to be in the background.
        // Report it so Dart falls back to reconnect-on-resume.
        false
    }

    private fun stopKeepAliveService(): Boolean = try {
        // stopService, not a STOP intent via startService: a plain start from
        // the background can throw, and stopping must never fail that way.
        stopService(Intent(this, NetworkKeepAliveService::class.java))
        true
    } catch (err: Exception) {
        false
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return true
        return power.isIgnoringBatteryOptimizations(packageName)
    }

    // Opens the battery-optimisation LIST, not the direct
    // ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS dialog: Play policy restricts
    // the direct intent (and its permission) to apps whose core function needs
    // it, and one extra tap is cheaper than a rejected listing.
    private fun openBatteryOptimizationSettings(): Boolean = try {
        startActivity(
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        true
    } catch (err: Exception) {
        false
    }
}
