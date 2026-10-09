// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/controllers/gate_scan_controller.dart';
import 'package:restro/models/entry_ticket.dart';
import 'package:restro/services/entry_ticket_service.dart';

/// The gate scanner's rules against a fake desk and a fake clock: the local
/// QR filter, the per-code cooldown, one request in flight, the tone of each
/// answer and its words, an unanswered check-in held with its id, and no
/// scanning without the desk.
void main() {
  const dir = 'test/fixtures/crew-qsr';
  Map<String, dynamic> fixture(String name) =>
      jsonDecode(File('$dir/$name').readAsStringSync()) as Map<String, dynamic>;
  CheckInAnswered answered(String name) =>
      CheckInAnswered(CheckInResult.fromAck(fixture(name)));

  const ticketA = 'CDT:7QKX2MZ4HB6TNW3R';
  const ticketB = 'CDT:P3VJ5LDY2GQA7FEC';
  final start = DateTime.utc(2026, 10, 9, 14, 45);

  late List<TicketCheckInRequest> sent;
  late List<GateTone> tones;
  late TicketCheckInOutcome Function(TicketCheckInRequest) reply;
  Completer<TicketCheckInOutcome>? held;

  setUp(() {
    sent = <TicketCheckInRequest>[];
    tones = <GateTone>[];
    reply = (_) => answered('ticket_check_in_valid.json');
    held = null;
  });

  GateScanController make(FakeAsync async, {bool online = true}) =>
      GateScanController(
        checkIn: (request) {
          sent.add(request);
          final gate = held;
          if (gate != null) return gate.future;
          return Future<TicketCheckInOutcome>.value(reply(request));
        },
        config: () => const TicketConfig(coverPaymentMode: 'cover_ticket'),
        onTone: tones.add,
        now: () => start.add(async.elapsed),
        online: online,
      );

  group('the local filter', () {
    test('a QR that is not a ticket never reaches the desk', () {
      fakeAsync((async) {
        final gate = make(async);
        for (final raw in <String>[
          'https://example.com/menu',
          'CDT:short',
          'cdt:7qkx2mz4hb6tnw3r',
          'CDT:7QKX2MZ4HB6TNW3R1',
          'CDT:7QKX2MZ4HB6TNW31', // 1 is not base32
          'XYZ:7QKX2MZ4HB6TNW3R',
        ]) {
          gate.onDetected(raw);
          async.flushMicrotasks();
          expect(gate.state.card?.kind, GateCardKind.notTicket, reason: raw);
          expect(gate.state.card?.tone, GateTone.amber);
          gate.dismissCard();
        }
        expect(sent, isEmpty);
        gate.dispose();
      });
    });

    test('a ticket QR goes, trimmed, as a scan', () {
      fakeAsync((async) {
        final gate = make(async);
        gate.onDetected('  $ticketA\n');
        async.flushMicrotasks();
        expect(sent.single.code, ticketA);
        expect(sent.single.method, CheckInMethod.scan);
        gate.dispose();
      });
    });
  });

  group('the per-code cooldown', () {
    test('a code held in view stays quiet; 4s after it was last seen it may '
        'go again', () {
      fakeAsync((async) {
        final gate = make(async);
        gate.onDetected(ticketA);
        async.flushMicrotasks();
        expect(sent, hasLength(1));
        // The green card clears itself; the guest still holds the QR up.
        async.elapse(GateScanController.validCardFor);
        expect(gate.state.card, isNull);
        for (var i = 0; i < 10; i++) {
          async.elapse(const Duration(milliseconds: 400));
          gate.onDetected(ticketA);
        }
        expect(sent, hasLength(1), reason: 'held in view: no red card');
        // Away for under 4s: still quiet.
        async.elapse(const Duration(milliseconds: 3900));
        gate.onDetected(ticketA);
        expect(sent, hasLength(1));
        // Away for 4s since it was last seen: a rescan is a real one.
        async.elapse(GateScanController.cooldown);
        gate.onDetected(ticketA);
        async.flushMicrotasks();
        expect(sent, hasLength(2));
        expect(sent[1].clientRequestId, isNot(sent[0].clientRequestId),
            reason: 'a rescan is a new check-in, not a retry');
        gate.dispose();
      });
    });

    test('the next guest is not held up by the last one\'s cooldown', () {
      fakeAsync((async) {
        final gate = make(async);
        gate.onDetected(ticketA);
        async.flushMicrotasks();
        async.elapse(GateScanController.validCardFor);
        gate.onDetected(ticketB);
        async.flushMicrotasks();
        expect(sent.map((r) => r.code), <String>[ticketA, ticketB]);
        gate.dispose();
      });
    });

    test('a code the desk refused to act on goes again once the card is gone',
        () {
      fakeAsync((async) {
        reply = (_) => const CheckInRefused(
            code: 'reauth_required',
            message: 'Enter your PIN again, then scan again');
        final gate = make(async);
        gate.onDetected(ticketA);
        async.flushMicrotasks();
        gate.dismissCard();
        reply = (_) => answered('ticket_check_in_valid.json');
        gate.onDetected(ticketA);
        async.flushMicrotasks();
        expect(sent, hasLength(2));
        expect(gate.state.card?.tone, GateTone.green);
        gate.dispose();
      });
    });

    test('a code read while the gate is busy is not swallowed: it goes once '
        'the gate is free', () {
      fakeAsync((async) {
        final gate = make(async);
        gate.onDetected(ticketA);
        async.flushMicrotasks();
        // Guest B shows their QR while A's card is still up.
        gate.onDetected(ticketB);
        expect(sent, hasLength(1));
        async.elapse(GateScanController.validCardFor);
        gate.onDetected(ticketB);
        async.flushMicrotasks();
        expect(sent.map((r) => r.code), <String>[ticketA, ticketB]);
        gate.dispose();
      });
    });
  });

  test('one request in flight: nothing else is read until the desk answers',
      () {
    fakeAsync((async) {
      held = Completer<TicketCheckInOutcome>();
      final gate = make(async);
      gate.onDetected(ticketA);
      expect(gate.state.inFlight, isTrue);
      gate.onDetected(ticketB);
      expect(gate.submitManual('ET-043'), isFalse);
      async.flushMicrotasks();
      expect(sent.map((r) => r.code), <String>[ticketA]);

      held!.complete(answered('ticket_check_in_valid.json'));
      async.flushMicrotasks();
      expect(gate.state.inFlight, isFalse);
      expect(gate.state.card?.tone, GateTone.green);
      gate.dispose();
    });
  });

  group('each answer has its tone and words', () {
    final cases = <String, (GateTone, String)>{
      'ticket_check_in_valid.json': (GateTone.green, 'Valid entry – 2 pax'),
      'ticket_check_in_already_used.json':
          (GateTone.red, 'Already used at 08:15 PM by Asha'),
      'ticket_check_in_expired.json':
          (GateTone.amber, 'Expired – issued 8 Oct'),
      // Spec §2.5: a cancelled or unknown ticket is a deny, like a reused one.
      'ticket_check_in_cancelled.json': (GateTone.red, 'Cancelled'),
      'ticket_check_in_not_found.json': (GateTone.red, 'Not found'),
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        fakeAsync((async) {
          reply = (_) => answered(entry.key);
          final gate = make(async);
          gate.onDetected(ticketB);
          async.flushMicrotasks();
          final card = gate.state.card!;
          expect(card.kind, GateCardKind.answer);
          expect(card.tone, entry.value.$1);
          expect(card.headline, entry.value.$2);
          expect(tones, <GateTone>[entry.value.$1],
              reason: 'one haptic per answer, in its tone');
          gate.dispose();
        });
      });
    }

    test(
        'the mapping itself (spec §2.5): valid green; already used, '
        'cancelled and not found red; expired amber', () {
      expect(toneForOutcome(CheckInOutcome.valid), GateTone.green);
      for (final deny in <CheckInOutcome>[
        CheckInOutcome.alreadyUsed,
        CheckInOutcome.cancelled,
        CheckInOutcome.notFound,
      ]) {
        expect(toneForOutcome(deny), GateTone.red, reason: deny.name);
      }
      expect(toneForOutcome(CheckInOutcome.expired), GateTone.amber);
      expect(toneForOutcome(CheckInOutcome.unknown), GateTone.amber,
          reason: 'a word this app does not know: not admitted, ask the desk');
    });

    test('words without the optional parts', () {
      expect(
          checkInHeadline(
              const CheckInResult(outcome: CheckInOutcome.alreadyUsed)),
          'Already used');
      expect(
          checkInHeadline(const CheckInResult(outcome: CheckInOutcome.expired)),
          'Expired');
      expect(checkInHeadline(const CheckInResult(outcome: CheckInOutcome.valid)),
          'Valid entry');
      expect(dayMonthOf('2026-01-05'), '5 Jan');
      expect(dayMonthOf('not a date'), isNull);
    });
  });

  group('cards come and go', () {
    test('green clears itself fast; red stays until tapped or 8s', () {
      fakeAsync((async) {
        final gate = make(async);
        gate.onDetected(ticketA);
        async.flushMicrotasks();
        async.elapse(GateScanController.validCardFor);
        expect(gate.state.card, isNull);

        reply = (_) => answered('ticket_check_in_already_used.json');
        gate.onDetected(ticketB);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 7));
        expect(gate.state.card?.tone, GateTone.red, reason: 'sticky');
        async.elapse(const Duration(seconds: 1));
        expect(gate.state.card, isNull);
        gate.dispose();
      });
    });

    test('a tap clears a card for the next guest', () {
      fakeAsync((async) {
        reply = (_) => answered('ticket_check_in_already_used.json');
        final gate = make(async);
        gate.onDetected(ticketA);
        async.flushMicrotasks();
        gate.dismissCard();
        expect(gate.state.card, isNull);
        expect(gate.state.acceptsScans, isTrue);
        gate.dispose();
      });
    });
  });

  group('an unanswered check-in', () {
    test('is kept with its id and locks the scanner until retried', () {
      fakeAsync((async) {
        reply = (_) => const CheckInUnconfirmed();
        final gate = make(async);
        gate.onDetected(ticketA);
        async.flushMicrotasks();
        final pending = gate.state.pending!;
        expect(gate.state.shownCard?.kind, GateCardKind.unconfirmed);
        expect(tones, <GateTone>[GateTone.amber]);

        // Locked: no other guest, no typing, no tapping it away, no timeout.
        async.elapse(const Duration(seconds: 30));
        gate.onDetected(ticketB);
        expect(gate.submitManual('ET-043'), isFalse);
        gate.dismissCard();
        expect(gate.state.shownCard?.kind, GateCardKind.unconfirmed);
        expect(sent, hasLength(1));

        reply = (_) => answered('ticket_check_in_valid.json');
        unawaited(gate.retryPending());
        async.flushMicrotasks();
        expect(sent, hasLength(2));
        expect(sent[1], same(pending),
            reason: 'the same request, so the desk replays "valid"');
        expect(gate.state.pending, isNull);
        expect(gate.state.card?.tone, GateTone.green);
        gate.dispose();
      });
    });

    test('a retry that again gets no answer stays held', () {
      fakeAsync((async) {
        reply = (_) => const CheckInUnconfirmed();
        final gate = make(async);
        gate.onDetected(ticketA);
        async.flushMicrotasks();
        unawaited(gate.retryPending());
        async.flushMicrotasks();
        expect(sent[1].clientRequestId, sent[0].clientRequestId);
        expect(gate.state.pending, isNotNull);
        gate.dispose();
      });
    });

    test('can be dropped on purpose, which frees the scanner', () {
      fakeAsync((async) {
        reply = (_) => const CheckInUnconfirmed();
        final gate = make(async);
        gate.onDetected(ticketA);
        async.flushMicrotasks();
        gate.abandonPending();
        expect(gate.state.pending, isNull);
        expect(gate.state.shownCard, isNull);
        reply = (_) => answered('ticket_check_in_valid.json');
        gate.onDetected(ticketB);
        async.flushMicrotasks();
        expect(sent.last.code, ticketB);
        gate.dispose();
      });
    });

    test('a PIN not entered again keeps it held; another refusal drops it', () {
      fakeAsync((async) {
        reply = (_) => const CheckInUnconfirmed();
        final gate = make(async);
        gate.onDetected(ticketA);
        async.flushMicrotasks();

        reply = (_) => const CheckInRefused(
            code: 'reauth_required',
            message: 'Enter your PIN again, then scan again');
        unawaited(gate.retryPending());
        async.flushMicrotasks();
        expect(gate.state.pending, isNotNull);
        expect(gate.state.card?.kind, GateCardKind.refused);
        async.elapse(GateScanController.stickyCardFor);
        expect(gate.state.shownCard?.kind, GateCardKind.unconfirmed,
            reason: 'still held once the message is gone');

        reply = (_) => const CheckInRefused(
            code: 'permission_denied',
            message: "You can't check guests in — ask the desk");
        unawaited(gate.retryPending());
        async.flushMicrotasks();
        expect(gate.state.pending, isNull);
        gate.dispose();
      });
    });
  });

  group('without the desk', () {
    test('scanning pauses: nothing is read or typed, until it is back', () {
      fakeAsync((async) {
        final gate = make(async, online: false);
        gate.onDetected(ticketA);
        expect(gate.submitManual('ET-042'), isFalse);
        expect(gate.state.acceptsScans, isFalse);
        expect(sent, isEmpty);

        gate.setOnline(true);
        gate.onDetected(ticketA);
        async.flushMicrotasks();
        expect(sent.single.code, ticketA,
            reason: 'a code read while paused was not remembered');
        gate.dispose();
      });
    });

    test('going offline mid-way pauses the next reads', () {
      fakeAsync((async) {
        final gate = make(async);
        gate.setOnline(false);
        gate.onDetected(ticketA);
        async.flushMicrotasks();
        expect(sent, isEmpty);
        gate.dispose();
      });
    });

    test('a retry waits for the desk too', () {
      fakeAsync((async) {
        reply = (_) => const CheckInUnconfirmed();
        final gate = make(async);
        gate.onDetected(ticketA);
        async.flushMicrotasks();
        gate.setOnline(false);
        unawaited(gate.retryPending());
        async.flushMicrotasks();
        expect(sent, hasLength(1));
        expect(gate.state.pending, isNotNull);
        gate.dispose();
      });
    });
  });

  test('a typed number goes as typed (trimmed), as a manual check-in, with no '
      'QR filter', () {
    fakeAsync((async) {
      final gate = make(async);
      expect(gate.submitManual('  et-42 '), isTrue);
      async.flushMicrotasks();
      expect(sent.single.code, 'et-42');
      expect(sent.single.method, CheckInMethod.manual);
      expect(gate.submitManual('   '), isFalse);
      gate.dispose();
    });
  });
}
