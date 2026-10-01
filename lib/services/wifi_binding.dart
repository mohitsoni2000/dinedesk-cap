import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import 'link_monitor.dart' show NetworkEvent;
import 'log.dart';

const String _tag = '[WifiBinding]';

/// Pins the app's sockets to the Wi-Fi network, and reports network changes
/// the Dart side can't see on its own.
///
/// Why this exists (Android): when the Wi-Fi has no internet (a restaurant LAN
/// with the router's uplink down, or a captive-portal-ish AP) Android may route
/// "default" traffic over mobile data, or silently drop the Wi-Fi network
/// altogether — and a LAN desk is unreachable over mobile data. Binding the
/// process to the Wi-Fi `Network` keeps LAN traffic on the LAN. The native
/// half (Kotlin, channel names below) lives in `android/`; this is only the
/// Dart seam, and it must never be load-bearing: every failure degrades to
/// "unbound", exactly the behaviour before this existed.
abstract interface class WifiBinding {
  /// Binds the process to Wi-Fi. True iff a binding is now in place.
  Future<bool> bindWifi();

  Future<void> unbind();

  /// `available` / `lost` / `changed` network callbacks, with a network id when
  /// the platform has one.
  Stream<NetworkEvent> get events;
}

/// iOS (no equivalent) and tests with no native host.
class NoopWifiBinding implements WifiBinding {
  const NoopWifiBinding();

  @override
  Future<bool> bindWifi() async => false;

  @override
  Future<void> unbind() async {}

  @override
  Stream<NetworkEvent> get events => const Stream<NetworkEvent>.empty();
}

class AndroidWifiBinding implements WifiBinding {
  AndroidWifiBinding({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _method = methodChannel ?? const MethodChannel('crew/network'),
        _events = eventChannel ?? const EventChannel('crew/network/events');

  final MethodChannel _method;
  final EventChannel _events;

  @override
  Future<bool> bindWifi() async {
    try {
      return await _method.invokeMethod<bool>('bindWifi') ?? false;
    } on MissingPluginException {
      // No native half (older build, a test host): treat as unbound.
      return false;
    } on PlatformException catch (err) {
      logD(_tag, 'bindWifi failed: ${err.code} ${err.message}');
      return false;
    }
  }

  @override
  Future<void> unbind() async {
    try {
      await _method.invokeMethod<void>('unbind');
    } on MissingPluginException {
      // Nothing was bound.
    } on PlatformException catch (err) {
      logD(_tag, 'unbind failed: ${err.code} ${err.message}');
    }
  }

  @override
  Stream<NetworkEvent> get events {
    // Lazily and error-tolerant: a missing native EventChannel throws a
    // MissingPluginException into the stream on listen; swallow it so the
    // supervisor's subscription survives and the stream just stays quiet.
    return _events
        .receiveBroadcastStream()
        .map(NetworkEvent.fromMap)
        .where((e) => e != null)
        .cast<NetworkEvent>()
        .handleError((Object err) {
      logD(_tag, 'network events unavailable: $err');
    });
  }
}

/// The platform's binding: Android gets the real one, everything else a no-op.
WifiBinding createPlatformWifiBinding() {
  if (debugIsAndroid ?? Platform.isAndroid) return AndroidWifiBinding();
  return const NoopWifiBinding();
}

@visibleForTesting
bool? debugIsAndroid;
