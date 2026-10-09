import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:restro/data/gate_providers.dart';
import 'package:restro/data/parked_providers.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/entry_ticket.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/models/parked_draft.dart';
import 'package:restro/models/pay_mode.dart';
import 'package:restro/screens/gate_screen.dart';
import 'package:restro/screens/ticket_issue_result_screen.dart';
import 'package:restro/screens/ticket_issue_screen.dart';
import 'package:restro/screens/ticket_recent_screen.dart';
import 'package:restro/services/bt_printer_service.dart';
import 'package:restro/services/connection_bootstrap.dart';
import 'package:restro/services/session_service.dart';
import 'package:restro/services/slip_printer.dart';
import 'package:restro/services/socket_service.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_bluetooth_printer.dart';

class _Bootstrap extends ConnectionBootstrap {
  _Bootstrap(super.ref);
}

typedef _Sent = ({String event, Map<String, dynamic> data});

final FeatureFlags _usher = FeatureFlags.fromMap(<String, dynamic>{
  'flag_entry_tickets': 1,
  'flag_ticket_issue': 1,
  'flag_ticket_checkin': 1,
  'flag_collect_payment': 0,
  'flag_generate_bill': 0,
});

class _Gate {
  _Gate(this.container, this.router);

  final ProviderContainer container;
  final GoRouter router;
  final List<_Sent> sent = <_Sent>[];
  late FutureOr<Object> Function(String event, Map<String, dynamic> data)
      answer;

  List<Map<String, dynamic>> payloads(String event) => <Map<String, dynamic>>[
        for (final s in sent)
          if (s.event == event) s.data,
      ];

  String get path => router.routerDelegate.currentConfiguration.uri.path;
}

