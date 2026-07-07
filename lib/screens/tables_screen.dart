import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../data/table_open_intent.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/table_merge_sheet.dart';

class TablesScreen extends ConsumerStatefulWidget {
  const TablesScreen({super.key});
  @override
  ConsumerState<TablesScreen> createState() => _TablesScreenState();
}

class _TablesScreenState extends ConsumerState<TablesScreen> {
  String? _floor; // null = auto-select first floor
  String _query = '';
  bool _searchOpen = false;
  bool _openingTable = false;
  String? _openingTableId;

  void _onTableTap(RestaurantTable t) async {
    if (_openingTable) return;
    final intent = resolveTableOpenIntent(t);
    if (intent.action == TableOpenAction.blocked) {
      ref.read(feedbackServiceProvider).fire(const FeedbackLight());
      _showTableError(intent.message ?? 'Table cannot be opened');
      return;
    }

    ref.read(feedbackServiceProvider).fire(const FeedbackMedium());
    final prevTable = ref.read(selectedTableIdProvider);
    if (prevTable != null && prevTable != t.serverId) {
      ref.read(cartProvider.notifier).clear();
      ref.read(orderNotesProvider.notifier).state = '';
    }
    ref.read(selectedTableIdProvider.notifier).state = t.serverId;

    if (intent.action == TableOpenAction.createDraft) {
      setState(() {
        _openingTable = true;
        _openingTableId = t.serverId;
      });
      final response = await ref.read(socketServiceProvider).emitAck(
        'order:create',
        {
          'table_id': t.serverId,
          'items': const [],
          'order_type': 'dine_in',
        },
      );
      if (!mounted) return;
      setState(() {
        _openingTable = false;
        _openingTableId = null;
      });
      if (response['kind'] == 'error') {
        _showTableError(
            response['message']?.toString() ?? 'Could not open table');
        return;
      }
      ref.read(syncServiceProvider).applyOrderAck(response);
    }

    // KOT history seed: when opening an existing order, ensure historyProvider
    // has an entry for this table so KotHistorySheet shows correctly.
    if (intent.action == TableOpenAction.openOrder) {
      final activeOrders = ref.read(activeOrdersProvider);
      final tableData = ref
          .read(tablesProvider)
          .where((tbl) => tbl.serverId == t.serverId)
          .firstOrNull;
      final activeOrderId = tableData?.activeOrderId;
      final orderMap = activeOrders.where((o) {
        final id = o['id']?.toString();
        final tableId = o['table_id']?.toString();
        return (activeOrderId != null && id == activeOrderId) ||
            tableId == t.serverId;
      }).firstOrNull;
      if (orderMap != null) {
        ref.read(syncServiceProvider).applyOrderAck(
          {'order': orderMap},
          includeHistory: true,
        );
      }
    }

    if (!mounted || intent.route == null) return;
    context.go(intent.route!);
  }

