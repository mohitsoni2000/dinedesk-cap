import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'log.dart';

/// Opens this app's own page in the OS settings.
///
/// The camera-permission dead end needed it: the scan screen told the operator
/// to "allow camera access in Settings" and then gave them no way to get
/// there. Pairing is the very first thing a device does, so a waiter who
/// fat-fingers "Don't Allow" is stuck outside the app with a sentence of
/// instructions and no button.
///
/// The two platforms need different mechanisms:
///
///  * iOS exposes `app-settings:`, which `url_launcher` can open directly.
///  * Android needs an `ACTION_APPLICATION_DETAILS_SETTINGS` Intent, which no
///    URL scheme covers — hence the method channel into [MainActivity].
class AppSettingsLauncher {
  AppSettingsLauncher._();

  static const _channel = MethodChannel('crew/settings');

  /// Returns false if the OS refused, so the caller can leave the written
  /// instructions on screen rather than implying something happened.
  static Future<bool> open() async {
    try {
      if (Platform.isAndroid) {
        final ok = await _channel.invokeMethod<bool>('openAppSettings');
        return ok ?? false;
      }
      if (Platform.isIOS) {
        return launchUrl(Uri.parse('app-settings:'));
      }
      return false;
    } catch (e) {
      logE('[Settings]', 'Could not open app settings: $e');
      return false;
    }
  }
}
