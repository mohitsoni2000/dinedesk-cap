import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'log.dart';

const String _tag = '[KeepAlive]';

/// Dart-side switch for the Android foreground service that holds the Wi-Fi
/// locks (see `NetworkKeepAliveService.kt`), plus the foreground-only
/// low-latency Wi-Fi lock and the one-time battery-optimisation prompt state.
///
/// PLAY CONSOLE: the service declares `FOREGROUND_SERVICE_CONNECTED_DEVICE`,
/// which Play Console will not accept without a demo video of the permission in
/// use. Record that video before publishing a build containing this feature
/// (the first attempt, bf693f5, was pulled from a release for exactly this).
///
/// Every method is a no-op that reports failure on iOS and in tests with no
/// native host, so callers never need a platform check of their own: iOS has no
/// equivalent knob. Nothing here is load-bearing for correctness. If the
/// service refuses to start (Android 12+ rejects a background start, some OEM
/// skins simply won't) the app falls back to reconnect-on-resume.
abstract final class NetworkKeepAlive {
  static const _channel = MethodChannel('crew/network');

  /// SharedPreferences key of the "Keep connection alive in background" toggle.
  static const prefKey = 'setting_keepalive_background';
  static const _batteryPromptedKey = 'keepalive_battery_prompted';

  static bool _running = false;

  /// Whether this build's manifest declares the foreground service. False
  /// until the Play Console permission declaration (with its demo video) is
  /// filed: the service and its FOREGROUND_SERVICE_* permissions are left out
  /// of AndroidManifest.xml (see the comment there), so starting it would be a
  /// silent no-op that reports success. While false, [start] refuses, the
  /// Settings toggle is hidden and the battery prompt never appears; the
  /// foreground low-latency lock and reconnect-on-resume still apply.
  @visibleForTesting
  static bool serviceShipped = false;

  /// Read-only view of [serviceShipped] for the UI (Settings hides the toggle).
  static bool get isServiceShipped => serviceShipped;

  /// Tests set this to pretend to be Android on the host machine.
  @visibleForTesting
  static bool? debugIsAndroid;

  static bool get _android => debugIsAndroid ?? Platform.isAndroid;

  /// True once [start] has succeeded and [stop] hasn't been called since.
  /// Reflects our intent, not a live query of the service.
  static bool get isRunning => _running;

  /// Default ON: a restaurant shift is the whole point of the app.
  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefKey) ?? true;
  }

  /// Persists the toggle and applies it immediately: turning it off stops the
  /// service; turning it on starts it (the caller only offers the toggle while
  /// paired, so no pairing check is needed here).
  static Future<void> setEnabled(bool enabled, {String? restaurant}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, enabled);
    if (enabled) {
      await start(restaurant: restaurant);
    } else {
      await stop();
    }
  }

  /// Starts the service if the toggle is on. Returns whether it is running.
  static Future<bool> start({String? restaurant}) async {
    if (!_android) return false;
    if (!serviceShipped) {
      _running = false;
      return false;
    }
    if (!await isEnabled()) return false;
    final ok = await _invoke<bool>(
          'startKeepAlive',
          <String, dynamic>{'restaurant': restaurant},
        ) ??
        false;
    _running = ok;
    logD(
        _tag, ok ? 'foreground service started' : 'foreground service refused');
    return ok;
  }

  /// Always asks the host, even when we think nothing runs: a sticky service
  /// can outlive the Dart isolate that started it, and unpair/logout must stop
  /// it regardless.
  static Future<void> stop() async {
    if (!_android) return;
    _running = false;
    await _invoke<bool>('stopKeepAlive');
    logD(_tag, 'foreground service stopped');
  }

  /// Holds the foreground-only Wi-Fi lock (LOW_LATENCY on Android 10+, else
  /// HIGH_PERF) while the app is on screen. Independent of the service.
  static Future<void> setLowLatencyLock(bool held) async {
    if (!_android) return;
    await _invoke<bool>('setLowLatencyLock', held);
  }

  /// False means an OEM battery manager may still freeze or kill the app
  /// mid-shift despite the foreground service.
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!_android) return true;
    return await _invoke<bool>('isIgnoringBatteryOptimizations') ?? true;
  }

  /// One-time: true only on Android, only if the OS still optimises this app,
  /// and only if we have never asked. The prompt must be dismissible, so call
  /// [markBatteryPrompted] as soon as it is shown, not when it is accepted.
  static Future<bool> shouldPromptBatteryOptimization() async {
    if (!_android) return false;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_batteryPromptedKey) ?? false) return false;
    return !await isIgnoringBatteryOptimizations();
  }

  static Future<void> markBatteryPrompted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_batteryPromptedKey, true);
  }

  /// Sends the operator to the system battery-optimisation list, where they
  /// select this app themselves.
  static Future<bool> openBatteryOptimizationSettings() async {
    if (!_android) return false;
    return await _invoke<bool>('requestIgnoreBatteryOptimizations') ?? false;
  }

  static Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null; // unit tests, or an older host build
    } catch (err) {
      logE(_tag, '$method failed', err);
      return null;
    }
  }
}
