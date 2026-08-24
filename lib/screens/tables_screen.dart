import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
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
  bool _mineOnly = false;
  bool _openingTable = false;
  String? _openingTableId;
  _StatusTag? _spotlight;
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
                    1.3 *
                    context.effectiveTextScale.clamp(1.0, 1.55) +
                8,
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

    final mineCountOnFloor = ref.watch(tablesProvider.select((list) => list
        .where((t) => t.floor == activeFloor && t.state == TableState.mine)
        .length));

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
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    _MineFilterToggle(
                      active: _mineOnly,
                      count: mineCountOnFloor,
                      onTap: () {
                        ref
                            .read(feedbackServiceProvider)
                            .fire(const FeedbackSelection());
                        setState(() => _mineOnly = !_mineOnly);
                      },
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _FloorTabs(
                        value: activeFloor,
                        floors: floors,
                        counts: floorCounts,
                        enabled: !isSearching,
                        onChange: (v) => _goFloor(v, floors),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: isSearching
                    ? _TablesGridSlot(
                        query: query,
                        showFloorTags: true,
                        mineOnly: _mineOnly,
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
                          mineOnly: _mineOnly,
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
  final _StatusTag? active;
  final ValueChanged<_StatusTag?> onChange;
  const _LegendStrip({required this.active, required this.onChange});

  // Mine/Other dropped as legend entries — color no longer encodes ownership
  // (the Mine tab covers that), it encodes order progress, so the legend
  // shows the same stages the pills themselves can now display.
  static const _entries = [
    _StatusTag.free,
    _StatusTag.orderOpen,
    _StatusTag.eating,
    _StatusTag.bill,
    _StatusTag.dirty,
    _StatusTag.reserved,
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final tag in _entries)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: GestureDetector(
                onTap: () => onChange(active == tag ? null : tag),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: active == tag
                        ? _ringColor(context, tag).withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: const BorderRadius.all(AppRadii.pill),
                    border: Border.all(
                      color: active == tag
                          ? _ringColor(context, tag)
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
                          color: _ringColor(context, tag),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(_tagLabel(tag),
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

/// Pinned filter next to the floor tabs — tap to show only the tables this
/// operator is currently working, on whichever floor is active. Styled to
/// match _FloorTabs' pills but in the same terra accent used for TableState.mine
/// elsewhere, so it reads as "my tables" rather than another floor choice.
class _MineFilterToggle extends StatelessWidget {
  final bool active;
  final int count;
  final VoidCallback onTap;
  const _MineFilterToggle({
    required this.active,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SpringBuilder(
        to: active ? 1.0 : 0.0,
        spring: RestroSprings.snappy,
        builder: (BuildContext _, double t, Widget? child) {
          return Transform.scale(
            scale: 1 + 0.03 * t,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: Color.lerp(context.palette.surface, AppColors.terra, t),
                borderRadius: const BorderRadius.all(AppRadii.pill),
                border: Border.all(
                  color: t > 0.5 ? Colors.transparent : AppColors.terra,
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
            Icon(Icons.person,
                size: 13, color: active ? Colors.white : AppColors.terra),
            const SizedBox(width: 4),
            Text(
              'Mine',
              style: AppTypography.micro.copyWith(
                color: active ? Colors.white : AppColors.terra,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '$count',
              style: AppTypography.micro.copyWith(
                color: active
                    ? Colors.white.withValues(alpha: 0.7)
                    : AppColors.terra.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
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

/// What a table's pill actually communicates. Free/dirty/reserved map 1:1
/// from TableState; an occupied table (mine or other — ownership doesn't
/// change the color, only whether a name is prefixed) resolves to whichever
/// stage its order is at. Mirrors the desk's `cardStatus()` ladder
/// (floor-plan.component.ts) for the tiers this app has data for. 'Serve' is
/// deliberately not folded in here — it's already shown via the separate
/// pulsing `_ReadyChip`, so repeating it in the pill would just be noise.
/// 'Not Sent' / 'Bill Saved' need pending-item and advance totals the wire
/// payload doesn't carry yet, so they're not replicated.
enum _StatusTag { free, orderOpen, eating, bill, dirty, reserved }

_StatusTag _statusTagFor(
    TableState state, int orderItemCount, int activeBillCount) {
  switch (state) {
    case TableState.free:
      return _StatusTag.free;
    case TableState.dirty:
      return _StatusTag.dirty;
    case TableState.reserved:
      return _StatusTag.reserved;
    case TableState.mine:
    case TableState.other:
      if (orderItemCount == 0) return _StatusTag.orderOpen;
      if (activeBillCount > 0) return _StatusTag.bill;
      return _StatusTag.eating;
  }
}

/// The solid accent for a tag — matches the desk's own palette
/// (is-noorder/is-eating/is-bill in floor-plan.component.scss) so a table
/// reads the same color on both screens. Free/dirty/reserved keep this
/// app's existing soft-pill palette instead — only the three occupied-order
/// stages get the desk's bold solid treatment.
Color _tagAccent(_StatusTag tag) {
  switch (tag) {
    case _StatusTag.orderOpen:
      return const Color(0xFF64748B); // slate — matches desk's is-noorder
    case _StatusTag.eating:
      return AppColors.warn; // matches desk's is-eating (--warning)
    case _StatusTag.bill:
      return AppColors.info; // matches desk's is-bill (--info)
    case _StatusTag.free:
    case _StatusTag.dirty:
    case _StatusTag.reserved:
      return AppColors.terra; // unused — those tags never reach here
  }
}

Color _pillBg(BuildContext context, _StatusTag tag) {
  switch (tag) {
    case _StatusTag.free:
      return context.palette.tableFreeBg;
    case _StatusTag.dirty:
      return context.palette.tableDirtyBg;
    case _StatusTag.reserved:
      return context.palette.tableReservedBg;
    case _StatusTag.orderOpen:
    case _StatusTag.eating:
    case _StatusTag.bill:
      return _tagAccent(tag);
  }
}

Color _pillFg(BuildContext context, _StatusTag tag) {
  switch (tag) {
    case _StatusTag.free:
      return context.palette.tableFreeText;
    case _StatusTag.dirty:
      return context.palette.tableDirtyText;
    case _StatusTag.reserved:
      return context.palette.tableReservedText;
    case _StatusTag.orderOpen:
    case _StatusTag.eating:
    case _StatusTag.bill:
      return Colors.white;
  }
}

/// The visible accent for rings/legend swatches — the solid tags' own fg is
/// plain white (fine on their filled pill, invisible as a ring color), so
/// those three use their accent color directly instead.
Color _ringColor(BuildContext context, _StatusTag tag) {
  switch (tag) {
    case _StatusTag.orderOpen:
    case _StatusTag.eating:
    case _StatusTag.bill:
      return _tagAccent(tag);
    case _StatusTag.free:
    case _StatusTag.dirty:
    case _StatusTag.reserved:
      return _pillFg(context, tag);
  }
}

String _tagLabel(_StatusTag tag) {
  switch (tag) {
    case _StatusTag.free:
      return 'FREE';
    case _StatusTag.orderOpen:
      return 'ORDER OPEN';
    case _StatusTag.eating:
      return 'EATING';
    case _StatusTag.bill:
      return 'BILL';
    case _StatusTag.dirty:
      return 'DIRTY';
    case _StatusTag.reserved:
      return 'RESERVED';
  }
}

String _pillLabel(TableState state, _StatusTag tag, List<String> operatorNames) {
  final label = _tagLabel(tag);
  if (state != TableState.other) return label;
  final first = operatorNames.isNotEmpty ? operatorNames.first.trim() : null;
  if (first == null || first.isEmpty) return label;
  final who = operatorNames.length > 1
      ? '${first.split(' ').first.toUpperCase()} +${operatorNames.length - 1}'
      : first.split(' ').first.toUpperCase();
  return '$who · $label';
}

String? _pillTooltip(TableState state, List<String> operatorNames) {
  if (state != TableState.other || operatorNames.length < 2) return null;
  return '${operatorNames.join(', ')} are working here';
}

Widget _applySpotlight(BuildContext context, Widget card, _StatusTag tag,
    _StatusTag? spotlight) {
  if (spotlight == null) return card;
  if (tag == spotlight) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(AppRadii.lg),
        border: Border.all(color: _ringColor(context, tag), width: 1.5),
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
  final int orderItemCount;
  final int activeBillCount;
  const _StatePill({
    required this.state,
    this.operatorNames = const [],
    this.orderItemCount = 0,
    this.activeBillCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final tag = _statusTagFor(state, orderItemCount, activeBillCount);
    final bg = _pillBg(context, tag);
    final fg = _pillFg(context, tag);
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
          Text(_pillLabel(state, tag, operatorNames),
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
  final _StatusTag? spotlight;
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
    final tag =
        _statusTagFor(table.state, table.orderItemCount, table.activeBillCount);
    final borderColor = _ringColor(context, tag);
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
                    border: Border.all(color: borderColor, width: 1),
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
                border: Border.all(color: borderColor, width: 1),
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
                          _StatePill(
                              state: table.state,
                              operatorNames: table.joinedOperatorNames,
                              orderItemCount: table.orderItemCount,
                              activeBillCount: table.activeBillCount),
                          if (isReady) ...[
                            const SizedBox(height: 4),
                            const AttentionPulse(
                                scale: 1.06, child: _ReadyChip()),
                          ],
                          if (isMine && occupiedSince != null) ...[
                            const SizedBox(height: 4),
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
        _applySpotlight(context, card, tag, spotlight),
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
    this.mineOnly = false,
    required this.showFloorTags,
    required this.builder,
  });

  final String? floor;
  final String query;
  final bool mineOnly;
  final bool showFloorTags;
  final Widget Function(List<RestaurantTable> list,
      {required bool showFloorTags}) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tables = ref.watch(tablesProvider);
    var list = floor == null
        ? tables
            .where((t) =>
                t.id.toLowerCase().contains(query) ||
                t.joinedOperatorNames
                    .any((n) => n.toLowerCase().contains(query)))
            .toList(growable: false)
        : tables.where((t) => t.floor == floor).toList(growable: false);
    if (mineOnly) {
      list = list.where((t) => t.state == TableState.mine).toList(
            growable: false,
          );
    }
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
