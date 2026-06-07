// KOT History Sheet — shows past KOT rounds for the current table.
//
// Opened from the order builder header. Displays all orders sent
// from this table during the current session, grouped by time.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../theme/tokens.dart';
import 'kot_edit_sheet.dart';
import 'liquid_chrome.dart';
import 'liquid_glass_surface.dart';

class KotHistorySheet extends ConsumerWidget {
  final String tableServerId;
  const KotHistorySheet({super.key, required this.tableServerId});

  static Future<void> show(BuildContext context, String tableServerId) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => KotHistorySheet(tableServerId: tableServerId),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allOrders = ref.watch(historyProvider);
    final tables = ref.watch(tablesProvider);

    final table =
        tables.where((t) => t.serverId == tableServerId).firstOrNull;
    final tableDisplay = table?.id ?? tableServerId;
    final activeOrderId = table?.activeOrderId;

    // Primary filter: match by active order ID (most reliable — one order per table).
    // Fallback: match by tableId display name or raw serverId for orders loaded
    // before the active order was tracked (e.g. boot-loaded entries).
    final tableOrders = allOrders.where((o) {
      if (activeOrderId != null && o.orderId == activeOrderId) return true;
      if (o.tableId == tableDisplay) return true;
      if (o.tableId == tableServerId) return true;
      return false;
    }).toList()
      ..sort((a, b) {
        // Newest first: compare YYYY-MM-DDTHH:MM lexicographically.
        final aKey = '${a.date}T${a.time}';
        final bKey = '${b.date}T${b.time}';
        return bKey.compareTo(aKey);
      });

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      expand: false,
      builder: (_, scroll) => LiquidGlassSurface(
        blur: 30,
        thickness: 14,
        borderRadius: const BorderRadius.vertical(top: AppRadii.lg),
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.ink30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.history, color: AppColors.ink70, size: 20),
                  const SizedBox(width: 8),
                  Text('KOT History · $tableDisplay',
                      style: AppTypography.title),
                  const Spacer(),
                  Text('${tableOrders.length} orders',
                      style: AppTypography.caption),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.ink10),
            Expanded(
              child: tableOrders.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.receipt_long,
                              color: AppColors.ink30, size: 48),
                          SizedBox(height: 12),
                          Text('No orders yet', style: AppTypography.title),
                          SizedBox(height: 4),
                          Text('KOTs sent to this table will appear here',
                              style: AppTypography.caption),
                        ],
                      ),
                    )
                  : ListView.separated(
                      controller: scroll,
                      padding: const EdgeInsets.all(16),
                      itemCount: tableOrders.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) {
                        final order = tableOrders[i];
                        return _KotCard(order: order);
                      },
                    ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  16, 8, 16, 16 + MediaQuery.of(context).viewPadding.bottom),
              child: LiquidPrimaryButton(
                label: 'Close',
                fullWidth: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KotCard extends ConsumerWidget {
  final HistoryOrder order;
  const _KotCard({required this.order});

  Color get _statusColor => switch (order.status) {
        OrderStatus.sent => AppColors.success,
        OrderStatus.modified => AppColors.warn,
        OrderStatus.cancelled => AppColors.danger,
        OrderStatus.paid => AppColors.teal,
      };

  String get _statusLabel => switch (order.status) {
        OrderStatus.sent => 'SENT',
        OrderStatus.modified => 'MODIFIED',
        OrderStatus.cancelled => 'CANCELLED',
        OrderStatus.paid => 'PAID',
      };

  bool get _isEditable =>
      order.status == OrderStatus.sent || order.status == OrderStatus.modified;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(flagsProvider).kotEdit && _isEditable;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.paper,
        borderRadius: const BorderRadius.all(AppRadii.md),
        border: Border.all(color: AppColors.ink10),
        boxShadow: AppShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 32,
                decoration: BoxDecoration(
                  color: _statusColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(order.id,
                            style: AppTypography.bodyMd
                                .copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: _statusColor.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(_statusLabel,
                              style: AppTypography.micro.copyWith(
                                  color: _statusColor, letterSpacing: 0.6)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text('${order.time} · ${order.itemCount} items',
                        style: AppTypography.caption),
                  ],
                ),
              ),
              Text(formatRupeesCompact(order.total),
                  style: AppTypography.title
                      .copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
          if (order.lines.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(height: 1, color: AppColors.ink10),
            const SizedBox(height: 8),
            for (final line in order.lines.take(5))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    SizedBox(
                        width: 24,
                        child: Text('${line.qty}×',
                            style: AppTypography.caption
                                .copyWith(fontWeight: FontWeight.w600))),
                    Expanded(
                        child: Text(line.name,
                            style: AppTypography.caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                    Text(formatRupeesCompact(line.price * line.qty),
                        style: AppTypography.caption),
                  ],
                ),
              ),
            if (order.lines.length > 5)
              Text('+${order.lines.length - 5} more items',
                  style: AppTypography.micro.copyWith(color: AppColors.ink50)),
          ],
          if (canEdit) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: AppColors.ink10),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () => KotEditSheet.show(context, order),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.edit_note, size: 15, color: AppColors.warn),
                  const SizedBox(width: 4),
                  Text('Edit KOT',
                      style: AppTypography.caption
                          .copyWith(color: AppColors.warn, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
