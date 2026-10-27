// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/screens/tables_screen.dart';
import 'package:restro/services/socket_service.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tapping a table on the phone goes where the desk's floor plan goes: a
/// billed table to its bill, a running table to its order.
void main() {
  const billedOrderId = 'ord_9';

  RestaurantTable table(
    String name,
    TableState state, {
    String serverId = 'srv-5',
    String? orderId,
    int bills = 0,
  }) =>
      RestaurantTable(
        id: name,
        serverId: serverId,
        seats: 4,
        floor: 'Ground',
        state: state,
        activeOrderId: orderId,
        activeBillCount: bills,
      );

  const history = HistoryOrder(
    id: 'KOT-0001',
    orderId: billedOrderId,
    tableId: 'T5',
    time: '14:58',
    date: '2026-10-09',
    itemCount: 2,
    total: Money.rupees(1000),
    status: OrderStatus.sent,
    lines: <HistoryOrderLine>[],
  );

  /// The tables screen never goes idle (a status animation loops), so
  /// pumpAndSettle would time out; a second covers the page transition.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<GoRouter> pumpTables(
    WidgetTester tester, {
    required List<RestaurantTable> tables,
    List<HistoryOrder> inHistory = const <HistoryOrder>[],
    Map<String, int> flags = const <String, int>{'flag_generate_bill': 1},
    SocketService? socket,
  }) async {
    tester.view.physicalSize = const Size(1024, 1366);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final container = ProviderContainer(overrides: [
      if (socket != null) socketServiceProvider.overrideWithValue(socket),
    ]);
    addTearDown(container.dispose);
    container.read(tablesProvider.notifier).state = tables;
    container.read(historyProvider.notifier).state = inHistory;
    container.read(flagsProvider.notifier).state = FeatureFlags.fromMap(
        <String, dynamic>{for (final e in flags.entries) e.key: e.value});

    final router = GoRouter(
      initialLocation: '/tables',
      routes: <RouteBase>[
        GoRoute(path: '/tables', builder: (_, __) => const TablesScreen()),
        GoRoute(
            path: '/history/:orderId',
            builder: (_, s) =>
                Scaffold(body: Text('BILL ${s.pathParameters['orderId']}'))),
        GoRoute(
            path: '/order/:tableId',
            builder: (_, s) =>
                Scaffold(body: Text('ORDER ${s.pathParameters['tableId']}'))),
      ],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ));
    await settle(tester);
    return router;
  }

  /// The page on top: a pushed page keeps the underlying location, so read
  /// the last match rather than the router's uri.
  String path(GoRouter r) =>
      r.routerDelegate.currentConfiguration.last.matchedLocation;

  testWidgets('a billed table opens its bill', (tester) async {
    final router = await pumpTables(
      tester,
      tables: [
        table('T5', TableState.mine, orderId: billedOrderId, bills: 1),
      ],
      inHistory: const [history],
    );

    await tester.tap(find.text('T5'));
    await settle(tester);

    expect(path(router), '/history/$billedOrderId');
    expect(find.text('BILL $billedOrderId'), findsOneWidget);
  });

  testWidgets('the bill is a step on top of Tables, so Back returns there',
      (tester) async {
    final router = await pumpTables(
      tester,
      tables: [
        table('T5', TableState.mine, orderId: billedOrderId, bills: 1),
      ],
      inHistory: const [history],
    );

    await tester.tap(find.text('T5'));
    await settle(tester);
    router.pop();
    await settle(tester);

    expect(path(router), '/tables');
  });

  testWidgets(
      'a billed table whose order the phone does not hold falls back to the '
      'order instead of a dead "Order not found"', (tester) async {
    final router = await pumpTables(
      tester,
      tables: [
        table('T5', TableState.mine, orderId: billedOrderId, bills: 1),
      ],
    );

    await tester.tap(find.text('T5'));
    await settle(tester);

    expect(path(router), '/order/srv-5');
  });

  testWidgets(
      'without the right to make a bill, a billed table opens its order '
      '(the bill screen could not load the bill)', (tester) async {
    final router = await pumpTables(
      tester,
      tables: [
        table('T5', TableState.mine, orderId: billedOrderId, bills: 1),
      ],
      inHistory: const [history],
      flags: const <String, int>{'flag_generate_bill': 0, 'flag_direct_bill': 0},
    );

    await tester.tap(find.text('T5'));
    await settle(tester);

    expect(path(router), '/order/srv-5');
  });

  testWidgets('a running table without a bill opens its order',
      (tester) async {
    final router = await pumpTables(
      tester,
      tables: [table('T5', TableState.other, orderId: billedOrderId)],
      inHistory: const [history],
    );

    await tester.tap(find.text('T5'));
    await settle(tester);

    expect(path(router), '/order/srv-5');
  });

  testWidgets('a table that needs cleaning stays on Tables', (tester) async {
    final router = await pumpTables(
      tester,
      tables: [table('T5', TableState.dirty, orderId: billedOrderId, bills: 1)],
      inHistory: const [history],
    );

    await tester.tap(find.text('T5'));
    await tester.pump();

    expect(path(router), '/tables');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
      'a free table opens without creating an order: leaving it empty must '
      'not leave "Order open" behind (the desk deletes an empty draft on Back; '
      'the phone has no way to, so it never makes one)', (tester) async {
    final sent = <String>[];
    final socket = SocketService()..debugSetState(SocketState.verified);
    socket.rawEmitOverride = (event, data, timeout) async {
      sent.add(event);
      return <String, dynamic>{'kind': 'success'};
    };
    addTearDown(socket.dispose);

    final router = await pumpTables(
      tester,
      tables: [table('T1', TableState.free, serverId: 'srv-1')],
      socket: socket,
    );

    await tester.tap(find.text('T1'));
    await settle(tester);

    expect(path(router), '/order/srv-1');
    expect(sent, isNot(contains('order:create')),
        reason: 'the order is created with its first KOT or Save');
  });
}
