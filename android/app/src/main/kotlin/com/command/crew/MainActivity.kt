package com.command.crew

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// local_auth requires a FragmentActivity host.
class MainActivity : FlutterFragmentActivity() {
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

        // Network resilience controls. See NetworkKeepAliveService.kt for what
        // the service actually holds and why; this channel is only the switch.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "crew/network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startKeepAlive" -> {
                        val intent = Intent(this, NetworkKeepAliveService::class.java)
                            .setAction(NetworkKeepAliveService.ACTION_START)
                            .putExtra(
                                NetworkKeepAliveService.EXTRA_RESTAURANT,
                                call.argument<String>("restaurant")
                            )
                        result.success(startKeepAliveService(intent))
                    }

                    "stopKeepAlive" -> {
                        result.success(
                            sendServiceAction(NetworkKeepAliveService.ACTION_STOP)
                        )
                    }

                    // Layers the (screen-on, foreground-only) low-latency Wi-Fi
                    // lock on top of the always-held high-perf one.
                    "setAppForeground" -> {
                        val foreground = call.arguments as? Boolean ?: false
                        result.success(
                            sendServiceAction(
                                if (foreground) {
                                    NetworkKeepAliveService.ACTION_APP_FOREGROUNDED
                                } else {
                                    NetworkKeepAliveService.ACTION_APP_BACKGROUNDED
                                }
                            )
                        )
                    }

                    "isIgnoringBatteryOptimizations" ->
                        result.success(isIgnoringBatteryOptimizations())

                    // Opens the system dialog. Deliberately NOT the direct
                    // ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS intent with a
                    // package extra — Play policy restricts that to apps whose
                    // core function genuinely requires it, and a rejected
                    // listing is a worse outcome than one extra tap. This lands
                    // the operator on the battery-optimization list where they
                    // pick the app themselves.
                    "requestIgnoreBatteryOptimizations" ->
                        result.success(openBatteryOptimizationSettings())

                    else -> result.notImplemented()
                }
            }
    }

    private fun startKeepAliveService(intent: Intent): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        true
    } catch (err: Exception) {
        // Android 12+ throws if the app is judged to be in the background at
        // this moment. Report the failure so Dart can fall back to the plain
        // reconnect-on-resume path instead of assuming a live service.
        false
    }

    private fun sendServiceAction(action: String): Boolean = try {
        startService(
            Intent(this, NetworkKeepAliveService::class.java).setAction(action)
        )
        true
    } catch (err: Exception) {
        false
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return true
        return power.isIgnoringBatteryOptimizations(packageName)
    }

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
