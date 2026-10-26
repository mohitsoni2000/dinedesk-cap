import '../services/socket_service.dart';

/// What to tell the waiter when a desk request failed.
///
/// A refusal carries the desk's own reason (no permission, the table moved,
/// "send the KOT before billing"), and a retry rarely fixes it, so that
/// reason is shown. No answer is different: the request may still have gone
/// through, so [noAnswer] says so when given; the transport's own text is
/// never shown.
String ackFailureText(
  Map<String, dynamic> ack, {
  required String fallback,
  String? noAnswer,
}) {
  if (isTransportFailure(ack)) return noAnswer ?? fallback;
  final message = ack['message']?.toString().trim() ?? '';
  return message.isEmpty ? fallback : message;
}
