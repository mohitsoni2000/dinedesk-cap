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
import 'package:restro/widgets/liquid_chrome.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A discount already on a bill can be changed or taken off from Crew, as on
/// the desk's own order screen: Discount and Coupon replace it (the desk's
/// discount:apply overwrites), the discount line's ✕ removes it
/// (discount:remove), and the bill is made again at the new total.
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

  final sent = <String, List<Map<String, dynamic>>>{};
  var billDiscount = 50;
  var removeAnswer = <String, dynamic>{'kind': 'success'};

  Future<void> openDetail(WidgetTester tester,
      {required Map<String, int> flags}) async {
    tester.view.physicalSize = const Size(1024, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final socket = SocketService()..debugSetState(SocketState.verified);
    socket.rawEmitOverride = (event, data, timeout) async {
      sent.putIfAbsent(event, () => []).add(Map<String, dynamic>.from(data));
      if (event == 'discount:remove') {
        if (removeAnswer['kind'] == 'success') billDiscount = 0;
        return removeAnswer;
      }
      if (event != 'bill:generate') return <String, dynamic>{'kind': 'success'};
      return <String, dynamic>{
        'kind': 'success',
        'bills': <Object>[
          <String, dynamic>{
            'id': 'b1',
            'bill_number': 'INV/1',
            'bill_type': 'food',
            'total_amount': 500 - billDiscount,
            'discount_amount': billDiscount,
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
    container.read(tablesProvider.notifier).state = const [
      RestaurantTable(
        id: 'T5',
        serverId: 'srv-5',
        seats: 4,
        floor: 'Ground',
        state: TableState.mine,
        activeOrderId: orderId,
        activeBillCount: 1,
      ),
    ];

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

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  setUp(() {
    sent.clear();
    billDiscount = 50;
    removeAnswer = <String, dynamic>{'kind': 'success'};
  });

  const captain = <String, int>{
    'flag_generate_bill': 1,
    'flag_collect_payment': 1,
    'flag_discounts': 1,
  };

  LiquidSecondaryButton button(WidgetTester tester, String label) =>
      tester.widget<LiquidSecondaryButton>(
          find.widgetWithText(LiquidSecondaryButton, label));

  testWidgets('a discounted bill can still take another discount or a coupon',
      (tester) async {
    await openDetail(tester, flags: captain);

    expect(find.text('-₹50'), findsOneWidget);
    expect(button(tester, 'Discount').onPressed, isNotNull);
    expect(button(tester, 'Coupon').onPressed, isNotNull);
    expect(find.text('Discount Applied'), findsNothing);
  });

  testWidgets(
      'the discount line takes the discount off, and the bill is made '
      'again at the full total', (tester) async {
    await openDetail(tester, flags: captain);

    await tester.tap(find.byTooltip('Remove discount'));
    await settle(tester);
    await tester.tap(find.text('Remove discount'));
    await settle(tester);

    expect(sent['discount:remove'], [
      containsPair('order_id', orderId),
    ]);
    expect(sent['bill:generate'], hasLength(2),
        reason: 'opened with the bill, then made again without the discount');
    expect(find.text('-₹50'), findsNothing);
    expect(find.byTooltip('Remove discount'), findsNothing);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('keeping the discount at the prompt sends nothing',
      (tester) async {
    await openDetail(tester, flags: captain);

    await tester.tap(find.byTooltip('Remove discount'));
    await settle(tester);
    await tester.tap(find.text('Keep'));
    await settle(tester);

    expect(sent['discount:remove'], isNull);
    expect(find.text('-₹50'), findsOneWidget);
  });

  testWidgets('a refusal from the desk leaves the discount on and says why',
      (tester) async {
    removeAnswer = <String, dynamic>{
      'kind': 'error',
      'message': 'The bill is already paid, so its discount stays — void the '
          'bill from Admin > Bills first to change it.',
    };
    await openDetail(tester, flags: captain);

    await tester.tap(find.byTooltip('Remove discount'));
    await settle(tester);
    await tester.tap(find.text('Remove discount'));
    await settle(tester);

    expect(find.textContaining('already paid'), findsOneWidget);
    expect(find.text('-₹50'), findsOneWidget);
    expect(sent['bill:generate'], hasLength(1));
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets(
      'without the Discounts permission the discount cannot be '
      'changed or taken off', (tester) async {
    await openDetail(tester, flags: const <String, int>{
      'flag_generate_bill': 1,
      'flag_collect_payment': 1,
      'flag_discounts': 0,
    });

    expect(find.text('-₹50'), findsOneWidget);
    expect(find.byTooltip('Remove discount'), findsNothing);
    expect(
        find.widgetWithText(LiquidSecondaryButton, 'Discount'), findsNothing);
  });
}
