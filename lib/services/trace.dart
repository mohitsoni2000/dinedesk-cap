library;

class TraceMark {
  final String label;
  final int atMs;
  const TraceMark(this.label, this.atMs);
}

class Trace {
  Trace._();

  static final Stopwatch _stopwatch = Stopwatch()..start();
  static final List<TraceMark> _marks = <TraceMark>[];

  static void reset() {
    _stopwatch
      ..reset()
      ..start();
    _marks.clear();
  }

  static void mark(String label) {
    _marks.add(TraceMark(label, _stopwatch.elapsedMilliseconds));
  }

  static List<TraceMark> get marks => List.unmodifiable(_marks);

  static int? _at(String label) {
    for (final m in _marks) {
      if (m.label == label) return m.atMs;
    }
    return null;
  }

  static const List<(String, String, String)> _legs = [
    ('boot -> pairing_read_done', 'app_start', 'pairing_read_done'),
    (
      'pairing_read_done -> socket_connect_called',
      'pairing_read_done',
      'socket_connect_called'
    ),
    (
      'socket_connect_called -> socket_connected',
      'socket_connect_called',
      'socket_connected'
    ),
    (
      'socket_connected -> resync_emitted',
      'socket_connected',
      'resync_emitted'
    ),
    ('resync_emitted -> resync_acked', 'resync_emitted', 'resync_acked'),
    ('resync_acked -> menu_gate_done', 'resync_acked', 'menu_gate_done'),
    (
      'resync_acked -> timer_cache_loaded',
      'resync_acked',
      'timer_cache_loaded'
    ),
    (
      'timer_cache_loaded -> floor_table_room_applied',
      'timer_cache_loaded',
      'floor_table_room_applied'
    ),
    (
      'floor_table_room_applied -> menu_gate_done',
      'floor_table_room_applied',
      'menu_gate_done'
    ),
    ('menu_gate_done -> menu_parsed', 'menu_gate_done', 'menu_parsed'),
    ('menu_parsed -> tables_visible', 'menu_parsed', 'tables_visible'),
    ('boot -> tables_visible', 'app_start', 'tables_visible'),
  ];

  static Map<String, int> connectBreakdown() {
    final result = <String, int>{};
    for (final (label, startLabel, endLabel) in _legs) {
      final startMs = _at(startLabel);
      final endMs = _at(endLabel);
      if (startMs != null && endMs != null) {
        result[label] = endMs - startMs;
      }
    }
    return result;
  }
}
