import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'log.dart';

class AppSettingsLauncher {
  AppSettingsLauncher._();

  static const _channel = MethodChannel('crew/settings');

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
