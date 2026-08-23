import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import 'log.dart';

final biometricServiceProvider =
    Provider<BiometricService>((ref) => BiometricService());

class BiometricService {
  static const _kEnabled = 'bio_enabled_v1';
  static const _kPin = 'bio_pin_v1';
  static const _kPrompted = 'bio_prompted_v1';
  static const _tag = '[Biometric]';

  final _auth = LocalAuthentication();
  final _store = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<bool> canUse() async {
    try {
      return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } catch (e) {
      logD(_tag, 'canUse error: $e');
      return false;
    }
  }

  Future<bool> isEnabled() async => (await _store.read(key: _kEnabled)) == '1';

  Future<bool> wasPrompted() async =>
      (await _store.read(key: _kPrompted)) == '1';

  Future<void> markPrompted() => _store.write(key: _kPrompted, value: '1');

  Future<void> enable(String pin) async {
    await _store.write(key: _kPin, value: pin);
    await _store.write(key: _kEnabled, value: '1');
    logD(_tag, 'enabled');
  }

  Future<void> disable() async {
    await _store.delete(key: _kPin);
    await _store.write(key: _kEnabled, value: '0');
    logD(_tag, 'disabled');
  }

  Future<void> forget() async {
    await _store.delete(key: _kPin);
    await _store.delete(key: _kEnabled);
    await _store.delete(key: _kPrompted);
    logD(_tag, 'credentials forgotten');
  }

  Future<String?> unlock() async {
    if (!await isEnabled() || !await canUse()) return null;
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock your shift',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
      if (!ok) return null;
      return _store.read(key: _kPin);
    } catch (e) {
      logD(_tag, 'unlock error: $e');
      return null;
    }
  }
}
