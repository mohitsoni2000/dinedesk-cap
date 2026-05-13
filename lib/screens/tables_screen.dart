import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/customer_count_sheet.dart';
import '../widgets/table_merge_sheet.dart';

class TablesScreen extends ConsumerStatefulWidget {
  const TablesScreen({super.key});
  @override
  ConsumerState<TablesScreen> createState() => _TablesScreenState();
}

class _TablesScreenState extends ConsumerState<TablesScreen> {
  String _floor = 'GROUND';
  String _query = '';
  bool _searchOpen = false;

  void _onTableTap(RestaurantTable t) async {
    if (t.state == TableState.free) {
      // Free table → ask customer count, then open builder.
      final count = await CustomerCountSheet.show(context, t);
      if (!mounted || count == null) return;
      ref.read(cartProvider.notifier).clear();
      ref.read(orderNotesProvider.notifier).state = '';
      ref.read(orderCustomerCountProvider.notifier).state = count;
      ref.read(selectedTableIdProvider.notifier).state = t.id;
      // Table state will be updated via socket broadcast from Desktop.
      if (mounted) context.push('/order/${t.id}');
    } else if (t.state == TableState.mine) {
      // Clear stale cart if switching to a different table (C1 fix).
      final prevTable = ref.read(selectedTableIdProvider);
      if (prevTable != null && prevTable != t.id) {
        ref.read(cartProvider.notifier).clear();
        ref.read(orderNotesProvider.notifier).state = '';
      }
      ref.read(orderCustomerCountProvider.notifier).state = t.coverCount ?? 2;
      ref.read(selectedTableIdProvider.notifier).state = t.id;
      context.push('/order/${t.id}');
    } else if (t.state == TableState.other) {
      ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(SnackBar(
        backgroundColor: AppColors.ink,
        content: Text('Held by ${t.waiterName} — tap-and-hold to request',
            style: AppTypography.bodyMd.copyWith(color: Colors.white)),
        duration: const Duration(seconds: 2),
      ));
    } else if (t.state == TableState.dirty) {
      ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(const SnackBar(
        content: Text('Table needs cleaning. Bus boy notified.'),
      ));
    } else if (t.state == TableState.reserved) {
      ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(SnackBar(
        content: Text('Reserved · ${t.note ?? "see admin"}'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tables = ref.watch(tablesProvider);
    final conn = ref.watch(connectionProvider);
    final op = ref.watch(operatorProvider);
    final opName = op?.name ?? 'there';
    final restaurant = ref.watch(restaurantProvider);
    final restaurantName = restaurant?.name ?? 'Restaurant';
    final activeOps = ref.watch(activeOperatorsProvider);

    // Derive floors from actual table data; fall back to 'GROUND' before data loads.
    final allFloors = tables.map((t) => t.floor).toSet().toList();
    final floors = allFloors.isNotEmpty ? allFloors : ['GROUND'];
    // If the current floor is no longer in the list, snap to the first available.
    if (!floors.contains(_floor)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _floor = floors.first);
      });
    }

    final filtered = tables.where((t) {
      if (t.floor != _floor) return false;
      if (_query.isEmpty) return true;
      return t.id.toLowerCase().contains(_query.toLowerCase()) ||
          (t.waiterName?.toLowerCase().contains(_query.toLowerCase()) ?? false);
    }).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Tables', style: AppTypography.displayMd),
                      Row(children: [
                        Text('Hi, ${opName.split(' ').first} · ',
                            style: AppTypography.caption),
                        Text(restaurantName,
                            style: AppTypography.caption
                                .copyWith(fontWeight: FontWeight.w600)),
                      ]),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(_searchOpen ? Icons.close : Icons.search,
                      color: AppColors.ink70),
                  onPressed: () => setState(() {
                    _searchOpen = !_searchOpen;
                    if (!_searchOpen) _query = '';
                  }),
                ),
                LiquidPill(
                  tint: conn.online
                      ? null
                      : AppColors.warn.withValues(alpha: 0.32),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              conn.online ? AppColors.success : AppColors.warn,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(conn.online ? 'LIVE' : 'OFFLINE'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_searchOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.55),
                  borderRadius: const BorderRadius.all(AppRadii.sm),
                  border: Border.all(color: AppColors.ink10),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Search table number or waiter…',
                    icon: Icon(Icons.search, color: AppColors.ink50, size: 18),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ),
          // Multi-operator presence.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _OnlineStrip(operators: activeOps),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _FloorTabs(
              value: _floor,
              floors: floors,
              onChange: (v) => setState(() => _floor = v),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: filtered.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.search_off,
                              color: AppColors.ink30, size: 48),
                          SizedBox(height: 12),
                          Text('No tables match', style: AppTypography.title),
                          SizedBox(height: 4),
                          Text('Try a different search or floor',
                              style: AppTypography.caption),
                        ],
                      ),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 200,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.05,
                    ),
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final t = filtered[i];
                      return _TableCard(
                        table: t,
                        onTap: () => _onTableTap(t),
                        onLongPress: t.state == TableState.mine ||
                                t.state == TableState.free
                            ? () => TableMergeSheet.show(context, t)
                            : null,
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

class _OnlineStrip extends StatelessWidget {
  final List<ActiveOperator> operators;
  const _OnlineStrip({required this.operators});

  @override
  Widget build(BuildContext context) {
    if (operators.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        SizedBox(
          width: (operators.length - 1) * 18.0 + 26 + 4,
          height: 26,
          child: Stack(
            children: [
              for (int i = 0; i < operators.length; i++)
                Positioned(
                  left: i * 18.0,
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.terra300, AppColors.terra500],
                      ),
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.paper, width: 2),
                    ),
                    child: Center(
                      child: Text(
                        operators[i].name.isNotEmpty ? operators[i].name[0] : '?',
                        style: AppTypography.caption.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${operators.map((o) => o.name).take(2).join(", ")} '
            '${operators.length > 2 ? "+${operators.length - 2} others " : ""}'
            'online',
            style: AppTypography.caption,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _FloorTabs extends StatelessWidget {
  final String value;
  final List<String> floors;
  final ValueChanged<String> onChange;
  const _FloorTabs(
      {required this.value, required this.floors, required this.onChange});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.5),
        borderRadius: const BorderRadius.all(AppRadii.sm),
        border: Border.all(color: AppColors.ink10, width: 0.5),
      ),
      child: Row(
        children: [
          for (final f in floors)
            Expanded(
              child: GestureDetector(
                onTap: () => onChange(f),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: value == f ? AppColors.ink : Colors.transparent,
                    borderRadius: const BorderRadius.all(AppRadii.xs),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    f,
                    style: AppTypography.micro.copyWith(
                      color: value == f ? Colors.white : AppColors.ink70,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TableCard extends StatelessWidget {
  final RestaurantTable table;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _TableCard(
      {required this.table, required this.onTap, this.onLongPress});

  Color _bg() {
    switch (table.state) {
      case TableState.mine:
        return AppColors.tableMineBg;
      case TableState.other:
        return AppColors.tableOtherBg;
      case TableState.dirty:
        return AppColors.tableDirtyBg;
      case TableState.reserved:
        return AppColors.tableReservedBg;
      case TableState.free:
        return AppColors.tableFreeBg;
    }
  }

  Color _border() {
    switch (table.state) {
      case TableState.mine:
        return AppColors.terra400.withValues(alpha: 0.45);
      case TableState.other:
        return AppColors.info.withValues(alpha: 0.4);
      case TableState.dirty:
        return AppColors.warn.withValues(alpha: 0.4);
      case TableState.reserved:
        return AppColors.violet.withValues(alpha: 0.4);
      case TableState.free:
        return AppColors.success.withValues(alpha: 0.32);
    }
  }

  String _stateLabel() {
    switch (table.state) {
      case TableState.mine:
        return 'MINE';
      case TableState.other:
        return 'OTHER · ${table.waiterName}';
      case TableState.dirty:
        return 'DIRTY';
      case TableState.reserved:
        return 'RESERVED';
      case TableState.free:
        return 'FREE';
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Hero(
        tag: 'table-${table.id}',
        flightShuttleBuilder: (_, anim, __, ___, ____) {
          return AnimatedBuilder(
            animation: anim,
            builder: (_, __) => Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: _bg(),
                  borderRadius: const BorderRadius.all(AppRadii.lg),
                  border: Border.all(color: _border(), width: 1),
                  boxShadow: AppShadows.terraGlow,
                ),
              ),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: _bg(),
            borderRadius: const BorderRadius.all(AppRadii.lg),
            border: Border.all(color: _border(), width: 1),
            boxShadow: table.state == TableState.mine
                ? AppShadows.terraGlow
                : AppShadows.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      table.id,
                      style: AppTypography.displayMd.copyWith(fontSize: 24),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text('${table.seats} seats', style: AppTypography.caption),
                ],
              ),
              const Spacer(),
              Text(_stateLabel(), style: AppTypography.micro,
                maxLines: 1, overflow: TextOverflow.ellipsis),
              if (table.coverCount != null) ...[
                const SizedBox(height: 2),
                Text('${table.coverCount} guests',
                    style: AppTypography.caption),
              ],
              if (table.bill != null) ...[
                const SizedBox(height: 4),
                Text(
                  formatRupeesCompact(table.bill!),
                  style:
                      AppTypography.title.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
              if (table.note != null) ...[
                const SizedBox(height: 4),
                Text(table.note!, style: AppTypography.caption,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
