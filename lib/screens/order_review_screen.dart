import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../motion/motion.dart';
import '../services/pin_guard.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/customer_sheet.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_mesh_background.dart';
import '../widgets/order_submitting_overlay.dart';
import '../widgets/liquid_glass_surface.dart';

class OrderReviewScreen extends ConsumerStatefulWidget {
  final String tableId;
  const OrderReviewScreen({super.key, required this.tableId});
  @override
  ConsumerState<OrderReviewScreen> createState() => _OrderReviewScreenState();
}

enum _OrderType { dineIn, takeaway }

class _OrderReviewScreenState extends ConsumerState<OrderReviewScreen> {
  final TextEditingController _notes = TextEditingController();
  Map<String, dynamic>? _customer;
  _OrderType _orderType = _OrderType.dineIn;

  @override
  void initState() {
    super.initState();
    _notes.text = ref.read(orderNotesProvider);
  }

  bool _submitted = false;

  // OR2 fix: track the order ID for which KOT was already sent successfully.
  // On retry after bill:generate failure, skip order:create/update + kot:send.
  String? _kotSentOrderId;

  @override
  void dispose() {
    // Reset notes if leaving without submitting (C2 fix).
    if (!_submitted) {
      ref.read(orderNotesProvider.notifier).state = '';
    }
    _notes.dispose();
    super.dispose();
  }

  String _kitchenLabel(String key) => switch (key) {
        'tandoor' => 'Tandoor',
        'curry' => 'Curry / Main',
        'south' => 'South',
        'chinese' => 'Chinese',
        'beverages' => 'Beverages & Desserts',
        'tikka' => 'Tikka',
        _ => key[0].toUpperCase() + key.substring(1),
      };

  IconData _kitchenIcon(String key) => switch (key) {
        'tandoor' => Icons.local_fire_department_outlined,
        'curry' => Icons.soup_kitchen_outlined,
        'south' => Icons.ramen_dining_outlined,
        'chinese' => Icons.takeout_dining_outlined,
        'beverages' => Icons.local_cafe_outlined,
        _ => Icons.restaurant_menu,
      };

  List<Map<String, dynamic>> _itemsPayload(List<CartLine> cart) {
    return cart
        .map((l) => <String, dynamic>{
              'item_id': l.item.id,
              if (l.variationId != null) 'variation_id': l.variationId,
              if (l.variationName != null) 'variation_name': l.variationName,
              'quantity': l.qty,
              'selected_options':
                  l.selectedOptions.map((o) => o.toJson()).toList(),
              'notes': l.itemNote,
            })
        .toList();
  }

  String? _activeOrderIdForTable() {
    if (_orderType != _OrderType.dineIn) return null;
    final table = ref
        .read(tablesProvider)
        .where((t) => t.serverId == widget.tableId)
        .firstOrNull;
    if (table?.activeOrderId != null && table!.activeOrderId!.isNotEmpty) {
      return table.activeOrderId;
    }
    final active = ref.read(activeOrdersProvider).where((order) {
      return order['table_id']?.toString() == widget.tableId &&
          order['status']?.toString() != 'paid' &&
          order['status']?.toString() != 'cancelled';
    }).firstOrNull;
    return active?['id']?.toString();
  }

  String? _orderIdFromResponse(
    Map<String, dynamic> response, {
    String? fallback,
  }) {
    final order = response['order'];
    if (order is Map && order['id'] != null) return order['id'].toString();
    return response['order_id']?.toString() ?? fallback;
  }

  void _rememberKotLabel(Map<String, dynamic> response) {
    final order = response['order'];
    final label = order is Map
        ? (order['kot_number']?.toString() ?? order['order_number']?.toString())
        : null;
    ref.read(lastKotIdProvider.notifier).state = label ?? generateKotId();
  }

