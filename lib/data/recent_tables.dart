import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final recentTablesProvider =
    StateNotifierProvider<RecentTablesNotifier, List<String>>(
        (ref) => RecentTablesNotifier());

class RecentTablesNotifier extends StateNotifier<List<String>> {
  RecentTablesNotifier() : super(const []) {
    _restore();
  }

  static const String _prefsKey = 'ui.recent_tables.v1';
  static const int _cap = 6;

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_prefsKey);
      if (saved != null && mounted) state = saved;
    } catch (_) {}
  }

  void record(String serverId) {
    if (serverId.isEmpty) return;
    final next = <String>[
      serverId,
      ...state.where((id) => id != serverId),
    ].take(_cap).toList();
    state = next;
    _persist(next);
  }

  void clear() {
    state = const [];
    _persist(const []);
  }

  Future<void> _persist(List<String> ids) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, ids);
    } catch (_) {}
  }
}
