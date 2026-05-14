// History Screen — list of orders sent to kitchen during this shift.
//
// Filters by status (All / Sent / Modified / Cancelled) and date scope
// (Today / Yesterday). Tap a row → /history/:orderId for full read-only view.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/liquid_chrome.dart';

enum _DateScope { today, yesterday }

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});
  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  OrderStatus? _statusFilter;
  _DateScope _dateScope = _DateScope.today;

  /// Date-scoped orders (before status filter).
  List<HistoryOrder> _dateScoped(List<HistoryOrder> orders) {
    if (_dateScope == _DateScope.yesterday) return [];
    return orders;
  }

  /// Build status chips with counts from the date-scoped subset.
  List<Widget> _buildStatusChips(List<HistoryOrder> allOrders) {
    final scoped = _dateScoped(allOrders);
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
        count: scoped.where((o) => o.status == OrderStatus.sent).length,
        selected: _statusFilter == OrderStatus.sent,
        onTap: () => setState(() => _statusFilter = OrderStatus.sent),
      ),
      const SizedBox(width: 8),
      _StatusChip(
        label: 'Modified',
        color: AppColors.warn,
        count: scoped.where((o) => o.status == OrderStatus.modified).length,
        selected: _statusFilter == OrderStatus.modified,
        onTap: () => setState(() => _statusFilter = OrderStatus.modified),
      ),
      const SizedBox(width: 8),
      _StatusChip(
        label: 'Cancelled',
        color: AppColors.danger,
        count: scoped.where((o) => o.status == OrderStatus.cancelled).length,
        selected: _statusFilter == OrderStatus.cancelled,
        onTap: () => setState(() => _statusFilter = OrderStatus.cancelled),
      ),
      const SizedBox(width: 8),
      _StatusChip(
        label: 'Paid',
        color: AppColors.teal,
        count: scoped.where((o) => o.status == OrderStatus.paid).length,
        selected: _statusFilter == OrderStatus.paid,
        onTap: () => setState(() => _statusFilter = OrderStatus.paid),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final orders = ref.watch(historyProvider);

    final filtered = _dateScoped(orders).where((o) {
      if (_statusFilter != null && o.status != _statusFilter) return false;
      return true;
    }).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            const LiquidAppBar(title: 'History'),
            // Date scope segmented control.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.5),
                  borderRadius: const BorderRadius.all(AppRadii.sm),
                  border: Border.all(color: AppColors.ink10, width: 0.5),
                ),
                child: Row(
                  children: [
                    _DateTab(
                      label: 'TODAY',
                      selected: _dateScope == _DateScope.today,
                      onTap: () => setState(() => _dateScope = _DateScope.today),
                    ),
                    _DateTab(
                      label: 'YESTERDAY',
                      selected: _dateScope == _DateScope.yesterday,
                      onTap: () => setState(() => _dateScope = _DateScope.yesterday),
                    ),
                  ],
                ),
              ),
            ),
            // Status filter chips.
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                children: [
                  // Compute counts from date-scoped list (H5 fix).
                  ..._buildStatusChips(orders),
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
                          const Icon(Icons.receipt_long,
                            color: AppColors.ink30, size: 48),
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
                            style: AppTypography.caption,
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
                      return _OrderTile(
                        order: o,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          context.push('/history/${o.id}');
                        },
                      );
                    },
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _DateTab({
    required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.ink : Colors.transparent,
            borderRadius: const BorderRadius.all(AppRadii.xs),
          ),
          alignment: Alignment.center,
          child: Text(label,
            style: AppTypography.micro.copyWith(
              color: selected ? Colors.white : AppColors.ink70,
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
      onTap: () { HapticFeedback.selectionClick(); onTap(); },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : Colors.white.withValues(alpha: 0.6),
          borderRadius: const BorderRadius.all(AppRadii.pill),
          border: Border.all(color: selected ? AppColors.ink : AppColors.ink10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (color != null) ...[
              Container(
                width: 6, height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
            ],
            Text(label,
              style: AppTypography.caption.copyWith(
                color: selected ? Colors.white : AppColors.ink,
                fontWeight: FontWeight.w600,
              )),
            const SizedBox(width: 6),
            Text('$count',
              style: AppTypography.caption.copyWith(
                color: selected ? Colors.white.withValues(alpha: 0.7) : AppColors.ink50,
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
          Container(
            width: 4, height: 48,
            decoration: BoxDecoration(
              color: _statusColor(order.status),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(order.id, style: AppTypography.title,
                        overflow: TextOverflow.ellipsis, maxLines: 1),
                    ),
                    const SizedBox(width: 8),
                    _StatusBadge(status: order.status),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${order.tableId} · ${order.time} · ${order.itemCount} items',
                  style: AppTypography.caption,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(formatRupeesCompact(order.total),
                style: AppTypography.headline),
              const SizedBox(height: 2),
              const Icon(Icons.chevron_right,
                color: AppColors.ink30, size: 18),
            ],
          ),
        ],
      ),
    );
  }

  static Color _statusColor(OrderStatus s) => switch (s) {
    OrderStatus.sent      => AppColors.success,
    OrderStatus.modified  => AppColors.warn,
    OrderStatus.cancelled => AppColors.danger,
    OrderStatus.paid      => AppColors.teal,
  };
}

class _StatusBadge extends StatelessWidget {
  final OrderStatus status;
  const _StatusBadge({required this.status});

  Color get _color => switch (status) {
    OrderStatus.sent      => AppColors.success,
    OrderStatus.modified  => AppColors.warn,
    OrderStatus.cancelled => AppColors.danger,
    OrderStatus.paid      => AppColors.teal,
  };

  String get _label => switch (status) {
    OrderStatus.sent      => 'SENT',
    OrderStatus.modified  => 'MODIFIED',
    OrderStatus.cancelled => 'CANCELLED',
    OrderStatus.paid      => 'PAID',
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(_label,
        style: AppTypography.micro.copyWith(
          color: _color, letterSpacing: 0.8,
        )),
    );
  }
}
