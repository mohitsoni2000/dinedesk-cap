import 'package:flutter/foundation.dart';

/// Release-safe logging.
///
/// `debugPrint` is **not** stripped from release builds — only `assert` is.
/// Every `debugPrint` in this app was therefore writing to device logs in
/// production, including 20 characters of the pairing bearer token, full
/// socket payloads (customer names and phone numbers), and every order total.
/// Any crash reporter added later would have swept all of it up.
///
/// Everything now routes through here, and here it compiles down to nothing
/// in release.
void logD(String tag, String message) {
  if (kReleaseMode) return;
  debugPrint('$tag $message');
}

/// Errors are worth keeping in profile builds too, but still never in release
/// — an operator's phone is not our log sink.
void logE(String tag, String message, [Object? error, StackTrace? stack]) {
  if (kReleaseMode) return;
  debugPrint('$tag ERROR $message${error == null ? '' : ' — $error'}');
  if (stack != null && kDebugMode) debugPrint('$stack');
}

/// Redacts a secret down to a length hint. Use this if a token or PIN ever
/// genuinely needs to appear in a debug line — never the value itself, not
/// even a prefix. A 20-character prefix of a JWT leaks the header and the
/// start of the payload.
String redact(String? secret) =>
    secret == null ? '<null>' : '<redacted:${secret.length}>';

/// Summarises a socket payload for debug logs without printing values.
///
/// The old `_summarize` printed every scalar, which meant customer names,
/// phone numbers and amounts went to logcat on every emit. This prints shape
/// only — keys and value *kinds* — which is what is actually useful when
/// debugging a wire mismatch anyway.
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
