import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/perf_mode.dart';

class DeviceTier {
  DeviceTier._();

  static const _channel = MethodChannel('crew/device');

  static const _cacheKey = 'device_perf_tier';

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
      final raw = await _channel.invokeMapMethod<String, dynamic>('deviceTier');
      final isLowRam = raw?['isLowRamDevice'] as bool? ?? false;
      final totalMb = raw?['totalMemMb'] as int? ?? 0;
      if (isLowRam || (totalMb > 0 && totalMb <= _lowRamMbThreshold)) {
        return PerfTier.low;
      }
      return PerfTier.capable;
    } catch (_) {
      return Platform.numberOfProcessors <= 4 ? PerfTier.low : PerfTier.capable;
    }
  }
}
