// Order Builder — menu + cart for a specific table.
//
// Tap row → ItemDetailSheet for qty + grouped modifiers + note.
// Save & exit keeps the cart in memory until the session ends.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../services/socket_service.dart';
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

  bool _readOnly = false;
  String _holderName = '';
  bool _isSaving = false;
  SocketService? _socketSvc;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _socketSvc = ref.read(socketServiceProvider);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _joinPresence();
        _maybeAutoShowPayment();
      }
    });
  }

  Future<void> _joinPresence() async {
    final socketService = ref.read(socketServiceProvider);
    try {
      final ack = await socketService.emitAck(
        'table:presence:join',
        {'table_id': widget.tableId},
      );
      if (!mounted) return;
      if (ack['kind'] == 'success' && ack['holder'] != null) {
        final holder = ack['holder'];
        if (holder is Map) {
          setState(() {
            _readOnly = true;
            _holderName = holder['operator_name']?.toString() ?? 'Another waiter';
          });
        }
      }
    } catch (_) {
      // Presence is non-critical — silently ignore if server is unreachable.
    }
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

  /// Converts the current cart into a server-side draft order, then navigates away.
  Future<void> _saveAndExitDraft() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    final messenger = ScaffoldMessenger.of(context);
    final socketService = ref.read(socketServiceProvider);
    final notes = ref.read(orderNotesProvider);
    final items = ref.read(cartProvider)
        .map((l) => <String, dynamic>{
              'item_id': l.item.id,
              if (l.variationId != null) 'variation_id': l.variationId,
              if (l.variationName != null) 'variation_name': l.variationName,
              'quantity': l.qty,
              'selected_options':
                  l.selectedOptions.map((o) => o.toJson()).toList(),
              'notes': l.itemNote,
            })
        .toList();

    final response = await socketService.emitAck(
      'order:create',
      <String, dynamic>{
        'table_id': widget.tableId,
        'items': items,
        'notes': notes,
        'order_type': 'dine_in',
      },
    );

    if (!mounted) return;
    setState(() => _isSaving = false);

    if (response['kind'] == 'error') {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              response['message']?.toString() ?? 'Could not save draft — please try again',
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.danger,
          ),
        );
      return;
    }

    ref.read(syncServiceProvider).applyOrderAck(response, includeHistory: true);
    ref.read(cartProvider.notifier).clear();
    ref.read(orderNotesProvider.notifier).state = '';
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('Draft saved — resume anytime'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 3),
        ),
      );
    _leaveOrder();
  }

  void _leaveOrder() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/tables');
    }
  }

  Future<bool> _confirmKotBanner(int itemCount) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.paper,
        title: const Text('Send KOT to kitchen now?', style: AppTypography.title),
        content: Text(
          '$itemCount ${itemCount == 1 ? "item" : "items"} ready to fire. '
          'You can keep editing before sending from the review screen.',
          style: AppTypography.bodyMd,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send',
                style: TextStyle(color: AppColors.terra500)),
          ),
        ],
      ),
    );
    return ok ?? false;
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

  Future<void> _confirmClearCart() async {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.paper,
        title: const Text('Clear cart?', style: AppTypography.title),
        content: Text(
          '${cart.length} ${cart.length == 1 ? "item" : "items"} will be removed.',
          style: AppTypography.bodyMd,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      ref.read(cartProvider.notifier).clear();
    }
  }

  Future<void> _showNotesDialog() async {
    final current = ref.read(orderNotesProvider);
    final controller = TextEditingController(text: current);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.paper,
        title: const Text('Order note', style: AppTypography.title),
        content: TextField(
          controller: controller,
          maxLines: 3,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. Birthday table, extra napkins, VIP…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              ref.read(orderNotesProvider.notifier).state =
                  controller.text.trim();
              Navigator.of(ctx).pop();
            },
            child: const Text('Save',
                style: TextStyle(color: AppColors.terra500)),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final menu = ref.watch(menuProvider);
    final cart = ref.watch(cartProvider);
    final cartTotal = cart.fold(0.0, (s, l) => s + l.lineTotal);
    final orderNotes = ref.watch(orderNotesProvider);

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
                if (_readOnly)
                  Container(
                    width: double.infinity,
                    color: AppColors.readOnlyBannerBg,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.lock_outline,
                            size: 16, color: AppColors.readOnlyBannerText),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$_holderName is working on this table. View-only mode.',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.readOnlyBannerText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
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
                    // More actions — collapsed into menu to reduce header clutter.
                    // Shift, Link, and Packages are less frequent, so they belong in a menu.
                    Builder(builder: (_) {
                      final tables = ref.watch(tablesProvider);
                      final table = tables
                          .where((t) => t.serverId == widget.tableId)
                          .firstOrNull;
                      final isTableAction =
                          table != null &&
                          (table.state == TableState.mine ||
                              table.state == TableState.other);
                      final linkGroups = ref.watch(linkGroupsProvider);
                      final isLinked = linkGroups.values
                          .any((ids) => ids.contains(widget.tableId));
                      final flags = ref.watch(flagsProvider);
                      if (!isTableAction && !flags.packages) {
                        return const SizedBox.shrink();
                      }
                      return PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, color: AppColors.ink70),
                        tooltip: 'More',
                        onSelected: (action) {
                          switch (action) {
                            case 'shift':
                              if (table != null) {
                                TableShiftSheet.show(context, table);
                              }
                              break;
                            case 'link':
                              if (table != null) {
                                TableLinkSheet.show(context, table);
                              }
                              break;
                            case 'packages':
                              PackageSheet.show(context);
                              break;
                            case 'clear_cart':
                              _confirmClearCart();
                              break;
                          }
                        },
                        itemBuilder: (ctx) => [
                          if (isTableAction)
                            PopupMenuItem(
                              value: 'shift',
                              child: Row(
                                children: [
                                  const Icon(Icons.swap_horiz,
                                      size: 18, color: AppColors.ink70),
                                  const SizedBox(width: 8),
                                  Text(
                                    isLinked ? 'Unlink Table' : 'Shift Table',
                                    style: AppTypography.bodyMd,
                                  ),
                                ],
                              ),
                            ),
                          if (isTableAction && !isLinked)
                            PopupMenuItem(
                              value: 'link',
                              child: Row(
                                children: [
                                  const Icon(Icons.link,
                                      size: 18, color: AppColors.ink70),
                                  const SizedBox(width: 8),
                                  Text('Link Table', style: AppTypography.bodyMd),
                                ],
                              ),
                            ),
                          if (flags.packages)
                            PopupMenuItem(
                              value: 'packages',
                              child: Row(
                                children: [
                                  const Icon(Icons.inventory_2_outlined,
                                      size: 18, color: AppColors.ink70),
                                  const SizedBox(width: 8),
                                  Text('Packages', style: AppTypography.bodyMd),
                                ],
                              ),
                            ),
                          if (cart.isNotEmpty) ...[
                            const PopupMenuDivider(),
                            PopupMenuItem(
                              value: 'clear_cart',
                              child: Row(
                                children: [
                                  const Icon(Icons.delete_sweep_outlined,
                                      size: 18, color: AppColors.danger),
                                  const SizedBox(width: 8),
                                  Text('Clear Cart',
                                      style: AppTypography.bodyMd
                                          .copyWith(color: AppColors.danger)),
                                ],
                              ),
                            ),
                          ],
                        ],
                      );
                    }),
                    IconButton(
                      icon: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.ink70,
                              ),
                            )
                          : const Icon(Icons.bookmark_border,
                              color: AppColors.ink70),
                      tooltip: 'Save & exit',
                      onPressed: _isSaving
                          ? null
                          : () async {
                              final cart = ref.read(cartProvider);
                              if (cart.isEmpty) {
                                _leaveOrder();
                                return;
                              }
                              await _saveAndExitDraft();
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
                // Section chips — min 48px touch target per accessibility guidelines.
                  SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
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
                  _RunningOrderCard(
                    order: runningOrder,
                    tableId: widget.tableId,
                    cartIsEmpty: cart.isEmpty,
                    onPrintSummary: () {
                      ref.read(socketServiceProvider).emit(
                        'print:summary',
                        {'order_id': runningOrder.id},
                      );
                    },
                  ),
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
                    height: AppTouchTargets.chip,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.xs),
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
                                          color: AppColors.trendingDot,
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
                    height: AppTouchTargets.chip,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.xs),
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
                  child: Builder(builder: (_) {
                    final isLoading = ref.watch(menuLoadingProvider);
                    if (isLoading) {
                      // Fix #2: Show skeleton loader while menu is loading.
                      return ListView(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        children: [
                          _SkeletonRow(),
                          const SizedBox(height: 24),
                          _SkeletonRow(),
                          const SizedBox(height: 24),
                          _SkeletonRow(),
                          const SizedBox(height: 24),
                          _SkeletonRow(),
                          const SizedBox(height: 24),
                          _SkeletonRow(),
                        ],
                      );
                    }
                    return sections.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.restaurant_menu,
                                      color: AppColors.ink30, size: 48),
                                  const SizedBox(height: 12),
                                  Text(
                                    _query.isNotEmpty
                                        ? 'No results for "$_query"'
                                        : _activeSection != null
                                            ? 'Nothing in "$_activeSection"'
                                            : menu.isEmpty
                                                ? 'Menu not loaded yet'
                                                : 'No items match',
                                    style: AppTypography.title,
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _query.isNotEmpty
                                        ? 'Try searching something else'
                                        : _activeSection != null
                                            ? 'Try a different section'
                                            : 'Menu will appear once synced',
                                    style: AppTypography.caption,
                                  ),
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
                        );
                  }),
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
                            onTap: _readOnly
                                ? null
                                : () async {
                                    final confirmed =
                                        await _confirmKotBanner(itemCount);
                                    if (confirmed) {
                                      if (context.mounted) {
                                        context.push(
                                            '/order/${widget.tableId}/review');
                                      }
                                    }
                                  },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: _readOnly
                                    ? Colors.grey.shade400
                                    : AppColors.amber,
                                borderRadius:
                                    const BorderRadius.all(AppRadii.pill),
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
                if (cart.isNotEmpty) ...[
                  _OrderNoteRow(
                    note: orderNotes,
                    onTap: _showNotesDialog,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Opacity(
                      opacity: _readOnly ? 0.45 : 1.0,
                      child: PredictiveScale(
                        enabled: false,
                        maxScaleBoost: 0.015,
                        child: Hero(
                          tag: HeroTags.cartBar,
                          child: Material(
                            color: Colors.transparent,
                            child: GestureDetector(
                              onTap: _readOnly
                                  ? null
                                  : () => context
                                      .push('/order/${widget.tableId}/review'),
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      AppColors.terra400,
                                      AppColors.terra600
                                    ],
                                  ),
                                  borderRadius:
                                      const BorderRadius.all(AppRadii.md),
                                  boxShadow:
                                      _readOnly ? [] : AppShadows.terraGlow,
                                ),
                                child: Row(
                                  children: [
                                    Text(
                                      _readOnly
                                          ? 'View-only — cannot review'
                                          : 'Review · ${cart.length} ${cart.length == 1 ? "item" : "items"}',
                                      style: AppTypography.bodyMd.copyWith(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600),
                                    ),
                                    const Spacer(),
                                    if (!_readOnly) ...[
                                      KineticRupeeCounter(
                                        amount: cartTotal,
                                        fontSize: 18,
                                        color: Colors.white,
                                      ),
                                      const SizedBox(width: 8),
                                    ],
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
                  ),
                ],
              ],
            ),
          ),
        ),
      ), // LiquidMeshBackground
    );
  }

  @override
  void dispose() {
    _socketSvc?.emit('table:presence:leave', {'table_id': widget.tableId});
    super.dispose();
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

class _OrderNoteRow extends StatelessWidget {
  final String note;
  final VoidCallback onTap;
  const _OrderNoteRow({required this.note, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hasNote = note.isNotEmpty;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: hasNote
              ? AppColors.terra50
              : Colors.white.withValues(alpha: 0.5),
          borderRadius: const BorderRadius.all(AppRadii.sm),
          border: Border.all(
            color: hasNote ? AppColors.terra200 : AppColors.ink10,
          ),
        ),
        child: Row(
          children: [
            Icon(
              hasNote ? Icons.notes : Icons.add_comment_outlined,
              size: 15,
              color: hasNote ? AppColors.terra600 : AppColors.ink30,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hasNote ? note : 'Add order note…',
                style: AppTypography.caption.copyWith(
                  color: hasNote ? AppColors.ink : AppColors.ink30,
                  fontWeight:
                      hasNote ? FontWeight.w600 : FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.edit_outlined,
              size: 13,
              color: AppColors.ink30,
            ),
          ],
        ),
      ),
    );
  }
}