/// The gate's screens over a fake desk: sell, see the slips, retry an
/// unanswered sale, park and resume, and today's list.
void main() {
  const dir = 'test/fixtures/crew-qsr';
  Map<String, dynamic> fixture(String name) =>
      jsonDecode(File('$dir/$name').readAsStringSync()) as Map<String, dynamic>;
  final sync = fixture('sync_qsr_keys.json');

  Object desk(String event, Map<String, dynamic> data) => switch (event) {
        'ticket:issue' => fixture('ticket_issue_ack.json'),
        'ticket:recent' => fixture('ticket_recent_ack.json'),
        'ticket:lookup' => fixture('ticket_lookup_ack.json'),
        _ => <String, dynamic>{'kind': 'success'},
      };

  Future<_Gate> pumpGate(
    WidgetTester tester, {
    String initial = '/gate/issue',
    FeatureFlags? flags,
    List<Override> overrides = const <Override>[],
    Map<String, Object> prefs = const <String, Object>{},
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(prefs);

    final socket = SocketService()..debugSetState(SocketState.verified);
    addTearDown(socket.dispose);
    final container = ProviderContainer(overrides: [
      ...overrides,
      socketServiceProvider.overrideWithValue(socket),
      connectionBootstrapProvider.overrideWith((ref) => _Bootstrap(ref)
        ..debugSetPairing(const PairingInfo(
            host: '192.168.1.20',
            port: 4100,
            token: 'tok',
            deskInstanceId: 'desk-1'))),
    ]);
    addTearDown(container.dispose);
    container.read(operatorProvider.notifier).state =
        const Operator(name: 'Asha', role: 'Usher', shift: 'Day', id: 'op-asha');
    container.read(flagsProvider.notifier).state = flags ?? _usher;
    container.read(ticketTypesProvider.notifier).state =
        TicketType.listFrom(sync['entry_ticket_types']);
    container.read(ticketConfigProvider.notifier).state =
        TicketConfig.tryParse(sync['entry_ticket_config'])!;
    container.read(listedPayModesProvider.notifier).state =
        PayMode.listFrom(sync['payment_modes']);

    final router = GoRouter(
      initialLocation: initial,
      routes: <RouteBase>[
        GoRoute(path: '/gate', builder: (_, __) => const GateScreen()),
        GoRoute(
            path: '/gate/issue',
            builder: (_, __) => const TicketIssueScreen()),
        GoRoute(
            path: '/gate/issue/result',
            builder: (_, __) => const TicketIssueResultScreen()),
        GoRoute(
            path: '/gate/recent',
            builder: (_, __) => const TicketRecentScreen()),
        GoRoute(
            path: '/gate/scan',
            builder: (_, __) => const Scaffold(body: Text('SCANNER'))),
        GoRoute(
            path: '/printer-settings',
            builder: (_, __) => const Scaffold(body: Text('PRINTER SETTINGS'))),
      ],
    );
    addTearDown(router.dispose);

    final h = _Gate(container, router)..answer = desk;
    socket.rawEmitOverride = (event, data, timeout) async {
      h.sent.add((event: event, data: Map<String, dynamic>.from(data)));
      final reply = await h.answer(event, data);
      if (reply is Exception || reply is Error) throw reply;
      return reply;
    };

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ));
    await tester.pumpAndSettle();
    return h;
  }

  /// Lets every toast run out, so no timer outlives the test.
  Future<void> drain(WidgetTester tester) =>
      tester.pumpAndSettle(const Duration(seconds: 5));

  Future<void> pickTwoCouplesAndCash(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey<String>('ticket-add-ett_couple')));
    await tester.tap(find.byKey(const ValueKey<String>('ticket-add-ett_couple')));
    await tester.pump();
    await tester.ensureVisible(find.text('Cash'));
    await tester.tap(find.text('Cash'));
    await tester.pump();
  }

  testWidgets('the gate home shows each tile only for the user\'s rights',
      (tester) async {
    await pumpGate(tester, initial: '/gate');
    expect(find.text('Issue tickets'), findsOneWidget);
    expect(find.text('Scan entry'), findsOneWidget);
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('Parked (0)'), findsOneWidget);
    expect(find.text('No printer'), findsOneWidget);

    await pumpGate(tester,
        initial: '/gate',
        flags: FeatureFlags.fromMap(<String, dynamic>{
          'flag_entry_tickets': 1,
          'flag_ticket_issue': 0,
          'flag_ticket_checkin': 1,
        }));
    expect(find.text('Issue tickets'), findsNothing);
    expect(find.text('Scan entry'), findsOneWidget);
    expect(find.textContaining('Parked'), findsNothing);
  });

  testWidgets('a sale: one ticket:issue with fill tenders, then the slips',
      (tester) async {
    final h = await pumpGate(tester);
    await pickTwoCouplesAndCash(tester);
    expect(find.text('Issue ₹4,000'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('issue-go')));
    await tester.pumpAndSettle();

    final sale = h.payloads('ticket:issue').single;
    expect(sale['lines'], <Map<String, dynamic>>[
      <String, dynamic>{'ticket_type_id': 'ett_couple', 'qty': 2},
    ]);
    expect(sale['payments'], <Map<String, dynamic>>[
      <String, dynamic>{'payment_mode': 'cash'},
    ], reason: 'the last tender fills: the desk charges its own total');
    expect(sale['expected_total'], 4000);
    expect(h.path, '/gate/issue/result');
    expect(find.text('ET/26-27/000037'), findsOneWidget);
    expect(find.text('ET-041'), findsOneWidget);
    expect(find.text('ET-042'), findsOneWidget);
    expect(find.text('Set up printer'), findsOneWidget,
        reason: 'no printer yet: Print waits for one');
    expect(h.container.read(ticketIssueFormProvider).hasTickets, isFalse,
        reason: 'the form is cleared for the next guest');

    await tester.tap(find.byKey(const ValueKey<String>('show-qr-et_41a')));
    await tester.pumpAndSettle();
    expect(find.text('ADMITS 2 PAX'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('no printer: the chip opens the printer settings',
      (tester) async {
    await pumpGate(tester, initial: '/gate');
    await tester.tap(find.text('No printer'));
    await tester.pumpAndSettle();
    expect(find.text('PRINTER SETTINGS'), findsOneWidget);
  });

  /// A Bluetooth printer is set up on this phone, as main.dart wires it.
  final printerPrefs = <String, Object>{
    BtPrinterSettings.prefsKey: jsonEncode(const BtPrinterSettings(
            printer: BtPrinterInfo(name: 'RPP02N', address: '66:02:BD:06:18:7B'))
        .toJson()),
  };
  List<Override> printerOverrides(FakeBluetoothPrinter printer) => [
        bluetoothPrinterProvider.overrideWithValue(printer),
        btPrinterServiceProvider.overrideWith(
            (ref) => BtPrinterService(printer, interSlipPause: Duration.zero)),
        slipPrinterProvider
            .overrideWith((ref) => ref.watch(btSlipPrinterProvider)),
      ];

  testWidgets(
      'with a printer set up, a sale\'s slips print by themselves, once each',
      (tester) async {
    final printer = FakeBluetoothPrinter();
    final h = await pumpGate(tester,
        prefs: printerPrefs, overrides: printerOverrides(printer));
    await pickTwoCouplesAndCash(tester);
    await tester.tap(find.byKey(const ValueKey<String>('issue-go')));
    await tester.pumpAndSettle();

    expect(h.path, '/gate/issue/result');
    expect(printer.written, hasLength(2), reason: 'one write per slip');
    expect(latin1.decode(printer.written[0]), contains('ET-041'));
    expect(latin1.decode(printer.written[1]), contains('ET-042'));
    expect(find.text('Slip printed'), findsNWidgets(2));
    expect(find.text('Reprint 2 slips'), findsOneWidget,
        reason: 'printed already: a second copy only after a warning');

    await tester.ensureVisible(find.text('Reprint 2 slips'));
    await tester.tap(find.text('Reprint 2 slips'));
    await tester.pumpAndSettle();
    expect(find.text('Print again?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(printer.written, hasLength(2), reason: 'nothing reprinted');
    await drain(tester);
  });

  testWidgets('a slip that did not print waits on the gate home until it does',
      (tester) async {
    final printer = FakeBluetoothPrinter()..writeAnswers.addAll(<bool>[true, false]);
    final h = await pumpGate(tester,
        prefs: printerPrefs, overrides: printerOverrides(printer));
    await pickTwoCouplesAndCash(tester);
    await tester.tap(find.byKey(const ValueKey<String>('issue-go')));
    await tester.pumpAndSettle();
    expect(find.text('Slip printed'), findsOneWidget);
    expect(find.text("Didn't print"), findsOneWidget);
    expect(find.text('Print 1 slip'), findsOneWidget,
        reason: 'only the one that did not print, no warning');

    h.router.go('/gate');
    await tester.pumpAndSettle();
    expect(find.text('Printer ready'), findsOneWidget);
    await tester.tap(find.text('1 slip not printed'));
    await tester.pumpAndSettle();
    expect(find.text('ET-042'), findsOneWidget);
    expect(find.text('ET-041'), findsNothing, reason: 'that one printed');

    await tester.tap(find.byKey(const ValueKey<String>('slip-queue-print')));
    await tester.pumpAndSettle();
    expect(printer.written, hasLength(2));
    expect(latin1.decode(printer.written.last), contains('ET-042'));
    expect(find.text('Every slip has printed.'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('an unanswered sale locks the form; Retry sends the same one',
      (tester) async {
    final h = await pumpGate(tester);
    h.answer = (_, __) => TimeoutException('ack timed out');
    await pickTwoCouplesAndCash(tester);
    await tester.tap(find.byKey(const ValueKey<String>('issue-go')));
    await tester.pumpAndSettle();

    expect(h.container.read(pendingTicketIssueProvider), isNotNull);
    expect(find.text('Not confirmed yet'), findsOneWidget);
    expect(find.text('Retry sale'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('ticket-add-ett_couple')),
        findsNothing,
        reason: 'locked: nothing can be changed under the kept sale');

    h.answer = desk;
    await tester.tap(find.text('Retry sale'));
    await tester.pumpAndSettle();
    final sales = h.payloads('ticket:issue');
    expect(sales, hasLength(2));
    expect(sales[1], sales[0], reason: 'same request, same id');
    expect(h.path, '/gate/issue/result');
    expect(h.container.read(pendingTicketIssueProvider), isNull);
    await drain(tester);
  });

  testWidgets('a refusal that proves nothing is kept too; a business one is not',
      (tester) async {
    final h = await pumpGate(tester);
    h.answer = (_, __) =>
        <String, dynamic>{'kind': 'error', 'message': 'Internal error'};
    await pickTwoCouplesAndCash(tester);
    await tester.tap(find.byKey(const ValueKey<String>('issue-go')));
    await tester.pumpAndSettle();
    expect(h.container.read(pendingTicketIssueProvider), isNotNull,
        reason: 'an error with no code may follow a sale that went through');
    await drain(tester);

    h.container.read(pendingTicketIssueProvider.notifier).state = null;
    await tester.pumpAndSettle();
    h.answer = (_, __) => <String, dynamic>{
          'kind': 'error',
          'code': 'payment_short',
          'message': 'PAYMENT_SHORT',
        };
    await tester.tap(find.byKey(const ValueKey<String>('issue-go')));
    await tester.pumpAndSettle();
    expect(h.container.read(pendingTicketIssueProvider), isNull);
    expect(find.text("The payments don't cover the tickets"), findsOneWidget);
    expect(h.path, '/gate/issue');
    await drain(tester);
  });

  testWidgets('a sale can be parked, and resumed over another (park current)',
      (tester) async {
    final h = await pumpGate(tester);
    await pickTwoCouplesAndCash(tester);
    await tester.tap(find.byKey(const ValueKey<String>('issue-park')));
    await tester.pumpAndSettle();
    expect(h.container.read(ticketIssueFormProvider).hasTickets, isFalse);
    expect(h.container.read(parkedCountProvider(ParkedKind.ticketIssue)), 1);

    // A new guest: one stag entry on screen, then the parked sale back.
    await tester.tap(find.byKey(const ValueKey<String>('ticket-add-ett_stag')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('issue-parked')));
    await tester.pumpAndSettle();
    final parked = h.container
        .read(parkedByKindProvider(ParkedKind.ticketIssue))
        .single;
    await tester
        .tap(find.byKey(ValueKey<String>('parked-resume-${parked.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Sale in progress'), findsOneWidget);
    await tester.tap(find.text('Park current and resume'));
    await tester.pumpAndSettle();

    final form = h.container.read(ticketIssueFormProvider);
    expect(form.quantities, <String, int>{'ett_couple': 2});
    final left =
        h.container.read(parkedByKindProvider(ParkedKind.ticketIssue)).single;
    expect((left.payload as TicketIssueDraft).lines.single.ticketTypeId,
        'ett_stag');
    await drain(tester);
  });

  testWidgets('today\'s list: counters, statuses, phones as last four',
      (tester) async {
    final h = await pumpGate(tester, initial: '/gate/recent');
    expect(h.payloads('ticket:recent').single, <String, dynamic>{'limit': 100});
    expect(find.text('ET-043'), findsOneWidget);
    expect(find.text('Cancelled'), findsWidgets);
    expect(find.textContaining('•••• 3210'), findsWidgets);
    expect(find.textContaining('9876'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Entered'));
    await tester.pumpAndSettle();
    expect(find.text('ET-042'), findsOneWidget);
    expect(find.text('ET-043'), findsNothing);
    await drain(tester);
  });
}
