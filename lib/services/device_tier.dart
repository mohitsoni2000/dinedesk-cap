import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/perf_mode.dart';

/// Classifies the host device once per install.
///
/// The signal is Android's own [ActivityManager.isLowRamDevice] — the flag the
/// platform documents for exactly this ("apps should turn off features that
/// require more RAM"). It beats guessing from refresh rate or core count, both
/// of which misclassify plenty of capable budget hardware.
class DeviceTier {
  DeviceTier._();

  static const _channel = MethodChannel('crew/device');

  /// Detected hardware fact, not a user preference — hence no `setting_` prefix.
  static const _cacheKey = 'device_perf_tier';

  /// Some OEMs leave `isLowRamDevice` false on 3GB units that still struggle.
  /// On a shared restaurant tablet fleet, erring toward "low" is the safe way
  /// to be wrong.
  static const _lowRamMbThreshold = 3072;

  static Future<PerfTier> detect() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKey);
    if (cached != null) {
      return PerfTier.values.firstWhere(
        (t) => t.name == cached,
        orElse: () => PerfTier.capable,
      );
    }
    final tier = await _resolve();
    await prefs.setString(_cacheKey, tier.name);
    return tier;
  }

  static Future<PerfTier> _resolve() async {
    if (!Platform.isAndroid) return PerfTier.capable;
    try {
      final raw =
          await _channel.invokeMapMethod<String, dynamic>('deviceTier');
      final isLowRam = raw?['isLowRamDevice'] as bool? ?? false;
      final totalMb = raw?['totalMemMb'] as int? ?? 0;
      if (isLowRam || (totalMb > 0 && totalMb <= _lowRamMbThreshold)) {
        return PerfTier.low;
      }
      return PerfTier.capable;
    } catch (_) {
      // Channel unavailable (widget tests, older install). Core count is a
      // weak proxy, but it's better than assuming every device is capable.
      return Platform.numberOfProcessors <= 4
          ? PerfTier.low
          : PerfTier.capable;
    }
  }
}
