

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../services/pin_guard.dart';
import '../theme/tokens.dart';
import 'liquid_chrome.dart';
import 'liquid_glass_surface.dart';
import 'sheet_handle.dart';

class TableLinkSheet extends ConsumerStatefulWidget {
  final RestaurantTable origin;
  const TableLinkSheet({super.key, required this.origin});

  @override
  ConsumerState<TableLinkSheet> createState() => _TableLinkSheetState();

  static Future<void> show(BuildContext context, RestaurantTable origin) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => TableLinkSheet(origin: origin),
    );
  }
}

class _TableLinkSheetState extends ConsumerState<TableLinkSheet> {
  String? _pickedServerId;
  bool _submitting = false;

  String? _currentGroupId(Map<String, List<String>> groups) {
    for (final entry in groups.entries) {
      if (entry.value.contains(widget.origin.serverId)) return entry.key;
    }
    return null;
  }

  Future<void> _link() async {
    final picked = _pickedServerId;
    if (picked == null || _submitting) return;

    final pinOk = await requirePinIfNeeded(context, ref, 'table_shift');
    if (!pinOk || !mounted) return;

    setState(() => _submitting = true);
    HapticFeedback.heavyImpact();

    final response = await ref.read(socketServiceProvider).emitAck(
      'table:link',
      {
        'table_a_id': widget.origin.serverId,
        'table_b_id': picked,
      },
    );

    if (!mounted) return;
    setState(() => _submitting = false);

    if (response['kind'] == 'error') {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          backgroundColor: AppColors.danger,
          content: Text(
            response['message']?.toString() ?? 'Link failed',
          ),
        ));
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _unlink() async {
    if (_submitting) return;

    final pinOk = await requirePinIfNeeded(context, ref, 'table_shift');
    if (!pinOk || !mounted) return;

    setState(() => _submitting = true);
    HapticFeedback.heavyImpact();

    final response = await ref.read(socketServiceProvider).emitAck(
      'table:unlink',
      {'table_id': widget.origin.serverId},
    );

    if (!mounted) return;
    setState(() => _submitting = false);

    if (response['kind'] == 'error') {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          backgroundColor: AppColors.danger,
          content: Text(
            response['message']?.toString() ?? 'Unlink failed',
          ),
        ));
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final selectedFill = palette.isDark ? AppColors.terra600 : AppColors.ink;
    final tables = ref.watch(tablesProvider);
    final linkGroups = ref.watch(linkGroupsProvider);
    final currentGroupId = _currentGroupId(linkGroups);
    final isLinked = currentGroupId != null;

    final linkedPeerIds = isLinked
        ? (linkGroups[currentGroupId] ?? [])
            .where((id) => id != widget.origin.serverId)
            .toList()
        : <String>[];
    final linkedPeers = tables
        .where((t) => linkedPeerIds.contains(t.serverId))
        .toList();

