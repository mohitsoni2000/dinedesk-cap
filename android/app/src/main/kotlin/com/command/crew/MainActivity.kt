package com.command.crew

import android.app.ActivityManager
import android.content.Context
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
    }
}
