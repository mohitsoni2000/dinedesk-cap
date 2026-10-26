// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/screens/order_detail_screen.dart';
import 'package:restro/services/socket_service.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The bill screen opened for an order the desk has already billed loads that
/// bill straight away, as the desk's own Bill screen does, so payment and
/// printing are there without a "Generate Bill" tap.
void main() {
  const orderId = 'ord_9';

  const order = HistoryOrder(
    id: 'KOT-0001',
    orderId: orderId,
    tableId: 'T5',
    time: '14:58',
    date: '2026-10-09',
    itemCount: 2,
    total: Money.rupees(500),
    status: OrderStatus.sent,
    lines: <HistoryOrderLine>[],
  );

  RestaurantTable table({int bills = 1}) => RestaurantTable(
        id: 'T5',
        serverId: 'srv-5',
        seats: 4,
        floor: 'Ground',
        state: TableState.mine,
        activeOrderId: orderId,
        activeBillCount: bills,
      );

  final sent = <String>[];
  var printKotAnswer = <String, dynamic>{'kind': 'success', 'queued': true};

  Future<void> openDetail(
    WidgetTester tester, {
    required Map<String, int> flags,
    int bills = 1,
    bool onTable = true,
    List<RestaurantRoom> rooms = const <RestaurantRoom>[],
  }) async {
    tester.view.physicalSize = const Size(1024, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final socket = SocketService()..debugSetState(SocketState.verified);
    socket.rawEmitOverride = (event, data, timeout) async {
      sent.add(event);
      if (event == 'print:kot') return printKotAnswer;
      if (event != 'bill:generate') return <String, dynamic>{'kind': 'success'};
      return <String, dynamic>{
        'kind': 'success',
        'bills': <Object>[
          <String, dynamic>{
            'id': 'b1',
            'bill_number': 'INV/1',
            'bill_type': 'food',
            'total_amount': 500,
            'payment_status': 'unpaid',
            'status': 'active',
          },
        ],
      };
    };
    addTearDown(socket.dispose);

    final container = ProviderContainer(overrides: [
      socketServiceProvider.overrideWithValue(socket),
    ]);
    addTearDown(container.dispose);
    container.read(flagsProvider.notifier).state = FeatureFlags.fromMap(
        <String, dynamic>{for (final e in flags.entries) e.key: e.value});
    container.read(historyProvider.notifier).state = const [order];
    container.read(tablesProvider.notifier).state =
        onTable ? [table(bills: bills)] : const <RestaurantTable>[];
    container.read(roomsProvider.notifier).state = rooms;

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const OrderDetailScreen(orderId: orderId),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  setUp(() {
    sent.clear();
    printKotAnswer = <String, dynamic>{'kind': 'success', 'queued': true};
  });

  const cashier = <String, int>{
    'flag_generate_bill': 1,
    'flag_collect_payment': 1,
    'flag_bill_printing': 1,
  };

  testWidgets('a billed order opens with its bill: pay and print, no Generate',
      (tester) async {
    await openDetail(tester, flags: cashier);

    expect(sent, contains('bill:generate'));
    expect(find.text('Collect Payment'), findsOneWidget);
    expect(find.text('Print Bill'), findsOneWidget);
    expect(find.text('Generate Bill'), findsNothing);
  });

  testWidgets('an order with no bill yet still waits for Generate Bill',
      (tester) async {
    await openDetail(tester, flags: cashier, bills: 0);

    expect(sent, isNot(contains('bill:generate')));
    expect(find.text('Generate Bill'), findsOneWidget);
  });

  testWidgets('without the right to make a bill, nothing is asked of the desk',
      (tester) async {
    await openDetail(tester, flags: const <String, int>{
      'flag_generate_bill': 0,
      'flag_direct_bill': 0,
      'flag_collect_payment': 1,
    });

    expect(sent, isNot(contains('bill:generate')));
  });

  group('Cancel Order', () {
    const canCancel = <String, int>{
      'flag_cancel_order': 1,
      'flag_void_bills': 1,
    };

    testWidgets('a table order with no bill can be cancelled', (tester) async {
      await openDetail(tester, flags: canCancel, bills: 0);

      expect(find.text('Cancel Order'), findsOneWidget);
    });

    testWidgets('a room order cannot: a stay is ended at the desk',
        (tester) async {
      await openDetail(tester, flags: canCancel, onTable: false, rooms: const [
        RestaurantRoom(
          id: '101',
          serverId: 'room-101',
          capacity: 2,
          state: RoomState.mine,
          activeOrderId: orderId,
        ),
      ]);

      expect(find.text('Cancel Order'), findsNothing,
          reason: 'cancelling releases the room and voids its bills');
    });
  });

  testWidgets(
      'an unpaid bill can still take a discount, as on the desk (the desk '
      'resyncs the bill)', (tester) async {
    await openDetail(tester, flags: const <String, int>{
      ...cashier,
      'flag_discounts': 1,
    });

    expect(find.text('Collect Payment'), findsOneWidget);
    expect(find.text('Discount'), findsOneWidget,
        reason: 'a bill with no discount on it is not "Discount Applied"');
  });

  testWidgets('Link Customer needs the change-customer permission, not just '
      'the Customers module', (tester) async {
    await openDetail(tester, bills: 0, flags: const <String, int>{
      'flag_customers': 1,
      'flag_customer_link': 0,
    });
    expect(find.byIcon(Icons.person_add_outlined), findsNothing);
  });

  testWidgets('a reprint the desk dropped as a duplicate is not "queued"',
      (tester) async {
    printKotAnswer = <String, dynamic>{
      'kind': 'success',
      'queued': false,
      'duplicate': true,
    };
    await openDetail(tester, bills: 0, flags: const <String, int>{
      'flag_kot_printing': 1,
      'flag_kot_reprint': 1,
    });

    await tester.tap(find.text('Reprint KOT'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(sent, contains('print:kot'));
    expect(find.textContaining('Reprint queued'), findsNothing);
    expect(find.text('This KOT was just sent to the printer'), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
  });
}
