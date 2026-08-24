import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../data/money.dart';
import '../data/table_selectors.dart';
import '../data/recent_tables.dart';
import '../data/table_open_intent.dart';
import '../motion/motion.dart';
import '../services/socket_service.dart' show SocketState;
import '../services/trace.dart';
import '../theme/tokens.dart';
import '../widgets/app_surface.dart';
import '../widgets/page_content_clamp.dart';
import '../widgets/dynamic_toast.dart';
import '../widgets/table_merge_sheet.dart';

class TablesScreen extends ConsumerStatefulWidget {
  const TablesScreen({super.key});
  @override
  ConsumerState<TablesScreen> createState() => _TablesScreenState();
}

class _TablesScreenState extends ConsumerState<TablesScreen>
    with SingleTickerProviderStateMixin {
  String? _floor;
  String _query = '';
  bool _searchOpen = false;
  bool _openingTable = false;
  String? _openingTableId;
  TableState? _spotlight;
  bool _refreshing = false;
  late final AnimationController _refreshController;

  bool _hasScrolled = false;

  final PageController _floorPager = PageController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => Trace.mark('tables_visible'));

    _refreshController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void dispose() {
    _refreshController.dispose();
    _floorPager.dispose();
    super.dispose();
  }

  void _goFloor(String f, List<String> floors) {
    final idx = floors.indexOf(f);
    if (idx >= 0 && _floorPager.hasClients) {
      _floorPager.animateToPage(
        idx,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
      );
    }
    setState(() => _floor = f);
  }

  Widget _buildTablesGrid(List<RestaurantTable> list,
      {required bool showFloorTags}) {
    final query = _query.trim().toLowerCase();
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off, color: context.palette.ink30, size: 48),
              const SizedBox(height: 12),
              const Text('No tables match', style: AppTypography.title),
              const SizedBox(height: 4),
              Text(
                showFloorTags && query.isNotEmpty
                    ? 'No tables match — searched every floor for "$query"'
                    : showFloorTags
                        ? 'Try a different search or floor'
                        : 'No tables on this floor yet',
                textAlign: TextAlign.center,
                style: AppTypography.caption,
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      color: AppColors.terra,
      backgroundColor: context.palette.surface,
      displacement: 28,
      child: NotificationListener<ScrollUpdateNotification>(
        onNotification: (n) {
          if (!_hasScrolled && (n.scrollDelta?.abs() ?? 0) > 2) {
            _hasScrolled = true;
          }
          return false;
        },
        child: GridView.builder(
          scrollCacheExtent:
              ScrollCacheExtent.pixels(AppPerf.gridCacheExtentFor(context)),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: context.tableTileExtent,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            mainAxisExtent: context.tableTileExtent /
                    1.05 *
                    context.effectiveTextScale.clamp(1.0, 1.55) +
                16,
          ),
          itemCount: list.length,
          itemBuilder: (_, i) {
            final t = list[i];
            final card = _TableCard(
              table: t,
              isLoading: _openingTable && _openingTableId == t.serverId,
              onTap: () => _onTableTap(t),
              spotlight: _spotlight,
              showFloorTag: showFloorTags,
              onLongPress: ((t.state == TableState.mine ||
                          t.state == TableState.other) &&
                      ref.watch(flagsProvider.select((f) => f.tableMerge)))
                  ? () => TableMergeSheet.show(context, t)
                  : null,
              occupiedSince: t.occupiedSince,
            );

            if (i >= 12 || _hasScrolled || AppPerf.reduceEffects(context)) {
              return KeyedSubtree(key: ValueKey(t.serverId), child: card);
            }
            return KeyedSubtree(
              key: ValueKey(t.serverId),
              child: Entrance(
                delay: Duration(milliseconds: 35 * i),
                offsetY: 10,
                child: card,
              ),
            );
          },
        ),
      ),
    );
  }

  void _onTableTap(RestaurantTable t) async {
    if (_openingTable) return;
    final intent = resolveTableOpenIntent(t);
    if (intent.action == TableOpenAction.blocked) {
      ref.read(feedbackServiceProvider).fire(const FeedbackLight());
      _showTableError(intent.message ?? 'Table cannot be opened');
      return;
    }

    ref.read(feedbackServiceProvider).fire(const FeedbackMedium());
    ref.read(recentTablesProvider.notifier).record(t.serverId);
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
      final response =
          await ref.read(socketServiceProvider).emitAckWhenConnected(
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

    if (intent.action == TableOpenAction.openOrder) {
      final activeOrders = ref.read(activeOrdersProvider);
      final tableData = ref
          .read(tablesProvider)
          .where((tbl) => tbl.serverId == t.serverId)
          .firstOrNull;
      final activeOrderId = tableData?.activeOrderId;

      final active = activeOrders.where((o) {
        return (activeOrderId != null && o.id == activeOrderId) ||
            o.tableId == t.serverId;
      }).firstOrNull;
      if (active != null) {
        ref.read(syncServiceProvider).adoptOrder(active);
      }
    }

    if (!mounted || intent.route == null) return;
    context.go(intent.route!);
  }

  void _showTableError(String message) {
    DynamicToast.show(context,
        message: message,
        kind: ToastKind.error,
        duration: const Duration(seconds: 2));
  }

  Future<void> _refresh() async {
    if (_refreshing) return;

    final socketState = ref.read(socketServiceProvider).state;
    if (socketState != SocketState.connected &&
        socketState != SocketState.verified) {
      _showTableError('Not connected — nothing to resync');
      return;
    }
    setState(() => _refreshing = true);
    _refreshController.repeat();
    try {
      await ref.read(syncServiceProvider).requestResync();
      if (!mounted) return;
      DynamicToast.show(context,
          message: 'Resynced with the desk · just now',
          kind: ToastKind.success,
          duration: const Duration(seconds: 2));
    } finally {
      if (mounted) {
        _refreshController.stop();
        _refreshController.value = 0;
        setState(() => _refreshing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final connOnline = ref.watch(connectionProvider.select((c) => c.online));
    final op = ref.watch(operatorProvider);
    final opName = op?.name ?? 'there';
    final restaurant = ref.watch(restaurantProvider);
    final restaurantName = restaurant?.name ?? 'Restaurant';
    final activeOps = ref.watch(activeOperatorsProvider);

    final floors = ref.watch(orderedFloorNamesProvider);
    final activeFloor = _floor ?? floors.first;

    if (!floors.contains(activeFloor) && floors.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _floor = floors.first);
      });
    }

    final query = _query.trim().toLowerCase();
    final isSearching = query.isNotEmpty;
    final floorCounts = ref.watch(floorCountsProvider);

    final floorDataStale = ref.watch(isFloorDataStaleProvider);

    return Scaffold(
      backgroundColor: context.palette.paper,
      body: SafeArea(
        bottom: false,
        child: PageContentClamp(
          maxWidth: PageContentClamp.grid,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Tables', style: AppTypography.displayLg),
                          const SizedBox(height: 2),
                          Row(children: [
                            Flexible(
                              child: Text(
                                'Hi ${opName.split(' ').first} · ',
                                style: AppTypography.caption,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Flexible(
                              child: Text(
                                restaurantName,
                                style: AppTypography.caption
                                    .copyWith(fontWeight: FontWeight.w600),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ]),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _HeaderIconTile(
                      label: 'Refresh the floor',
                      onTap: _refresh,
                      child: RotationTransition(
                        turns: _refreshController,
                        child: Icon(Icons.refresh,
                            size: 18, color: context.palette.ink70),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _HeaderIconTile(
                      label: _searchOpen ? 'Close search' : 'Search tables',
                      icon: _searchOpen ? Icons.close : Icons.search,
                      onTap: () {
                        ref
                            .read(feedbackServiceProvider)
                            .fire(const FeedbackSelection());
                        setState(() {
                          _searchOpen = !_searchOpen;
                          if (!_searchOpen) _query = '';
                        });
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _ConnectionRail(
                    online: connOnline,
                    restaurantName: restaurantName,
                  ),
                ),
              ),
              if (floorDataStale)
                Container(
                  width: double.infinity,
                  color: context.palette.warnBg,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.history_toggle_off,
                          size: 16, color: context.palette.warnText),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Showing last known table layout — syncing…',
                          style: TextStyle(
                            fontSize: 12,
                            color: context.palette.warnText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_searchOpen)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: AppSurface(
                    borderRadius: const BorderRadius.all(AppRadii.sm),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shadow: const [],
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
              _RecentTablesRow(onOpen: _onTableTap),
              _CollapseSection(
                hidden: _searchOpen,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      child: _OnlineStrip(operators: activeOps),
                    ),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _LegendStrip(
                        active: _spotlight,
                        onChange: (s) => setState(() => _spotlight = s),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _StatsStrip(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _FloorTabs(
                  value: activeFloor,
                  floors: floors,
                  counts: floorCounts,
                  enabled: !isSearching,
                  onChange: (v) => _goFloor(v, floors),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: isSearching
                    ? _TablesGridSlot(
                        query: query,
                        showFloorTags: true,
                        builder: _buildTablesGrid,
                      )
                    : _FloorCoast(
                        controller: _floorPager,
                        floors: floors,
                        activeFloor: activeFloor,
                        onPageChanged: (i) {
                          if (_floor == floors[i]) return;
                          ref
                              .read(feedbackServiceProvider)
                              .fire(const FeedbackSelection());
                          setState(() => _floor = floors[i]);
                        },
                        pageBuilder: (context, floor) => _TablesGridSlot(
                          floor: floor,
                          showFloorTags: false,
                          builder: _buildTablesGrid,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderIconTile extends StatelessWidget {
  final IconData? icon;
  final Widget? child;
  final VoidCallback? onTap;
  final String label;
  const _HeaderIconTile({
    required this.label,
    this.icon,
    this.child,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      child: SizedBox(
        width: AppTouchTargets.minimum,
        height: AppTouchTargets.minimum,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: context.palette.surface,
              borderRadius: const BorderRadius.all(AppRadii.sm),
              border: Border.all(color: context.palette.hairline),
            ),
            alignment: Alignment.center,
            child: child ?? Icon(icon, size: 18, color: context.palette.ink70),
          ),
        ),
      ),
    );
  }
}

class _ConnectionRail extends StatelessWidget {
  final bool online;
  final String restaurantName;
  const _ConnectionRail({required this.online, required this.restaurantName});

  @override
  Widget build(BuildContext context) {
    final color = online ? AppColors.success : AppColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: const BorderRadius.all(AppRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (online)
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            )
          else
            _BlinkingDot(color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              online ? 'Connected · $restaurantName' : 'Reconnecting…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.caption.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlinkingDot extends StatefulWidget {
  final Color color;
  const _BlinkingDot({required this.color});
  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppPerf.reduceEffects(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

class _LegendStrip extends StatelessWidget {
  final TableState? active;
  final ValueChanged<TableState?> onChange;
  const _LegendStrip({required this.active, required this.onChange});

  static const _entries = [
    (TableState.free, 'FREE'),
    (TableState.mine, 'MINE'),
    (TableState.other, 'OTHER'),
    (TableState.dirty, 'DIRTY'),
    (TableState.reserved, 'RESERVED'),
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final e in _entries)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: GestureDetector(
                onTap: () => onChange(active == e.$1 ? null : e.$1),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: active == e.$1
                        ? _ringColor(context, e.$1).withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: const BorderRadius.all(AppRadii.pill),
                    border: Border.all(
                      color: active == e.$1
                          ? _ringColor(context, e.$1)
                          : context.palette.hairline,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _ringColor(context, e.$1),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(e.$2,
                          style: AppTypography.pill
                              .copyWith(color: context.palette.ink70)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatsStrip extends ConsumerWidget {
  const _StatsStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mineCount = ref.watch(tablesProvider.select(
      (list) => list.where((t) => t.state == TableState.mine).length,
    ));
    final freeCount = ref.watch(tablesProvider.select(
      (list) => list.where((t) => t.state == TableState.free).length,
    ));

    final billSum = ref.watch(tablesProvider.select(
      (list) => list.map((t) => t.bill ?? Money.zero).sumMoney(),
    ));

    return Row(
      children: [
        Expanded(
          child: _StatMiniCard(
            dotColor: AppColors.terra,
            label: 'My tables',
            value: _BumpNumber(value: mineCount),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatMiniCard(
            dotColor: AppColors.success,
            label: 'Free now',
            value: _BumpNumber(value: freeCount),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatMiniCard(
            label: 'On tables',
            value: Text(
              formatRupeesCompact(billSum),
              style: AppTypography.title.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatMiniCard extends StatelessWidget {
  final Color? dotColor;
  final String label;
  final Widget value;
  const _StatMiniCard(
      {this.dotColor, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      borderRadius: const BorderRadius.all(AppRadii.md),
      shadow: const [],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (dotColor != null) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration:
                      BoxDecoration(color: dotColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.pill
                        .copyWith(color: context.palette.ink50)),
              ),
            ],
          ),
          const SizedBox(height: 3),
          value,
        ],
      ),
    );
  }
}

class _BumpNumber extends StatelessWidget {
  final int value;
  const _BumpNumber({required this.value});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: value.toDouble(), end: value.toDouble()),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      builder: (_, v, __) => Text(
        '${v.round()}',
        style: AppTypography.title.copyWith(fontWeight: FontWeight.w800),
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
                      color: AppColors.terra,
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
  final Map<String, int> counts;
  final bool enabled;
  final ValueChanged<String> onChange;
  const _FloorTabs({
    required this.value,
    required this.floors,
    required this.counts,
    required this.enabled,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: enabled ? 1 : 0.4,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !enabled,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final f in floors)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => onChange(f),
                    child: SpringBuilder(
                      to: value == f ? 1.0 : 0.0,
                      spring: RestroSprings.snappy,
                      builder: (BuildContext _, double t, Widget? child) {
                        return Transform.scale(
                          scale: 1 + 0.03 * t,
                          child: Container(
                            constraints: const BoxConstraints(minWidth: 96),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: Color.lerp(context.palette.surface,
                                  context.palette.selectedPill, t),
                              borderRadius:
                                  const BorderRadius.all(AppRadii.pill),
                              border: Border.all(
                                color: t > 0.5
                                    ? Colors.transparent
                                    : context.palette.hairline,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: child,
                          ),
                        );
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            f,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.micro.copyWith(
                              color: value == f
                                  ? Colors.white
                                  : context.palette.ink70,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${counts[f] ?? 0}',
                            style: AppTypography.micro.copyWith(
                              color: value == f
                                  ? Colors.white.withValues(alpha: 0.7)
                                  : context.palette.ink50,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _pillBg(BuildContext context, TableState state) {
  switch (state) {
    case TableState.mine:
      return AppColors.terra;
    case TableState.other:
      return context.palette.tableOtherBg;
    case TableState.dirty:
      return context.palette.tableDirtyBg;
    case TableState.reserved:
      return context.palette.tableReservedBg;
    case TableState.free:
      return context.palette.tableFreeBg;
  }
}

Color _pillFg(BuildContext context, TableState state) {
  switch (state) {
    case TableState.mine:
      return Colors.white;
    case TableState.other:
      return context.palette.tableOtherText;
    case TableState.dirty:
      return context.palette.tableDirtyText;
    case TableState.reserved:
      return context.palette.tableReservedText;
    case TableState.free:
      return context.palette.tableFreeText;
  }
}

Color _ringColor(BuildContext context, TableState state) =>
    state == TableState.mine ? AppColors.terra : _pillFg(context, state);

String _pillLabel(TableState state, List<String> operatorNames) {
  switch (state) {
    case TableState.mine:
      return 'MINE';
    case TableState.other:
      final first =
          operatorNames.isNotEmpty ? operatorNames.first.trim() : null;
      if (first == null || first.isEmpty) return 'OTHER';
      final label = first.split(' ').first.toUpperCase();
      final extra = operatorNames.length - 1;
      return extra > 0 ? '$label +$extra' : label;
    case TableState.dirty:
      return 'DIRTY';
    case TableState.reserved:
      return 'RESERVED';
    case TableState.free:
      return 'FREE';
  }
}

String? _pillTooltip(TableState state, List<String> operatorNames) {
  if (state != TableState.other || operatorNames.length < 2) return null;
  return '${operatorNames.join(', ')} are working here';
}

Widget _applySpotlight(BuildContext context, Widget card, TableState state,
    TableState? spotlight) {
  if (spotlight == null) return card;
  if (state == spotlight) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(AppRadii.lg),
        border: Border.all(color: _ringColor(context, state), width: 1.5),
      ),
      child: card,
    );
  }
  return Opacity(
    opacity: 0.3,
    child: ColorFiltered(
      colorFilter: const ColorFilter.matrix(<double>[
        0.2126,
        0.7152,
        0.0722,
        0,
        0,
        0.2126,
        0.7152,
        0.0722,
        0,
        0,
        0.2126,
        0.7152,
        0.0722,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ]),
      child: card,
    ),
  );
}

class _StatePill extends StatelessWidget {
  final TableState state;
  final List<String> operatorNames;
  const _StatePill({required this.state, this.operatorNames = const []});

  @override
  Widget build(BuildContext context) {
    final bg = _pillBg(context, state);
    final fg = _pillFg(context, state);
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.all(AppRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(_pillLabel(state, operatorNames),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.pill.copyWith(color: fg)),
        ],
      ),
    );
    final tooltip = _pillTooltip(state, operatorNames);
    return tooltip == null ? pill : Tooltip(message: tooltip, child: pill);
  }
}

class _BillTag extends StatelessWidget {
  const _BillTag();

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.6, end: 1.0),
      duration: const Duration(milliseconds: 320),
      curve: Curves.elasticOut,
      builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.warn, width: 1),
          borderRadius: const BorderRadius.all(AppRadii.pill),
        ),
        child: Text('BILL',
            style: AppTypography.pill.copyWith(color: AppColors.warn)),
      ),
    );
  }
}

class _CustomerTag extends StatelessWidget {
  final String name;
  const _CustomerTag({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      constraints: const BoxConstraints(maxWidth: 90),
      decoration: BoxDecoration(
        color: context.palette.terraSoft,
        borderRadius: const BorderRadius.all(AppRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.person, size: 10, color: AppColors.terraInk),
          const SizedBox(width: 3),
          Flexible(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.pill.copyWith(color: AppColors.terraInk)),
          ),
        ],
      ),
    );
  }
}

class _FloorTag extends StatelessWidget {
  final String floor;
  const _FloorTag({required this.floor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: context.palette.terraSoft,
        borderRadius: BorderRadius.all(AppRadii.pill),
      ),
      child: Text(floor,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.pill.copyWith(color: AppColors.terraInk)),
    );
  }
}

class _ReadyChip extends StatelessWidget {
  const _ReadyChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: const BoxDecoration(
        color: AppColors.success,
        borderRadius: BorderRadius.all(AppRadii.pill),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 10, color: Colors.white),
          SizedBox(width: 3),
          Text('READY',
              style: TextStyle(
                fontFamily: AppTypography.inter,
                fontWeight: FontWeight.w700,
                fontSize: 9,
                color: Colors.white,
                letterSpacing: 0.4,
              )),
        ],
      ),
    );
  }
}

class _TimerChip extends StatefulWidget {
  final DateTime since;
  const _TimerChip({required this.since});

  @override
  State<_TimerChip> createState() => _TimerChipState();
}

class _TimerChipState extends State<_TimerChip> {
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
    final Color bg;
    final Color fg;
    if (elapsed.inMinutes < 30) {
      bg = AppColors.success.withValues(alpha: 0.14);
      fg = AppColors.success;
    } else if (elapsed.inMinutes < 60) {
      bg = AppColors.warn.withValues(alpha: 0.16);
      fg = AppColors.warn;
    } else {
      bg = context.palette.timerBadBg;
      fg = context.palette.timerBadText;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.all(AppRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 10, color: fg),
          const SizedBox(width: 3),
          Text(label, style: AppTypography.pill.copyWith(color: fg)),
        ],
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
  final TableState? spotlight;
  final bool showFloorTag;
  const _TableCard({
    required this.table,
    required this.isLoading,
    required this.onTap,
    this.onLongPress,
    this.occupiedSince,
    this.spotlight,
    this.showFloorTag = false,
  });

  Widget _buildBody(BuildContext context) {
    if (table.bill != null) {
      return Text(
        formatRupeesCompact(table.bill!),
        style: AppTypography.title
            .copyWith(fontWeight: FontWeight.w800, fontSize: 20),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (table.state == TableState.free) {
      return const Text(
        'Start order →',
        style: TextStyle(
          fontFamily: AppTypography.inter,
          fontWeight: FontWeight.w600,
          fontSize: 12.5,
          color: AppColors.success,
        ),
      );
    }
    if (table.state == TableState.dirty) {
      return Text('Needs cleaning',
          style: AppTypography.caption.copyWith(color: context.palette.ink50));
    }
    if (table.state == TableState.reserved && table.note != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 12, color: context.palette.ink50),
          const SizedBox(width: 4),
          Flexible(
            child: Text(table.note!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.caption
                    .copyWith(color: context.palette.ink50)),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLinked = ref.watch(
        linkedTableIdsProvider.select((ids) => ids.contains(table.serverId)));
    final isReady = ref.watch(
        readyTableIdsProvider.select((ids) => ids.contains(table.serverId)));
    final isMine = table.state == TableState.mine;
    final customerName = ref.watch(flagsProvider.select((f) => f.customers))
        ? ref.watch(historyProvider.select((orders) => orders
            .where((o) => o.orderId == table.activeOrderId)
            .firstOrNull
            ?.customerName))
        : null;

    final card = RepaintBoundary(
      child: JellyTap(
        amount: 0.05,
        onTap: isLoading ? null : onTap,
        onLongPress: onLongPress,
        onPressFeedback: () =>
            ref.read(feedbackServiceProvider).fire(const FeedbackLight()),
        child: Hero(
          tag: HeroTags.tableCard(table.serverId),
          flightShuttleBuilder: (flightContext, anim, __, ___, ____) {
            return AnimatedBuilder(
              animation: anim,
              builder: (_, __) => Material(
                color: Colors.transparent,
                child: Container(
                  decoration: BoxDecoration(
                    color: isMine
                        ? context.palette.tableMineWashEnd
                        : flightContext.palette.surface,
                    borderRadius: const BorderRadius.all(AppRadii.lg),
                    border:
                        Border.all(color: context.palette.hairline, width: 1),
                    boxShadow: isMine
                        ? AppShadows.mineFor(context)
                        : AppShadows.cardFor(context),
                  ),
                ),
              ),
            );
          },
          child: TiltOnTouch(
            maxTilt: 0.045,
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color:
                    isMine ? context.palette.mineWash : context.palette.surface,
                borderRadius: const BorderRadius.all(AppRadii.lg),
                border: Border.all(
                  color: isMine
                      ? context.palette.tableMineBorder
                      : context.palette.hairline,
                  width: 1,
                ),
                boxShadow: isMine
                    ? AppShadows.mineFor(context)
                    : AppShadows.cardFor(context),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Opacity(
                          opacity: table.state == TableState.dirty ? 0.55 : 1,
                          child: Text(
                            table.id,
                            style: AppTypography.tableName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (isReady)
                            const AttentionPulse(
                                scale: 1.06, child: _ReadyChip()),
                          if (isMine && occupiedSince != null) ...[
                            if (isReady) const SizedBox(height: 4),
                            _TimerChip(since: occupiedSince!),
                          ],
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _StatePill(
                          state: table.state,
                          operatorNames: table.joinedOperatorNames),
                      if (table.activeBillCount > 0) const _BillTag(),
                      if (customerName != null && customerName.isNotEmpty)
                        _CustomerTag(name: customerName),
                      if (isLinked)
                        const Icon(Icons.link, size: 12, color: AppColors.info),
                    ],
                  ),
                  const Spacer(),
                  _buildBody(context),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.event_seat_outlined,
                          size: 12, color: context.palette.ink50),
                      const SizedBox(width: 3),
                      Text('${table.seats}',
                          style: AppTypography.caption
                              .copyWith(color: context.palette.ink50)),
                      if (table.coverCount != null) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.people_outline,
                            size: 12, color: context.palette.ink50),
                        const SizedBox(width: 3),
                        Text('${table.coverCount}',
                            style: AppTypography.caption
                                .copyWith(color: context.palette.ink50)),
                      ],
                      const Spacer(),
                      if (showFloorTag) _FloorTag(floor: table.floor),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return Stack(
      children: [
        _applySpotlight(context, card, table.state, spotlight),
        if (isLoading)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: context.palette.ink.withValues(alpha: 0.38),
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
    );
  }
}

class _RecentTablesRow extends ConsumerWidget {
  final ValueChanged<RestaurantTable> onOpen;
  const _RecentTablesRow({required this.onOpen});

  Color _dot(BuildContext context, TableState s) => switch (s) {
        TableState.free => AppColors.success,
        TableState.mine => AppColors.terra,
        TableState.other => context.palette.tableOtherText,
        TableState.dirty => AppColors.amber,
        TableState.reserved => context.palette.tableReservedText,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = ref.watch(recentTablesProvider);
    if (ids.isEmpty) return const SizedBox.shrink();
    final byId = ref.watch(tablesProvider.select(
      (list) => {for (final t in list) t.serverId: t},
    ));
    final entries = <RestaurantTable>[
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
    if (entries.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SizedBox(
        height: 34,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  Icon(Icons.history, size: 13, color: context.palette.ink50),
                  const SizedBox(width: 4),
                  Text('RECENT',
                      style: AppTypography.micro.copyWith(
                          color: context.palette.ink50, letterSpacing: 1.0)),
                ],
              ),
            ),
            for (final t in entries)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Pressable(
                  onTap: () => onOpen(t),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                    decoration: BoxDecoration(
                      color: t.state == TableState.mine
                          ? context.palette.terraSoft
                          : context.palette.surface,
                      borderRadius: const BorderRadius.all(AppRadii.pill),
                      border: Border.all(
                        color: t.state == TableState.mine
                            ? context.palette.tableMineBorder
                            : context.palette.hairline,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: _dot(context, t.state),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(t.id,
                            style: AppTypography.caption
                                .copyWith(fontWeight: FontWeight.w700)),
                        if (t.bill != null) ...[
                          const SizedBox(width: 5),
                          Text(formatRupeesCompact(t.bill!),
                              style: AppTypography.caption
                                  .copyWith(color: context.palette.ink50)),
                        ],
                      ],
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

class _CollapseSection extends StatelessWidget {
  final bool hidden;
  final Widget child;
  const _CollapseSection({required this.hidden, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: hidden ? 0 : 1, end: hidden ? 0 : 1),
        duration: AppMotion.standard,
        curve: Curves.easeOutCubic,
        child: child,
        builder: (context, v, c) {
          if (v <= 0.002) return const SizedBox(width: double.infinity);
          return Align(
            alignment: Alignment.topCenter,
            heightFactor: v,
            child: Opacity(opacity: v, child: c),
          );
        },
      ),
    );
  }
}

class _TablesGridSlot extends ConsumerWidget {
  const _TablesGridSlot({
    this.floor,
    this.query = '',
    required this.showFloorTags,
    required this.builder,
  });

  final String? floor;
  final String query;
  final bool showFloorTags;
  final Widget Function(List<RestaurantTable> list,
      {required bool showFloorTags}) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tables = ref.watch(tablesProvider);
    final list = floor == null
        ? tables
            .where((t) =>
                t.id.toLowerCase().contains(query) ||
                t.joinedOperatorNames
                    .any((n) => n.toLowerCase().contains(query)))
            .toList(growable: false)
        : tables.where((t) => t.floor == floor).toList(growable: false);
    return builder(list, showFloorTags: showFloorTags);
  }
}

class _FloorCoast extends StatefulWidget {
  final PageController controller;
  final List<String> floors;
  final String activeFloor;
  final ValueChanged<int> onPageChanged;
  final Widget Function(BuildContext context, String floor) pageBuilder;
  const _FloorCoast({
    required this.controller,
    required this.floors,
    required this.activeFloor,
    required this.onPageChanged,
    required this.pageBuilder,
  });

  @override
  State<_FloorCoast> createState() => _FloorCoastState();
}

class _FloorCoastState extends State<_FloorCoast> {
  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.controller.hasClients) return;
      final int want = widget.floors.indexOf(widget.activeFloor);
      if (want < 0) return;
      final double at =
          widget.controller.page ?? widget.controller.initialPage.toDouble();
      if ((at - want).abs() > 0.5) widget.controller.jumpToPage(want);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.floors.length <= 1) {
      return widget.pageBuilder(context, widget.floors.first);
    }
    return PageView.builder(
      controller: widget.controller,
      onPageChanged: widget.onPageChanged,
      itemCount: widget.floors.length,
      itemBuilder: (context, i) {
        final Widget page = RepaintBoundary(
          child: widget.pageBuilder(context, widget.floors[i]),
        );
        if (AppPerf.reduceEffects(context)) return page;
        return AnimatedBuilder(
          animation: widget.controller,
          child: page,
          builder: (context, child) {
            double off = 0;
            if (widget.controller.position.haveDimensions) {
              off = (widget.controller.page ?? i.toDouble()) - i;
            }
            final double a = off.abs().clamp(0.0, 1.0);
            return Transform.translate(
              offset: Offset(off * -26, 0),
              child: Opacity(opacity: 1 - a * 0.28, child: child),
            );
          },
        );
      },
    );
  }
}
