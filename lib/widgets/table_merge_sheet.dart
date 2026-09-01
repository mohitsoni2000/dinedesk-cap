import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../services/pin_guard.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'dynamic_toast.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

class TableMergeSheet extends ConsumerStatefulWidget {
  final RestaurantTable origin;
  const TableMergeSheet({super.key, required this.origin});

  @override
  ConsumerState<TableMergeSheet> createState() => _TableMergeSheetState();

  static Future<void> show(BuildContext context, RestaurantTable origin) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => TableMergeSheet(origin: origin),
    );
  }
}

class _TableMergeSheetState extends ConsumerState<TableMergeSheet> {
  String? _pickedServerId;
  bool _submitting = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final tables = ref.watch(tablesProvider);

    final candidates = tables
        .where((t) =>
            t.serverId != widget.origin.serverId &&
            (t.state == TableState.mine || t.state == TableState.other))
        .toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                      child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Merge into ${widget.origin.id}',
                          style: AppTypography.sheetTitle),
                      const SizedBox(height: 2),
                      const Text(
                        'Pick a table to absorb into this one',
                        style: AppTypography.caption,
                      ),
                    ],
                  )),
                  if (_pickedServerId != null)
                    const LiquidPill(
                      tint: AppColors.amber,
                      child: Text('1 selected'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Divider(height: 1, color: context.palette.hairline),
            Expanded(
              child: candidates.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No free tables nearby to merge.',
                            style: AppTypography.caption,
                            textAlign: TextAlign.center),
                      ),
                    )
                  : ListView.separated(
                      controller: scroll,
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg, vertical: 8),
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemCount: candidates.length,
                      itemBuilder: (_, i) {
                        final t = candidates[i];
                        final on = _pickedServerId == t.serverId;
                        return GestureDetector(
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() {
                              _pickedServerId = on ? null : t.serverId;
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 14),
                            decoration: BoxDecoration(
                              color: on
                                  ? context.palette.terraSoft
                                  : palette.surface,
                              borderRadius: const BorderRadius.all(AppRadii.md),
                              border: Border.all(
                                  color: on
                                      ? AppColors.terra
                                      : context.palette.hairline,
                                  width: on ? 1.5 : 1),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: AppColors.terra
                                        .withValues(alpha: on ? 0.18 : 0.10),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(Icons.table_restaurant_outlined,
                                      size: 18,
                                      color: on
                                          ? AppColors.terraDeep
                                          : AppColors.terra),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(t.id,
                                        style: AppTypography.bodyMd.copyWith(
                                          color: on
                                              ? AppColors.terraDeep
                                              : palette.ink,
                                          fontWeight: FontWeight.w600,
                                        )),
                                    Text('${t.seats} seats · ${t.state.name}',
                                        style: AppTypography.caption.copyWith(
                                          color: on
                                              ? AppColors.terraInk
                                              : palette.ink70,
                                        )),
                                  ],
                                )),
                                Icon(
                                  on
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                                  color: on ? AppColors.terra : palette.ink30,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg,
                  AppSpacing.lg, AppSpacing.lg + context.sheetBottomInset),
              child: Row(
                children: [
                  Expanded(
                      child: LiquidSecondaryButton(
                    label: 'Cancel',
                    onPressed: () => Navigator.of(context).pop(),
                  )),
                  const SizedBox(width: 8),
                  Expanded(
                      child: LiquidPrimaryButton(
                    label: _submitting ? 'Merging…' : 'Merge',
                    fullWidth: true,
                    leadingIcon: Icons.merge_type,
                    onPressed: (_pickedServerId == null || _submitting)
                        ? null
                        : () async {
                            final pinOk = await requirePinIfNeeded(
                                context, ref, 'table_merge');
                            if (!pinOk || !mounted) return;
                            setState(() => _submitting = true);
                            unawaited(HapticFeedback.heavyImpact());
                            final response = await ref
                                .read(socketServiceProvider)
                                .emitAck('table:merge', {
                              'primary_table_id': widget.origin.serverId,
                              'absorbed_table_id': _pickedServerId,
                            });
                            if (!mounted) return;
                            setState(() => _submitting = false);
                            if (!context.mounted) return;
                            if (response['kind'] == 'error') {
                              DynamicToast.show(context,
                                  message: response['message']?.toString() ??
                                      'Merge failed',
                                  kind: ToastKind.error);
                              return;
                            }
                            Navigator.of(context).pop();
                          },
                  )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
