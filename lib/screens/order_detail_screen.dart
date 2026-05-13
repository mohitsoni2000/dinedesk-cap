// Order Detail Screen — read-only view of a sent order.
//
// Reached from /history/:orderId. Operator can:
//   • Reprint KOT  (re-emits the print event to the admin desktop)
//   • Cancel order (only allowed for orders < 5 minutes old;
//                    disabled for already-cancelled orders)
//   • Generate Bill (after KOT sent, not cancelled)
//   • Apply Discount (before billing)
//   • Collect Payment (after bill generated)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../services/pin_guard.dart';
import '../theme/tokens.dart';
import '../utils/socket_helpers.dart';
import '../widgets/app_card.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_mesh_background.dart';
import '../widgets/payment_sheet.dart';
import '../widgets/discount_sheet.dart';

class OrderDetailScreen extends ConsumerStatefulWidget {
  final String orderId;
  const OrderDetailScreen({super.key, required this.orderId});

  @override
  ConsumerState<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends ConsumerState<OrderDetailScreen> {
  String get orderId => widget.orderId;

  // Bill state tracked locally in this screen instance.
  String? _billId;
  String? _billNumber;
  double? _billTotal;
  double? _billGst;
  double? _billServiceCharge;
  double? _discountAmount;
  String? _discountLabel;
  bool _billGenerated = false;
  bool _paymentCollected = false;
  bool _generatingBill = false;

  static String _kitchenLabel(String key) => switch (key) {
    'tandoor'   => 'Tandoor',
    'curry'     => 'Curry / Main',
    'south'     => 'South',
    'chinese'   => 'Chinese',
    'beverages' => 'Beverages & Desserts',
    _           => key[0].toUpperCase() + key.substring(1),
  };

  static IconData _kitchenIcon(String key) => switch (key) {
    'tandoor'   => Icons.local_fire_department_outlined,
    'curry'     => Icons.soup_kitchen_outlined,
    'south'     => Icons.ramen_dining_outlined,
    'chinese'   => Icons.takeout_dining_outlined,
    'beverages' => Icons.local_cafe_outlined,
    _           => Icons.restaurant_menu,
  };

  void _reprintKot(BuildContext context) {
    HapticFeedback.mediumImpact();
    final socketService = ref.read(socketServiceProvider);
    socketService.emit('print:kot', {'order_id': orderId});
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(
        content: Text('Reprint queued · admin desktop'),
        duration: Duration(seconds: 2),
      ));
  }

