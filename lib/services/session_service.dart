import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'biometric_service.dart';
import 'log.dart';

const String _tag = '[Session]';

/// Ceiling on how many alternate desk addresses a pairing carries — from the
/// QR's `hosts` fan-out and from addresses the desk has since moved off. A
/// desk realistically has two or three interfaces; every entry past that is
/// one more address the phone probes on each repair, so the list is capped
/// rather than allowed to grow for the life of the pairing.
const int maxPairingAltHosts = 8;

class PairingInfo {
  final String host;
  final int port;
  final String token;

  final String? deviceSecret;

  final String? deskInstanceId;

  /// Other addresses the same desk said it can be reached on, from the QR's
  /// `hosts` parameter. A desk on both Ethernet and Wi-Fi can only put one of
  /// them in [host], and it has no way of knowing which network the phone is
  /// on — these are the rest, probed when [host] turns out to be unreachable.
  /// Empty for a QR minted by a Desk build older than multi-host pairing.
  final List<String> altHosts;
  const PairingInfo(
      {required this.host,
      required this.port,
      required this.token,
      this.deviceSecret,
      this.deskInstanceId,
      this.altHosts = const []});

  /// The same pairing, relocated to [ip]:[port].
  ///
  /// The address being moved off is kept as an alternate, at the front: it is
  /// a real interface of the same desk, and on a multi-homed desk it is
  /// exactly the address that becomes reachable again when the phone moves
  /// back to that network. Most recently abandoned first, since that is the
  /// likeliest to work, and capped at [maxPairingAltHosts] so a desk that
  /// hops addresses all shift doesn't grow an unbounded probe list.
  PairingInfo movedTo(String ip, int port) {
    final demoted = <String>[
      if (ip != host) host,
      ...altHosts.where((h) => h != ip),
    ];
    return PairingInfo(
      host: ip,
      port: port,
      token: token,
      deviceSecret: deviceSecret,
      deskInstanceId: deskInstanceId,
      altHosts: List.unmodifiable(demoted.take(maxPairingAltHosts)),
    );
  }
}

class SessionService {
  static const _keyHost = 'pairing_host';
  static const _keyPort = 'pairing_port';
  static const _keyToken = 'pairing_token';
  static const _keyDeviceSecret = 'pairing_device_secret';
  static const _keyDeskInstanceId = 'pairing_desk_instance_id';
  static const _keyAltHosts = 'pairing_alt_hosts';

  final _secureStore = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<void> savePairing(PairingInfo info) async {
    logD(_tag, 'Saving pairing → ${info.host}:${info.port}');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyHost, info.host);
    await prefs.setInt(_keyPort, info.port);
    await prefs.setStringList(_keyAltHosts, info.altHosts);
    await _secureStore.write(key: _keyToken, value: info.token);
    if (info.deviceSecret != null) {
      await _secureStore.write(key: _keyDeviceSecret, value: info.deviceSecret);
    }
    if (info.deskInstanceId != null) {
      await _secureStore.write(
          key: _keyDeskInstanceId, value: info.deskInstanceId);
    }
    logD(_tag, '✓ Pairing saved');
  }

  Future<void> saveRecoveredCredentials({
    required String token,
    required String deviceSecret,
  }) async {
    await _secureStore.write(key: _keyToken, value: token);
    await _secureStore.write(key: _keyDeviceSecret, value: deviceSecret);
    logD(_tag, '✓ Recovered credentials saved');
  }

  Future<String?> getDeviceSecret() => _secureStore.read(key: _keyDeviceSecret);

  Future<bool> hasDeviceSecret() async =>
      (await getDeviceSecret())?.isNotEmpty ?? false;

  Future<String?> getDeskInstanceId() =>
      _secureStore.read(key: _keyDeskInstanceId);

  Future<PairingInfo?> getSavedPairing() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(_keyHost);
    final port = prefs.getInt(_keyPort);
    final altHosts = prefs.getStringList(_keyAltHosts) ?? const <String>[];

    final secureReads = await Future.wait([
      _secureStore.read(key: _keyToken),
      getDeviceSecret(),
      getDeskInstanceId(),
    ]);
    var token = secureReads[0];
    final deviceSecret = secureReads[1];
    final deskInstanceId = secureReads[2];

    final legacyToken = prefs.getString(_keyToken);
    if (token == null && legacyToken != null) {
      token = legacyToken;
      await _secureStore.write(key: _keyToken, value: legacyToken);
    }
    if (legacyToken != null) await prefs.remove(_keyToken);

    if (host == null || port == null || token == null) {
      logD(_tag, 'No saved pairing found');
      return null;
    }
    logD(_tag, '✓ Loaded saved pairing → $host:$port');
    return PairingInfo(
        host: host,
        port: port,
        token: token,
        deviceSecret: deviceSecret,
        deskInstanceId: deskInstanceId,
        altHosts: altHosts);
  }

  Future<void> clearPairing() async {
    logD(_tag, 'Clearing pairing data');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyHost);
    await prefs.remove(_keyPort);
    await prefs.remove(_keyAltHosts);
    await _secureStore.delete(key: _keyToken);
    await _secureStore.delete(key: _keyDeviceSecret);
    await _secureStore.delete(key: _keyDeskInstanceId);
    await BiometricService().forget();
    logD(_tag, 'Pairing cleared');
  }
}
