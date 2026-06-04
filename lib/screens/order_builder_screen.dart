// Order Builder — menu + cart for a specific table.
//
// Tap row → ItemDetailSheet for qty + grouped modifiers + note.
// Save & exit keeps the cart in memory until the session ends.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../models/server_models.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_mesh_background.dart';
import '../widgets/app_card.dart';
import '../widgets/item_detail_sheet.dart';
import '../widgets/kot_history_sheet.dart';
import '../widgets/package_sheet.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/payment_sheet.dart';
import '../widgets/table_link_sheet.dart';
import '../widgets/table_shift_sheet.dart';

class OrderBuilderScreen extends ConsumerStatefulWidget {
  final String tableId;
  const OrderBuilderScreen({super.key, required this.tableId});
  @override
  ConsumerState<OrderBuilderScreen> createState() => _OrderBuilderScreenState();
}

class _OrderBuilderScreenState extends ConsumerState<OrderBuilderScreen> {
  String _query = '';
  bool _searchOpen = false;
  String? _activeSection;

  @override
  void initState() {
    super.initState();
    // Auto-show payment sheet if the table already has active bills (billed state).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeAutoShowPayment();
    });
  }

  void _maybeAutoShowPayment() {
    final tables = ref.read(tablesProvider);
    final table =
        tables.where((t) => t.serverId == widget.tableId).firstOrNull;
    if (table == null || table.activeBillCount <= 0) return;

    final activeOrders = ref.read(activeOrdersProvider);
    final activeOrderId = table.activeOrderId;
    final orderMap = activeOrders.where((o) {
      final id = o['id']?.toString();
      final tableId = o['table_id']?.toString();
      return (activeOrderId != null && id == activeOrderId) ||
          tableId == widget.tableId;
    }).firstOrNull;
    if (orderMap == null) return;

    final billsRaw = orderMap['bills'];
    if (billsRaw is! List || billsRaw.isEmpty) return;

    final bills = billsRaw
        .whereType<Map>()
        .map((b) => BillInfo.fromMap(Map<String, dynamic>.from(b)))
        .where((b) => b.id.isNotEmpty)
        .toList();
    if (bills.isEmpty) return;

    PaymentSheet.show(context, bills: bills);
  }

  ServerOrder? _runningOrder(List<RestaurantTable> tables) {
    final table = tables.where((t) => t.serverId == widget.tableId).firstOrNull;
    final activeOrderId = table?.activeOrderId;
    final raw = ref.read(activeOrdersProvider).where((order) {
      final id = order['id']?.toString();
      final tableId = order['table_id']?.toString();
      return (activeOrderId != null && id == activeOrderId) ||
          tableId == widget.tableId;
    }).firstOrNull;
    if (raw == null) return null;
    return ServerOrder.fromMap(Map<String, dynamic>.from(raw));
  }

  void _leaveOrder() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/tables');
    }
  }

  Future<bool> _confirmDiscard() async {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.paper,
        title: const Text('Discard draft?', style: AppTypography.title),
        content: Text(
            '${cart.length} unsent ${cart.length == 1 ? "item" : "items"} will be lost. '
            'Send to kitchen first or tap "Save & exit" to keep the draft.',
            style: AppTypography.bodyMd),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final menu = ref.watch(menuProvider);
    final cart = ref.watch(cartProvider);
    final cartTotal = cart.fold(0.0, (s, l) => s + l.lineTotal);

    final sections = <String, List<MenuItem>>{};
    for (final m in menu) {
      if (_query.isNotEmpty &&
          !m.name.toLowerCase().contains(_query.toLowerCase())) {
        continue;
      }
      if (_activeSection != null && m.section != _activeSection) continue;
      sections.putIfAbsent(m.section, () => []).add(m);
    }

    final allSections = menu.map((m) => m.section).toSet().toList();

    // Resolve display name from serverId.
    final tables = ref.watch(tablesProvider);
    final runningOrder = _runningOrder(tables);
    final tableDisplay = tables
            .where((t) => t.serverId == widget.tableId)
            .map((t) => t.id)
            .firstOrNull ??
        widget.tableId;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final ok = await _confirmDiscard();
        if (!context.mounted) return;
        if (ok) {
          ref.read(cartProvider.notifier).clear();
          _leaveOrder();
        }
      },
      child: LiquidMeshBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(
              children: [
                LiquidAppBar(
                  title: 'Table $tableDisplay',
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () async {
                      final ok = await _confirmDiscard();
                      if (!context.mounted) return;
                      if (ok) {
                        ref.read(cartProvider.notifier).clear();
                        _leaveOrder();
                      }
                    },
                  ),
                  actions: [
                    Material(
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.tableMineBg,
                          borderRadius: const BorderRadius.all(AppRadii.xs),
                          border: Border.all(
                              color: AppColors.terra400.withValues(alpha: 0.4)),
                        ),
                        child: Text(tableDisplay,
                            style: AppTypography.caption
                                .copyWith(fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(_searchOpen ? Icons.close : Icons.search,
                          color: AppColors.ink70),
                      onPressed: () => setState(() {
                        _searchOpen = !_searchOpen;
                        if (!_searchOpen) _query = '';
                      }),
                    ),
                    IconButton(
                      icon: const Icon(Icons.receipt_long,
                          color: AppColors.ink70),
                      tooltip: 'KOT History',
                      onPressed: () =>
                          KotHistorySheet.show(context, widget.tableId),
                    ),
                    Builder(builder: (_) {
                      final tables = ref.watch(tablesProvider);
                      final table = tables
                          .where((t) => t.serverId == widget.tableId)
                          .firstOrNull;
                      if (table == null) return const SizedBox.shrink();
                      if (table.state != TableState.mine &&
                          table.state != TableState.other) {
                        return const SizedBox.shrink();
                      }
                      return IconButton(
                        icon: const Icon(Icons.swap_horiz,
                            color: AppColors.ink70),
                        tooltip: 'Shift Table',
                        onPressed: () =>
                            TableShiftSheet.show(context, table),
                      );
                    }),
                    Builder(builder: (_) {
                      final tables = ref.watch(tablesProvider);
                      final table = tables
                          .where((t) => t.serverId == widget.tableId)
                          .firstOrNull;
                      if (table == null) return const SizedBox.shrink();
                      if (table.state != TableState.mine &&
                          table.state != TableState.other) {
                        return const SizedBox.shrink();
                      }
                      final linkGroups = ref.watch(linkGroupsProvider);
                      final isLinked = linkGroups.values
                          .any((ids) => ids.contains(widget.tableId));
                      return IconButton(
                        icon: Icon(
                          isLinked ? Icons.link_off : Icons.link,
                          color: isLinked ? AppColors.info : AppColors.ink70,
                        ),
                        tooltip: isLinked ? 'Unlink Table' : 'Link Table',
                        onPressed: () =>
                            TableLinkSheet.show(context, table),
                      );
                    }),
                    // Packages — feature-flagged.
                    Builder(builder: (_) {
                      final flags = ref.watch(flagsProvider);
                      if (!flags.packages) return const SizedBox.shrink();
                      return IconButton(
                        icon: const Icon(Icons.inventory_2_outlined,
                            color: AppColors.ink70),
                        tooltip: 'Packages',
                        onPressed: () => PackageSheet.show(context),
                      );
                    }),
                    IconButton(
                      icon: const Icon(Icons.bookmark_border,
                          color: AppColors.ink70),
                      tooltip: 'Save & exit',
                      onPressed: () {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(const SnackBar(
                          content: Text('Draft saved — resume from Tables'),
                          backgroundColor: AppColors.ink,
                        ));
                        _leaveOrder();
                      },
                    ),
                  ],
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
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Search menu…',
                          icon: Icon(Icons.search,
                              color: AppColors.ink50, size: 18),
                        ),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                  ),
                // Section chips.
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    children: [
                      _SectionChip(
                        label: 'All',
                        selected: _activeSection == null,
                        onTap: () {
                          ref
                              .read(feedbackServiceProvider)
                              .fire(const FeedbackSelection());
                          setState(() => _activeSection = null);
                        },
                      ),
                      const SizedBox(width: 8),
                      for (final s in allSections) ...[
                        _SectionChip(
                          label: s,
                          selected: _activeSection == s,
                          onTap: () {
                            ref
                                .read(feedbackServiceProvider)
                                .fire(const FeedbackSelection());
                            setState(() => _activeSection = s);
                          },
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
                // Fast-add bar — pinned + auto trending items from server.
                if (runningOrder != null && runningOrder.itemCount > 0)
                  _RunningOrderCard(order: runningOrder),
                Builder(builder: (context) {
                  final pinned = ref.watch(fastAddPinnedProvider);
                  final auto = ref.watch(fastAddAutoProvider);
                  // Merge: pinned first, then auto (exclude duplicates)
                  final pinnedIds = pinned.map((m) => m.id).toSet();
                  final merged = [
                    ...pinned,
                    ...auto.where((m) => !pinnedIds.contains(m.id)),
                  ];
                  if (merged.isEmpty) return const SizedBox.shrink();
                  return SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          alignment: Alignment.center,
                          child: Text('⚡ FAST ADD',
                              style: AppTypography.micro.copyWith(
                                  color: AppColors.ink50, letterSpacing: 1.0)),
                        ),
                        for (final item in merged)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: GestureDetector(
                              onTap: () {
                                ref
                                    .read(feedbackServiceProvider)
                                    .fire(const FeedbackLight());
                                ref.read(cartProvider.notifier).add(item);
                                ref
                                    .read(recentItemsProvider.notifier)
                                    .track(item);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: pinnedIds.contains(item.id)
                                      ? AppColors.terra50
                                      : Colors.white.withValues(alpha: 0.6),
                                  borderRadius:
                                      const BorderRadius.all(AppRadii.pill),
                                  border: Border.all(
                                    color: pinnedIds.contains(item.id)
                                        ? AppColors.terra200
                                        : AppColors.ink10,
                                    style: pinnedIds.contains(item.id)
                                        ? BorderStyle.solid
                                        : BorderStyle.none,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (!pinnedIds.contains(item.id))
                                      Container(
                                        width: 6,
                                        height: 6,
                                        margin: const EdgeInsets.only(right: 4),
                                        decoration: const BoxDecoration(
                                          color: Color(0xFFFF6B35),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: item.isVeg
                                            ? AppColors.success
                                            : AppColors.danger,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(item.name,
                                        style: AppTypography.caption.copyWith(
                                            fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                }),
                // Recent items bar — last 8 items for quick re-add.
                Builder(builder: (context) {
                  final recent = ref.watch(recentItemsProvider);
                  if (recent.isEmpty) return const SizedBox.shrink();
                  return SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          alignment: Alignment.center,
                          child: Text('RECENT',
                              style: AppTypography.micro.copyWith(
                                  color: AppColors.ink50, letterSpacing: 1.0)),
                        ),
                        for (final item in recent)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: GestureDetector(
                              onTap: () {
                                ref
                                    .read(feedbackServiceProvider)
                                    .fire(const FeedbackLight());
                                ref.read(cartProvider.notifier).add(item);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: AppColors.terra50,
                                  borderRadius:
                                      const BorderRadius.all(AppRadii.pill),
                                  border: Border.all(color: AppColors.terra200),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: item.isVeg
                                            ? AppColors.success
                                            : AppColors.danger,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(item.name,
                                        style: AppTypography.caption.copyWith(
                                            fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                }),
                Expanded(
                  child: sections.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.restaurant_menu,
                                    color: AppColors.ink30, size: 48),
                                SizedBox(height: 12),
                                Text('No items match',
                                    style: AppTypography.title),
                                SizedBox(height: 4),
                                Text('Try a different search',
                                    style: AppTypography.caption),
                              ],
                            ),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.all(AppSpacing.lg),
                          children: [
                            for (final entry in sections.entries) ...[
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  entry.key.toUpperCase(),
                                  style: AppTypography.micro
                                      .copyWith(letterSpacing: 1.2),
                                ),
                              ),
                              AppCard(
                                padding: EdgeInsets.zero,
                                child: Column(
                                  children: [
                                    for (int i = 0;
                                        i < entry.value.length;
                                        i++) ...[
                                      _ItemRow(
                                        item: entry.value[i],
                                        onAdd: () {
                                          ref
                                              .read(feedbackServiceProvider)
                                              .fire(const FeedbackLight());
                                          ref
                                              .read(cartProvider.notifier)
                                              .add(entry.value[i]);
                                          ref
                                              .read(
                                                  recentItemsProvider.notifier)
                                              .track(entry.value[i]);
                                        },
                                        onTap: () => ItemDetailSheet.show(
                                            context, entry.value[i]),
                                      ),
                                      if (i < entry.value.length - 1)
                                        const Divider(
                                            height: 1, color: AppColors.ink10),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 80),
                          ],
                        ),
                ),
                // Auto-KOT hint — shows when cart reaches threshold.
                Builder(builder: (_) {
                  final flags = ref.watch(flagsProvider);
                  final itemCount = cart.fold<int>(0, (s, l) => s + l.qty);
                  if (!flags.autoKot ||
                      itemCount < flags.autoKotThreshold ||
                      cart.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.amber.withValues(alpha: 0.12),
                        borderRadius: const BorderRadius.all(AppRadii.sm),
                        border: Border.all(
                            color: AppColors.amber.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.auto_awesome,
                              color: AppColors.amber, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '$itemCount items ready — send KOT now?',
                              style: AppTypography.caption.copyWith(
                                  color: AppColors.ink,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                          GestureDetector(
                            onTap: () =>
                                context.push('/order/${widget.tableId}/review'),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: const BoxDecoration(
                                color: AppColors.amber,
                                borderRadius: BorderRadius.all(AppRadii.pill),
                              ),
                              child: Text('Send',
                                  style: AppTypography.caption.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                if (cart.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: PredictiveScale(
                      enabled: false, // Behind flag — enable when ready
                      maxScaleBoost: 0.015,
                      child: Hero(
                        tag: HeroTags.cartBar,
                        child: Material(
                          color: Colors.transparent,
                          child: GestureDetector(
                            onTap: () =>
                                context.push('/order/${widget.tableId}/review'),
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    AppColors.terra400,
                                    AppColors.terra600
                                  ],
                                ),
                                borderRadius: BorderRadius.all(AppRadii.md),
                                boxShadow: AppShadows.terraGlow,
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    'Review · ${cart.length} ${cart.length == 1 ? "item" : "items"}',
                                    style: AppTypography.bodyMd.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  const Spacer(),
                                  KineticRupeeCounter(
                                    amount: cartTotal,
                                    fontSize: 18,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 8),
                                  const Icon(Icons.arrow_forward,
                                      color: Colors.white),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ), // LiquidMeshBackground
    );
  }
}

class _SectionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SectionChip(
      {required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SpringBuilder(
        to: selected ? 1.0 : 0.0,
        spring: RestroSprings.snappy,
        builder: (BuildContext _, double t, Widget? child) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Color.lerp(
                  Colors.white.withValues(alpha: 0.6), AppColors.ink, t),
              borderRadius: const BorderRadius.all(AppRadii.pill),
              border: Border.all(
                  color: Color.lerp(AppColors.ink10, AppColors.ink, t) ??
                      AppColors.ink10),
            ),
            child: child,
          );
        },
        child: Center(
          child: Text(label,
              style: AppTypography.caption.copyWith(
                color: selected ? Colors.white : AppColors.ink,
                fontWeight: FontWeight.w600,
              )),
        ),
      ),
    );
  }
}

class _RunningOrderCard extends StatelessWidget {
  final ServerOrder order;
  const _RunningOrderCard({required this.order});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: AppCard(
        background: AppColors.paper.withValues(alpha: 0.92),
        border: Border.all(color: AppColors.terra200),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.restaurant_menu,
                    size: 16, color: AppColors.terra600),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Running order',
                    style: AppTypography.bodyMd
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  formatRupeesCompact(order.total),
                  style: AppTypography.title,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (order.items.isEmpty)
              Text(
                '${order.itemCount} ${order.itemCount == 1 ? "item" : "items"} already sent',
                style: AppTypography.caption.copyWith(
                  color: AppColors.ink70,
                  fontWeight: FontWeight.w600,
                ),
              )
            else ...[
              for (final item in order.items.take(4))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Text('${item.quantity}x',
                          style: AppTypography.caption
                              .copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item.itemName,
                          style: AppTypography.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        formatRupeesCompact(item.totalPrice),
                        style: AppTypography.caption,
                      ),
                    ],
                  ),
                ),
              if (order.items.length > 4) ...[
                const SizedBox(height: 6),
                Text(
                  '+${order.items.length - 4} more items',
                  style: AppTypography.micro,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  final MenuItem item;
  final VoidCallback onAdd;
  final VoidCallback onTap;
  const _ItemRow(
      {required this.item, required this.onAdd, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final unavailable = !item.available;
    return InkWell(
      onTap: unavailable ? null : onTap,
      child: Opacity(
        opacity: unavailable ? 0.45 : 1,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              // Veg/non-veg indicator (FSSAI dot).
              _VegMark(isVeg: item.isVeg),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(item.name, style: AppTypography.bodyMd),
                        ),
                        if (unavailable) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.warn.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('86',
                                style: AppTypography.micro.copyWith(
                                  color: AppColors.warn,
                                  letterSpacing: 0.6,
                                )),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(formatRupeesCompact(item.price),
                        style: AppTypography.caption),
                  ],
                ),
              ),
              if (!unavailable)
                GestureDetector(
                  onTap: onAdd,
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: AppColors.ink,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(Icons.add,
                            color: Colors.white, size: 18),
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

/// FSSAI veg/non-veg marker — green square dot for veg, red for non-veg.
class _VegMark extends StatelessWidget {
  final bool isVeg;
  const _VegMark({required this.isVeg});
  @override
  Widget build(BuildContext context) {
    final color = isVeg ? AppColors.success : AppColors.danger;
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Center(
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
