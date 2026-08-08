

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/currency.dart';
import '../data/money.dart';
import '../data/providers.dart';
import '../services/pin_guard.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'dynamic_toast.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

/// One fired KOT round, reassembled from the order's lines.
///
/// [HistoryOrder] covers a whole order rather than a round, so rounds are
/// rebuilt here by grouping on `kot_number` — the field the desk keeps
/// accurate across splits.
class _Round {
  final String kotNumber;
  final List<HistoryOrderLine> lines;
  const _Round({required this.kotNumber, required this.lines});

  Money get total => lines.fold(
        Money.zero,
        (sum, l) => sum + l.price.times(l.qty),
      );

  int get itemCount => lines.fold(0, (sum, l) => sum + l.qty);
}

/// Moves fired KOT lines to another table, leaving the rest of the order in
/// place. Distinct from `TableShiftSheet`, which moves the whole order.
///
/// An occupied destination is valid — the desk appends the moved lines to that
/// table's existing order rather than refusing — so unlike the whole-table
/// shift this picker does not filter down to free tables.
class KotShiftSheet extends ConsumerStatefulWidget {
  final HistoryOrder order;
  final String originServerId;

  const KotShiftSheet({
    super.key,
    required this.order,
    required this.originServerId,
  });

  @override
  ConsumerState<KotShiftSheet> createState() => _KotShiftSheetState();

  /// Rounds available to shift, newest first. Lines never sent to the kitchen
  /// carry no round number and are left out — there is no round to move them
  /// with, and the desk would file them under the destination's next KOT.
  static List<_Round> roundsOf(HistoryOrder order) {
    final grouped = <String, List<HistoryOrderLine>>{};
    for (final line in order.lines) {
      final kot = line.kotNumber;
      if (kot == null || kot.trim().isEmpty) continue;
      grouped.putIfAbsent(kot, () => <HistoryOrderLine>[]).add(line);
    }
    final rounds = grouped.entries
        .map((e) => _Round(kotNumber: e.key, lines: e.value))
        .toList()
      ..sort((a, b) => b.kotNumber.compareTo(a.kotNumber));
    return rounds;
  }

  static bool hasShiftableRounds(HistoryOrder order) =>
      roundsOf(order).isNotEmpty;

  static Future<void> show(
    BuildContext context,
    HistoryOrder order,
    String originServerId,
  ) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => KotShiftSheet(
        order: order,
        originServerId: originServerId,
      ),
    );
  }
}

enum _Step { pickItems, pickTable }

class _KotShiftSheetState extends ConsumerState<KotShiftSheet> {
  late final List<_Round> _rounds;

  /// Which round is expanded. Only one at a time, so a shift can never span
  /// two rounds by accident.
  String? _openKot;

  /// Selected `orderItemId`s within [_openKot]. Cleared whenever the open
  /// round changes, so the selection can only ever describe one round.
  final Set<String> _picked = <String>{};