  Future<void> _confirmCancel(BuildContext context, HistoryOrder order) async {
    // PIN guard — verify operator before cancelling.
    final pinOk = await requirePinIfNeeded(context, ref, 'cancel_order');
    if (!pinOk || !context.mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.paper,
        title: Text('Cancel order ${order.id}?', style: AppTypography.title),
        content: const Text(
          'The kitchen will be notified to stop preparation. This cannot be undone.',
          style: AppTypography.bodyMd),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep order'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel order',
              style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    HapticFeedback.heavyImpact();

    // Emit cancel to server so the kitchen is notified.
    final socketService = ref.read(socketServiceProvider);
    socketService.emit('order:cancel', {
      'order_id': order.id,
      'reason': 'Cancelled by waiter',
    }, onAck: (response) {
      if (!mounted) return;
      if (response['kind'] == 'error') {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            backgroundColor: AppColors.danger,
            content: Text(
              response['message']?.toString() ?? 'Cancel failed',
              style: AppTypography.bodyMd.copyWith(color: Colors.white),
            ),
          ));
        return;
      }
      // Only update local state on success.
      final list = ref.read(historyProvider);
      ref.read(historyProvider.notifier).state = [
        for (final o in list)
          if (o.id == order.id)
            HistoryOrder(
              id: o.id, tableId: o.tableId, time: o.time,
              itemCount: o.itemCount, total: o.total,
              status: OrderStatus.cancelled,
              lines: o.lines, notes: o.notes,
            )
          else o,
      ];
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: AppColors.danger,
          content: Text('Order ${order.id} cancelled',
            style: AppTypography.bodyMd.copyWith(color: Colors.white)),
        ));
        context.pop();
      }
    });
  }

  Future<void> _generateBill(HistoryOrder order) async {
    if (_generatingBill) return;
    _generatingBill = true;
    setState(() {});
    HapticFeedback.heavyImpact();

    final socketService = ref.read(socketServiceProvider);
    socketService.emit('bill:generate', {
      'order_id': order.id,
    }, onAck: (response) {
      if (!mounted) return;
      if (response['kind'] == 'error') {
        setState(() => _generatingBill = false);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            backgroundColor: AppColors.danger,
            content: Text(
              response['message']?.toString() ?? 'Bill generation failed',
              style: AppTypography.bodyMd.copyWith(color: Colors.white),
            ),
          ));
      } else {
        final bills = response['bills'] as List<dynamic>?;
        final bill = (bills != null && bills.isNotEmpty)
            ? Map<String, dynamic>.from(bills[0] as Map)
            : null;
        setState(() {
          _generatingBill = false;
          _billGenerated = true;
          _billId = bill?['id']?.toString() ??
              response['bill_id']?.toString() ??
              response['id']?.toString();
          _billNumber = bill?['bill_number']?.toString() ??
              response['bill_number']?.toString() ??
              response['number']?.toString();
          _billTotal = (bill?['total_amount'] as num?)?.toDouble() ??
              (response['total'] as num?)?.toDouble() ??
              (response['grand_total'] as num?)?.toDouble() ??
              order.total;
          _billGst = (bill?['total_gst'] as num?)?.toDouble() ??
              (response['gst'] as num?)?.toDouble() ??
              (response['tax'] as num?)?.toDouble();
          _billServiceCharge =
              (bill?['service_charge'] as num?)?.toDouble() ??
              (response['service_charge'] as num?)?.toDouble();
          _discountAmount =
              (bill?['discount_amount'] as num?)?.toDouble() ??
              (response['discount'] as num?)?.toDouble() ??
              (response['discount_amount'] as num?)?.toDouble();
          _discountLabel = response['discount_label']?.toString();
        });
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            backgroundColor: AppColors.success,
            content: Text(
              'Bill generated${_billNumber != null ? ' · $_billNumber' : ''}',
              style: AppTypography.bodyMd.copyWith(color: Colors.white),
            ),
          ));
      }
    });

    // Timeout fallback
    scheduleSocketTimeout(
      duration: const Duration(seconds: 10),
      isMounted: () => mounted,
      isStillWaiting: () => _generatingBill,
      onTimeout: () {
        setState(() => _generatingBill = false);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(
            content: Text('Bill generation timed out — please retry'),
          ));
      },
    );
  }

  Future<void> _openPayment() async {
    if (_billId == null) return;
    final paid = await PaymentSheet.show(
      context,
      billId: _billId!,
      totalAmount: _billTotal ?? 0,
    );
    if (paid == true && mounted) {
      setState(() => _paymentCollected = true);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          backgroundColor: AppColors.success,
          content: Text('Payment collected',
            style: AppTypography.bodyMd.copyWith(color: Colors.white)),
        ));
    }
  }

  Future<void> _openDiscount(HistoryOrder order) async {
    final result = await DiscountSheet.show(
      context,
      orderId: order.id,
      orderTotal: order.total,
    );
    if (result != null && mounted) {
      setState(() {
        _discountAmount =
            (result['discount_amount'] as num?)?.toDouble() ??
            (result['amount'] as num?)?.toDouble();
        _discountLabel = result['discount_label']?.toString() ??
            result['label']?.toString();
      });
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          backgroundColor: AppColors.success,
          content: Text(
            'Discount applied${_discountLabel != null ? ' · $_discountLabel' : ''}',
            style: AppTypography.bodyMd.copyWith(color: Colors.white),
          ),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final orders = ref.watch(historyProvider);
    final flags = ref.watch(flagsProvider);
    final order = orders.where((o) => o.id == orderId).firstOrNull;

    if (order == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              LiquidAppBar(
                title: 'Order',
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => context.pop(),
                ),
              ),
              const Spacer(),
              const Icon(Icons.error_outline, color: AppColors.ink30, size: 48),
              const SizedBox(height: 12),
              const Text('Order not found', style: AppTypography.title),
              const SizedBox(height: 4),
              const Text('It may have been removed', style: AppTypography.caption),
              const Spacer(),
            ],
          ),
        ),
      );
    }

    // Group lines by kitchen.
    final byKitchen = <String, List<HistoryOrderLine>>{};
    for (final l in order.lines) {
      byKitchen.putIfAbsent(l.kitchenSection, () => []).add(l);
    }

    final isCancelled = order.status == OrderStatus.cancelled;
    final isSent = order.status == OrderStatus.sent ||
                   order.status == OrderStatus.modified;

    return LiquidMeshBackground(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            LiquidAppBar(
              title: order.id,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.pop(),
              ),
              actions: [
                _StatusBadge(status: order.status),
                const SizedBox(width: 8),
              ],
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  // Header — table, time, total.
                  AppCard(
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.tableMineBg,
                            borderRadius: const BorderRadius.all(AppRadii.xs),
                            border: Border.all(
                              color: AppColors.terra400.withValues(alpha: 0.4)),
                          ),
                          child: Text(order.tableId,
                            style: AppTypography.caption.copyWith(
                              fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${order.itemCount} items · ${order.time}',
                                style: AppTypography.bodyMd),
                              const SizedBox(height: 2),
                              Text(
                                _paymentCollected
                                    ? 'Payment collected'
                                    : _billGenerated
                                        ? 'Bill generated'
                                        : order.status == OrderStatus.cancelled
                                            ? 'Order cancelled'
                                            : order.status == OrderStatus.modified
                                                ? 'Modified after sending'
                                                : 'Sent to kitchen',
                                style: AppTypography.caption),
                            ],
                          ),
                        ),
                        Text(formatRupeesCompact(order.total),
                          style: AppTypography.headline),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Bill details card (shown after bill is generated)
                  if (_billGenerated) ...[
                    AppCard(
                      background: AppColors.success.withValues(alpha: 0.06),
                      border: Border.all(
                        color: AppColors.success.withValues(alpha: 0.3)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.receipt_long_outlined,
                                color: AppColors.success, size: 18),
                              const SizedBox(width: 8),
                              Text('Bill Details',
                                style: AppTypography.title.copyWith(
                                  color: AppColors.success)),
                              const Spacer(),
                              if (_billNumber != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: AppColors.success.withValues(
                                      alpha: 0.14),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(_billNumber!,
                                    style: AppTypography.micro.copyWith(
                                      color: AppColors.success,
                                      letterSpacing: 0.6)),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              const Text('Subtotal',
                                style: AppTypography.bodyMd),
                              const Spacer(),
                              Text(formatRupeesCompact(order.total),
                                style: AppTypography.bodyMd),
                            ],
                          ),
                          if (_discountAmount != null &&
                              _discountAmount! > 0) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Text(
                                  'Discount${_discountLabel != null ? ' ($_discountLabel)' : ''}',
                                  style: AppTypography.bodyMd.copyWith(
                                    color: AppColors.success)),
                                const Spacer(),
                                Text(
                                  '-${formatRupeesCompact(_discountAmount!)}',
                                  style: AppTypography.bodyMd.copyWith(
                                    color: AppColors.success)),
                              ],
                            ),
                          ],
                          if (_billGst != null) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Text('GST', style: AppTypography.bodyMd),
                                const Spacer(),
                                Text(formatRupeesCompact(_billGst!),
                                  style: AppTypography.bodyMd),
                              ],
                            ),
                          ],
                          if (_billServiceCharge != null) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Text('Service Charge',
                                  style: AppTypography.bodyMd),
                                const Spacer(),
                                Text(formatRupeesCompact(_billServiceCharge!),
                                  style: AppTypography.bodyMd),
                              ],
                            ),
                          ],
                          const Divider(height: 16, color: AppColors.ink10),
                          Row(
                            children: [
                              const Text('Total', style: AppTypography.title),
                              const Spacer(),
                              Text(formatRupeesCompact(_billTotal ?? order.total),
                                style: AppTypography.headline),
                            ],
                          ),
                          if (_paymentCollected) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: AppColors.success.withValues(alpha: 0.14),
                                borderRadius: const BorderRadius.all(AppRadii.xs),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.check_circle,
                                    color: AppColors.success, size: 16),
                                  const SizedBox(width: 6),
                                  Text('PAID',
                                    style: AppTypography.micro.copyWith(
                                      color: AppColors.success,
                                      letterSpacing: 0.8)),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Lines, grouped by kitchen.
                  for (final entry in byKitchen.entries) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Container(
                            width: 28, height: 28,
                            decoration: BoxDecoration(
                              color: AppColors.terra500.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(_kitchenIcon(entry.key),
                              size: 14, color: AppColors.terra600),
                          ),
                          const SizedBox(width: 10),
                          Text(_kitchenLabel(entry.key).toUpperCase(),
                            style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
                        ],
                      ),
                    ),
                    AppCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (int i = 0; i < entry.value.length; i++) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 28, height: 28,
                                    decoration: BoxDecoration(
                                      color: AppColors.ink05,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Center(
                                      child: Text('${entry.value[i].qty}×',
                                        style: AppTypography.caption.copyWith(
                                          fontWeight: FontWeight.w700)),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(entry.value[i].name,
                                          style: AppTypography.bodyMd),
                                        if (entry.value[i].mods.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text(entry.value[i].mods.join(' · '),
                                            style: AppTypography.caption.copyWith(
                                              color: AppColors.ink70)),
                                        ],
                                      ],
                                    ),
                                  ),
                                  Text(formatRupeesCompact(
                                    entry.value[i].price * entry.value[i].qty),
                                    style: AppTypography.bodyMd.copyWith(
                                      fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                            if (i < entry.value.length - 1)
                              const Divider(height: 1, color: AppColors.ink10),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],

                  if (order.notes != null && order.notes!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('NOTES',
                      style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                    const SizedBox(height: 8),
                    AppCard(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.sticky_note_2_outlined,
                            color: AppColors.ink70, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(order.notes!, style: AppTypography.bodyMd),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),

            // Footer action buttons
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                children: [
                  // Row 1: Reprint KOT + Cancel Order (existing)
                  Row(
                    children: [
                      Expanded(
                        child: LiquidSecondaryButton(
                          label: 'Reprint KOT',
                          leadingIcon: Icons.print_outlined,
                          onPressed: isCancelled
                              ? null
                              : () => _reprintKot(context),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: LiquidSecondaryButton(
                          label: isCancelled ? 'Cancelled' : 'Cancel Order',
                          leadingIcon: isCancelled
                              ? Icons.block
                              : Icons.cancel_outlined,
                          onPressed: isCancelled
                              ? null
                              : () => _confirmCancel(context, order),
                        ),
                      ),
                    ],
                  ),

                  // Row 2: Discount + Generate Bill / Collect Payment
                  if (isSent && !_paymentCollected) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        // Discount button (before bill is generated)
                        if (!_billGenerated && flags.discounts)
                          Expanded(
                            child: LiquidSecondaryButton(
                              label: _discountAmount != null
                                  ? 'Discount Applied'
                                  : 'Discount',
                              leadingIcon: Icons.discount_outlined,
                              onPressed: _discountAmount != null
                                  ? null
                                  : () => _openDiscount(order),
                            ),
                          ),
                        if (!_billGenerated && flags.discounts)
                          const SizedBox(width: 8),

                        // Generate Bill or Collect Payment
                        Expanded(
                          child: _billGenerated
                              ? LiquidPrimaryButton(
                                  label: 'Collect Payment',
                                  fullWidth: true,
                                  leadingIcon: Icons.payment_outlined,
                                  onPressed: _openPayment,
                                )
                              : LiquidPrimaryButton(
                                  label: _generatingBill
                                      ? 'Generating...'
                                      : 'Generate Bill',
                                  fullWidth: true,
                                  leadingIcon: _generatingBill
                                      ? Icons.hourglass_top
                                      : Icons.receipt_long_outlined,
                                  onPressed: _generatingBill
                                      ? null
                                      : () => _generateBill(order),
                                ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      ),  // LiquidMeshBackground
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final OrderStatus status;
  const _StatusBadge({required this.status});

  Color get _color => switch (status) {
    OrderStatus.sent      => AppColors.success,
    OrderStatus.modified  => AppColors.warn,
    OrderStatus.cancelled => AppColors.danger,
  };

  String get _label => switch (status) {
    OrderStatus.sent      => 'SENT',
    OrderStatus.modified  => 'MODIFIED',
    OrderStatus.cancelled => 'CANCELLED',
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(_label,
        style: AppTypography.micro.copyWith(
          color: _color, letterSpacing: 0.8,
        )),
    );
  }
}
