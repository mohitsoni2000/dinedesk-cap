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
  final slot = _freeAsideSlot(prefs, key);
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

/// Keeps [value] in the first free `<key>.unreadable` slot, as [keepAside]
/// does with all of [key]: for one part of what [key] holds that this app
/// cannot read, so the rest of [key] can go on without it. True once kept.
Future<bool> keepValueAside(
    SharedPreferences prefs, String key, String value) async {
  try {
    return await prefs.setString(_freeAsideSlot(prefs, key), value);
  } catch (_) {
    return false;
  }
}

String _freeAsideSlot(SharedPreferences prefs, String key) {
  var slot = '$key.unreadable';
  for (var n = 2; prefs.containsKey(slot); n++) {
    slot = '$key.unreadable.$n';
  }
  return slot;
}
