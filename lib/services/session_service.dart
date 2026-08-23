import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'biometric_service.dart';
import 'log.dart';

const String _tag = '[Session]';

class PairingInfo {
  final String host;
  final int port;
  final String token;

  final String? deviceSecret;

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
        deskInstanceId: deskInstanceId);
  }

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
