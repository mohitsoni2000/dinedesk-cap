

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
import '../widgets/coupon_sheet.dart';
import '../widgets/offers_sheet.dart';

class OrderDetailScreen extends ConsumerStatefulWidget {
  final String orderId;
  const OrderDetailScreen({super.key, required this.orderId});

  @override
  ConsumerState<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends ConsumerState<OrderDetailScreen> {
  String get orderId => widget.orderId;

  List<BillInfo> _bills = [];
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

  bool _hasLinkedCustomer(HistoryOrder order) {
    final activeOrders = ref.read(activeOrdersProvider);
    for (final raw in activeOrders) {
      if (raw['id']?.toString() == order.orderId) {
        final customerId = raw['customer_id']?.toString();
        return customerId != null && customerId.isNotEmpty;
      }
    }
    return false;
  }

  static String _kitchenLabel(String key) => switch (key) {
        'tandoor' => 'Tandoor',
        'curry' => 'Curry / Main',
        'south' => 'South',
        'chinese' => 'Chinese',
        'beverages' => 'Beverages & Desserts',
        _ => key[0].toUpperCase() + key.substring(1),
      };

  static IconData _kitchenIcon(String key) => switch (key) {
        'tandoor' => Icons.local_fire_department_outlined,
        'curry' => Icons.soup_kitchen_outlined,
        'south' => Icons.ramen_dining_outlined,
        'chinese' => Icons.takeout_dining_outlined,
        'beverages' => Icons.local_cafe_outlined,
        _ => Icons.restaurant_menu,
      };

  void _reprintKot(BuildContext context) {
    HapticFeedback.mediumImpact();
    final socketService = ref.read(socketServiceProvider);

    final order = ref
        .read(historyProvider)
        .where((o) => o.id == orderId || o.orderId == orderId)
        .firstOrNull;
    bool acked = false;
    socketService.emit(
      'print:kot',
      {'order_id': order?.orderId ?? orderId},
      onAck: (response) {
        acked = true;
        if (!mounted) return;
        if (response['kind'] == 'error') {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(SnackBar(
              backgroundColor: AppColors.danger,
              content: Text(
                response['message']?.toString() ?? 'Reprint failed',
                style: AppTypography.bodyMd.copyWith(color: Colors.white),
              ),
            ));
        } else {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(const SnackBar(
              content: Text('Reprint queued · admin desktop'),
              duration: Duration(seconds: 2),
            ));
        }
      },
    );
    scheduleSocketTimeout(
      duration: const Duration(seconds: 10),
      isMounted: () => mounted,
      isStillWaiting: () => !acked,
      onTimeout: () {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(
            content: Text('Reprint request timed out — please retry'),
          ));
      },
    );
  }

