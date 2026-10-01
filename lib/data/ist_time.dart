const Duration _istOffset = Duration(hours: 5, minutes: 30);

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

final RegExp _dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final RegExp _sqliteUtc = RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}(:\d{2})?$');
final RegExp _zonelessIst = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$');
final RegExp _withZone = RegExp(r'(Z|[+-]\d{2}:?\d{2})$');

/// A desk DB timestamp as a UTC instant, or null when unreadable. Mirrors the
/// desk's parseUtc: a bare DateTime.tryParse would read the SQLite and the
/// zone-less IST forms as device-local time.
DateTime? parseDbTimestamp(String? raw) {
  final s = raw?.trim() ?? '';
  if (s.isEmpty) return null;
  DateTime? parsed;
  if (_dateOnly.hasMatch(s)) {
    parsed = DateTime.tryParse('${s}T00:00:00Z');
  } else if (_sqliteUtc.hasMatch(s)) {
    parsed = DateTime.tryParse('${s}Z');
  } else if (_zonelessIst.hasMatch(s)) {
    parsed = DateTime.tryParse('$s+05:30');
  } else if (_withZone.hasMatch(s)) {
    parsed = DateTime.tryParse(s);
  }
  return parsed?.toUtc();
}

DateTime _istFields(DateTime instant) => instant.toUtc().add(_istOffset);

String _two(int n) => n.toString().padLeft(2, '0');

String istDateOf(DateTime instant) {
  final d = _istFields(instant);
  return '${d.year}-${_two(d.month)}-${_two(d.day)}';
}

String formatIstTime(DateTime instant) {
  final d = _istFields(instant);
  final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$hour:${_two(d.minute)} ${d.hour < 12 ? 'am' : 'pm'}';
}

String formatIstDayTime(DateTime instant) {
  final d = _istFields(instant);
  return '${d.day} ${_months[d.month - 1]}, ${formatIstTime(instant)}';
}

Duration untilNextIstMidnight(DateTime now) {
  final d = _istFields(now);
  final midnight = DateTime.utc(d.year, d.month, d.day + 1);
  return midnight.difference(DateTime.utc(
      d.year, d.month, d.day, d.hour, d.minute, d.second, d.millisecond));
}