  _Step _step = _Step.pickItems;
  String? _pickedTableServerId;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _rounds = KotShiftSheet.roundsOf(widget.order);
    if (_rounds.length == 1) {
      _openRound(_rounds.first);
    }
  }

  void _openRound(_Round round) {
    _openKot = round.kotNumber;
    _picked
      ..clear()
      ..addAll(round.lines.map((l) => l.orderItemId));
  }

  void _toggleRound(_Round round) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_openKot == round.kotNumber) {
        _openKot = null;
        _picked.clear();
      } else {
        _openRound(round);
      }
    });
  }

  void _toggleLine(HistoryOrderLine line) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_picked.remove(line.orderItemId)) _picked.add(line.orderItemId);
    });
  }

  Future<void> _shift() async {
    final table = _pickedTableServerId;
    if (table == null || _picked.isEmpty || _submitting) return;

    final pinOk = await requirePinIfNeeded(context, ref, 'kot_shift');
    if (!pinOk || !mounted) return;

    setState(() => _submitting = true);
    HapticFeedback.heavyImpact();

    final response = await ref.read(socketServiceProvider).emitAck(
      'kot:shift',
      {
        'order_id': widget.order.orderId,
        'order_item_ids': _picked.toList(),
        'to_table_id': table,
      },
    );

    if (!mounted) return;
    setState(() => _submitting = false);

    if (response['kind'] == 'error') {
      DynamicToast.show(context,
          message: response['message']?.toString() ?? 'Shift failed',
          kind: ToastKind.error);
      return;
    }

    Navigator.of(context).pop();
  }

  List<RestaurantTable> _candidates() {
    // Free and occupied both qualify; a table awaiting cleaning or held for a
    // reservation is not somewhere a round should land.
    final tables = ref.watch(tablesProvider);
    return tables
        .where((t) =>
            t.serverId != widget.originServerId &&
            (t.state == TableState.free ||
                t.state == TableState.mine ||
                t.state == TableState.other))
        .toList()
      ..sort((a, b) {
        final aFree = a.state == TableState.free ? 0 : 1;
        final bFree = b.state == TableState.free ? 0 : 1;
        if (aFree != bFree) return aFree - bFree;
        return a.id.compareTo(b.id);
      });
  }

  @override
  Widget build(BuildContext context) {
    final onItems = _step == _Step.pickItems;

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.92,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => AppSurface(
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            const SizedBox(height: 8),
            const SheetHandle(),
            const SizedBox(height: 12),
            _header(),
            const SizedBox(height: 12),
            Divider(height: 1, color: context.palette.hairline),
            Expanded(
              child: onItems ? _roundList(scroll) : _tableList(scroll),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final onItems = _step == _Step.pickItems;
    final subtitle = onItems
        ? 'Pick a round, then fine-tune its items'
        : '${_picked.length} ${_picked.length == 1 ? 'item' : 'items'} '
            'from ${_openKot ?? ''}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Shift KOT Round',
                    style: AppTypography.sheetTitle),
                const SizedBox(height: 2),
                Text(subtitle, style: AppTypography.caption),
              ],
            ),
          ),
          if (!onItems && _pickedTableServerId != null)
            LiquidPill(
              tint: AppColors.success,
              child: const Text('Selected'),
            ),
        ],
      ),
    );
  }

  Widget _roundList(ScrollController scroll) {
    if (_rounds.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Nothing to shift — no KOT has been sent for this order yet.',
            style: AppTypography.caption,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      controller: scroll,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: 8),
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemCount: _rounds.length,
      itemBuilder: (_, i) => _roundCard(_rounds[i]),
    );
  }

  Widget _roundCard(_Round round) {
    final palette = context.palette;
    final open = _openKot == round.kotNumber;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: open ? palette.terraSoft : palette.surface,
        borderRadius: const BorderRadius.all(AppRadii.md),
        border: Border.all(
            color: open ? AppColors.terra : palette.hairline,
            width: open ? 1.5 : 1),
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: () => _toggleRound(round),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(open ? Icons.expand_more : Icons.chevron_right,
                      size: 20,
                      color: open ? AppColors.terra : palette.ink30),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${round.kotNumber} · ${round.itemCount} '
                      '${round.itemCount == 1 ? 'item' : 'items'}',
                      style: AppTypography.bodyMd.copyWith(
                        color: open ? AppColors.terraDeep : palette.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(formatRupeesCompact(round.total),
                      style: AppTypography.caption.copyWith(
                          color: open ? AppColors.terraInk : palette.ink70)),
                ],
              ),
            ),
          ),
          if (open) ...[
            Divider(height: 1, color: palette.ink10),
            for (final line in round.lines) _lineRow(line),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _lineRow(HistoryOrderLine line) {
    final palette = context.palette;
    final on = _picked.contains(line.orderItemId);

    return GestureDetector(
      onTap: () => _toggleLine(line),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Row(
          children: [
            Icon(on ? Icons.check_box : Icons.check_box_outline_blank,
                size: 20, color: on ? AppColors.terra : palette.ink30),
            const SizedBox(width: 10),
            SizedBox(
              width: 26,
              child: Text('${line.qty}×',
                  style: AppTypography.caption
                      .copyWith(fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(line.name,
                      style: AppTypography.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  if (line.mods.isNotEmpty)
                    Text(line.mods.join(' · '),
                        style: AppTypography.micro
                            .copyWith(color: palette.ink70),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(formatRupeesCompact(line.price.times(line.qty)),
                style: AppTypography.caption),
          ],
        ),
      ),
    );
  }

  Widget _tableList(ScrollController scroll) {
    final palette = context.palette;
    final candidates = _candidates();

    if (candidates.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No tables available to shift to.',
              style: AppTypography.caption, textAlign: TextAlign.center),
        ),
      );
    }

    return ListView.separated(
      controller: scroll,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: 8),
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemCount: candidates.length,
      itemBuilder: (_, i) {
        final t = candidates[i];
        final on = _pickedTableServerId == t.serverId;
        final isFree = t.state == TableState.free;
        final accent = isFree ? AppColors.success : AppColors.warn;

        return GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() => _pickedTableServerId = on ? null : t.serverId);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: on ? palette.terraSoft : palette.surface,
              borderRadius: const BorderRadius.all(AppRadii.md),
              border: Border.all(
                  color: on ? AppColors.terra : palette.hairline,
                  width: on ? 1.5 : 1),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                      isFree
                          ? Icons.table_restaurant_outlined
                          : Icons.receipt_long,
                      size: 18,
                      color: accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(t.id,
                              style: AppTypography.bodyMd.copyWith(
                                color: on ? AppColors.terraDeep : palette.ink,
                                fontWeight: FontWeight.w600,
                              )),
                          if (!isFree) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color:
                                    AppColors.warn.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text('HAS ORDER',
                                  style: AppTypography.micro.copyWith(
                                      color: AppColors.warn,
                                      letterSpacing: 0.6)),
                            ),
                          ],
                        ],
                      ),
                      Text(
                          isFree
                              ? '${t.seats} seats · ${t.floor}'
                              : '${t.seats} seats · ${t.floor} · items will be added to its order',
                          style: AppTypography.caption.copyWith(
                            color: on ? AppColors.terraInk : palette.ink70,
                          )),
                    ],
                  ),
                ),
                Icon(on ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: on ? AppColors.terra : palette.ink30),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _footer() {
    final onItems = _step == _Step.pickItems;
    final count = _picked.length;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg + context.sheetBottomInset,
      ),
      child: Column(
        children: [
          if (onItems && count > 0) ...[
            Text('$count ${count == 1 ? 'item' : 'items'} selected',
                style: AppTypography.caption),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: LiquidSecondaryButton(
                  label: onItems ? 'Cancel' : 'Back',
                  onPressed: () {
                    if (onItems) {
                      Navigator.of(context).pop();
                    } else {
                      setState(() => _step = _Step.pickItems);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: onItems
                    ? LiquidPrimaryButton(
                        label: 'Next: pick table',
                        fullWidth: true,
                        leadingIcon: Icons.arrow_forward,
                        onPressed: count == 0
                            ? null
                            : () => setState(() => _step = _Step.pickTable),
                      )
                    : LiquidPrimaryButton(
                        label: _submitting ? 'Shifting…' : 'Shift',
                        fullWidth: true,
                        leadingIcon: Icons.swap_horiz,
                        onPressed:
                            (_pickedTableServerId == null || _submitting)
                                ? null
                                : _shift,
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
