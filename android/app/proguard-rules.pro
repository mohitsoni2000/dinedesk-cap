# R8/ProGuard rules for the release build. Enabling minification/resource
# shrinking (build.gradle.kts) is the single highest-payoff cold-start lever
# left unaddressed on this perf branch — a plugin-heavy app (11+ native
# Android plugins) pays real per-launch dex/class-verification cost for
# every unshrunk method, and low-end/low-RAM Android hardware is exactly
# where that shows up.
#
# NEEDS A REAL-DEVICE SMOKE TEST BEFORE SHIPPING: a clean build with no R8
# warnings proves the *configuration* is consistent, not that every runtime
# code path (pairing, socket auth, biometric unlock, QR scan, printing)
# still works post-shrink. Most plugins below already ship their own
# consumer-rules.pro that R8 merges in automatically; the explicit keeps
# here are belt-and-suspenders for the handful of packages most likely to
# lean on reflection or platform-channel method names.

# Flutter engine / embedding — required by every Flutter Android app.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-dontwarn io.flutter.embedding.**

# flutter_secure_storage — AndroidKeyStore + EncryptedSharedPreferences.
-keep class androidx.security.crypto.** { *; }
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# local_auth — BiometricPrompt.
-keep class androidx.biometric.** { *; }

# mobile_scanner / ML Kit barcode scanning.
-keep class com.google.mlkit.vision.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-dontwarn com.google.mlkit.**

# flutter_local_notifications.
-keep class com.dexterous.** { *; }

# home_widget (AppWidgetProvider subclasses).
-keep class * extends android.appwidget.AppWidgetProvider

# Play Core (in_app_update) — split-install reflection the Flutter template
# itself warns about.
-keep class com.google.android.play.core.** { *; }
-dontwarn com.google.android.play.core.**

# General Android platform-channel/reflection safety net: don't strip
# anything with a native method signature (JNI lookups are name-based and
# invisible to R8's call-graph analysis).
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep enum values()/valueOf() — reflection-based, R8 can't see the call
# sites that need them for any plugin using enum-backed platform channels.
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}