  Future<Map<String, dynamic>> _createOrUpdateOrder({
    required List<Map<String, dynamic>> items,
    required String notes,
  }) {
    final socketService = ref.read(socketServiceProvider);
    final existingOrderId = _activeOrderIdForTable();
    if (existingOrderId != null && items.isNotEmpty) {
      return socketService.emitAck('order:update', <String, dynamic>{
        'order_id': existingOrderId,
        'items_add': items,
        'notes': notes,
      });
    }
    return socketService.emitAck('order:create', <String, dynamic>{
      if (_orderType == _OrderType.dineIn) 'table_id': widget.tableId,
      'items': items,
      'notes': notes,
      'order_type': _orderType == _OrderType.dineIn ? 'dine_in' : 'takeaway',
      if (_customer != null && _customer!['id'] != null)
        'customer_id': _customer!['id'],
    });
  }

  Future<bool> _runOrderFlow({
    required bool generateBill,
    required bool collectPayment,
    String quickSettleMode = 'cash',
  }) async {
    final cart = ref.read(cartProvider);
    final socketService = ref.read(socketServiceProvider);

    String? orderId;

    // OR2 fix: if KOT was already sent for this order (previous attempt
    // succeeded up to kot:send but bill:generate failed), skip order:create/
    // update and kot:send entirely to avoid doubling items in kitchen.
    if (_kotSentOrderId != null) {
      orderId = _kotSentOrderId;
    } else {
      final items = _itemsPayload(cart);
      final fallbackOrderId = _activeOrderIdForTable();

      final orderResponse = await _createOrUpdateOrder(
        items: items,
        notes: _notes.text,
      );
      if (orderResponse['kind'] == 'error') return false;
      ref
          .read(syncServiceProvider)
          .applyOrderAck(orderResponse, includeHistory: true);
      _rememberKotLabel(orderResponse);

      orderId =
          _orderIdFromResponse(orderResponse, fallback: fallbackOrderId);
      if (orderId == null || orderId.isEmpty) return false;

      final kotResponse = await socketService.emitAck(
        'kot:send',
        <String, dynamic>{'order_id': orderId},
      );
      if (kotResponse['kind'] == 'error') return false;
      ref
          .read(syncServiceProvider)
          .applyOrderAck(kotResponse, includeHistory: true);

      // Mark KOT as sent so retries skip order:create/update + kot:send.
      _kotSentOrderId = orderId;
    }

    if (!generateBill) return true;

    final billResponse = await socketService.emitAck(
      'bill:generate',
      <String, dynamic>{'order_id': orderId},
    );
    if (billResponse['kind'] == 'error') return false;
    ref.read(syncServiceProvider).applyOrderAck(
          billResponse,
          includeHistory: true,
          markTableBilled: true,
        );
    if (!collectPayment) return true;

    final bills = billResponse['bills'];
    final bill = (bills is List && bills.isNotEmpty && bills.first is Map)
        ? Map<String, dynamic>.from(bills.first as Map)
        : null;
    final billId = bill?['id']?.toString();
    if (billId == null || billId.isEmpty) return false;

    final total = cart.fold(0.0, (double s, CartLine l) => s + l.lineTotal);
    final billTotal = (bill?['total_amount'] as num?)?.toDouble() ?? total;
    final paymentResponse = await socketService.emitAck(
      'bill:payment',
      <String, dynamic>{
        'bill_id': billId,
        'payments': [
          {'payment_mode': quickSettleMode, 'amount': billTotal},
        ],
      },
    );
    ref
        .read(syncServiceProvider)
        .applyOrderAck(paymentResponse, includeHistory: true);
    return paymentResponse['kind'] != 'error';
  }

  Future<void> _submit() async {
    final pinOk = await requirePinIfNeeded(context, ref, 'kot');
    if (!pinOk || !mounted) return;
    await _submitWithFlow(generateBill: false, collectPayment: false);
  }

