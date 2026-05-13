// Order Detail Screen — read-only view of a sent order.
//
// Reached from /history/:orderId. Operator can:
//   • Reprint KOT  (re-emits the print event to the admin desktop)
//   • Cancel order (only allowed for orders < 5 minutes old; here always shown
//                    for demo, but disabled for already-cancelled orders)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_mesh_background.dart';

class OrderDetailScreen extends ConsumerWidget {
  final String orderId;
  const OrderDetailScreen({super.key, required this.orderId});

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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: AppColors.ink,
      content: Row(children: [
        const Icon(Icons.print_outlined, color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Text('Reprint queued · admin desktop',
          style: AppTypography.bodyMd.copyWith(color: Colors.white)),
      ]),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _confirmCancel(
      BuildContext context, WidgetRef ref, HistoryOrder order) async {
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
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.danger,
        content: Text('Order ${order.id} cancelled',
          style: AppTypography.bodyMd.copyWith(color: Colors.white)),
      ));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(historyProvider);
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
                                order.status == OrderStatus.cancelled
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

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: LiquidSecondaryButton(
                      label: 'Reprint KOT',
                      leadingIcon: Icons.print_outlined,
                      onPressed: isCancelled ? null : () => _reprintKot(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LiquidPrimaryButton(
                      label: isCancelled ? 'Cancelled' : 'Cancel Order',
                      fullWidth: true,
                      leadingIcon: isCancelled ? Icons.block : Icons.cancel_outlined,
                      onPressed: isCancelled
                        ? null
                        : () => _confirmCancel(context, ref, order),
                    ),
                  ),
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