    final candidates = tables
        .where((t) =>
            t.serverId != widget.origin.serverId &&
            (t.state == TableState.mine || t.state == TableState.other) &&
            !linkedPeerIds.contains(t.serverId))
        .toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => LiquidGlassSurface(
        blur: 30,
        thickness: 14,
        borderRadius: const BorderRadius.vertical(top: AppRadii.lg),
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            const SizedBox(height: 8),
            const SheetHandle(),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Link ${widget.origin.id}',
                            style: AppTypography.title),
                        const SizedBox(height: 2),
                        Text(
                          isLinked
                              ? 'Linked with ${linkedPeers.map((t) => t.id).join(", ")}'
                              : 'Connect to another occupied table',
                          style: AppTypography.caption,
                        ),
                      ],
                    ),
                  ),
                  if (isLinked)
                    LiquidPill(
                      tint: AppColors.info,
                      child: const Text('Linked'),
                    )
                  else if (_pickedServerId != null)
                    LiquidPill(
                      tint: AppColors.success,
                      child: const Text('Selected'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Divider(height: 1, color: palette.ink10),

            if (isLinked && linkedPeers.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, 12, AppSpacing.lg, 0),
                child: Row(
                  children: [
                    const Icon(Icons.link, size: 14, color: AppColors.info),
                    const SizedBox(width: 6),
                    Text('Currently linked',
                        style: AppTypography.caption
                            .copyWith(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              for (final peer in linkedPeers)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, 0, AppSpacing.lg, 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.info.withValues(alpha: 0.08),
                      borderRadius: const BorderRadius.all(AppRadii.md),
                      border: Border.all(
                          color: AppColors.info.withValues(alpha: 0.24)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: AppColors.info.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.table_restaurant_outlined,
                              size: 16, color: AppColors.info),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(peer.id,
                                  style: AppTypography.bodyMd.copyWith(
                                    fontWeight: FontWeight.w600,
                                  )),
                              Text('${peer.seats} seats · ${peer.floor}',
                                  style: AppTypography.caption),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Divider(height: 1, color: palette.ink10),
            ],

            Expanded(
              child: candidates.isEmpty && !isLinked
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No occupied tables available to link.',
                            style: AppTypography.caption,
                            textAlign: TextAlign.center),
                      ),
                    )
                  : candidates.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('No more tables to link.',
                                style: AppTypography.caption,
                                textAlign: TextAlign.center),
                          ),
                        )
                      : ListView.separated(
                          controller: scroll,
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.lg, vertical: 8),
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemCount: candidates.length,
                          itemBuilder: (_, i) {
                            final t = candidates[i];
                            final on = _pickedServerId == t.serverId;
                            return GestureDetector(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() =>
                                    _pickedServerId = on ? null : t.serverId);
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 14),
                                decoration: BoxDecoration(
                                  color: on
                                      ? selectedFill
                                      : palette.isDark
                                          ? Colors.white
                                              .withValues(alpha: 0.08)
                                          : Colors.white
                                              .withValues(alpha: 0.6),
                                  borderRadius:
                                      const BorderRadius.all(AppRadii.md),
                                  border: Border.all(
                                      color:
                                          on ? selectedFill : palette.ink10),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                        color: (on
                                                ? Colors.white
                                                : AppColors.info)
                                            .withValues(alpha: 0.12),
                                        borderRadius:
                                            BorderRadius.circular(10),
                                      ),
                                      child: Icon(
                                          Icons.table_restaurant_outlined,
                                          size: 18,
                                          color: on
                                              ? Colors.white
                                              : AppColors.info),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(t.id,
                                              style: AppTypography.bodyMd
                                                  .copyWith(
                                                color: on
                                                    ? Colors.white
                                                    : palette.ink,
                                                fontWeight: FontWeight.w600,
                                              )),
                                          Text(
                                              '${t.seats} seats · ${t.floor}',
                                              style: AppTypography.caption
                                                  .copyWith(
                                                color: on
                                                    ? Colors.white
                                                        .withValues(alpha: 0.7)
                                                    : palette.ink70,
                                              )),
                                        ],
                                      ),
                                    ),
                                    Icon(
                                      on
                                          ? Icons.check_circle
                                          : Icons.radio_button_unchecked,
                                      color:
                                          on ? Colors.white : palette.ink30,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg + MediaQuery.of(context).viewPadding.bottom,
              ),
              child: isLinked
                  ? Row(
                      children: [
                        Expanded(
                          child: LiquidSecondaryButton(
                            label: 'Cancel',
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: LiquidPrimaryButton(
                            label: _submitting ? 'Unlinking…' : 'Unlink',
                            fullWidth: true,
                            leadingIcon: Icons.link_off,
                            onPressed: _submitting ? null : _unlink,
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: LiquidSecondaryButton(
                            label: 'Cancel',
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: LiquidPrimaryButton(
                            label: _submitting ? 'Linking…' : 'Link Tables',
                            fullWidth: true,
                            leadingIcon: Icons.link,
                            onPressed:
                                (_pickedServerId == null || _submitting)
                                    ? null
                                    : _link,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