  Future<void> _submitWithFlow({
    required bool generateBill,
    required bool collectPayment,
    String quickSettleMode = 'cash',
  }) async {
    ref.read(feedbackServiceProvider).fire(const FeedbackHeavy());
    ref.read(orderNotesProvider.notifier).state = _notes.text;

    final completer = Completer<bool>();
    unawaited(_runOrderFlow(
      generateBill: generateBill,
      collectPayment: collectPayment,
      quickSettleMode: quickSettleMode,
    ).then((ok) {
      if (!completer.isCompleted) completer.complete(ok);
    }));

    final ok = await OrderSubmittingOverlay.show(context, completer: completer);
    if (!mounted) return;
    if (ok) {
      _submitted = true;
      _kotSentOrderId = null; // OR2: reset so next order starts fresh
      ref.read(cartProvider.notifier).clear();
      ref.read(orderNotesProvider.notifier).state = '';
      context.go('/order/${widget.tableId}/success');
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(
        content: Text('Order could not be confirmed — please retry'),
      ));
  }

  /// KOT + Bill: create order → send KOT → generate bill in one action.
  Future<void> _submitKotAndBill() async {
    final pinOk = await requirePinIfNeeded(context, ref, 'kot_and_bill');
    if (!pinOk || !mounted) return;
    await _submitWithFlow(generateBill: true, collectPayment: false);
  }

  /// Quick Settle: create → KOT → bill → pay, all in one.
  /// Shows a payment mode picker before committing.
  Future<void> _quickSettle() async {
    final pinOk = await requirePinIfNeeded(context, ref, 'quick_settle');
    if (!pinOk || !mounted) return;

    final mode = await _pickQuickSettleMode();
    if (mode == null || !mounted) return;

    await _submitWithFlow(
        generateBill: true, collectPayment: true, quickSettleMode: mode);
  }

