package com.command.crew

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
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
    }
}
