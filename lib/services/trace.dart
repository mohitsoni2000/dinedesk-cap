/// CC-LAT-006 — production-safe connect-latency trace harness.
///
/// Unlike log.dart, this stays live in release builds: it records a label
/// and a millisecond offset only — never a value, a name, or an amount — so
/// there's nothing here for a crash reporter or a device-log scrape to leak.
/// `log.dart` compiles out in release, so without this there is currently no
/// production timing data at all for how long a real connect takes on a real
/// outlet's LAN — every number quoted anywhere else is synthetic or read off
/// code.
library;

class TraceMark {
  final String label;
  final int atMs;
  const TraceMark(this.label, this.atMs);
}

/// One connect attempt's worth of marks.
///
/// [reset] is called once at boot (`main()`) and again at the start of every
/// fresh connect attempt, so marks from a stale/abandoned attempt never leak
/// into the next one's breakdown.
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

  /// Ordered legs matching the acceptance table in COMMAND-LATENCY-SPEC.md.
  /// A leg is omitted (not zero) if either endpoint was never marked this
  /// session — e.g. resync_acked never fires on a failed connect.
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
    ('socket_connected -> resync_emitted', 'socket_connected', 'resync_emitted'),
    ('resync_emitted -> resync_acked', 'resync_emitted', 'resync_acked'),
    ('resync_acked -> menu_gate_done', 'resync_acked', 'menu_gate_done'),
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