  Future<String?> _pickQuickSettleMode() {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.paper,
        shape:
            const RoundedRectangleBorder(borderRadius: BorderRadius.all(AppRadii.lg)),
        title: const Text('Payment Mode', style: AppTypography.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in const {
              'cash': (Icons.payments_outlined, 'Cash'),
              'upi': (Icons.phone_android_outlined, 'UPI'),
              'card': (Icons.credit_card_outlined, 'Card'),
            }.entries)
              ListTile(
                leading: Icon(entry.value.$1, color: AppColors.ink70),
                title: Text(entry.value.$2, style: AppTypography.bodyMd),
                onTap: () => Navigator.of(ctx).pop(entry.key),
                shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(AppRadii.sm)),
              ),
          ],
        ),
      ),
    );
  }

  /// Undo a recently deleted cart line.
  void _undoDelete(CartLine line) {
    ref.read(cartProvider.notifier).addCustom(
          item: line.item,
          qty: line.qty,
          mods: line.mods,
          selectedOptions: line.selectedOptions,
          modsExtra: line.modsExtra,
          itemNote: line.itemNote,
        );
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);
    final total = cart.fold(0.0, (s, l) => s + l.lineTotal);
    final byKitchen = <String, List<CartLine>>{};
    for (final l in cart) {
      byKitchen.putIfAbsent(l.item.kitchenSection, () => []).add(l);
    }
    final flags = ref.watch(flagsProvider);

    // Resolve display name for the table from the tables provider.
    final tables = ref.watch(tablesProvider);
    final tableDisplay = tables
            .where((t) => t.serverId == widget.tableId)
            .map((t) => t.id)
            .firstOrNull ??
        widget.tableId;

    // T1 fix: lock order_type toggle once a draft dine-in order exists for
    // this table — switching types after items are sent would create a
    // duplicate order on a different order_id.
    final activeOrders = ref.watch(activeOrdersProvider);
    final hasExistingOrder = tables.any(
          (t) =>
              t.serverId == widget.tableId &&
              t.activeOrderId != null &&
              t.activeOrderId!.isNotEmpty,
        ) ||
        activeOrders.any(
          (o) =>
              o['table_id']?.toString() == widget.tableId &&
              o['status']?.toString() != 'paid' &&
              o['status']?.toString() != 'cancelled',
        );

    // D1 fix: if another operator already generated a bill (activeBillCount > 0
    // from socket broadcast), disable "KOT + Bill" and "Quick Settle" to
    // prevent duplicate bill generation.
    final activeBillCount = tables
        .where((t) => t.serverId == widget.tableId)
        .map((t) => t.activeBillCount)
        .firstOrNull ?? 0;
    final billAlreadyGenerated = activeBillCount > 0;

    return LiquidMeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              Hero(
                tag: HeroTags.cartBar,
                child: Material(
                  color: Colors.transparent,
                  child: LiquidAppBar(
                    title: 'Review · $tableDisplay',
                    leading: IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => context.pop(),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: cart.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.shopping_basket_outlined,
                              color: AppColors.ink30,
                              size: 48,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Cart is empty',
                              style: AppTypography.title,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Go back and add items',
                              style: AppTypography.caption,
                            ),
                            const SizedBox(height: 20),
                            // Repeat Last Order — re-add items from previous order on this table.
                            Builder(
                              builder: (_) {
                                final history = ref.watch(historyProvider);
                                final lastOrder = history
                                    .where(
                                      (o) =>
                                          o.tableId == tableDisplay &&
                                          o.lines.isNotEmpty &&
                                          o.status != OrderStatus.cancelled,
                                    )
                                    .firstOrNull;
                                if (lastOrder == null) {
                                  return const SizedBox.shrink();
                                }
                                return LiquidSecondaryButton(
                                  label: 'Repeat Last Order (${lastOrder.id})',
                                  leadingIcon: Icons.replay,
                                  onPressed: () {
                                    final menu = ref.read(menuProvider);
                                    for (final line in lastOrder.lines) {
                                      // Match by item ID; fall back to name if ID missing.
                                      final menuItem = menu
                                          .where((m) =>
                                              line.itemId.isNotEmpty
                                                  ? m.id == line.itemId
                                                  : m.name == line.name)
                                          .firstOrNull;
                                      if (menuItem != null) {
                                        ref
                                            .read(cartProvider.notifier)
                                            .addCustom(
                                              item: menuItem,
                                              qty: line.qty,
                                              mods: line.mods,
                                              modsExtra: 0,
                                              itemNote: '',
                                            );
                                      }
                                    }
                                    ref
                                        .read(feedbackServiceProvider)
                                        .fire(const FeedbackMedium());
                                    ScaffoldMessenger.of(context)
                                      ..clearSnackBars()
                                      ..showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            '${lastOrder.lines.length} items added from ${lastOrder.id}',
                                          ),
                                        ),
                                      );
                                  },
                                );
                              },
                            ),
                          ],
                        ),
                      )
                    : ListView(
                        padding: EdgeInsets.fromLTRB(
                          AppSpacing.lg,
                          AppSpacing.lg,
                          AppSpacing.lg,
                          AppSpacing.lg +
                              MediaQuery.of(context).viewInsets.bottom,
                        ),
                        children: [
                          // Guest count removed — managed on Desktop side.
                          if (flags.customers) ...[
                            const SizedBox(height: 12),

                            // Customer attach row.
                            AppCard(
                              onTap: () async {
                                final result = await CustomerSheet.show(
                                  context,
                                );
                                if (result != null && mounted) {
                                  setState(() => _customer = result);
                                }
                              },
                              child: Row(
                                children: [
                                  Icon(
                                    _customer != null
                                        ? Icons.person
                                        : Icons.person_add_outlined,
                                    color: _customer != null
                                        ? AppColors.terra600
                                        : AppColors.ink70,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _customer != null
                                        ? Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                _customer!['name']
                                                        ?.toString() ??
                                                    'Customer',
                                                style: AppTypography.bodyMd
                                                    .copyWith(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              if (_customer!['phone'] != null &&
                                                  _customer!['phone']
                                                      .toString()
                                                      .isNotEmpty)
                                                Text(
                                                  _customer!['phone']
                                                      .toString(),
                                                  style: AppTypography.caption,
                                                ),
                                            ],
                                          )
                                        : const Text(
                                            'Add Customer',
                                            style: AppTypography.bodyMd,
                                          ),
                                  ),
                                  if (_customer != null)
                                    GestureDetector(
                                      onTap: () =>
                                          setState(() => _customer = null),
                                      child: const Icon(
                                        Icons.close,
                                        color: AppColors.ink50,
                                        size: 18,
                                      ),
                                    )
                                  else
                                    const Icon(
                                      Icons.chevron_right,
                                      color: AppColors.ink30,
                                      size: 20,
                                    ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),

                          // Cart lines.
                          AppCard(
                            padding: EdgeInsets.zero,
                            child: Column(
                              children: [
                                for (int i = 0; i < cart.length; i++) ...[
                                  Dismissible(
                                    key: ValueKey(cart[i].uid),
                                    direction: DismissDirection.endToStart,
                                    background: Container(
                                      alignment: Alignment.centerRight,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 20,
                                      ),
                                      color: AppColors.danger.withValues(
                                        alpha: 0.85,
                                      ),
                                      child: const Icon(
                                        Icons.delete_outline,
                                        color: Colors.white,
                                      ),
                                    ),
                                    onDismissed: (_) {
                                      ref
                                          .read(feedbackServiceProvider)
                                          .fire(const FeedbackMedium());
                                      final deleted = cart[i];
                                      final uid = deleted.uid;
                                      final current = ref.read(cartProvider);
                                      final idx = current.indexWhere(
                                        (l) => l.uid == uid,
                                      );
                                      if (idx >= 0) {
                                        ref
                                            .read(cartProvider.notifier)
                                            .removeAt(idx);
                                      }
                                      // Undo snackbar — 4 second window.
                                      ScaffoldMessenger.of(context)
                                        ..clearSnackBars()
                                        ..showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              '${deleted.item.name} removed',
                                            ),
                                            duration: const Duration(
                                              seconds: 4,
                                            ),
                                            action: SnackBarAction(
                                              label: 'UNDO',
                                              textColor: AppColors.terra400,
                                              onPressed: () =>
                                                  _undoDelete(deleted),
                                            ),
                                          ),
                                        );
                                    },
                                    child: _CartRow(line: cart[i], index: i),
                                  ),
                                  if (i < cart.length - 1)
                                    const Divider(
                                      height: 1,
                                      color: AppColors.ink10,
                                    ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),

                          // KOT preview by kitchen section.
                          Text(
                            'KOT PREVIEW',
                            style: AppTypography.micro.copyWith(
                              letterSpacing: 1.4,
                            ),
                          ),
                          const SizedBox(height: 8),
                          AppCard(
                            padding: EdgeInsets.zero,
                            child: Column(
                              children: [
                                for (int i = 0;
                                    i < byKitchen.entries.length;
                                    i++) ...[
                                  _KotRow(
                                    icon: _kitchenIcon(
                                      byKitchen.keys.elementAt(i),
                                    ),
                                    label: _kitchenLabel(
                                      byKitchen.keys.elementAt(i),
                                    ),
                                    lines: byKitchen.values.elementAt(i),
                                  ),
                                  if (i < byKitchen.entries.length - 1)
                                    const Divider(
                                      height: 1,
                                      color: AppColors.ink10,
                                    ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Order notes.
                          Text(
                            'ORDER NOTES',
                            style: AppTypography.micro.copyWith(
                              letterSpacing: 1.4,
                            ),
                          ),
                          const SizedBox(height: 8),
                          AppCard(
                            child: TextField(
                              controller: _notes,
                              maxLines: 2,
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                hintText: 'Allergies, urgency, etc.',
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Billing breakdown by type.
                          Builder(
                            builder: (_) {
                              double foodTotal = 0;
                              double liquorTotal = 0;
                              double bevTotal = 0;
                              for (final l in cart) {
                                final type =
                                    l.item.kitchenSection.toLowerCase();
                                final lineAmt = l.lineTotal;
                                if (type == 'beverages') {
                                  bevTotal += lineAmt;
                                } else if (type == 'liquor' || type == 'bar') {
                                  liquorTotal += lineAmt;
                                } else {
                                  foodTotal += lineAmt;
                                }
                              }
                              final showLiquor =
                                  liquorTotal > 0 && flags.liquorBilling;
                              final showBev =
                                  bevTotal > 0 && flags.beveragesBilling;

                              return AppCard(
                                child: Column(
                                  children: [
                                    if (showLiquor || showBev) ...[
                                      Row(
                                        children: [
                                          const Text(
                                            'Food',
                                            style: AppTypography.bodyMd,
                                          ),
                                          const Spacer(),
                                          Text(
                                            formatRupeesCompact(foodTotal),
                                            style: AppTypography.bodyMd,
                                          ),
                                        ],
                                      ),
                                      if (showLiquor) ...[
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            const Text(
                                              'Liquor',
                                              style: AppTypography.bodyMd,
                                            ),
                                            const Spacer(),
                                            Text(
                                              formatRupeesCompact(liquorTotal),
                                              style: AppTypography.bodyMd,
                                            ),
                                          ],
                                        ),
                                      ],
                                      if (showBev) ...[
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            const Text(
                                              'Beverages',
                                              style: AppTypography.bodyMd,
                                            ),
                                            const Spacer(),
                                            Text(
                                              formatRupeesCompact(bevTotal),
                                              style: AppTypography.bodyMd,
                                            ),
                                          ],
                                        ),
                                      ],
                                    ] else ...[
                                      Row(
                                        children: [
                                          const Text(
                                            'Subtotal',
                                            style: AppTypography.bodyMd,
                                          ),
                                          const Spacer(),
                                          Text(
                                            formatRupeesCompact(total),
                                            style: AppTypography.bodyMd,
                                          ),
                                        ],
                                      ),
                                    ],
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Taxes added on bill (admin desktop)',
                                      style: AppTypography.caption,
                                      textAlign: TextAlign.right,
                                    ),
                                    const Divider(
                                      height: 16,
                                      color: AppColors.ink10,
                                    ),
                                    Row(
                                      children: [
                                        const Text(
                                          'Total',
                                          style: AppTypography.title,
                                        ),
                                        const Spacer(),
                                        Hero(
                                          tag: HeroTags.orderTotal,
                                          child: Material(
                                            color: Colors.transparent,
                                            child: KineticRupeeCounter(
                                              amount: total,
                                              fontSize: 24,
                                              color: AppColors.ink,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
              ),
              if (cart.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    children: [
                      // Dine-in / Takeaway toggle.
                      // Locked once a draft order exists — changing type after
                      // items are sent would create a duplicate order.
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: hasExistingOrder
                                  ? null
                                  : () => setState(
                                        () => _orderType = _OrderType.dineIn,
                                      ),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: _orderType == _OrderType.dineIn
                                      ? AppColors.ink
                                      : Colors.white.withValues(alpha: 0.5),
                                  borderRadius: const BorderRadius.horizontal(
                                    left: AppRadii.sm,
                                  ),
                                  border: Border.all(color: AppColors.ink10),
                                ),
                                alignment: Alignment.center,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.restaurant,
                                      size: 16,
                                      color: _orderType == _OrderType.dineIn
                                          ? Colors.white
                                          : AppColors.ink70,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Dine-in',
                                      style: AppTypography.caption.copyWith(
                                        color: _orderType == _OrderType.dineIn
                                            ? Colors.white
                                            : AppColors.ink,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: hasExistingOrder
                                  ? null
                                  : () => setState(
                                        () => _orderType = _OrderType.takeaway,
                                      ),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: _orderType == _OrderType.takeaway
                                      ? AppColors.ink
                                      : Colors.white.withValues(alpha: 0.5),
                                  borderRadius: const BorderRadius.horizontal(
                                    right: AppRadii.sm,
                                  ),
                                  border: Border.all(color: AppColors.ink10),
                                ),
                                alignment: Alignment.center,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.takeout_dining,
                                      size: 16,
                                      color: _orderType == _OrderType.takeaway
                                          ? Colors.white
                                          : AppColors.ink70,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Takeaway',
                                      style: AppTypography.caption.copyWith(
                                        color: _orderType == _OrderType.takeaway
                                            ? Colors.white
                                            : AppColors.ink,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Primary action: Send to Kitchen.
                      LiquidPrimaryButton(
                        label: 'Send to Kitchen',
                        fullWidth: true,
                        leadingIcon: Icons.restaurant_menu,
                        onPressed: _submit,
                      ),
                      const SizedBox(height: 8),
                      // Secondary actions row.
                      Row(
                        children: [
                          Expanded(
                            child: LiquidSecondaryButton(
                              label: 'KOT + Bill',
                              leadingIcon: Icons.receipt_long,
                              // D1: disable if bill already generated from
                              // another device — prevent duplicate billing.
                              onPressed: billAlreadyGenerated
                                  ? null
                                  : _submitKotAndBill,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: LiquidSecondaryButton(
                              label: 'Quick Settle',
                              leadingIcon: Icons.payments_outlined,
                              onPressed: billAlreadyGenerated
                                  ? null
                                  : _quickSettle,
                            ),
                          ),
                        ],
                      ),
                      if (billAlreadyGenerated) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Bill already generated — go back to collect payment',
                          style: AppTypography.caption.copyWith(
                            color: AppColors.ink50,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ), // LiquidMeshBackground
    );
  }
}

class _CartRow extends ConsumerWidget {
  final CartLine line;
  final int index;
  const _CartRow({required this.line, required this.index});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _VegMark(isVeg: line.item.isVeg),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.item.name, style: AppTypography.bodyMd),
                if (line.mods.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    line.mods.join(' · '),
                    style: AppTypography.caption.copyWith(
                      color: AppColors.ink70,
                    ),
                  ),
                ],
                if (line.itemNote.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    '"${line.itemNote}"',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.terra600,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  formatRupeesCompact(line.item.price + line.modsExtra),
                  style: AppTypography.caption,
                ),
              ],
            ),
          ),
          _Step(
            icon: Icons.remove,
            onTap: () {
              ref.read(feedbackServiceProvider).fire(const FeedbackSelection());
              ref.read(cartProvider.notifier).setQtyAt(index, line.qty - 1);
            },
          ),
          SizedBox(
            width: 32,
            child: Center(
              child: Text(
                '${line.qty}',
                style: AppTypography.title.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          _Step(
            icon: Icons.add,
            onTap: () {
              ref.read(feedbackServiceProvider).fire(const FeedbackSelection());
              ref.read(cartProvider.notifier).setQtyAt(index, line.qty + 1);
            },
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 70,
            child: Text(
              formatRupeesCompact(line.lineTotal),
              style: AppTypography.title,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

/// Qty stepper with hold-to-repeat: tap = single step, long-press = rapid fire.
/// 500ms threshold before repeat starts, 150ms interval.
class _Step extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _Step({required this.icon, required this.onTap});
  @override
  State<_Step> createState() => _StepState();
}

class _StepState extends State<_Step> {
  Timer? _timer;

  void _startRepeat() {
    widget.onTap();
    _timer = Timer(const Duration(milliseconds: 500), () {
      _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
        widget.onTap();
      });
    });
  }

  void _stopRepeat() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopRepeat();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: widget.onTap,
        onLongPressStart: (_) => _startRepeat(),
        onLongPressEnd: (_) => _stopRepeat(),
        onLongPressCancel: _stopRepeat,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: LiquidGlassSurface(
              borderRadius: BorderRadius.circular(14),
              blur: 14,
              thickness: 6,
              child: SizedBox(
                width: 28,
                height: 28,
                child: Center(
                    child: Icon(widget.icon, size: 14, color: AppColors.ink)),
              ),
            ),
          ),
        ),
      );
}

class _KotRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final List<CartLine> lines;
  const _KotRow({required this.icon, required this.label, required this.lines});
  @override
  Widget build(BuildContext context) {
    final qty = lines.fold<int>(0, (s, l) => s + l.qty);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.terra500.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: AppColors.terra600),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppTypography.bodyMd.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${lines.length} ${lines.length == 1 ? "item" : "items"} · '
                  '$qty units',
                  style: AppTypography.caption,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.ink05,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '1 KOT',
              style: AppTypography.micro.copyWith(letterSpacing: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _VegMark extends StatelessWidget {
  final bool isVeg;
  const _VegMark({required this.isVeg});
  @override
  Widget build(BuildContext context) {
    final color = isVeg ? AppColors.success : AppColors.danger;
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Center(
        child: Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
