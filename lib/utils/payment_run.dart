/// What the payment sheet does once a Pay stops: every `bill:payment` was
/// answered, or one failed. Pure, so each transition is tested on its own;
/// the sheet only applies the verdict.
library;

import '../data/currency.dart';
import '../data/money.dart';
import 'tender_allocation.dart';

/// Shown when a `bill:payment` got no answer: it may have gone through.
const String kPaymentNoAnswer =
    "The desk didn't answer — it may have gone through. "
    'Pay retries exactly as entered.';

/// The `bill:payment` calls one Pay planned. Kept until the desk has
/// answered each of them, so a retry resends exactly these: the same
/// payloads, so the same `client_request_id`s.
class PaymentRun {
  PaymentRun(this.calls);

  final List<BillPaymentCall> calls;

  /// Bills whose call the desk answered with success.
  final Set<String> done = <String>{};

  /// Some attempt got no answer (timeout, dropped link, garbled reply), so
  /// a later refusal cannot mean "nothing was charged".
  bool sawNoAnswer = false;

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
///
/// "Nothing was charged" is said only when the desk refused outright, no
/// call went through and no earlier attempt went unanswered.
PayVerdict decidePay({
  required PaymentRun run,
  required CallFailure? failure,
  required int settled,
  required int total,
  required Money due,
  required List<ShortBill> short,
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
  // recorded by it.
  if (run.started) {
    return PayVerdict(
      clearInputs: true,
      stillDue: const StillDue(StillDueReason.partly),
      toast: failure.carriesCover
          ? failure.refusal
          : 'Settled $settled of $total. Take payment for the remaining '
              '${formatRupeesCompact(due)}.',
    );
  }
  if (run.sawNoAnswer) {
    return PayVerdict(
        toast: '${failure.refusal}. An earlier try got no answer — check the '
            'bill on the order screen.');
  }
  return PayVerdict(
    toast: failure.carriesCover ? failure.refusal : _retryText(0, total),
  );
}

String _retryText(int settled, int total) => settled == 0
    ? 'Payment failed — nothing was charged. Retry.'
    : 'Settled $settled of $total. '
        'Retry sends only the remaining ${total - settled}.';
