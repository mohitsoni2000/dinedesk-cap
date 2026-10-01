import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../data/ist_time.dart';
import '../data/room_card_view.dart';
import '../data/table_open_intent.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';
import '../widgets/page_content_clamp.dart';
import '../widgets/dynamic_toast.dart';
import '../widgets/liquid_chrome.dart';

class RoomsScreen extends ConsumerStatefulWidget {
  const RoomsScreen({super.key});
  @override
  ConsumerState<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends ConsumerState<RoomsScreen> {
  String _query = '';
  bool _searchOpen = false;
  bool _openingRoom = false;

  bool _hasScrolled = false;
  String? _openingRoomId;
  Timer? _midnight;

  @override
  void initState() {
    super.initState();
    _armMidnight();
  }

  @override
  void dispose() {
    _midnight?.cancel();
    super.dispose();
  }

  // Tonight's arrivals start holding their rooms at IST midnight, even on an
  // idle or offline screen.
  void _armMidnight() {
    _midnight?.cancel();
    _midnight = Timer(
        untilNextIstMidnight(DateTime.now()) + const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() {});
      _armMidnight();
    });
  }

  void _onRoomTap(RestaurantRoom r) async {
    if (_openingRoom) return;
    final intent = resolveRoomOpenIntent(r);
    if (intent.action == TableOpenAction.blocked) {
      ref.read(feedbackServiceProvider).fire(const FeedbackLight());
      _showRoomError(intent.message ?? 'Room cannot be opened');
      return;
    }

    ref.read(feedbackServiceProvider).fire(const FeedbackMedium());
    final prevTable = ref.read(selectedTableIdProvider);
    if (prevTable != null && prevTable != r.serverId) {
      ref.read(cartProvider.notifier).clear();
      ref.read(orderNotesProvider.notifier).state = '';
    }
    ref.read(selectedTableIdProvider.notifier).state = r.serverId;

    if (intent.action == TableOpenAction.createDraft) {
      setState(() {
        _openingRoom = true;
        _openingRoomId = r.serverId;
      });
      final response = await ref.read(socketServiceProvider).emitAck(
        'order:create',
        {
          'room_id': r.serverId,
          'items': const <Map<String, dynamic>>[],
          'order_type': 'room',
        },
      );
      if (!mounted) return;
      setState(() {
        _openingRoom = false;
        _openingRoomId = null;
      });
      if (response['kind'] == 'error') {
        _showRoomError(
            response['message']?.toString() ?? 'Could not open room');
        return;
      }
      ref.read(syncServiceProvider).applyOrderAck(response);
    }

    if (intent.action == TableOpenAction.openOrder) {
      final activeOrders = ref.read(activeOrdersProvider);
      final activeOrderId = r.activeOrderId;
      final active = activeOrders.where((o) {
        return (activeOrderId != null && o.id == activeOrderId) ||
            o.roomId == r.serverId;
      }).firstOrNull;
      if (active != null) {
        ref.read(syncServiceProvider).adoptOrder(active);
      }
    }

    if (!mounted || intent.route == null) return;
    context.go(intent.route!);
  }

  void _showRoomError(String message) {
    DynamicToast.show(context,
        message: message,
        kind: ToastKind.error,
        duration: const Duration(seconds: 2));
  }

  @override
  Widget build(BuildContext context) {
    final rooms = ref.watch(roomsProvider);
    final connOnline = ref.watch(connectionProvider.select((c) => c.online));

    final today = istDateOf(DateTime.now());
    final query = _query.toLowerCase();
    final filtered = rooms.where((r) {
      if (query.isEmpty) return true;
      return r.id.toLowerCase().contains(query) ||
          (r.guestName?.toLowerCase().contains(query) ?? false) ||
          (r.activeHold(today)?.guestName.toLowerCase().contains(query) ??
              false);
    }).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
          bottom: false,
          child: PageContentClamp(
            maxWidth: PageContentClamp.grid,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('Rooms', style: AppTypography.displayMd),
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
                    child: Container(
                      decoration: BoxDecoration(
                        color: context.palette.surface,
                        borderRadius: const BorderRadius.all(AppRadii.sm),
                        border: Border.all(
                            color: context.palette.hairline, width: 1.5),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        autofocus: true,
                        cursorColor: AppColors.terra,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Search room number or guest…',
                          icon: Icon(Icons.search,
                              color: context.palette.ink50, size: 18),
                        ),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Expanded(
                  child: rooms.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.hotel_outlined,
                                    color: context.palette.ink30, size: 48),
                                const SizedBox(height: 12),
                                const Text('No rooms configured',
                                    style: AppTypography.title),
                              ],
                            ),
                          ),
                        )
                      : filtered.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.search_off,
                                        color: context.palette.ink30, size: 48),
                                    const SizedBox(height: 12),
                                    const Text('No rooms match',
                                        style: AppTypography.title),
                                    const SizedBox(height: 4),
                                    const Text('Try a different search',
                                        style: AppTypography.caption),
                                  ],
                                ),
                              ),
                            )
                          : NotificationListener<ScrollUpdateNotification>(
                              onNotification: (n) {
                                if (!_hasScrolled &&
                                    (n.scrollDelta?.abs() ?? 0) > 2) {
                                  _hasScrolled = true;
                                }
                                return false;
                              },
                              child: GridView.builder(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                scrollCacheExtent: ScrollCacheExtent.pixels(
                                    AppPerf.gridCacheExtentFor(context)),
                                gridDelegate:
                                    SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: context.tableTileExtent,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                  mainAxisExtent: context.tableTileMainExtent,
                                ),
                                itemCount: filtered.length,
                                itemBuilder: (context, i) {
                                  final r = filtered[i];
                                  final card = _RoomCard(
                                    room: r,
                                    view: roomCardView(r, today),
                                    isLoading: _openingRoom &&
                                        _openingRoomId == r.serverId,
                                    onTap: () => _onRoomTap(r),
                                  );

                                  if (i >= 12 ||
                                      _hasScrolled ||
                                      AppPerf.reduceEffects(context)) {
                                    return KeyedSubtree(
                                        key: ValueKey(r.serverId), child: card);
                                  }
                                  return KeyedSubtree(
                                    key: ValueKey(r.serverId),
                                    child: Entrance(
                                      delay: Duration(milliseconds: 35 * i),
                                      offsetY: 10,
                                      child: card,
                                    ),
                                  );
                                },
                              ),
                            ),
                ),
              ],
            ),
          )),
    );
  }
}

