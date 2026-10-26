import '../services/socket_service.dart';

/// What the desk answered to a batch of `print:bill` requests.
class PrintBillResult {
  final int queued;

  /// The desk's own words for the first refusal; null when none was refused.
  final String? refusal;

  const PrintBillResult({required this.queued, this.refusal});
}

/// Reads the desk's answers rather than assuming each one was a yes: a
/// refused print (permission, wrong bill) must reach the waiter, not a
/// "queued" the desk never gave.
PrintBillResult summarizePrintBillAcks(List<Map<String, dynamic>> acks) {
  var queued = 0;
  String? refusal;
  for (final ack in acks) {
    if (ack['kind'] == 'error') {
      final message = ack['message']?.toString() ?? '';
      refusal ??= isTransportFailure(ack)
          ? 'The desk did not confirm the bill print — check the printer'
          : message.isEmpty
              ? 'The desk refused to print this bill'
              : message;
    } else {
      queued++;
    }
  }
  return PrintBillResult(queued: queued, refusal: refusal);
}

/// Asks the desk to print [billIds] and reports, once every answer is in, the
/// first refusal or unconfirmed print through [onProblem]. For prints asked
/// right after money moved, where the screen that asked may already be gone,
/// so the caller hands in a toast or notice that outlives it.
void requestBillPrints(
  SocketService socket,
  List<String> billIds,
  void Function(String message) onProblem,
) {
  if (billIds.isEmpty) return;
  final acks = <Map<String, dynamic>>[];
  for (final id in billIds) {
    socket.emit('print:bill', <String, dynamic>{'bill_id': id}, onAck: (ack) {
      acks.add(ack);
      if (acks.length != billIds.length) return;
      final refusal = summarizePrintBillAcks(acks).refusal;
      if (refusal != null) onProblem(refusal);
    });
  }
}