  Future<void> _confirmCancel(BuildContext context, HistoryOrder order) async {

    final pinOk = await requirePinIfNeeded(context, ref, 'cancel_order');
    if (!pinOk || !context.mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: context.palette.surface,
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

    final socketService = ref.read(socketServiceProvider);
    socketService.emit('order:cancel', {
      'order_id': order.orderId,
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

      final list = ref.read(historyProvider);
      ref.read(historyProvider.notifier).state = [
        for (final o in list)
          if (o.id == order.id)
            HistoryOrder(
              id: o.id,
              orderId: o.orderId,
              tableId: o.tableId,
              time: o.time,
              date: o.date,
              itemCount: o.itemCount,
              total: o.total,
              status: OrderStatus.cancelled,
              lines: o.lines,
              notes: o.notes,
              createdBy: o.createdBy,
            )
          else
            o,
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
    final pinOk = await requirePinIfNeeded(context, ref, 'generate_bill');
    if (!pinOk || !mounted) return;
    _generatingBill = true;
    setState(() {});
    HapticFeedback.heavyImpact();

    final socketService = ref.read(socketServiceProvider);
    socketService.emit('bill:generate', {
      'order_id': order.orderId,
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
        final billsRaw = response['bills'];
        final parsedBills = <BillInfo>[];
        if (billsRaw is List) {
          for (final b in billsRaw) {
            if (b is Map) {
              parsedBills.add(BillInfo.fromMap(Map<String, dynamic>.from(b)));
            }
          }
        }
        final bill =
            (billsRaw is List && billsRaw.isNotEmpty && billsRaw[0] is Map)
                ? Map<String, dynamic>.from(billsRaw[0])
                : null;

        final grandTotal =
            parsedBills.fold(0.0, (double s, BillInfo b) => s + b.totalAmount);

        setState(() {
          _generatingBill = false;
          _billGenerated = true;
          _bills = parsedBills;
          _billId = bill?['id']?.toString() ?? response['bill_id']?.toString();
          _billNumber = bill?['bill_number']?.toString() ??
              response['bill_number']?.toString();
          _billTotal = grandTotal > 0 ? grandTotal : order.total;
          _billGst = (bill?['total_gst'] as num?)?.toDouble() ??
              (response['gst'] as num?)?.toDouble();
          _billServiceCharge = (bill?['service_charge'] as num?)?.toDouble() ??
              (response['service_charge'] as num?)?.toDouble();
          _discountAmount = (bill?['discount_amount'] as num?)?.toDouble() ??
              (response['discount'] as num?)?.toDouble();
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
    if (_bills.isEmpty && _billId == null) return;
    final billsToPass = _bills.isNotEmpty
        ? _bills
        : [
            BillInfo(
                id: _billId!,
                billNumber: _billNumber ?? '',
                totalAmount: _billTotal ?? 0,
                billType: 'food')
          ];

    final currentOrder =
        ref.read(historyProvider).where((o) => o.id == orderId).firstOrNull;
    final paid = await PaymentSheet.show(
      context,
      bills: billsToPass,
      hasCustomer: currentOrder != null && _hasLinkedCustomer(currentOrder),
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
      orderId: order.orderId,
      orderTotal: order.total,
    );
    if (result != null && mounted) {

      final orderMap = result['order'];
      if (orderMap is Map) {
        setState(() {
          _discountAmount = (orderMap['discount_amount'] as num?)?.toDouble() ??
              (result['discount_amount'] as num?)?.toDouble();
          _discountLabel = orderMap['discount_label']?.toString() ??
              result['discount_label']?.toString();
        });
      } else {
        setState(() {
          _discountAmount = (result['discount_amount'] as num?)?.toDouble() ??
              (result['amount'] as num?)?.toDouble();
          _discountLabel = result['discount_label']?.toString() ??
              result['label']?.toString();
        });
      }

      if (_billGenerated) {
        _billGenerated = false;
        _bills = [];
        _billId = null;
        _generateBill(order);
      }
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

  Future<void> _openCoupon(HistoryOrder order) async {
    final result = await CouponSheet.show(context, orderId: order.orderId);
    if (result != null && mounted) {
      final orderMap = result['order'];
      if (orderMap is Map) {
        setState(() {
          _discountAmount = (orderMap['discount_amount'] as num?)?.toDouble();
          _discountLabel = orderMap['discount_label']?.toString() ?? 'Coupon';
        });
      }
      if (_billGenerated) {
        _billGenerated = false;
        _bills = [];
        _billId = null;
        _generateBill(order);
      }
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          backgroundColor: AppColors.success,
          content: Text(
            'Coupon applied${_discountLabel != null ? ' · $_discountLabel' : ''}',
            style: AppTypography.bodyMd.copyWith(color: Colors.white),
          ),
        ));
    }
  }

  Future<void> _openOffers(HistoryOrder order) async {
    final result = await OffersSheet.show(context, orderId: order.orderId);
    if (result != null && mounted) {
      setState(() {
        _discountAmount = (result['discount_amount'] as num?)?.toDouble();
        _discountLabel = result['discount_label']?.toString() ?? 'Offer';
      });
      if (_billGenerated) {
        _billGenerated = false;
        _bills = [];
        _billId = null;
        _generateBill(order);
      }
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          backgroundColor: AppColors.success,
          content: Text(
            'Offer applied${_discountLabel != null ? ' · $_discountLabel' : ''}',
            style: AppTypography.bodyMd.copyWith(color: Colors.white),
          ),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final orders = ref.watch(historyProvider);
    final flags = ref.watch(flagsProvider);
    final order = orders
        .where((o) => o.id == orderId || o.orderId == orderId)
        .firstOrNull;

    ref.listen(activeOrdersProvider, (_, activeOrders) {
      if (_billGenerated || order == null) return;
      for (final raw in activeOrders) {
        if (raw['id']?.toString() != order.orderId) continue;
        final bills = raw['bills'];
        if (bills is List && bills.isNotEmpty) {
          setState(() => _billGenerated = true);
        }
        break;
      }
    });

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
              Icon(Icons.error_outline,
                  color: context.palette.ink30, size: 48),
              const SizedBox(height: 12),
              const Text('Order not found', style: AppTypography.title),
              const SizedBox(height: 4),
              const Text('It may have been removed',
                  style: AppTypography.caption),
              const Spacer(),
            ],
          ),
        ),
      );
    }

    final byKitchen = <String, List<HistoryOrderLine>>{};
    for (final l in order.lines) {
      byKitchen.putIfAbsent(l.kitchenSection, () => []).add(l);
    }

    final isCancelled = order.status == OrderStatus.cancelled;
    final isSent = order.status == OrderStatus.sent ||
        order.status == OrderStatus.modified;

    return LiquidMeshBackground(
      animate: false,
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

                    AppCard(
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: context.palette.tableMineBg,
                              borderRadius: const BorderRadius.all(AppRadii.xs),
                              border: Border.all(
                                  color: AppColors.terra400
                                      .withValues(alpha: 0.4)),
                            ),
                            child: Text(order.tableId,
                                style: AppTypography.caption
                                    .copyWith(fontWeight: FontWeight.w700)),
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
                                            : order.status ==
                                                    OrderStatus.cancelled
                                                ? 'Order cancelled'
                                                : order.status ==
                                                        OrderStatus.modified
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
                                    style: AppTypography.title
                                        .copyWith(color: AppColors.success)),
                                const Spacer(),
                                if (_billNumber != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: AppColors.success
                                          .withValues(alpha: 0.14),
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
                                      style: AppTypography.bodyMd
                                          .copyWith(color: AppColors.success)),
                                  const Spacer(),
                                  Text(
                                      '-${formatRupeesCompact(_discountAmount!)}',
                                      style: AppTypography.bodyMd
                                          .copyWith(color: AppColors.success)),
                                ],
                              ),
                            ],
                            if (_billGst != null) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Expanded(
                                      child: Text('GST',
                                          style: AppTypography.bodyMd)),
                                  Text(formatRupeesCompact(_billGst!),
                                      style: AppTypography.bodyMd),
                                ],
                              ),
                            ],
                            if (_billServiceCharge != null) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Expanded(
                                      child: Text('Service Charge',
                                          style: AppTypography.bodyMd)),
                                  Text(formatRupeesCompact(_billServiceCharge!),
                                      style: AppTypography.bodyMd),
                                ],
                              ),
                            ],
                            Divider(height: 16, color: context.palette.ink10),
                            Row(
                              children: [
                                const Text('Total', style: AppTypography.title),
                                const Spacer(),
                                Text(
                                    formatRupeesCompact(
                                        _billTotal ?? order.total),
                                    style: AppTypography.headline),
                              ],
                            ),
                            if (_paymentCollected) ...[
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color:
                                      AppColors.success.withValues(alpha: 0.14),
                                  borderRadius:
                                      const BorderRadius.all(AppRadii.xs),
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

                    for (final entry in byKitchen.entries) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color:
                                    AppColors.terra500.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(_kitchenIcon(entry.key),
                                  size: 14, color: AppColors.terra600),
                            ),
                            const SizedBox(width: 10),
                            Text(_kitchenLabel(entry.key).toUpperCase(),
                                style: AppTypography.micro
                                    .copyWith(letterSpacing: 1.2)),
                          ],
                        ),
                      ),
                      AppCard(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            for (int i = 0; i < entry.value.length; i++) ...[
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 12, 16, 12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 28,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        color: context.palette.ink05,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Center(
                                        child: Text('${entry.value[i].qty}×',
                                            style: AppTypography.caption
                                                .copyWith(
                                                    fontWeight:
                                                        FontWeight.w700)),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(entry.value[i].name,
                                              style: AppTypography.bodyMd),
                                          if (entry
                                              .value[i].mods.isNotEmpty) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                                entry.value[i].mods.join(' · '),
                                                style: AppTypography.caption
                                                    .copyWith(
                                                        color: context
                                                            .palette.ink70)),
                                          ],
                                        ],
                                      ),
                                    ),
                                    Text(
                                        formatRupeesCompact(
                                            entry.value[i].price *
                                                entry.value[i].qty),
                                        style: AppTypography.bodyMd.copyWith(
                                            fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ),
                              if (i < entry.value.length - 1)
                                Divider(
                                    height: 1, color: context.palette.ink10),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],

                    if (order.notes != null && order.notes!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text('NOTES',
                          style:
                              AppTypography.micro.copyWith(letterSpacing: 1.4)),
                      const SizedBox(height: 8),
                      AppCard(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.sticky_note_2_outlined,
                                color: context.palette.ink70, size: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(order.notes!,
                                  style: AppTypography.bodyMd),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                  ],
                ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  children: [

                    if (isSent) ...[
                    Row(
                      children: [
                        Expanded(
                          child: LiquidSecondaryButton(
                            label: 'Reprint KOT',
                            leadingIcon: Icons.print_outlined,
                            onPressed:
                                isCancelled ? null : () => _reprintKot(context),
                          ),
                        ),

                        if (!ref.watch(isWaiterProvider)) ...[
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
                      ],
                    ),
                    ],

                    if (isSent &&
                        !_paymentCollected &&
                        !ref.watch(isWaiterProvider)) ...[

                      if (!_billGenerated &&
                          (flags.discounts || flags.offers)) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            if (flags.discounts) ...[
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
                              const SizedBox(width: 8),
                              Expanded(
                                child: LiquidSecondaryButton(
                                  label: 'Coupon',
                                  leadingIcon:
                                      Icons.confirmation_number_outlined,
                                  onPressed: _discountAmount != null
                                      ? null
                                      : () => _openCoupon(order),
                                ),
                              ),
                            ],
                            if (flags.offers) ...[
                              if (flags.discounts) const SizedBox(width: 8),
                              Expanded(
                                child: LiquidSecondaryButton(
                                  label: 'Offers',
                                  leadingIcon: Icons.local_activity_outlined,
                                  onPressed: () => _openOffers(order),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [

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

                    if (_billGenerated &&
                        (_bills.isNotEmpty || _billId != null) &&
                        !ref.watch(isWaiterProvider)) ...[
                      const SizedBox(height: 8),
                      LiquidSecondaryButton(
                        label: _bills.length > 1
                            ? 'Print All Bills (${_bills.length})'
                            : 'Print Bill',
                        leadingIcon: Icons.receipt_long_outlined,
                        onPressed: () {
                          final socketService = ref.read(socketServiceProvider);
                          final billIds = _bills.isNotEmpty
                              ? _bills.map((b) => b.id).toList()
                              : [_billId!];
                          int printed = 0;
                          for (final id in billIds) {
                            socketService.emit('print:bill', <String, dynamic>{
                              'bill_id': id,
                            }, onAck: (response) {
                              if (!mounted) return;
                              printed++;
                              if (printed == billIds.length) {
                                ScaffoldMessenger.of(context)
                                  ..clearSnackBars()
                                  ..showSnackBar(SnackBar(
                                    content: Text(
                                        '${billIds.length} bill${billIds.length > 1 ? "s" : ""} queued · admin desktop'),
                                  ));
                              }
                            });
                          }
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final OrderStatus status;
  const _StatusBadge({required this.status});

  Color get _color => switch (status) {
        OrderStatus.sent => AppColors.success,
        OrderStatus.modified => AppColors.warn,
        OrderStatus.cancelled => AppColors.danger,
        OrderStatus.paid => AppColors.teal,
      };

  String get _label => switch (status) {
        OrderStatus.sent => 'SENT',
        OrderStatus.modified => 'MODIFIED',
        OrderStatus.cancelled => 'CANCELLED',
        OrderStatus.paid => 'PAID',
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
            color: _color,
            letterSpacing: 0.8,
          )),
    );
  }
}