  void _showTableError(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        backgroundColor: AppColors.ink,
        content: Text(
          message,
          style: AppTypography.bodyMd.copyWith(color: Colors.white),
        ),
        duration: const Duration(seconds: 2),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final tables = ref.watch(tablesProvider);
    final connOnline = ref.watch(connectionProvider.select((c) => c.online));
    final op = ref.watch(operatorProvider);
    final opName = op?.name ?? 'there';
    final restaurant = ref.watch(restaurantProvider);
    final restaurantName = restaurant?.name ?? 'Restaurant';
    final activeOps = ref.watch(activeOperatorsProvider);

    // Derive floors from actual table data.
    final allFloors = tables.map((t) => t.floor).toSet().toList();
    final floors = allFloors.isNotEmpty ? allFloors : ['Ground'];
    final activeFloor = _floor ?? floors.first;
    // If the current floor is no longer in the list, snap to the first.
    if (!floors.contains(activeFloor) && floors.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _floor = floors.first);
      });
    }

    final query = _query.toLowerCase();
    final filtered = tables.where((t) {
      if (t.floor != activeFloor) return false;
      if (query.isEmpty) return true;
      return t.id.toLowerCase().contains(query) ||
          (t.waiterName?.toLowerCase().contains(query) ?? false);
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
                        color: context.palette.ink70),
                    onPressed: () => setState(() {
                      _searchOpen = !_searchOpen;
                      if (!_searchOpen) _query = '';
                    }),
                  ),
                  LiquidPill(
                    tint: connOnline
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
                            color: connOnline
                                ? AppColors.success
                                : AppColors.warn,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(connOnline ? 'ONLINE' : 'OFFLINE'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (_searchOpen)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: LiquidGlassSurface(
                  borderRadius: const BorderRadius.all(AppRadii.sm),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  blur: 20,
                  thickness: 10,
                  child: TextField(
                    autofocus: true,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Search table number or waiter…',
                      icon: Icon(Icons.search,
                          color: context.palette.ink50, size: 18),
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
                value: activeFloor,
                floors: floors,
                onChange: (v) => setState(() => _floor = v),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.search_off,
                                  color: context.palette.ink30, size: 48),
                              const SizedBox(height: 12),
                              const Text('No tables match',
                                  style: AppTypography.title),
                              const SizedBox(height: 4),
                              const Text('Try a different search or floor',
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
                          return Entrance(
                            delay:
                                Duration(milliseconds: 35 * (i < 12 ? i : 12)),
                            offsetY: 10,
                            child: _TableCard(
                              table: t,
                              isLoading: _openingTable &&
                                  _openingTableId == t.serverId,
                              onTap: () => _onTableTap(t),
                              // Table merge — disabled for waiters (operator-only).
                              onLongPress: ((t.state == TableState.mine ||
                                          t.state == TableState.other) &&
                                      !ref.watch(isWaiterProvider))
                                  ? () => TableMergeSheet.show(context, t)
                                  : null,
                              occupiedSince: t.occupiedSince,
                            ),
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
                      border:
                          Border.all(color: context.palette.surface, width: 2),
                    ),
                    child: Center(
                      child: Text(
                        operators[i].name.isNotEmpty
                            ? operators[i].name[0]
                            : '?',
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
    return LiquidGlassSurface(
      borderRadius: const BorderRadius.all(AppRadii.sm),
      padding: const EdgeInsets.all(4),
      blur: 24,
      thickness: 12,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final f in floors)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: GestureDetector(
                  onTap: () => onChange(f),
                  child: SpringBuilder(
                    to: value == f ? 1.0 : 0.0,
                    spring: RestroSprings.snappy,
                    builder: (BuildContext _, double t, Widget? child) {
                      return Container(
                        constraints: const BoxConstraints(minWidth: 96),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Color.lerp(
                              Colors.transparent,
                              context.palette.isDark
                                  ? AppColors.terra600
                                  : AppColors.ink,
                              t),
                          borderRadius: const BorderRadius.all(AppRadii.xs),
                        ),
                        alignment: Alignment.center,
                        child: child,
                      );
                    },
                    child: Text(
                      f,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.micro.copyWith(
                        color:
                            value == f ? Colors.white : context.palette.ink70,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Occupied-since badge that keeps its own clock. Only this ~40px widget
/// rebuilds each minute — previously the entire tables grid rebuilt on a
/// screen-level Timer, freezing low-end devices once a minute.
class _OccupancyBadge extends StatefulWidget {
  final DateTime since;
  const _OccupancyBadge({required this.since});

  @override
  State<_OccupancyBadge> createState() => _OccupancyBadgeState();
}

class _OccupancyBadgeState extends State<_OccupancyBadge> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(widget.since);
    final label = elapsed.inHours >= 1
        ? '${elapsed.inHours}h ${elapsed.inMinutes.remainder(60)}m'
        : '${elapsed.inMinutes}m';
    final color = elapsed.inMinutes < 30
        ? AppColors.success
        : elapsed.inMinutes < 60
            ? AppColors.warn
            : AppColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadiiValues.sm),
      ),
      child: Text(
        label,
        style: AppTypography.micro.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _TableCard extends ConsumerWidget {
  final RestaurantTable table;
  final bool isLoading;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final DateTime? occupiedSince;
  const _TableCard({
    required this.table,
    required this.isLoading,
    required this.onTap,
    this.onLongPress,
    this.occupiedSince,
  });

  Color _bg(BuildContext context) {
    final palette = context.palette;
    switch (table.state) {
      case TableState.mine:
        return palette.tableMineBg;
      case TableState.other:
        return palette.tableOtherBg;
      case TableState.dirty:
        return palette.tableDirtyBg;
      case TableState.reserved:
        return palette.tableReservedBg;
      case TableState.free:
        return palette.tableFreeBg;
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
    if (table.activeBillCount > 0) return 'BILL PENDING';
    switch (table.state) {
      case TableState.mine:
        return 'MINE';
      case TableState.other:
        final waiter = table.waiterName;
        return waiter == null || waiter.isEmpty ? 'OTHER' : 'OTHER · $waiter';
      case TableState.dirty:
        return 'DIRTY';
      case TableState.reserved:
        return 'RESERVED';
      case TableState.free:
        return 'FREE';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLinked = ref.watch(linkGroupsProvider.select(
      (groups) => groups.values.any((ids) => ids.contains(table.serverId)),
    ));
    final isReady = ref.watch(readyOrdersProvider.select(
      (list) => list.any((t) => t.tableId == table.serverId),
    ));

    return Pressable(
      onTap: isLoading ? null : onTap,
      onLongPress: onLongPress,
      pressedScale: 0.97,
      child: Hero(
        tag: HeroTags.tableCard(table.serverId),
        flightShuttleBuilder: (flightContext, anim, __, ___, ____) {
          return AnimatedBuilder(
            animation: anim,
            builder: (_, __) => Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: _bg(flightContext),
                  borderRadius: const BorderRadius.all(AppRadii.lg),
                  border: Border.all(color: _border(), width: 1),
                  boxShadow: AppShadows.terraGlow,
                ),
              ),
            ),
          );
        },
        child: Stack(
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: _bg(context),
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(_stateLabel(),
                            style: AppTypography.micro,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (isLinked)
                        const Icon(Icons.link, size: 12, color: AppColors.info),
                    ],
                  ),
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (table.note != null) ...[
                    const SizedBox(height: 4),
                    Text(table.note!,
                        style: AppTypography.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
            if (table.state == TableState.mine && occupiedSince != null)
              Positioned(
                right: 4,
                bottom: 4,
                child: _OccupancyBadge(since: occupiedSince!),
              ),
            if (isReady)
              Positioned(
                right: 4,
                top: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.success,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'READY',
                    style: AppTypography.micro.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            if (isLoading)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.ink.withValues(alpha: 0.38),
                    borderRadius: const BorderRadius.all(AppRadii.lg),
                  ),
                  child: const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