class _RunningOrderCard extends StatelessWidget {
  final ServerOrder order;
  final String tableId;
  final bool cartIsEmpty;
  final VoidCallback onPrintSummary;

  const _RunningOrderCard({
    required this.order,
    required this.tableId,
    required this.cartIsEmpty,
    required this.onPrintSummary,
  });

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
            if (cartIsEmpty) ...[
              const SizedBox(height: 10),
              const Divider(height: 1, thickness: 1, color: AppColors.terra200),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onPrintSummary,
                      icon: const Icon(Icons.print_outlined, size: 14),
                      label: const Text('Print Summary'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.terra600,
                        side: const BorderSide(color: AppColors.terra300),
                        textStyle: AppTypography.caption
                            .copyWith(fontWeight: FontWeight.w600),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => KotHistorySheet.show(context, tableId),
                      icon: const Icon(Icons.history_outlined, size: 14),
                      label: const Text('KOT History'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.ink70,
                        side: const BorderSide(color: AppColors.ink30),
                        textStyle: AppTypography.caption
                            .copyWith(fontWeight: FontWeight.w600),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ],
              ),
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
                            padding: AppChipPadding.statusBadge,
                            decoration: BoxDecoration(
                              color: AppColors.warn.withValues(alpha: AppAlphas.warnOverlay),
                              borderRadius: BorderRadius.all(AppRadii.xs),
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

/// Shimmer skeleton row for menu loading state.
class _SkeletonRow extends StatefulWidget {
  @override
  State<_SkeletonRow> createState() => _SkeletonRowState();
}

class _SkeletonRowState extends State<_SkeletonRow>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _anim = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment(-1.0 + _anim.value, 0),
              end: Alignment(_anim.value, 0),
              colors: const [
                AppColors.ink05,
                AppColors.ink10,
                AppColors.ink05,
              ],
            ),
          ),
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: AppColors.ink10,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 14,
                      width: 120,
                      decoration: BoxDecoration(
                        color: AppColors.ink10,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 10,
                      width: 60,
                      decoration: BoxDecoration(
                        color: AppColors.ink05,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.ink10,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
