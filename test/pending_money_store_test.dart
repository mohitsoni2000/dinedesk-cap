import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/counter_providers.dart';
import 'package:restro/data/gate_providers.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/parked_draft.dart';
import 'package:restro/models/pay_mode.dart';
import 'package:restro/models/token.dart';
import 'package:restro/screens/counter_checkout_screen.dart';
import 'package:restro/services/connection_bootstrap.dart';
import 'package:restro/services/entry_ticket_service.dart';
import 'package:restro/services/pending_money_store.dart';
import 'package:restro/services/qsr_checkout_service.dart';
import 'package:restro/services/session_service.dart';
import 'package:restro/services/socket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bootstrap extends ConnectionBootstrap {
  _Bootstrap(super.ref);
}

/// An unanswered Pay & Fire or ticket sale is written to the phone before it
/// is sent, and stays there until the desk answers it for certain. A
/// restart, a crash or a sign-out (forced or not) cannot lose its id: its
/// operator gets the same request back to retry, and nobody else sees it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const dir = 'test/fixtures/crew-qsr';
  Map<String, dynamic> fixture(String name) =>
      jsonDecode(File('$dir/$name').readAsStringSync()) as Map<String, dynamic>;

  const asha =
      Operator(name: 'Asha', role: 'Cashier', shift: 'Day', id: 'op-asha');
  const ravi =
      Operator(name: 'Ravi', role: 'Cashier', shift: 'Day', id: 'op-ravi');
  const ashaHere = ParkedScope(operatorId: 'op-asha', deskInstanceId: '');
  const raviHere = ParkedScope(operatorId: 'op-ravi', deskInstanceId: '');

  late SocketService socket;
  late List<({String event, Map<String, dynamic> data})> sent;
  late FutureOr<Object> Function(String event, Map<String, dynamic> data)
      answer;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    socket = SocketService()..debugSetState(SocketState.verified);
    sent = <({String event, Map<String, dynamic> data})>[];
    answer = (event, _) => event == 'qsr:checkout'
        ? fixture('qsr_checkout_ack.json')
        : fixture('ticket_issue_ack.json');
    socket.rawEmitOverride = (event, data, timeout) async {
      sent.add((event: event, data: Map<String, dynamic>.from(data)));
      final reply = await answer(event, data);
      if (reply is Exception || reply is Error) throw reply;
      return reply;
    };
  });

  tearDown(() => socket.dispose());

  /// A fresh app process: a new container over the same phone storage.
  ProviderContainer boot({Operator? operator}) {
    final c = ProviderContainer(overrides: [
      socketServiceProvider.overrideWithValue(socket),
      qsrCheckoutServiceProvider.overrideWithValue(QsrCheckoutService(socket)),
      entryTicketServiceProvider.overrideWithValue(EntryTicketService(socket)),
    ]);
    addTearDown(c.dispose);
    if (operator != null) c.read(operatorProvider.notifier).state = operator;
    return c;
  }

  /// Reads the provider (so it starts reading the phone) and lets it finish.
  Future<T?> settled<T>(ProviderContainer c, ProviderListenable<T?> p) async {
    c.read(p);
    await pumpEventQueue();
    return c.read(p);
  }

  QsrCheckoutRequest checkout() => QsrCheckoutRequest(
        fulfillment: FulfillmentType.standing,
        items: <Map<String, dynamic>>[
          <String, dynamic>{'item_id': 'itm_roll', 'quantity': 2},
        ],
        payments: const <TenderLine>[
          TenderLine(mode: 'cover_ticket', ticketCode: 'CDT:7QKX2MZ4HB6TNW3R'),
          TenderLine(mode: 'upi', reference: '628311904417'),
        ],
        notes: 'no onion',
        customerId: 'cus_9',
        expectedTotal: const Money(105050),
      );

  PendingCheckout keptCheckout({String operatorId = 'op-asha'}) =>
      PendingCheckout(
        request: checkout(),
        cart: const <CartLine>[],
        estimate: const Money(105050),
        operatorId: operatorId,
        itemCount: 2,
      );

  TicketIssueRequest sale() => TicketIssueRequest(
        lines: const <TicketIssueLine>[
          TicketIssueLine(ticketTypeId: 'ett_couple', qty: 2),
        ],
        guestName: 'Ravi Sharma',
        guestPhone: '9876543210',
        payments: const <TenderLine>[
          TenderLine(mode: 'cash', amount: Money.rupees(1000)),
          TenderLine(mode: 'upi', reference: '628311904417'),
        ],
        expectedTotal: const Money.rupees(4000),
      );

  PendingTicketIssue keptSale() => PendingTicketIssue(
        request: sale(),
        summary: '2× Couple Pass',
        form: const TicketIssueForm(),
        operatorId: 'op-asha',
      );

  group('PendingMoneyStore', () {
    test('one attempt per operator per desk; the others are never touched',
        () async {
      final store = PendingMoneyStore(PendingMoneyStore.checkoutKey);
      await store.write(ashaHere, <String, dynamic>{'client_request_id': 'a1'});
      await store.write(raviHere, <String, dynamic>{'client_request_id': 'r1'});
      const elsewhere =
          ParkedScope(operatorId: 'op-asha', deskInstanceId: 'desk-2');
      await store
          .write(elsewhere, <String, dynamic>{'client_request_id': 'e1'});

      // A new store reads what the last one wrote (a new app process).
      final again = PendingMoneyStore(PendingMoneyStore.checkoutKey);
      expect((await again.read(ashaHere))?.attempt['client_request_id'], 'a1');
      expect((await again.read(raviHere))?.attempt['client_request_id'], 'r1');
      expect((await again.read(elsewhere))?.attempt['client_request_id'], 'e1');

      await again.remove(ashaHere, 'some-other-id');
      expect(await again.read(ashaHere), isNotNull,
          reason: 'only the answered attempt is removed, never a newer one');
      await again.remove(ashaHere, 'a1');
      expect(await again.read(ashaHere), isNull);
      expect(await again.read(raviHere), isNotNull);
      expect(await again.read(elsewhere), isNotNull);
    });

    test(
        "past the replay window, anyone's attempt is dropped by the next "
        'write: it can never be retried, and a sale names its guest', () async {
      final old = PendingMoneyStore(PendingMoneyStore.issueKey,
          now: () => DateTime.now().subtract(const Duration(hours: 49)));
      await old.write(raviHere, <String, dynamic>{'client_request_id': 'r0'});
      final store = PendingMoneyStore(PendingMoneyStore.issueKey);
      expect(await store.read(raviHere), isNotNull, reason: 'a read drops none');

      await store.write(ashaHere, <String, dynamic>{'client_request_id': 'a1'});
      expect(await store.read(raviHere), isNull);
      expect((await store.read(ashaHere))?.attempt['client_request_id'], 'a1');
    });

    test("a removal drops them too, and a slot it can't date is kept",
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'pending_checkout_v1': jsonEncode(<String, Object?>{
          'schema': 1,
          'attempts': <String, Object?>{
            jsonEncode(<String>['', 'op-ravi']): <String, Object?>{
              'saved_at': DateTime.now()
                  .subtract(const Duration(hours: 49))
                  .toUtc()
                  .toIso8601String(),
              'attempt': <String, Object?>{'client_request_id': 'r0'},
            },
            jsonEncode(<String>['', 'op-old']): <String, Object?>{
              'attempt': <String, Object?>{'client_request_id': 'x0'},
            },
          },
        }),
      });
      final store = PendingMoneyStore(PendingMoneyStore.checkoutKey);
      await store.write(ashaHere, <String, dynamic>{'client_request_id': 'a1'});
      await store.remove(ashaHere, 'a1');
      expect(await store.read(raviHere), isNull);
      expect(
          await store.read(
              const ParkedScope(operatorId: 'op-old', deskInstanceId: '')),
          isNotNull,
          reason: 'never drop what cannot be dated');
    });

    test('something unreadable is moved aside, never deleted', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{'pending_issue_v1': '{not json'});
      final store = PendingMoneyStore(PendingMoneyStore.issueKey);
      expect(await store.read(ashaHere), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('pending_issue_v1'), '{not json',
          reason: 'a read changes nothing');

      expect(
          await store
              .write(ashaHere, <String, dynamic>{'client_request_id': 'a'}),
          isTrue);
      expect(prefs.getString('pending_issue_v1.unreadable'), '{not json');
      expect((await store.read(ashaHere))?.attempt['client_request_id'], 'a');
    });
  });

  group('a kept Pay & Fire', () {
    test(
        'written ahead and then the app dies: its operator gets the very same '
        'request back, and the retry is a replay', () async {
      final first = boot(operator: asha);
      final attempt = keptCheckout();
      await first.read(pendingCheckoutProvider.notifier).writeAhead(attempt);
      first.dispose(); // killed while the desk was answering

      final next = boot(operator: asha);
      final back = await settled(next, pendingCheckoutProvider);
      expect(back, isNotNull);
      expect(back!.clientRequestId, attempt.clientRequestId);
      expect(back.request.toPayload(), attempt.request.toPayload());
      expect(back.itemCount, 2);
      expect(back.estimate, const Money(105050));

      final result = await retryPendingCheckout(next, back);
      expect(result, isA<QsrCheckoutOk>());
      expect(sent.single.data, attempt.request.toPayload(),
          reason: 'the same payload and client_request_id');
      expect(next.read(pendingCheckoutProvider), isNull);
      await pumpEventQueue();
      expect(
          await settled(boot(operator: asha), pendingCheckoutProvider), isNull,
          reason: 'answered for certain: gone from the phone too');
    });

    test(
        'a forced sign-out hides it, another operator never sees it, its '
        'operator back gets it again', () async {
      final c = boot(operator: asha);
      final attempt = keptCheckout();
      await c.read(pendingCheckoutProvider.notifier).writeAhead(attempt);
      c.read(pendingCheckoutProvider.notifier).hold(attempt);
      expect(c.read(pendingCheckoutProvider), same(attempt));

      // Revoked: the operator is cleared.
      c.read(operatorProvider.notifier).state = null;
      expect(c.read(pendingCheckoutProvider), isNull);

      c.read(operatorProvider.notifier).state = ravi;
      expect(await settled(c, pendingCheckoutProvider), isNull,
          reason: "Ravi's retry would charge again");

      c.read(operatorProvider.notifier).state = asha;
      final back = await settled(c, pendingCheckoutProvider);
      expect(back?.clientRequestId, attempt.clientRequestId);
    });

    test('dropped on purpose, it is gone from the phone', () async {
      final c = boot(operator: asha);
      final attempt = keptCheckout();
      c.read(pendingCheckoutProvider.notifier).hold(attempt);
      await pumpEventQueue();
      await c.read(pendingCheckoutProvider.notifier).settle(attempt);
      expect(c.read(pendingCheckoutProvider), isNull);
      expect(
          await settled(boot(operator: asha), pendingCheckoutProvider), isNull);
    });

    test('past the desk\'s 48 h replay window it is not offered again',
        () async {
      final old = PendingMoneyStore(PendingMoneyStore.checkoutKey,
          now: () => DateTime.now().subtract(const Duration(hours: 49)));
      await old.write(ashaHere, keptCheckout().toJson());
      expect(
          await settled(boot(operator: asha), pendingCheckoutProvider), isNull,
          reason: 'the desk no longer replays it: a retry would charge anew');
      expect(await old.read(ashaHere), isNull);
    });
  });

  group('on the phone, kept tidy', () {
    test("signing in drops anyone's attempt past the replay window",
        () async {
      await PendingMoneyStore(PendingMoneyStore.issueKey,
              now: () => DateTime.now().subtract(const Duration(hours: 49)))
          .write(raviHere, keptSale().toJson());
      expect(await settled(boot(operator: asha), pendingTicketIssueProvider),
          isNull);
      expect(
          await PendingMoneyStore(PendingMoneyStore.issueKey).read(raviHere),
          isNull,
          reason: "Ravi never came back: his guest's name and phone go");
    });

    test(
        'a kept attempt this app cannot read back is moved aside, never '
        'written over by the next one', () async {
      final store = PendingMoneyStore(PendingMoneyStore.checkoutKey);
      // A shape this version cannot read (no fulfillment in its payload).
      await store.write(ashaHere, <String, dynamic>{
        'client_request_id': 'req_unreadable',
        'operator_id': 'op-asha',
        'desk': '',
        'payload': <String, dynamic>{'client_request_id': 'req_unreadable'},
      });
      final c = boot(operator: asha);
      expect(await settled(c, pendingCheckoutProvider), isNull,
          reason: 'it cannot be retried as it was sent, so it is not offered');
      await pumpEventQueue();
      final prefs = await SharedPreferences.getInstance();
      final aside = prefs.getString('pending_checkout_v1.unreadable');
      expect(aside, contains('req_unreadable'));
      expect(await store.read(ashaHere), isNull, reason: 'its slot is free');

      final next = keptCheckout();
      await c.read(pendingCheckoutProvider.notifier).writeAhead(next);
      expect(prefs.getString('pending_checkout_v1.unreadable'), aside,
          reason: 'kept on the phone, never written over');
      expect((await store.read(ashaHere))?.attempt['client_request_id'],
          next.clientRequestId);
    });
  });

  group('a kept ticket sale', () {
    test(
        'survives a restart for its operator only, guest and all, and the '
        'retry is the same request', () async {
      final first = boot(operator: asha);
      final attempt = keptSale();
      await first.read(pendingTicketIssueProvider.notifier).writeAhead(attempt);
      first.dispose();

      final other = boot(operator: ravi);
      expect(await settled(other, pendingTicketIssueProvider), isNull,
          reason: "never another operator's sale, nor its guest");

      final next = boot(operator: asha);
      final back = await settled(next, pendingTicketIssueProvider);
      expect(back, isNotNull);
      expect(back!.summary, '2× Couple Pass');
      expect(back.request.toPayload(), attempt.request.toPayload());
      expect(back.form.qtyOf('ett_couple'), 2);
      expect(back.form.guestName, 'Ravi Sharma');

      final outcome = await retryPendingIssue(next, back);
      expect(outcome, isA<TicketIssueOk>());
      expect(sent.single.data, attempt.request.toPayload());
      expect(next.read(pendingTicketIssueProvider), isNull);
      expect(next.read(ticketIssueResultProvider), isNotNull);
    });

    test(
        'another desk never sees it, not even under the same operator id; '
        'unpairing hides it until its own desk is back', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      ProviderContainer on(String desk) {
        final c = ProviderContainer(overrides: [
          socketServiceProvider.overrideWithValue(socket),
          entryTicketServiceProvider
              .overrideWithValue(EntryTicketService(socket)),
          connectionBootstrapProvider.overrideWith((ref) => _Bootstrap(ref)
            ..debugSetPairing(PairingInfo(
                host: '10.0.0.5',
                port: 4100,
                token: 'tok',
                deskInstanceId: desk))),
        ]);
        addTearDown(c.dispose);
        // A username fallback id: the same on every desk.
        c.read(operatorProvider.notifier).state = asha;
        return c;
      }

      final here = on('desk-1');
      final attempt = PendingTicketIssue(
        request: sale(),
        summary: '2× Couple Pass',
        form: const TicketIssueForm(),
        operatorId: 'op-asha',
        desk: 'desk-1',
      );
      await here.read(pendingTicketIssueProvider.notifier).writeAhead(attempt);
      here.read(pendingTicketIssueProvider.notifier).hold(attempt);
      expect(here.read(pendingTicketIssueProvider), same(attempt));

      await here.read(connectionBootstrapProvider.notifier).signOut();
      expect(here.read(pendingTicketIssueProvider), isNull,
          reason: 'unpaired: not shown');

      expect(await settled(on('desk-2'), pendingTicketIssueProvider), isNull,
          reason: "another desk's sale (and guest) is never shown");
      expect(
          (await settled(on('desk-1'), pendingTicketIssueProvider))
              ?.clientRequestId,
          attempt.clientRequestId,
          reason: 'kept on the phone for its own desk and operator');
    });

    test('a forced sign-out does not drop it', () async {
      final c = boot(operator: asha);
      final attempt = keptSale();
      await c.read(pendingTicketIssueProvider.notifier).writeAhead(attempt);
      c.read(pendingTicketIssueProvider.notifier).hold(attempt);
      c.read(operatorProvider.notifier).state = null;
      expect(c.read(pendingTicketIssueProvider), isNull);
      c.read(operatorProvider.notifier).state = asha;
      expect((await settled(c, pendingTicketIssueProvider))?.clientRequestId,
          attempt.clientRequestId);
    });
  });
}
