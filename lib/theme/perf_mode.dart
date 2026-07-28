import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/device_tier.dart';

/// What the operator asked for. [PerfMode.auto] defers to the detected
/// [PerfTier]; the other two override it in either direction.
enum PerfMode { auto, performance, full }

/// What the hardware actually is. Resolved once per install — RAM doesn't
/// change at runtime — and cached, so this never costs more than a prefs read
/// after the first cold start.
enum PerfTier { capable, low }

class PerfState {
  final PerfMode mode;
  final PerfTier tier;
  const PerfState({this.mode = PerfMode.auto, this.tier = PerfTier.capable});

  PerfState copyWith({PerfMode? mode, PerfTier? tier}) =>
      PerfState(mode: mode ?? this.mode, tier: tier ?? this.tier);
}

/// Owns the persisted preference and the detected device tier. Deliberately
/// does *not* carry the OS `disableAnimations` flag — that's live MediaQuery
/// state, folded in at the [PerfScope] bridge rather than cached here.
final perfStateProvider =
    StateNotifierProvider<PerfNotifier, PerfState>((ref) => PerfNotifier());

class PerfNotifier extends StateNotifier<PerfState> {
  PerfNotifier() : super(const PerfState()) {
    _load();
  }

  static const _prefsKey = 'setting_perf_mode';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final tier = await DeviceTier.detect();
    if (!mounted) return;
    final raw = prefs.getString(_prefsKey);
    state = PerfState(
      mode: PerfMode.values.firstWhere(
        (m) => m.name == raw,
        orElse: () => PerfMode.auto,
      ),
      tier: tier,
    );
  }

  Future<void> set(PerfMode mode) async {
    state = state.copyWith(mode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, mode.name);
  }
}
