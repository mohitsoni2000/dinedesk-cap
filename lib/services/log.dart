import 'package:flutter/foundation.dart';

void logD(String tag, String message) {
  if (kReleaseMode) return;
  debugPrint('$tag $message');
}

void logE(String tag, String message, [Object? error, StackTrace? stack]) {
  if (kReleaseMode) return;
  debugPrint('$tag ERROR $message${error == null ? '' : ' — $error'}');
  if (stack != null && kDebugMode) debugPrint('$stack');
}

String redact(String? secret) =>
    secret == null ? '<null>' : '<redacted:${secret.length}>';

String summarizeShape(Map<String, dynamic> data) {
  if (kReleaseMode) return '';
  final buffer = StringBuffer('{');
  var first = true;
  for (final entry in data.entries) {
    if (!first) buffer.write(', ');
    first = false;
    final value = entry.value;
    final kind = switch (value) {
      null => 'null',
      final List<Object?> list => 'List(${list.length})',
      final Map<Object?, Object?> map => 'Map(${map.length})',
      final String s => 'String(${s.length})',
      final int _ => 'int',
      final double _ => 'double',
      final bool _ => 'bool',
      _ => value.runtimeType.toString(),
    };
    buffer.write('${entry.key}: $kind');
  }
  buffer.write('}');
  return buffer.toString();
}
