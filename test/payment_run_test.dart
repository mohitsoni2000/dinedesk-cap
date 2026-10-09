import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/models/pay_mode.dart';
import 'package:restro/utils/payment_run.dart';
import 'package:restro/utils/request_id.dart';
import 'package:restro/utils/tender_allocation.dart';

const _cash = TenderLine(mode: 'cash', amount: Money.rupees(100));
const _cover = TenderLine(
    mode: 'cover_ticket',
    amount: Money.rupees(100),
    ticketCode: 'CDT:P3VJ5LDY2GQA7FEC');

PaymentRun _run(Map<String, List<TenderLine>> calls) =>
    PaymentRun(<BillPaymentCall>[
      for (final e in calls.entries)
        BillPaymentCall(billId: e.key, lines: e.value),
    ]);

CallFailure _failure(PaymentRun run, String billId,
        {bool noAnswer = false, String refusal = 'Bill not found'}) =>
    CallFailure(
      call: run.calls.singleWhere((c) => c.billId == billId),
      noAnswer: noAnswer,
      refusal: refusal,
    );

/// What the payment sheet does after a Pay, decided apart from the widget.
void main() {
  group('every call answered', () {
    test('every bill settled: close', () {
      final run = _run({
        'food': [_cash]
      })
        ..done.add('food');
      final v = decidePay(
          run: run,
          failure: null,
          settled: 1,
          total: 1,
          due: Money.zero,
          short: const <ShortBill>[]);
      expect(v.close, isTrue);
    });

    test('a bill short after cover: the cover-capped notice', () {
      final run = _run({
        'food': [_cover, _cash]
      })
        ..done.add('food');
      final v = decidePay(
          run: run,
          failure: null,
          settled: 0,
          total: 1,
          due: const Money.rupees(100),
          short: const <ShortBill>[(label: 'Food · INV/1', hadCover: true)]);
      expect(v.close, isFalse);
      expect(v.keepRun, isFalse);
      expect(v.clearInputs, isTrue, reason: 'what was entered is spent');
      expect(v.stillDue!.reason, StillDueReason.coverCapped);
      expect(v.stillDue!.message(const Money.rupees(100)),
          '₹100 still due — a ticket had less cover left than shown. Take another payment for it.');
      expect(v.toast, '₹100 still due');
      expect(v.toastIsWarning, isTrue);
    });

    test('a bill short without cover: named plainly, no word of tickets', () {
      final run = _run({
        'food': [_cash]
      })
        ..done.add('food');
      final one = decidePay(
          run: run,
          failure: null,
          settled: 0,
          total: 1,
          due: const Money(2),
          short: const <ShortBill>[(label: 'Food · INV/1', hadCover: false)]);
      expect(one.stillDue!.message(const Money(2)),
          '₹0.02 is still due on Food · INV/1. Take another payment for it.');
      final two = decidePay(
          run: run,
          failure: null,
          settled: 0,
          total: 2,
          due: const Money(4),
          short: const <ShortBill>[
            (label: 'Food · INV/1', hadCover: false),
            (label: 'Liquor · INV/2', hadCover: false),
          ]);
      expect(two.stillDue!.message(const Money(4)),
          '₹0.04 is still due on 2 bills. Take another payment for it.');
    });

    test('a bill nothing landed on: as before, and the spent cover is cleared',
        () {
      final run = _run({
        'food': [_cover]
      })
        ..done.add('food');
      final v = decidePay(
          run: run,
          failure: null,
          settled: 1,
          total: 2,
          due: Money.zero,
          short: const <ShortBill>[]);
      expect(v.clearInputs, isTrue);
      expect(v.toast, 'Settled 1 of 2. Retry sends only the remaining 1.');
    });
  });

  group('no answer', () {
    test('first call: keep the run, and never say nothing was charged', () {
      final run = _run({
        'food': [_cash],
        'liquor': [_cash]
      })
        ..sawNoAnswer = true;
      final v = decidePay(
          run: run,
          failure: _failure(run, 'food', noAnswer: true),
          settled: 0,
          total: 2,
          due: const Money.rupees(200),
          short: const <ShortBill>[]);
      expect(v.keepRun, isTrue);
      expect(v.clearInputs, isFalse);
      expect(v.toast, kPaymentNoAnswer);
      expect(v.toast, isNot(contains('nothing was charged')));
    });

    test('after a bill settled: keep the run, the count says what went', () {
      final run = _run({
        'food': [_cash],
        'liquor': [_cash]
      })
        ..done.add('food')
        ..sawNoAnswer = true;
      final v = decidePay(
          run: run,
          failure: _failure(run, 'liquor', noAnswer: true),
          settled: 1,
          total: 2,
          due: const Money.rupees(100),
          short: const <ShortBill>[]);
      expect(v.keepRun, isTrue);
      expect(v.toast, 'Settled 1 of 2. Retry sends only the remaining 1.');
    });
  });

  group('refused outright', () {
    test('nothing went through: keep what was entered; as before', () {
      final run = _run({
        'food': [_cash]
      });
      final v = decidePay(
          run: run,
          failure: _failure(run, 'food'),
          settled: 0,
          total: 1,
          due: const Money.rupees(100),
          short: const <ShortBill>[]);
      expect(v.keepRun, isFalse);
      expect(v.clearInputs, isFalse);
      expect(v.stillDue, isNull);
      expect(v.toast, 'Payment failed — nothing was charged. Retry.');
    });

    test('a cover call refused: its reason, in staff words', () {
      final run = _run({
        'food': [_cover, _cash]
      });
      final v = decidePay(
          run: run,
          failure:
              _failure(run, 'food', refusal: "This ticket's cover is used up"),
          settled: 0,
          total: 1,
          due: const Money.rupees(200),
          short: const <ShortBill>[]);
      expect(v.toast, "This ticket's cover is used up");
      expect(v.clearInputs, isFalse);
    });

    test('after an earlier try got no answer: never "nothing was charged"', () {
      final run = _run({
        'food': [_cash]
      })
        ..sawNoAnswer = true;
      final v = decidePay(
          run: run,
          failure: _failure(run, 'food', refusal: 'Bill already fully paid'),
          settled: 0,
          total: 1,
          due: const Money.rupees(100),
          short: const <ShortBill>[]);
      expect(v.keepRun, isFalse);
      expect(
          v.toast,
          'Bill already fully paid. An earlier try got no answer — check '
          'the bill on the order screen.');
    });

    test('after a bill went through: clear what is spent, the rest is due', () {
      final run = _run({
        'food': [_cash],
        'liquor': [_cash]
      })
        ..done.add('food');
      final v = decidePay(
          run: run,
          failure: _failure(run, 'liquor'),
          settled: 1,
          total: 2,
          due: const Money.rupees(400),
          short: const <ShortBill>[]);
      expect(v.keepRun, isFalse);
      expect(v.clearInputs, isTrue);
      expect(v.stillDue!.reason, StillDueReason.partly);
      expect(v.stillDue!.message(const Money.rupees(400)),
          '₹400 still due — part of the payment went through. Take another payment for the rest.');
      expect(v.toast, 'Settled 1 of 2. Take payment for the remaining ₹400.');
    });

    test('a cover refused after a bill went through: its reason', () {
      final run = _run({
        'food': [_cover],
        'liquor': [_cover, _cash],
      })
        ..done.add('food');
      final v = decidePay(
          run: run,
          failure: _failure(run, 'liquor',
              refusal: "This ticket's cover is used up"),
          settled: 1,
          total: 2,
          due: const Money.rupees(700),
          short: const <ShortBill>[]);
      expect(v.clearInputs, isTrue);
      expect(v.stillDue!.reason, StillDueReason.partly);
      expect(v.toast, "This ticket's cover is used up");
    });
  });

  group('a try that got no answer, then let go unanswered', () {
    test('after a bill went through: the hint, and it stays unresolved', () {
      final run = _run({
        'food': [_cash],
        'liquor': [_cash]
      })
        ..done.add('food')
        ..sawNoAnswer = true;
      final v = decidePay(
          run: run,
          failure: _failure(run, 'liquor',
              refusal: 'Payment amount exceeds remaining'),
          settled: 1,
          total: 2,
          due: const Money.rupees(400),
          short: const <ShortBill>[]);
      expect(v.unresolved, isTrue);
      expect(v.clearInputs, isTrue);
      expect(
          v.toast,
          'Settled 1 of 2. An earlier try got no answer — check the bill on '
          'the order screen before taking the remaining ₹400.');
    });

    test('nothing through: unresolved, never "nothing was charged"', () {
      final run = _run({
        'food': [_cash]
      })
        ..sawNoAnswer = true;
      final v = decidePay(
          run: run,
          failure: _failure(run, 'food', refusal: 'Bill already fully paid'),
          settled: 0,
          total: 1,
          due: const Money.rupees(100),
          short: const <ShortBill>[]);
      expect(v.unresolved, isTrue);
      expect(v.keepRun, isFalse);
    });

    test('a later run on the same sheet: still never "nothing was charged"',
        () {
      final run = _run({
        'food': [_cash]
      });
      final v = decidePay(
          run: run,
          failure: _failure(run, 'food', refusal: 'Internal error'),
          settled: 0,
          total: 1,
          due: const Money.rupees(100),
          short: const <ShortBill>[],
          earlierUnanswered: true);
      expect(v.toast, isNot(contains('nothing was charged')));
      expect(
          v.toast,
          'Internal error. An earlier try got no answer — check the bill on '
          'the order screen.');
      expect(v.unresolved, isFalse, reason: 'this run itself was answered');
    });

    test('an answered run is not unresolved', () {
      final run = _run({
        'food': [_cash]
      })
        ..done.add('food')
        ..sawNoAnswer = true;
      final v = decidePay(
          run: run,
          failure: null,
          settled: 1,
          total: 1,
          due: Money.zero,
          short: const <ShortBill>[]);
      expect(v.close, isTrue);
      expect(v.unresolved, isFalse);
    });
  });

  test('a run holds each call\'s id past the 15-minute intent expiry', () {
    var now = DateTime(2026, 10, 9, 21);
    requestIdClock = () => now;
    addTearDown(() {
      requestIdClock = DateTime.now;
      resetRequestIds();
    });
    final run = _run({
      'food': [_cash]
    });
    final call = run.calls.single;
    final first = run.idFor(call);
    expect(first, requestIdFor('bill:payment', call.toPayload()),
        reason: 'stamped from the intent, so a reopened sheet still replays');
    now = now.add(kRequestIdTtl + const Duration(minutes: 1));
    expect(requestIdFor('bill:payment', call.toPayload()), isNot(first),
        reason: 'the intent id has lapsed');
    expect(run.idFor(call), first, reason: 'the run still sends the same id');
  });

  test('PaymentRun: what is still unsent, and which bills carry cover', () {
    final run = _run({
      'food': [_cover],
      'liquor': [_cash],
    });
    expect(run.started, isFalse);
    run.done.add('food');
    expect(run.started, isTrue);
    expect(run.unsent.map((c) => c.billId), <String>['liquor']);
    expect(run.carriesCover('food'), isTrue);
    expect(run.carriesCover('liquor'), isFalse);
  });
}
