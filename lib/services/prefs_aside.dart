import 'package:shared_preferences/shared_preferences.dart';

/// Copies what [key] holds to the first free `<key>.unreadable` slot
/// (`<key>.unreadable`, then `<key>.unreadable.2`, …), so a stored value this
/// app cannot read is kept on the phone, out of the way, instead of being
/// written over or blocking [key] for good.
///
/// True when [key] may now be started afresh: it held nothing, or its value
/// was copied aside. False when the copy failed: leave [key] as it is.
Future<bool> keepAside(SharedPreferences prefs, String key) async {
  final Object? value = prefs.get(key);
  if (value == null) return true;
  var slot = '$key.unreadable';
  for (var n = 2; prefs.containsKey(slot); n++) {
    slot = '$key.unreadable.$n';
  }
  try {
    return switch (value) {
      String() => await prefs.setString(slot, value),
      bool() => await prefs.setBool(slot, value),
      int() => await prefs.setInt(slot, value),
      double() => await prefs.setDouble(slot, value),
      List<Object?>() =>
        await prefs.setStringList(slot, <String>[for (final v in value) '$v']),
      _ => await prefs.setString(slot, '$value'),
    };
  } catch (_) {
    return false;
  }
}
