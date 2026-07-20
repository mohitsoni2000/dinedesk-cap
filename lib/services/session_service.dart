import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tag = '[Session]';

class PairingInfo {
  final String host;
  final int port;
  final String token;
  const PairingInfo(
      {required this.host, required this.port, required this.token});
}

class SessionService {
  static const _keyHost = 'pairing_host';
  static const _keyPort = 'pairing_port';
  static const _keyToken = 'pairing_token';

  // The bearer token grants full operator socket access for up to 24h — it
  // belongs in the platform keystore/keychain, not plaintext SharedPreferences
  // (readable via device backup extraction or on a rooted/jailbroken device).
  // Host/port are just connection details, not credentials — SharedPreferences
  // is fine for those.
  final _secureStore = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<void> savePairing(PairingInfo info) async {
    debugPrint('$_tag Saving pairing → ${info.host}:${info.port}');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyHost, info.host);
    await prefs.setInt(_keyPort, info.port);
    await _secureStore.write(key: _keyToken, value: info.token);
    debugPrint('$_tag ✓ Pairing saved');
  }

  Future<PairingInfo?> getSavedPairing() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(_keyHost);
    final port = prefs.getInt(_keyPort);
    var token = await _secureStore.read(key: _keyToken);

    // One-time migration: earlier builds stored the token in plaintext
    // SharedPreferences under this same key. Move it into secure storage on
    // next read instead of forcing every paired device to re-scan its QR.
    final legacyToken = prefs.getString(_keyToken);
    if (token == null && legacyToken != null) {
      token = legacyToken;
      await _secureStore.write(key: _keyToken, value: legacyToken);
    }
    if (legacyToken != null) await prefs.remove(_keyToken);

    if (host == null || port == null || token == null) {
      debugPrint('$_tag No saved pairing found');
      return null;
    }
    debugPrint('$_tag ✓ Loaded saved pairing → $host:$port');
    return PairingInfo(host: host, port: port, token: token);
  }

  Future<void> clearPairing() async {
    debugPrint('$_tag Clearing pairing data');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyHost);
    await prefs.remove(_keyPort);
    await _secureStore.delete(key: _keyToken);
    debugPrint('$_tag ✓ Pairing cleared');
  }
}
