

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';

enum _DateScope { today, yesterday }

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});
  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  OrderStatus? _statusFilter;
  _DateScope _dateScope = _DateScope.today;

  List<HistoryOrder> _dateScoped(List<HistoryOrder> orders) {
    final now = DateTime.now();
    final String targetDate;
    if (_dateScope == _DateScope.yesterday) {
      final yesterday = now.subtract(const Duration(days: 1));
      targetDate =
          '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
    } else {
      targetDate =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    }
    return orders.where((o) => o.date == targetDate).toList();
  }

  List<Widget> _buildStatusChips(List<HistoryOrder> allOrders) {
    final scoped = _dateScoped(allOrders);

    final counts = <OrderStatus, int>{};
    for (final o in scoped) {
      counts[o.status] = (counts[o.status] ?? 0) + 1;
    }
    return [
      _StatusChip(
        label: 'All',
        count: scoped.length,
        selected: _statusFilter == null,
        onTap: () => setState(() => _statusFilter = null),
      ),
      const SizedBox(width: 8),
      _StatusChip(
        label: 'Sent',
        color: AppColors.success,
        count: counts[OrderStatus.sent] ?? 0,
        selected: _statusFilter == OrderStatus.sent,
        onTap: () => setState(() => _statusFilter = OrderStatus.sent),
      ),
      const SizedBox(width: 8),
      _StatusChip(
        label: 'Modified',
        color: AppColors.warn,
        count: counts[OrderStatus.modified] ?? 0,
        selected: _statusFilter == OrderStatus.modified,
        onTap: () => setState(() => _statusFilter = OrderStatus.modified),
      ),
      const SizedBox(width: 8),
      _StatusChip(
        label: 'Cancelled',
        color: AppColors.danger,
        count: counts[OrderStatus.cancelled] ?? 0,
        selected: _statusFilter == OrderStatus.cancelled,
        onTap: () => setState(() => _statusFilter = OrderStatus.cancelled),
      ),
      const SizedBox(width: 8),
      _StatusChip(
        label: 'Paid',
        color: AppColors.teal,
        count: counts[OrderStatus.paid] ?? 0,
        selected: _statusFilter == OrderStatus.paid,
        onTap: () => setState(() => _statusFilter = OrderStatus.paid),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final orders = ref.watch(historyProvider);

    final myId = ref.watch(operatorProvider)?.username ?? '';
    final myOrders = myId.isEmpty
        ? orders
        : orders
            .where((o) => o.createdBy == null || o.createdBy == myId)
            .toList();

    final filtered = _dateScoped(myOrders).where((o) {
      if (_statusFilter != null && o.status != _statusFilter) return false;
      return true;
    }).toList()
      ..sort((a, b) => b.time.compareTo(a.time));

    return ColoredBox(
      color: context.palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('History', style: AppTypography.displayLg),
                ),
              ),
              const SizedBox(height: 8),

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: context.palette.surface,
                  borderRadius: const BorderRadius.all(AppRadii.sm),
                  border: Border.all(color: context.palette.hairline),
                ),
                child: Row(
                  children: [
                    _DateTab(
                      label: 'TODAY',
                      selected: _dateScope == _DateScope.today,
                      onTap: () =>
                          setState(() => _dateScope = _DateScope.today),
                    ),
                    _DateTab(
                      label: 'YESTERDAY',
                      selected: _dateScope == _DateScope.yesterday,
                      onTap: () =>
                          setState(() => _dateScope = _DateScope.yesterday),
                    ),
                  ],
                ),
              ),
            ),

            SizedBox(
              height: AppTouchTargets.chip,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                children: [

                  ..._buildStatusChips(myOrders),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.receipt_long,
                                color: context.palette.ink30, size: 48),
                            const SizedBox(height: 12),
                            Text(
                                _dateScope == _DateScope.yesterday
                                    ? 'Nothing from yesterday'
                                    : 'No orders yet',
                                style: AppTypography.title),
                            const SizedBox(height: 4),
                            Text(
                                _statusFilter == null
                                    ? 'Orders you send will appear here'
                                    : 'No orders match this filter',
                                style: context.palette.caption,
                                textAlign: TextAlign.center),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) {
                        final o = filtered[i];
                        return Entrance(
                          delay: Duration(milliseconds: 45 * (i < 10 ? i : 10)),
                          child: _OrderTile(
                            order: o,
                            onTap: () {
                              HapticFeedback.selectionClick();
                              context.push('/history/${o.id}');
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _DateTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _DateTab(
      {required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? context.palette.selectedPill : Colors.transparent,
            borderRadius: const BorderRadius.all(AppRadii.xs),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: AppTypography.micro.copyWith(
              color: selected ? Colors.white : context.palette.ink70,
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final Color? color;
  final VoidCallback onTap;
  const _StatusChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.color,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? context.palette.selectedPill : context.palette.surface,
          borderRadius: const BorderRadius.all(AppRadii.pill),
          border: Border.all(
              color: selected ? context.palette.selectedPill : context.palette.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (color != null) ...[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
            ],
            Text(label,
                style: AppTypography.caption.copyWith(
                  color: selected ? Colors.white : context.palette.ink,
                  fontWeight: FontWeight.w600,
                )),
            const SizedBox(width: 6),
            Text('$count',
                style: AppTypography.caption.copyWith(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.7)
                      : context.palette.ink50,
                  fontWeight: FontWeight.w500,
                )),
          ],
        ),
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  final HistoryOrder order;
  final VoidCallback onTap;
  const _OrderTile({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(order.tableId,
                          style: AppTypography.tableName.copyWith(
                              fontSize: 20, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1),
                    ),
                    const SizedBox(width: 8),
                    _StatusBadge(status: order.status),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${order.time} · ${order.id} · ${order.itemCount} items',
                  style: context.palette.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(formatRupeesCompact(order.total),
                  style: AppTypography.bodyMd.copyWith(
                      fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 2),
              Icon(Icons.chevron_right,
                  color: context.palette.ink30, size: 18),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final OrderStatus status;
  const _StatusBadge({required this.status});

  (Color, Color) _tint(BuildContext context) => switch (status) {
        OrderStatus.sent => (
            AppColors.success.withValues(alpha: 0.12),
            AppColors.success
          ),
        OrderStatus.modified => (
            AppColors.warn.withValues(alpha: 0.14),
            AppColors.warn
          ),
        OrderStatus.cancelled => (
            AppColors.danger.withValues(alpha: 0.12),
            AppColors.danger
          ),
        OrderStatus.paid => (context.palette.paidBg, context.palette.paidText),
      };

  String get _label => switch (status) {
        OrderStatus.sent => 'SENT',
        OrderStatus.modified => 'MODIFIED',
        OrderStatus.cancelled => 'CANCELLED',
        OrderStatus.paid => 'PAID',
      };

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _tint(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(_label,
          style: AppTypography.micro.copyWith(
            color: fg,
            letterSpacing: 0.8,
          )),
    );
  }
}
