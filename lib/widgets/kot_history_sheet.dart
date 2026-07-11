

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'kot_edit_sheet.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

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

    final tableOrders = allOrders.where((o) {
      if (o.status == OrderStatus.paid || o.status == OrderStatus.cancelled) {
        return false;
      }
      if (activeOrderId != null && o.orderId == activeOrderId) return true;
      if (o.tableId == tableDisplay) return true;
      if (o.tableId == tableServerId) return true;
      return false;
    }).toList()
      ..sort((a, b) {

        final aKey = '${a.date}T${a.time}';
        final bKey = '${b.date}T${b.time}';
        return bKey.compareTo(aKey);
      });

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      expand: false,
      builder: (_, scroll) => AppSurface(
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            const SizedBox(height: 8),
            const SheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.history, color: AppColors.terra, size: 20),
                  const SizedBox(width: 8),
                  Text('KOT History · $tableDisplay',
                      style: AppTypography.sheetTitle),
                  const Spacer(),
                  Text('${tableOrders.length} orders',
                      style: AppTypography.caption),
                ],
              ),
            ),
            Divider(height: 1, color: context.palette.ink10),
            Expanded(
              child: tableOrders.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.receipt_long,
                              color: context.palette.ink30, size: 48),
                          const SizedBox(height: 12),
                          const Text('No orders yet',
                              style: AppTypography.title),
                          const SizedBox(height: 4),
                          const Text('KOTs sent to this table will appear here',
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
                        return _KotCard(
                            order: order, index: tableOrders.length - i);
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
  final int index;
  const _KotCard({required this.order, required this.index});

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

    final canEdit = ref.watch(flagsProvider).kotEdit &&
        _isEditable &&
        !ref.watch(isWaiterProvider);
    final myId = ref.watch(operatorProvider)?.username;
    final isMine = order.createdBy != null && order.createdBy == myId;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.palette.surface,
        borderRadius: const BorderRadius.all(AppRadii.md),
        border: Border.all(color: context.palette.hairline),
        boxShadow: context.palette.cardShadow,
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
                        Text('KOT #$index',
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
                        if (isMine) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: context.palette.terraSoft,
                              borderRadius:
                                  BorderRadius.all(AppRadii.pill),
                            ),
                            child: Text('YOU',
                                style: AppTypography.pill.copyWith(
                                    color: AppColors.terraDeep)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                        isMine || order.createdBy == null
                            ? '${order.time} · ${order.itemCount} items'
                            : '${order.createdBy} · ${order.time} · ${order.itemCount} items',
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
            Divider(height: 1, color: context.palette.ink10),
            const SizedBox(height: 8),
            for (final line in order.lines)
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
          ],
          if (canEdit) ...[
            const SizedBox(height: 10),
            Divider(height: 1, color: context.palette.ink10),
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
