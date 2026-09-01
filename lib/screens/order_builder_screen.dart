import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/menu_selectors.dart';
import '../data/money.dart';
import '../data/providers.dart';
import '../data/currency.dart';
import '../services/socket_service.dart';
import '../models/server_models.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/app_surface.dart';
import '../widgets/dynamic_toast.dart';
import '../widgets/item_detail_sheet.dart';
import '../widgets/kot_history_sheet.dart';
import '../widgets/quick_action_tile.dart';
import '../widgets/package_sheet.dart';
import '../widgets/table_link_sheet.dart';
import '../widgets/table_shift_sheet.dart';

class OrderBuilderScreen extends ConsumerStatefulWidget {
  final String tableId;

  final bool isRoom;
  const OrderBuilderScreen(
      {super.key, required this.tableId, this.isRoom = false});
  @override
  ConsumerState<OrderBuilderScreen> createState() => _OrderBuilderScreenState();
}

class _OrderBuilderScreenState extends ConsumerState<OrderBuilderScreen> {
  String _query = '';
  Timer? _searchDebounce;
  bool _searchOpen = false;

  final ScrollController _menuScroll = ScrollController();
  final ValueNotifier<double> _scrollCollapse = ValueNotifier<double>(0);
  String? _activeSection;

  bool _readOnly = false;
  String _holderName = '';
  bool _isSaving = false;
  bool _tableMembershipInFlight = false;
  SocketService? _socketSvc;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _socketSvc = ref.read(socketServiceProvider);
  }

  void _onMenuScroll() {
    final double p = (_menuScroll.offset / 72).clamp(0.0, 1.0);
    if ((p - _scrollCollapse.value).abs() > 0.003) {
      _scrollCollapse.value = p;
    }
  }

  void _resetMenuScroll() {
    if (_menuScroll.hasClients) _menuScroll.jumpTo(0);
    _scrollCollapse.value = 0;
  }

  @override
  void initState() {
    super.initState();
    _menuScroll.addListener(_onMenuScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _joinPresence();
      }
    });
  }

  Future<void> _joinPresence() async {
    if (widget.isRoom) return;
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
            _holderName =
                holder['operator_name']?.toString() ?? 'Another waiter';
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _handleTableMembershipTap({
    required String event,
    required String tableServerId,
    required String errorFallback,
  }) async {
    if (_tableMembershipInFlight) return;
    setState(() => _tableMembershipInFlight = true);
    try {
      final response = await ref
          .read(socketServiceProvider)
          .emitAck(event, {'table_id': tableServerId});
      if (response['kind'] == 'error') {
        if (!mounted) return;
        DynamicToast.show(context,
            message: response['message']?.toString() ?? errorFallback,
            kind: ToastKind.error);
        return;
      }
      ref.read(syncServiceProvider).applyTableAck(response);
    } finally {
      if (mounted) setState(() => _tableMembershipInFlight = false);
    }
  }

  String? _activeOrderIdForSlot() {
    if (widget.isRoom) {
      final room = ref
          .read(roomsProvider)
          .where((r) => r.serverId == widget.tableId)
          .firstOrNull;
      return room?.activeOrderId;
    }
    final table = ref
        .read(tablesProvider)
        .where((t) => t.serverId == widget.tableId)
        .firstOrNull;
    return table?.activeOrderId;
  }

  ServerOrder? _runningOrder() {
    final activeOrderId = _activeOrderIdForSlot();

    return ref.read(activeOrdersProvider).where((order) {
      final slotId = widget.isRoom ? order.roomId : order.tableId;
      return (activeOrderId != null && order.id == activeOrderId) ||
          slotId == widget.tableId;
    }).firstOrNull;
  }

  Future<void> _saveAndExitDraft() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    final socketService = ref.read(socketServiceProvider);
    final notes = ref.read(orderNotesProvider);
    final items = ref
        .read(cartProvider)
        .map((l) => <String, dynamic>{
              'item_id': l.item.id,
              if (l.variationId != null) 'variation_id': l.variationId,
              'quantity': l.qty,
              'selected_options':
                  l.selectedOptions.map((o) => o.toJson()).toList(),
              if (l.selectedAddons.isNotEmpty)
                'selected_addons':
                    l.selectedAddons.map((g) => g.toJson()).toList(),
              if (l.weight != null) 'weight': l.weight,
              'notes': l.itemNote,
            })
        .toList();

    final response = await socketService.emitAck(
      'order:create',
      <String, dynamic>{
        if (widget.isRoom)
          'room_id': widget.tableId
        else
          'table_id': widget.tableId,
        'items': items,
        'notes': notes,
        'order_type': widget.isRoom ? 'room' : 'dine_in',
      },
    );

    if (!mounted) return;
    setState(() => _isSaving = false);

    if (response['kind'] == 'error') {
      DynamicToast.show(context,
          message: response['message']?.toString() ??
              'Could not save draft — please try again',
          kind: ToastKind.error);
      return;
    }

    ref.read(syncServiceProvider).applyOrderAck(response, includeHistory: true);
    ref.read(cartProvider.notifier).clear();
    ref.read(orderNotesProvider.notifier).state = '';
    DynamicToast.show(context,
        message: 'Draft saved — resume anytime',
        kind: ToastKind.success,
        duration: const Duration(seconds: 3));
    _leaveOrder();
  }

  void _leaveOrder() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/tables');
    }
  }

  String get _reviewRoute => widget.isRoom
      ? '/order/room/${widget.tableId}/review'
      : '/order/${widget.tableId}/review';

  Future<bool> _confirmDiscard() async {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: context.palette.surface,
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
        backgroundColor: context.palette.surface,
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
            child:
                const Text('Clear', style: TextStyle(color: AppColors.danger)),
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
        backgroundColor: ctx.palette.surface,
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
            child:
                const Text('Save', style: TextStyle(color: AppColors.terra500)),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  void _addOrConfigure(BuildContext context, MenuItem item,
      {bool track = true}) {
    if (_readOnly) {
      DynamicToast.show(context,
          message:
              'Another waiter is editing this table — view only right now.',
          kind: ToastKind.warning,
          duration: const Duration(seconds: 2));
      return;
    }
    final variationsEnabled = ref.read(flagsProvider).itemVariations;
    if (_itemNeedsSheet(item, variationsEnabled: variationsEnabled)) {
      ItemDetailSheet.show(context, item);
      return;
    }
    ref.read(feedbackServiceProvider).fire(const FeedbackLight());

    ref.read(cartProvider.notifier).addSimple(item);
    if (track) ref.read(recentItemsProvider.notifier).track(item);
  }

  void _showItemQuickMenu(BuildContext context, MenuItem item) {
    ref.read(feedbackServiceProvider).fire(const FeedbackMedium());
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: AppRadii.lg),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.name, style: AppTypography.headline),
            Text(formatRupeesCompact(item.price), style: AppTypography.caption),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: QuickActionTile(
                    icon: Icons.add,
                    label: 'Add',
                    onTap: () {
                      Navigator.of(context).pop();
                      _addOrConfigure(context, item);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: QuickActionTile(
                    icon: Icons.info_outline,
                    label: 'Details',
                    onTap: () {
                      Navigator.of(context).pop();
                      ItemDetailSheet.show(context, item);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: QuickActionTile(
                    icon: Icons.edit_note,
                    label: 'Add Note',
                    onTap: () {
                      Navigator.of(context).pop();
                      ItemDetailSheet.show(context, item, autoFocusNote: true);
                    },
                  ),
                ),
              ],
            ),
            SizedBox(height: context.sheetBottomInset),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sortedBySection = ref.watch(sortedMenuBySectionProvider);
    final allSections = ref.watch(orderedCategoryNamesProvider);

    final menu = ref.watch(menuProvider);

    final cartIsEmpty = ref.watch(cartProvider.select((c) => c.isEmpty));
    final orderNotes = ref.watch(orderNotesProvider);
    final flags = ref.watch(flagsProvider);

    final query = _query.trim().toLowerCase();
    final sections = <String, List<MenuItem>>{};
    for (final entry in sortedBySection.entries) {
      if (_activeSection != null && entry.key != _activeSection) continue;
      final items = query.isEmpty
          ? entry.value
          : entry.value
              .where((m) => m.name.toLowerCase().contains(query))
              .toList(growable: false);
      if (items.isNotEmpty) sections[entry.key] = items;
    }

    final table = widget.isRoom
        ? null
        : ref.watch(tablesProvider.select(
            (l) => l.where((t) => t.serverId == widget.tableId).firstOrNull));
    final room = widget.isRoom
        ? ref.watch(roomsProvider.select(
            (l) => l.where((r) => r.serverId == widget.tableId).firstOrNull))
        : null;
    final runningOrder = _runningOrder();
    final tableDisplay = widget.isRoom
        ? (room?.id ?? widget.tableId)
        : (table?.id ?? widget.tableId);
    final opName = ref.watch(operatorProvider)?.name;
    final kotCount = table?.kotCount ?? 0;

    final String subLine;
    if (widget.isRoom) {
      subLine = (room?.guestName != null && room!.guestName!.isNotEmpty)
          ? 'Serving · ${room.guestName}'
          : 'New order';
    } else if (table != null) {
      final guests =
          table.coverCount != null ? ' · ${table.coverCount} guests' : '';
      switch (table.state) {
        case TableState.mine:
          final myFirstName = (opName ?? 'You').split(' ').first;
          final otherNames = table.joinedOperatorNames
              .where((n) => n.split(' ').first != myFirstName)
              .toList();
          final names = [myFirstName, ...otherNames];
          subLine = 'Serving · ${names.join(', ')}$guests';
        case TableState.other:
          final names = table.joinedOperatorNames.isNotEmpty
              ? table.joinedOperatorNames.join(', ')
              : 'another waiter';
          subLine = 'Serving · $names$guests';
        case TableState.reserved:
          subLine = table.note ?? 'Reserved';
        default:
          subLine = 'New order';
      }
    } else {
      subLine = 'New order';
    }

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
      child: ColoredBox(
        color: context.palette.paper,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: LayoutBuilder(builder: (context, box) {
              final bool wide = box.isTwoPane;
              final Widget mainColumn = Column(
                children: [
                  if (_readOnly)
                    Container(
                      width: double.infinity,
                      color: context.palette.readOnlyBannerBg,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          Icon(Icons.lock_outline,
                              size: 16,
                              color: context.palette.readOnlyBannerText),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '$_holderName is editing this table — view only. Try again shortly.',
                              style: TextStyle(
                                fontSize: 12,
                                color: context.palette.readOnlyBannerText,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Pressable(
                          semanticLabel: 'Back, discarding this order',
                          onTap: () async {
                            final ok = await _confirmDiscard();
                            if (!context.mounted) return;
                            if (ok) {
                              ref.read(cartProvider.notifier).clear();
                              _leaveOrder();
                            }
                          },
                          child: SizedBox(
                            width: AppTouchTargets.minimum,
                            height: AppTouchTargets.minimum,
                            child: Center(
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: context.palette.surface,
                                  borderRadius:
                                      const BorderRadius.all(AppRadii.sm),
                                  border: Border.all(
                                      color: context.palette.hairline),
                                ),
                                alignment: Alignment.center,
                                child: Icon(Icons.arrow_back,
                                    size: 18, color: context.palette.ink70),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.isRoom
                                    ? 'Room $tableDisplay'
                                    : 'Table $tableDisplay',
                                style: AppTypography.tableName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                subLine,
                                style: AppTypography.caption
                                    .copyWith(color: context.palette.ink50),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (table != null &&
                                  table.state == TableState.other &&
                                  !widget.isRoom)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: GestureDetector(
                                    onTap: () => _handleTableMembershipTap(
                                      event: 'table:join',
                                      tableServerId: table.serverId,
                                      errorFallback: 'Could not join table',
                                    ),
                                    child: Opacity(
                                      opacity:
                                          _tableMembershipInFlight ? 0.5 : 1.0,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: AppColors.terra
                                              .withValues(alpha: 0.12),
                                          borderRadius: const BorderRadius.all(
                                              AppRadii.pill),
                                        ),
                                        child: Text('Join to help',
                                            style: AppTypography.caption
                                                .copyWith(
                                                    color: AppColors.terra,
                                                    fontWeight:
                                                        FontWeight.w700)),
                                      ),
                                    ),
                                  ),
                                ),
                              if (table != null &&
                                  table.state == TableState.mine &&
                                  table.joinedOperatorIds.length > 1 &&
                                  !widget.isRoom)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: GestureDetector(
                                    onTap: () => _handleTableMembershipTap(
                                      event: 'table:leave',
                                      tableServerId: table.serverId,
                                      errorFallback: 'Could not leave table',
                                    ),
                                    child: Opacity(
                                      opacity:
                                          _tableMembershipInFlight ? 0.5 : 1.0,
                                      child: Text('Leave this table',
                                          style: AppTypography.caption.copyWith(
                                              color: context.palette.ink50,
                                              decoration:
                                                  TextDecoration.underline)),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: _searchOpen ? 'Close search' : 'Search menu',
                          icon: Icon(_searchOpen ? Icons.close : Icons.search,
                              color: context.palette.ink70),
                          onPressed: () {
                            ref
                                .read(feedbackServiceProvider)
                                .fire(const FeedbackSelection());
                            setState(() {
                              _searchOpen = !_searchOpen;
                              if (!_searchOpen) _query = '';
                            });
                            _resetMenuScroll();
                          },
                        ),
                        IconButton(
                          icon: _isSaving
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: context.palette.ink70,
                                  ),
                                )
                              : Icon(Icons.bookmark_border,
                                  color: context.palette.ink70),
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
                        Builder(builder: (_) {
                          final isTableAction = table != null &&
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
                            icon: Icon(Icons.more_vert,
                                color: context.palette.ink70),
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
                              if (isTableAction && flags.tableShift)
                                PopupMenuItem(
                                  value: 'shift',
                                  child: Row(
                                    children: [
                                      Icon(Icons.swap_horiz,
                                          size: 18, color: ctx.palette.ink70),
                                      const SizedBox(width: 8),
                                      Text(
                                        isLinked
                                            ? 'Unlink Table'
                                            : 'Shift Table',
                                        style: AppTypography.bodyMd,
                                      ),
                                    ],
                                  ),
                                ),
                              if (isTableAction && !isLinked && flags.tableLink)
                                PopupMenuItem(
                                  value: 'link',
                                  child: Row(
                                    children: [
                                      Icon(Icons.link,
                                          size: 18, color: ctx.palette.ink70),
                                      const SizedBox(width: 8),
                                      const Text('Link Table',
                                          style: AppTypography.bodyMd),
                                    ],
                                  ),
                                ),
                              if (flags.packages)
                                PopupMenuItem(
                                  value: 'packages',
                                  child: Row(
                                    children: [
                                      Icon(Icons.inventory_2_outlined,
                                          size: 18, color: ctx.palette.ink70),
                                      const SizedBox(width: 8),
                                      const Text('Packages',
                                          style: AppTypography.bodyMd),
                                    ],
                                  ),
                                ),
                              if (!cartIsEmpty) ...[
                                const PopupMenuDivider(),
                                PopupMenuItem(
                                  value: 'clear_cart',
                                  child: Row(
                                    children: [
                                      const Icon(Icons.delete_sweep_outlined,
                                          size: 18, color: AppColors.danger),
                                      const SizedBox(width: 8),
                                      Text('Clear Cart',
                                          style: AppTypography.bodyMd.copyWith(
                                              color: AppColors.danger)),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          );
                        }),
                        const SizedBox(width: 4),
                        Pressable(
                          onTap: () =>
                              KotHistorySheet.show(context, widget.tableId),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: context.palette.surface,
                              borderRadius: const BorderRadius.all(AppRadii.sm),
                              border:
                                  Border.all(color: context.palette.hairline),
                            ),
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Center(
                                  child: Icon(Icons.receipt_long,
                                      size: 18, color: context.palette.ink70),
                                ),
                                if (kotCount > 0)
                                  Positioned(
                                    top: -4,
                                    right: -4,
                                    child: BoingOnChange(
                                      trigger: kotCount,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 1),
                                        decoration: const BoxDecoration(
                                          color: AppColors.terra,
                                          borderRadius:
                                              BorderRadius.all(AppRadii.pill),
                                        ),
                                        child: Text(
                                          '$kotCount',
                                          style: AppTypography.pill.copyWith(
                                            color: Colors.white,
                                            fontSize: 9,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_searchOpen)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: AppSurface(
                        shadow: const [],
                        borderRadius: const BorderRadius.all(AppRadii.sm),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: TextField(
                          autofocus: true,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: 'Search menu…',
                            icon: Icon(Icons.search,
                                color: context.palette.ink50, size: 18),
                          ),
                          onChanged: (v) {
                            _searchDebounce?.cancel();
                            _searchDebounce = Timer(
                              const Duration(milliseconds: 150),
                              () {
                                if (mounted) setState(() => _query = v);
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  _ZoneReveal(
                    visible: !_searchOpen,
                    child: SizedBox(
                      height: 44,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
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
                  ),
                  _ZoneReveal(
                    visible: !wide && !_searchOpen && cartIsEmpty,
                    scroll: _scrollCollapse,
                    child: (runningOrder != null && runningOrder.itemCount > 0)
                        ? _RunningOrderCard(
                            order: runningOrder,
                            tableId: widget.tableId,
                            cartIsEmpty: cartIsEmpty,
                            showPrintSummary: flags.printSummary,
                            onPrintSummary: () {
                              ref.read(socketServiceProvider).emit(
                                'print:summary',
                                {'order_id': runningOrder.id},
                              );
                            },
                          )
                        : const SizedBox.shrink(),
                  ),
                  _ZoneReveal(
                    visible: !_searchOpen,
                    scroll: _scrollCollapse,
                    child: Builder(builder: (context) {
                      final pinned = ref.watch(fastAddPinnedProvider);
                      final auto = ref.watch(fastAddAutoProvider);
                      final recent = ref.watch(recentItemsProvider);

                      final pinnedIds = pinned.map((m) => m.id).toSet();
                      final seen = <String>{...pinnedIds};
                      final trending = <MenuItem>[
                        for (final m in auto)
                          if (seen.add(m.id)) m,
                      ];
                      final trendingIds = trending.map((m) => m.id).toSet();
                      final merged = <MenuItem>[
                        ...pinned,
                        ...trending,
                        for (final m in recent)
                          if (seen.add(m.id)) m,
                      ];
                      if (merged.isEmpty) merged.addAll(menu.take(6));
                      if (merged.isEmpty) return const SizedBox.shrink();
                      final chips = merged.take(12).toList();
                      return SizedBox(
                        height: AppTouchTargets.chip,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.fromLTRB(AppSpacing.lg,
                              AppSpacing.xs, AppSpacing.lg, AppSpacing.xs),
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 6),
                              alignment: Alignment.center,
                              child: Text('⚡ QUICK ADD',
                                  style: AppTypography.micro.copyWith(
                                      color: context.palette.ink50,
                                      letterSpacing: 1.0)),
                            ),
                            for (final item in chips)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Builder(builder: (chipContext) {
                                  return GestureDetector(
                                    onTap: () {
                                      CartFlight.fly(chipContext);
                                      _addOrConfigure(context, item);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: trendingIds.contains(item.id)
                                            ? context.palette.surface
                                            : context.palette.terraSoft,
                                        borderRadius: const BorderRadius.all(
                                            AppRadii.pill),
                                        border: Border.all(
                                          color: trendingIds.contains(item.id)
                                              ? context.palette.hairline
                                              : AppColors.terra,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (trendingIds.contains(item.id))
                                            Container(
                                              width: 6,
                                              height: 6,
                                              margin: const EdgeInsets.only(
                                                  right: 4),
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
                                              style: AppTypography.caption
                                                  .copyWith(
                                                      fontWeight:
                                                          FontWeight.w600)),
                                        ],
                                      ),
                                    ),
                                  );
                                }),
                              ),
                          ],
                        ),
                      );
                    }),
                  ),
                  Expanded(
                    child: Builder(builder: (_) {
                      final isLoading = ref.watch(menuLoadingProvider);
                      if (isLoading) {
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
                                    Icon(Icons.restaurant_menu,
                                        color: context.palette.ink30, size: 48),
                                    const SizedBox(height: 12),
                                    Text(
                                      _query.isNotEmpty
                                          ? 'No results for "$_query"'
                                          : _activeSection != null
                                              ? 'Nothing in "$_activeSection"'
                                              : sortedBySection.isEmpty
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
                          : ScrollVelocityLean(
                              controller: _menuScroll,
                              child: ListView(
                                scrollCacheExtent: ScrollCacheExtent.pixels(
                                    AppPerf.listCacheExtentFor(context)),
                                controller: _menuScroll,
                                padding: const EdgeInsets.fromLTRB(
                                    AppSpacing.lg,
                                    AppSpacing.sm,
                                    AppSpacing.lg,
                                    AppSpacing.lg),
                                children: [
                                  for (final entry in sections.entries) ...[
                                    Padding(
                                      padding:
                                          const EdgeInsets.fromLTRB(0, 2, 0, 6),
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
                                            Builder(builder: (_) {
                                              final menuItem = entry.value[i];
                                              return _SwipeToAddWrapper(
                                                readOnly: _readOnly,
                                                onDragTick: () => ref
                                                    .read(
                                                        feedbackServiceProvider)
                                                    .fire(
                                                        const FeedbackDragTick()),
                                                onSwipeConfirm: () => ref
                                                    .read(
                                                        feedbackServiceProvider)
                                                    .fire(
                                                        const FeedbackMedium()),
                                                onAdd: () => _addOrConfigure(
                                                    context, menuItem),
                                                child: _ItemRow(
                                                  item: menuItem,
                                                  onAdd: () => _addOrConfigure(
                                                      context, menuItem),
                                                  onDecrement: () => ref
                                                      .read(
                                                          cartProvider.notifier)
                                                      .decrementPlainLine(
                                                          menuItem.id),
                                                  onTap: () =>
                                                      ItemDetailSheet.show(
                                                          context, menuItem),
                                                  onLongPress: _readOnly
                                                      ? null
                                                      : () =>
                                                          _showItemQuickMenu(
                                                              context,
                                                              menuItem),
                                                ),
                                              );
                                            }),
                                            if (i < entry.value.length - 1)
                                              Divider(
                                                  height: 1,
                                                  color: context.palette.ink10),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 32),
                                ],
                              ),
                            );
                    }),
                  ),
                  Consumer(builder: (context, ref, _) {
                    final flags = ref.watch(flagsProvider);
                    final (itemCount, isEmpty) = ref.watch(
                      cartProvider.select(
                        (c) => (c.fold<int>(0, (s, l) => s + l.qty), c.isEmpty),
                      ),
                    );
                    if (!flags.autoKot ||
                        itemCount < flags.autoKotThreshold ||
                        isEmpty) {
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
                                    color: context.palette.ink,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                            GestureDetector(
                              onTap: _readOnly
                                  ? null
                                  : () => context.push(
                                        _reviewRoute,
                                        extra: true,
                                      ),
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
                  Consumer(builder: (context, ref, _) {
                    final (count, total) = ref.watch(
                      cartProvider.select(
                        (c) => (
                          c.length,
                          c.map((l) => l.lineTotal).sumMoney(),
                        ),
                      ),
                    );
                    final hasRunning =
                        runningOrder != null && runningOrder.itemCount > 0;
                    if (wide) return const SizedBox.shrink();
                    if (count == 0 && !hasRunning) {
                      return const SizedBox.shrink();
                    }

                    final String label;
                    final String actionLabel;
                    final Money barTotal;
                    final VoidCallback? onBarTap;

                    final VoidCallback? onSendKotTap;
                    if (count > 0) {
                      label = _readOnly
                          ? 'View-only — cannot review'
                          : '$count ${count == 1 ? "item" : "items"}';
                      actionLabel = 'Review';
                      barTotal = total;
                      onBarTap =
                          _readOnly ? null : () => context.push(_reviewRoute);
                      onSendKotTap = _readOnly
                          ? null
                          : () => context.push(_reviewRoute, extra: true);
                    } else {
                      label = 'Running';
                      actionLabel = 'View bill';
                      barTotal = runningOrder!.total;
                      onBarTap =
                          () => context.push('/history/${runningOrder.id}');
                      onSendKotTap = null;
                    }

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (count > 0)
                          _OrderNoteRow(
                            note: orderNotes,
                            onTap: _showNotesDialog,
                          ),
                        BoingOnChange(
                          trigger: count,
                          power: 0.85,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                            child: Opacity(
                              opacity: (_readOnly && count > 0) ? 0.45 : 1.0,
                              child: PredictiveScale(
                                enabled: false,
                                maxScaleBoost: 0.015,
                                child: Hero(
                                  tag: HeroTags.cartBar,
                                  child: Material(
                                    color: Colors.transparent,
                                    child: GestureDetector(
                                      onTap: onBarTap,
                                      child: Container(
                                        key: CartFlight.cartBarKey,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16, vertical: 13),
                                        decoration: const BoxDecoration(
                                          color: AppColors.terra,
                                          borderRadius: BorderRadius.all(
                                              AppRadii.md),
                                        ),
                                        child: Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                label,
                                                overflow: TextOverflow.ellipsis,
                                                style: AppTypography.bodyMd
                                                    .copyWith(
                                                        color: Colors.white,
                                                        fontWeight:
                                                            FontWeight.w600),
                                              ),
                                            ),
                                            if (!_readOnly || count == 0) ...[
                                              Text('  ·  ',
                                                  style: AppTypography.bodyMd
                                                      .copyWith(
                                                          color: Colors.white
                                                              .withValues(
                                                                  alpha: 0.6))),
                                              KineticRupeeCounter(
                                                amount:
                                                    barTotal.asRupeesForDisplay,
                                                fontSize: 16,
                                                color: Colors.white,
                                              ),
                                            ],
                                            const Spacer(),
                                            if (onSendKotTap != null) ...[
                                              GestureDetector(
                                                onTap: onSendKotTap,
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                child: Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                      horizontal: 10,
                                                      vertical: 6),
                                                  decoration: BoxDecoration(
                                                    color: Colors.white
                                                        .withValues(
                                                            alpha: 0.18),
                                                    borderRadius:
                                                        const BorderRadius.all(
                                                            AppRadii.pill),
                                                  ),
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      const Icon(
                                                          Icons
                                                              .local_fire_department_outlined,
                                                          color: Colors.white,
                                                          size: 14),
                                                      const SizedBox(width: 4),
                                                      Text('Send KOT',
                                                          style: AppTypography
                                                              .caption
                                                              .copyWith(
                                                                  color: Colors
                                                                      .white,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w700)),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                            ],
                                            Text(actionLabel,
                                                style: AppTypography.bodyMd
                                                    .copyWith(
                                                        color: Colors.white,
                                                        fontWeight:
                                                            FontWeight.w600)),
                                            const SizedBox(width: 4),
                                            const Icon(Icons.arrow_forward,
                                                color: Colors.white, size: 18),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  }),
                ],
              );
              if (!wide) return mainColumn;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: mainColumn),
                  Container(width: 1, color: context.palette.hairline),
                  SizedBox(
                    width: 356,
                    child: _OrderSideRail(
                      runningOrder: runningOrder,
                      readOnly: _readOnly,
                      reviewRoute: _reviewRoute,
                      onSendKot: (_readOnly || cartIsEmpty)
                          ? null
                          : () => context.push(_reviewRoute, extra: true),
                      onViewBill: runningOrder != null
                          ? () => context.push('/history/${runningOrder.id}')
                          : null,
                      onPrintSummary: (flags.printSummary &&
                              runningOrder != null &&
                              runningOrder.itemCount > 0)
                          ? () {
                              ref.read(socketServiceProvider).emit(
                                'print:summary',
                                {'order_id': runningOrder.id},
                              );
                            }
                          : null,
                    ),
                  ),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _menuScroll.removeListener(_onMenuScroll);
    _menuScroll.dispose();
    _scrollCollapse.dispose();
    if (!widget.isRoom) {
      _socketSvc?.emit('table:presence:leave', {'table_id': widget.tableId});
    }
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
    final palette = context.palette;
    final fillTarget = palette.selectedPill;
    return GestureDetector(
      onTap: onTap,
      child: SpringBuilder(
        to: selected ? 1.0 : 0.0,
        spring: RestroSprings.snappy,
        builder: (BuildContext _, double t, Widget? child) {
          return Transform.scale(
            scale: 1 + 0.04 * t,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Color.lerp(
                    palette.isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.white.withValues(alpha: 0.6),
                    fillTarget,
                    t),
                borderRadius: const BorderRadius.all(AppRadii.pill),
                border: Border.all(
                    color: Color.lerp(palette.ink10, fillTarget, t) ??
                        palette.ink10),
              ),
              child: child,
            ),
          );
        },
        child: Center(
          child: Text(label,
              style: AppTypography.caption.copyWith(
                color: selected ? Colors.white : palette.ink,
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
              ? (context.palette.isDark
                  ? AppColors.terra600.withValues(alpha: 0.28)
                  : AppColors.terra50)
              : context.palette.isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.white.withValues(alpha: 0.5),
          borderRadius: const BorderRadius.all(AppRadii.sm),
          border: Border.all(
            color: hasNote ? AppColors.terra200 : context.palette.ink10,
          ),
        ),
        child: Row(
          children: [
            Icon(
              hasNote ? Icons.notes : Icons.add_comment_outlined,
              size: 15,
              color: hasNote ? AppColors.terra600 : context.palette.ink30,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hasNote ? note : 'Add order note…',
                style: AppTypography.caption.copyWith(
                  color: hasNote ? context.palette.ink : context.palette.ink30,
                  fontWeight: hasNote ? FontWeight.w600 : FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.edit_outlined,
              size: 13,
              color: context.palette.ink30,
            ),
          ],
        ),
      ),
    );
  }
}

class _RunningOrderCard extends StatefulWidget {
  final ServerOrder order;
  final String tableId;
  final bool cartIsEmpty;
  final bool showPrintSummary;
  final VoidCallback onPrintSummary;

  const _RunningOrderCard({
    required this.order,
    required this.tableId,
    required this.cartIsEmpty,
    required this.showPrintSummary,
    required this.onPrintSummary,
  });

  @override
  State<_RunningOrderCard> createState() => _RunningOrderCardState();
}

class _RunningOrderCardState extends State<_RunningOrderCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: AppCard(
        background: context.palette.surface.withValues(alpha: 0.92),
        border: Border.all(color: AppColors.terra200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  const Icon(Icons.restaurant_menu,
                      size: 16, color: AppColors.terra600),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Running · ${order.itemCount} '
                      '${order.itemCount == 1 ? "item" : "items"} sent',
                      style: AppTypography.bodyMd
                          .copyWith(fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    formatRupeesCompact(order.total),
                    style: AppTypography.title,
                  ),
                  const SizedBox(width: 2),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(Icons.keyboard_arrow_down,
                        size: 20, color: context.palette.ink50),
                  ),
                ],
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: !_expanded
                  ? const SizedBox(width: double.infinity)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),
                        if (order.items.isEmpty)
                          Text(
                            '${order.itemCount} ${order.itemCount == 1 ? "item" : "items"} already sent',
                            style: AppTypography.caption.copyWith(
                              color: context.palette.ink70,
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
                                      style: AppTypography.caption.copyWith(
                                          fontWeight: FontWeight.w700)),
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
                        if (widget.cartIsEmpty && widget.showPrintSummary) ...[
                          const SizedBox(height: 10),
                          const Divider(
                              height: 1,
                              thickness: 1,
                              color: AppColors.terra200),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: widget.onPrintSummary,
                                  icon: const Icon(Icons.print_outlined,
                                      size: 14),
                                  label: const Text('Print Summary'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppColors.terra600,
                                    side: const BorderSide(
                                        color: AppColors.terra300),
                                    textStyle: AppTypography.caption
                                        .copyWith(fontWeight: FontWeight.w600),
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 8),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => KotHistorySheet.show(
                                      context, widget.tableId),
                                  icon: const Icon(Icons.history_outlined,
                                      size: 14),
                                  label: const Text('KOT History'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: context.palette.ink70,
                                    side: BorderSide(
                                        color: context.palette.ink30),
                                    textStyle: AppTypography.caption
                                        .copyWith(fontWeight: FontWeight.w600),
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 8),
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
          ],
        ),
      ),
    );
  }
}

bool _itemNeedsSheet(MenuItem item, {bool variationsEnabled = true}) {
  if (variationsEnabled && item.variations.isNotEmpty) return true;
  if (item.isWeighed) return true;
  if (item.addonGroups.isNotEmpty) return true;
  return item.optionGroups.any((g) => g.isRequired || g.minSelect > 0);
}

class _SwipeToAddWrapper extends StatefulWidget {
  final Widget child;
  final VoidCallback? onDragTick;
  final VoidCallback? onSwipeConfirm;
  final VoidCallback onAdd;
  final bool readOnly;

  const _SwipeToAddWrapper({
    required this.child,
    required this.onAdd,
    this.onDragTick,
    this.onSwipeConfirm,
    this.readOnly = false,
  });

  @override
  State<_SwipeToAddWrapper> createState() => _SwipeToAddWrapperState();
}

class _SwipeToAddWrapperState extends State<_SwipeToAddWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  double _dragOffset = 0;
  double _springStartOffset = 0;
  bool _thresholdCrossed = false;
  static const double _maxDrag = 80;
  static const double _threshold = 40;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _ctrl.addListener(() {
      if (!mounted) return;
      setState(() => _dragOffset = _springStartOffset * (1 - _ctrl.value));
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (widget.readOnly) return;
    final prev = _dragOffset;
    _dragOffset = (_dragOffset + d.delta.dx).clamp(0.0, _maxDrag);
    setState(() {});
    if (!_thresholdCrossed && prev < _threshold && _dragOffset >= _threshold) {
      _thresholdCrossed = true;
      widget.onDragTick?.call();
    }
  }

  void _onDragEnd(DragEndDetails _) {
    _thresholdCrossed = false;
    if (widget.readOnly) return;
    if (_dragOffset >= _threshold) {
      widget.onSwipeConfirm?.call();
      CartFlight.fly(context);
      widget.onAdd();
    }

    _springStartOffset = _dragOffset;
    _ctrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: widget.readOnly ? null : _onDragUpdate,
      onHorizontalDragEnd: widget.readOnly ? null : _onDragEnd,
      child: Stack(
        children: [
          if (_dragOffset > 0)
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(color: AppColors.success),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 16),
                child: Opacity(
                  opacity: (_dragOffset / _maxDrag).clamp(0.0, 1.0),
                  child: const Icon(
                    Icons.add,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends ConsumerWidget {
  final MenuItem item;
  final VoidCallback onAdd;
  final VoidCallback onDecrement;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _ItemRow({
    required this.item,
    required this.onAdd,
    required this.onDecrement,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final simpleQty = ref.watch(plainCartQtyProvider(item.id));
    final unavailable = !item.available;
    final hasVariations = item.variations.isNotEmpty;
    final needsSheet = _itemNeedsSheet(item);
    return InkWell(
      onTap: unavailable ? null : onTap,
      onLongPress: unavailable ? null : onLongPress,
      child: Opacity(
        opacity: unavailable ? 0.45 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: Row(
            children: [
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
                        if (hasVariations) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: context.palette.terraSoft,
                              borderRadius: const BorderRadius.all(AppRadii.xs),
                            ),
                            child: Text(
                              '${item.variations.length} SIZES',
                              style: AppTypography.pill.copyWith(
                                  color: AppColors.terraInk, fontSize: 8.5),
                            ),
                          ),
                        ],
                        if (unavailable) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: AppChipPadding.statusBadge,
                            decoration: BoxDecoration(
                              color: AppColors.warn
                                  .withValues(alpha: AppAlphas.warnOverlay),
                              borderRadius: const BorderRadius.all(AppRadii.xs),
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
                    Text(
                      hasVariations
                          ? item.variations
                              .take(2)
                              .map((v) =>
                                  '${v.name} ${formatRupeesCompact(v.price)}')
                              .join(' · ')
                          : formatRupeesCompact(item.price),
                      style: AppTypography.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (!unavailable)
                if (needsSheet || simpleQty <= 0)
                  Semantics(
                    button: true,
                    label: 'Add to order',
                    child: GestureDetector(
                      onTap: () {
                        CartFlight.fly(context);
                        onAdd();
                      },
                      behavior: HitTestBehavior.opaque,
                      child: SizedBox(
                        width: AppTouchTargets.minimum,
                        height: AppTouchTargets.minimum,
                        child: Center(
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: const BoxDecoration(
                              color: AppColors.ink,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.add,
                                color: Colors.white, size: 18),
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _StepperButton(
                        label: 'Remove one',
                        icon: Icons.remove,
                        onTap: onDecrement,
                      ),
                      SizedBox(
                        width: 22,
                        child: Text('$simpleQty',
                            textAlign: TextAlign.center,
                            style: AppTypography.bodyMd
                                .copyWith(fontWeight: FontWeight.w700)),
                      ),
                      _StepperButton(
                        label: 'Add one',
                        icon: Icons.add,
                        onTap: () {
                          CartFlight.fly(context);
                          onAdd();
                        },
                      ),
                    ],
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  final String label;
  const _StepperButton({
    required this.icon,
    required this.onTap,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: AppTouchTargets.minimum,
          height: AppTouchTargets.minimum,
          child: Center(
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: context.palette.terraSoft,
                borderRadius: const BorderRadius.all(AppRadii.pill),
              ),
              child: Icon(icon, size: 15, color: AppColors.terraDeep),
            ),
          ),
        ),
      ),
    );
  }
}

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
    );
    _anim = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppPerf.reduceEffects(context)) {
      _ctrl.stop();
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat();
    }
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
            color: context.palette.ink05,
          ),
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: context.palette.ink10,
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
                        color: context.palette.ink10,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 10,
                      width: 60,
                      decoration: BoxDecoration(
                        color: context.palette.ink05,
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
                  color: context.palette.ink10,
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

class _ZoneReveal extends StatelessWidget {
  final bool visible;
  final ValueListenable<double>? scroll;
  final Widget child;
  const _ZoneReveal({
    required this.visible,
    this.scroll,
    required this.child,
  });

  Widget _core(double hide, Widget child) {
    if (hide >= 0.999) return const SizedBox(width: double.infinity);
    return Align(
      alignment: Alignment.topCenter,
      heightFactor: (1 - hide).clamp(0.0, 1.0),
      child: Opacity(
        opacity: (1 - hide * 1.25).clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, -6 * hide),
          child: IgnorePointer(ignoring: hide > 0.5, child: child),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRect(
        child: SpringBuilder(
          to: visible ? 0.0 : 1.0,
          spring: RestroSprings.soft,
          child: child,
          builder: (context, sv, c) {
            final double springHide = sv.clamp(0.0, 1.0);
            final s = scroll;
            if (s == null) return _core(springHide, c!);
            return ValueListenableBuilder<double>(
              valueListenable: s,
              builder: (_, sp, __) => _core(
                math.max(springHide, visible ? sp : 1.0),
                c!,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _OrderSideRail extends ConsumerWidget {
  final ServerOrder? runningOrder;
  final bool readOnly;
  final String reviewRoute;

  final VoidCallback? onSendKot;
  final VoidCallback? onViewBill;
  final VoidCallback? onPrintSummary;
  const _OrderSideRail({
    required this.runningOrder,
    required this.readOnly,
    required this.reviewRoute,
    required this.onSendKot,
    required this.onViewBill,
    required this.onPrintSummary,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final cart = ref.watch(cartProvider);
    final notes = ref.watch(orderNotesProvider);
    final Money cartTotal = cart.map((l) => l.lineTotal).sumMoney();
    final running = runningOrder;
    final bool hasRunning = running != null && running.itemCount > 0;

    return Container(
      color: palette.paper,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('This order', style: AppTypography.headline),
          const SizedBox(height: 10),
          if (hasRunning) ...[
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: Border.all(color: AppColors.terra200),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.receipt_long,
                          size: 16, color: AppColors.terraDeep),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Running · ${running.itemCount} '
                          '${running.itemCount == 1 ? "item" : "items"} sent',
                          style: AppTypography.caption
                              .copyWith(fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        formatRupees(running.total),
                        style: AppTypography.title
                            .copyWith(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                  if (onPrintSummary != null) ...[
                    const SizedBox(height: 8),
                    Pressable(
                      onTap: onPrintSummary,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.print_outlined,
                              size: 14, color: palette.ink70),
                          const SizedBox(width: 5),
                          Text('Print summary',
                              style: AppTypography.caption
                                  .copyWith(color: palette.ink70)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          Expanded(
            child: cart.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.shopping_basket_outlined,
                            size: 40, color: palette.ink30),
                        const SizedBox(height: 10),
                        Text('Cart is empty',
                            style: AppTypography.title
                                .copyWith(color: palette.ink70)),
                        const SizedBox(height: 4),
                        Text('Tap items on the menu to add them',
                            textAlign: TextAlign.center,
                            style: AppTypography.caption
                                .copyWith(color: palette.ink50)),
                      ],
                    ),
                  )
                : AppCard(
                    padding: EdgeInsets.zero,
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: cart.length,
                      separatorBuilder: (_, __) => Divider(
                          height: 1, thickness: 0.5, color: palette.ink05),
                      itemBuilder: (_, i) {
                        final l = cart[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${l.qty}×',
                                  style: AppTypography.caption.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.terraDeep)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  l.item.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.caption
                                      .copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(formatRupees(l.lineTotal),
                                  style: AppTypography.caption
                                      .copyWith(fontWeight: FontWeight.w700)),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.sticky_note_2_outlined,
                    size: 14, color: palette.ink50),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(notes,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          AppTypography.caption.copyWith(color: palette.ink70)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Container(
            key: CartFlight.railKey,
            child: BoingOnChange(
              trigger: cart.length,
              power: 0.8,
              child: Row(
                children: [
                  Text('Cart total',
                      style:
                          AppTypography.caption.copyWith(color: palette.ink50)),
                  const Spacer(),
                  KineticRupeeCounter(
                      amount: cartTotal.asRupeesForDisplay,
                      fontSize: 18,
                      color: palette.ink),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (onSendKot != null) ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onSendKot,
                    icon: const Icon(Icons.local_fire_department_outlined,
                        size: 16),
                    label: const Text('Send KOT'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.terra600,
                      side: const BorderSide(color: AppColors.terra300),
                      textStyle: AppTypography.caption
                          .copyWith(fontWeight: FontWeight.w700),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Pressable(
                    onTap: () => context.push(reviewRoute),
                    child: const _ReviewAndSendButton(label: 'Review'),
                  ),
                ),
              ],
            ),
          ] else
            Pressable(
              onTap: (readOnly || (cart.isEmpty && !hasRunning))
                  ? null
                  : cart.isEmpty
                      ? onViewBill
                      : () => context.push(reviewRoute),
              child: Opacity(
                opacity: (readOnly || (cart.isEmpty && !hasRunning)) ? 0.45 : 1,
                child: _ReviewAndSendButton(
                  label: cart.isEmpty ? 'View bill' : 'Review & send',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReviewAndSendButton extends StatelessWidget {
  final String label;
  const _ReviewAndSendButton({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(
        color: AppColors.terra,
        borderRadius: BorderRadius.all(AppRadii.md),
        boxShadow: AppShadows.terraGlow,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: AppTypography.bodyMd
                .copyWith(color: Colors.white, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.arrow_forward, color: Colors.white, size: 18),
        ],
      ),
    );
  }
}
