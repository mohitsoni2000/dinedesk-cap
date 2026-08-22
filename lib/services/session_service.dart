import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'biometric_service.dart';
import 'log.dart';

const String _tag = '[Session]';

class PairingInfo {
  final String host;
  final int port;
  final String token;

  /// Present when the Desk minted one alongside the token (every QR from an
  /// updated Desk). Null for pairings made before this existed, or via manual
  /// token entry — those phones simply have no recovery-login fallback until
  /// they re-pair with a fresh QR.
  final String? deviceSecret;

  /// The Desk's stable identity (see CREW_NETWORK_DESIGN.md §5.1). Null for
  /// pairings made before this existed — those phones trust any reachable
  /// address the same way they always did, until they re-pair with a fresh QR.
  final String? deskInstanceId;
  const PairingInfo(
      {required this.host,
      required this.port,
      required this.token,
      this.deviceSecret,
      this.deskInstanceId});
}

class SessionService {
  static const _keyHost = 'pairing_host';
  static const _keyPort = 'pairing_port';
  static const _keyToken = 'pairing_token';
  static const _keyDeviceSecret = 'pairing_device_secret';
  static const _keyDeskInstanceId = 'pairing_desk_instance_id';

  // The bearer token grants full operator socket access for as long as the
  // Desk's "Device pairing expires after" setting allows (admin-configurable,
  // defaults to 30 days) — it belongs in the platform keystore/keychain, not
  // plaintext SharedPreferences (readable via device backup extraction or on
  // a rooted/jailbroken device).
  // Host/port are just connection details, not credentials — SharedPreferences
  // is fine for those.
  final _secureStore = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<void> savePairing(PairingInfo info) async {
    logD(_tag, 'Saving pairing → ${info.host}:${info.port}');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyHost, info.host);
    await prefs.setInt(_keyPort, info.port);
    await _secureStore.write(key: _keyToken, value: info.token);
    if (info.deviceSecret != null) {
      await _secureStore.write(key: _keyDeviceSecret, value: info.deviceSecret);
    }
    if (info.deskInstanceId != null) {
      await _secureStore.write(key: _keyDeskInstanceId, value: info.deskInstanceId);
    }
    logD(_tag, '✓ Pairing saved');
  }

  /// Updates just the token + device secret after a successful recovery
  /// login — host/port are unchanged, this device already knew them.
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

    // CC-LAT-002: these three were sequential awaits — each is a platform-
    // channel round trip plus a Keystore crypto op with
    // encryptedSharedPreferences: true, and the socket can't start until all
    // three finish. Future.wait fires them together instead.
    final secureReads = await Future.wait([
      _secureStore.read(key: _keyToken),
      getDeviceSecret(),
      getDeskInstanceId(),
    ]);
    var token = secureReads[0];
    final deviceSecret = secureReads[1];
    final deskInstanceId = secureReads[2];

    // One-time migration: earlier builds stored the token in plaintext
    // SharedPreferences under this same key. Move it into secure storage on
    // next read instead of forcing every paired device to re-scan its QR.
    // Runs after the parallel reads — it depends on `token` from above.
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
        deskInstanceId: deskInstanceId);
  }

  /// Clears the pairing **and every credential derived from it**.
  ///
  /// This used to leave the biometric keys alone, so unpairing a device and
  /// handing it to a different waiter left the previous operator's PIN in the
  /// keystore — still unlockable by whichever fingerprint is enrolled on the
  /// phone.
  Future<void> clearPairing() async {
    logD(_tag, 'Clearing pairing data');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyHost);
    await prefs.remove(_keyPort);
    await _secureStore.delete(key: _keyToken);
    await _secureStore.delete(key: _keyDeviceSecret);
    await _secureStore.delete(key: _keyDeskInstanceId);
    await BiometricService().forget();
    logD(_tag, 'Pairing cleared');
  }
}
