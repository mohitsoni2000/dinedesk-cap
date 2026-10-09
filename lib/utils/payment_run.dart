/// What the payment sheet does once a Pay stops: every `bill:payment` was
/// answered, or one failed. Pure, so each transition is tested on its own;
/// the sheet only applies the verdict.
library;

import '../data/currency.dart';
import '../data/money.dart';
import 'request_id.dart';
import 'tender_allocation.dart';

/// Shown when a `bill:payment` got no answer: it may have gone through.
const String kPaymentNoAnswer =
    "The desk didn't answer — it may have gone through. "
    'Pay retries exactly as entered.';

/// Shown while a try that got no answer was let go unanswered: it may have
/// gone through.
const String kEarlierTryUnanswered =
    'An earlier try got no answer — check the bill on the order screen';

/// The `bill:payment` calls one Pay planned. Kept until the desk has
/// answered each of them, so a retry resends exactly these: the same
/// payloads under the same `client_request_id`s.
class PaymentRun {
  PaymentRun(this.calls);

  final List<BillPaymentCall> calls;

  /// Bills whose call the desk answered with success.
  final Set<String> done = <String>{};

  /// Some attempt got no answer (timeout, dropped link, garbled reply), so
  /// a later refusal cannot mean "nothing was charged".
  bool sawNoAnswer = false;

  /// Each call's `client_request_id`, by bill, stamped on its first send.
  final Map<String, String> _ids = <String, String>{};

  /// [call]'s `client_request_id`: the intent's id ([requestIdFor], so a
  /// sheet closed and opened again on the same entries still replays) when
  /// first sent, then held for the run's life. The intent id lapses after
  /// [kRequestIdTtl]; the desk replays for 48 hours, so a resend an hour
  /// later must still be the same request.
  String idFor(BillPaymentCall call) => _ids.putIfAbsent(
      call.billId, () => requestIdFor('bill:payment', call.toPayload()));

  bool get started => done.isNotEmpty;

  List<BillPaymentCall> get unsent => <BillPaymentCall>[
        for (final call in calls)
          if (!done.contains(call.billId)) call,
      ];

  bool carriesCover(String billId) => calls
      .any((c) => c.billId == billId && c.lines.any((line) => line.isCover));
}

/// The call a Pay stopped at.
class CallFailure {
  final BillPaymentCall call;

  /// No answer came (timeout, dropped link, garbled reply): it may have
  /// gone through.
  final bool noAnswer;

  /// The refusal in staff words: a cover code's copy, else the desk's text.
  final String refusal;

  const CallFailure({
    required this.call,
    required this.noAnswer,
    required this.refusal,
  });

  bool get carriesCover => call.lines.any((line) => line.isCover);
}

enum StillDueReason { coverCapped, short, partly }

/// Why money is still due while the sheet stays open.
class StillDue {
  final StillDueReason reason;

  /// For [StillDueReason.short]: the bill it is on ("Food · INV/001"), or
  /// "2 bills".
  final String? where;

  const StillDue(this.reason, {this.where});

  String message(Money due) {
    final amount = formatRupeesCompact(due);
    return switch (reason) {
      StillDueReason.coverCapped => '$amount still due — a ticket had less '
          'cover left than shown. Take another payment for it.',
      StillDueReason.short =>
        '$amount is still due on $where. Take another payment for it.',
      StillDueReason.partly => '$amount still due — part of the payment went '
          'through. Take another payment for the rest.',
    };
  }
}

/// A bill this run reached that the desk says still owes money.
typedef ShortBill = ({String label, bool hadCover});

/// What the sheet does next.
class PayVerdict {
  /// Every bill is settled: close, reporting success.
  final bool close;

  /// Keep the run: Pay resends its unsent calls unchanged, the fields lock.
  final bool keepRun;

  /// A try in this run got no answer and the run is let go without one:
  /// what it did is unknown. The sheet remembers it (Close asks first; no
  /// later refusal says "nothing was charged").
  final bool unresolved;

  /// What was entered is spent (recorded on some bill): clear the covers
  /// and tenders.
  final bool clearInputs;

  /// A new reason money is still due; null leaves the current one.
  final StillDue? stillDue;
  final String? toast;
  final bool toastIsWarning;

  const PayVerdict({
    this.close = false,
    this.keepRun = false,
    this.unresolved = false,
    this.clearInputs = false,
    this.stillDue,
    this.toast,
    this.toastIsWarning = false,
  });
}

/// Decides what follows a Pay. [run] has every answered call in `done`;
/// [failure] is the call it stopped at, if any. [settled] of [total] bills
/// are settled, the open ones owe [due], and [short] are the bills this run
/// reached that the desk says still owe money (it took less than was sent).
/// [earlierUnanswered]: an earlier run on this sheet was let go with a try
/// unanswered.
///
/// "Nothing was charged" is said only when the desk refused outright, no
/// call went through and no attempt, in this run or an earlier one, went
/// unanswered.
PayVerdict decidePay({
  required PaymentRun run,
  required CallFailure? failure,
  required int settled,
  required int total,
  required Money due,
  required List<ShortBill> short,
  bool earlierUnanswered = false,
}) {
  if (failure == null) {
    if (settled == total) return const PayVerdict(close: true);
    if (short.isNotEmpty) {
      return PayVerdict(
        clearInputs: true,
        stillDue: short.any((s) => s.hadCover)
            ? const StillDue(StillDueReason.coverCapped)
            : StillDue(StillDueReason.short,
                where: short.length == 1
                    ? short.single.label
                    : '${short.length} bills'),
        toast: '${formatRupeesCompact(due)} still due',
        toastIsWarning: true,
      );
    }
    // A bill nothing landed on got no call, as before; what was sent is
    // spent all the same.
    return PayVerdict(clearInputs: true, toast: _retryText(settled, total));
  }
  if (failure.noAnswer) {
    return PayVerdict(
      keepRun: true,
      toast: settled == 0 ? kPaymentNoAnswer : _retryText(settled, total),
    );
  }
  // The desk refused that call outright, so nothing on its bill was
  // recorded by it. An earlier try that got no answer may have been.
  final unanswered = run.sawNoAnswer || earlierUnanswered;
  if (run.started) {
    return PayVerdict(
      clearInputs: true,
      unresolved: run.sawNoAnswer,
      stillDue: const StillDue(StillDueReason.partly),
      toast: failure.carriesCover
          ? (unanswered
              ? '${failure.refusal}. $kEarlierTryUnanswered.'
              : failure.refusal)
          : unanswered
              ? 'Settled $settled of $total. $kEarlierTryUnanswered before '
                  'taking the remaining ${formatRupeesCompact(due)}.'
              : 'Settled $settled of $total. Take payment for the remaining '
                  '${formatRupeesCompact(due)}.',
    );
  }
  if (unanswered) {
    return PayVerdict(
        unresolved: run.sawNoAnswer,
        toast: '${failure.refusal}. $kEarlierTryUnanswered.');
  }
  return PayVerdict(
    toast: failure.carriesCover ? failure.refusal : _retryText(0, total),
  );
}

String _retryText(int settled, int total) => settled == 0
    ? 'Payment failed — nothing was charged. Retry.'
    : 'Settled $settled of $total. '
        'Retry sends only the remaining ${total - settled}.';