class _RoomCard extends StatelessWidget {
  final RestaurantRoom room;
  final RoomCardView view;
  final bool isLoading;
  final VoidCallback onTap;
  const _RoomCard({
    required this.room,
    required this.view,
    required this.isLoading,
    required this.onTap,
  });

  Color _bg(BuildContext context) {
    final palette = context.palette;
    switch (view.state) {
      case RoomCardState.mine:
        return palette.tableMineBg;
      case RoomCardState.occupied:
        return palette.tableOtherBg;
      case RoomCardState.free:
        return palette.tableFreeBg;
      case RoomCardState.held:
        return palette.tableReservedBg;
      case RoomCardState.dirty:
      case RoomCardState.cleaning:
      case RoomCardState.inspect:
        return palette.tableDirtyBg;
      case RoomCardState.blocked:
        return palette.dangerBg;
    }
  }

  Color _border() {
    switch (view.state) {
      case RoomCardState.mine:
        return AppColors.terra400.withValues(alpha: 0.45);
      case RoomCardState.occupied:
        return AppColors.info.withValues(alpha: 0.4);
      case RoomCardState.free:
        return AppColors.success.withValues(alpha: 0.32);
      case RoomCardState.held:
        return AppColors.violet.withValues(alpha: 0.4);
      case RoomCardState.dirty:
      case RoomCardState.cleaning:
      case RoomCardState.inspect:
        return AppColors.warn.withValues(alpha: 0.45);
      case RoomCardState.blocked:
        return AppColors.danger.withValues(alpha: 0.4);
    }
  }

  Color? _tagColor(BuildContext context) {
    final palette = context.palette;
    switch (view.state) {
      case RoomCardState.held:
        return palette.tableReservedText;
      case RoomCardState.dirty:
      case RoomCardState.cleaning:
      case RoomCardState.inspect:
        return palette.tableDirtyText;
      case RoomCardState.blocked:
        return palette.dangerText;
      case RoomCardState.mine:
      case RoomCardState.occupied:
      case RoomCardState.free:
        return null;
    }
  }

  Widget? _note(BuildContext context) {
    final note = view.note;
    if (note == null) return null;
    final palette = context.palette;
    if (view.state == RoomCardState.held) {
      final color = view.lateNote ? palette.warnText : palette.ink70;
      return Row(
        children: [
          Icon(Icons.schedule, size: 12, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(note,
                style: AppTypography.caption.copyWith(color: color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      );
    }
    return Text(note,
        style: AppTypography.caption.copyWith(color: palette.tableReservedText),
        maxLines: 1,
        overflow: TextOverflow.ellipsis);
  }

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: isLoading ? null : onTap,
      pressedScale: 0.97,
      child: Stack(
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: _bg(context),
              borderRadius: const BorderRadius.all(AppRadii.lg),
              border: Border.all(color: _border(), width: 1),
              boxShadow: AppShadows.none,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Opacity(
                        opacity: view.unavailable ? 0.55 : 1,
                        child: Text(
                          room.id,
                          style: AppTypography.displayMd.copyWith(fontSize: 24),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text('${room.capacity} guests',
                        style: AppTypography.caption),
                  ],
                ),
                const Spacer(),
                Text(view.tag,
                    style:
                        AppTypography.micro.copyWith(color: _tagColor(context)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (view.guest != null && view.guest!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(view.guest!,
                      style: AppTypography.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
                if (_note(context) case final note?) ...[
                  const SizedBox(height: 2),
                  note,
                ],
                if (room.bill != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    formatRupeesCompact(room.bill!),
                    style: AppTypography.title
                        .copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
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
      ),
    );
  }
}
