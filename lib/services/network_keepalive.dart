import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'log.dart';

const String _tag = '[KeepAlive]';

/// Dart-side switch for the Android foreground service that holds the Wi-Fi
/// locks (see `NetworkKeepAliveService.kt`). Every method is a no-op that
/// reports failure on iOS and in tests, so callers never need a platform check
/// of their own — iOS keeps a backgrounded socket alive on its own terms and
/// has no equivalent knob to turn.
///
/// Nothing here is load-bearing for correctness: if the service refuses to
/// start (Android 12+ can reject a background start, and some OEM skins simply
/// won't), the app falls back to the reconnect-on-resume path it used before
/// this existed. It degrades, it doesn't break.
abstract final class NetworkKeepAlive {
  static const _channel = MethodChannel('crew/network');

  static bool _running = false;

  /// True once [start] has succeeded and [stop] hasn't been called since.
  /// Reflects our intent, not a live query of the service.
  static bool get isRunning => _running;

  static Future<bool> start({String? restaurant}) async {
    if (!Platform.isAndroid) return false;
    final ok = await _invoke<bool>(
          'startKeepAlive',
          <String, dynamic>{'restaurant': restaurant},
        ) ??
        false;
    _running = ok;
    logD(_tag, ok ? 'foreground service started' : 'foreground service refused');
    return ok;
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid || !_running) return;
    _running = false;
    await _invoke<bool>('stopKeepAlive');
    logD(_tag, 'foreground service stopped');
  }

  /// Layers the low-latency Wi-Fi lock on while the app is actually on screen.
  /// Safe to call when the service isn't running — it just does nothing.
  static Future<void> setAppForeground(bool foreground) async {
    if (!Platform.isAndroid || !_running) return;
    await _invoke<bool>('setAppForeground', foreground);
  }

  /// False means an OEM battery manager may still freeze or kill the app
  /// mid-shift despite the foreground service.
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    return await _invoke<bool>('isIgnoringBatteryOptimizations') ?? true;
  }

  /// Sends the operator to the system battery-optimization list, where they
  /// select this app themselves.
  static Future<bool> openBatteryOptimizationSettings() async {
    if (!Platform.isAndroid) return false;
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
