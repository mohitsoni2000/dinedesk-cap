// Merge / split sheet — combines two adjacent tables into one or splits a
// merged table back to individuals.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_glass_surface.dart';

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
  final Set<String> _picked = {};

  @override
  Widget build(BuildContext context) {
    final tables = ref.watch(tablesProvider);
    final candidates = tables.where((t) =>
      t.id != widget.origin.id &&
      (t.state == TableState.free || t.state == TableState.dirty)
    ).toList();

    final extraSeats = candidates
      .where((t) => _picked.contains(t.id))
      .fold<int>(0, (s, t) => s + t.seats);
    final newSeats = widget.origin.seats + extraSeats;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => LiquidGlassSurface(
        blur: 30, thickness: 14,
        borderRadius: const BorderRadius.vertical(top: AppRadii.lg),
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(width: 40, height: 4,
              decoration: BoxDecoration(color: AppColors.ink30, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Merge with ${widget.origin.id}', style: AppTypography.title),
                      const SizedBox(height: 2),
                      Text(
                        '${widget.origin.seats} seats → $newSeats seats',
                        style: AppTypography.caption,
                      ),
                    ],
                  )),
                  LiquidPill(
                    tint: AppColors.amber,
                    child: Text('${_picked.length} picked'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Divider(height: 1, color: AppColors.ink10),
            Expanded(
              child: candidates.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No free tables nearby to merge.',
                        style: AppTypography.caption, textAlign: TextAlign.center),
                    ),
                  )
                : ListView.separated(
                    controller: scroll,
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 8),
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemCount: candidates.length,
                    itemBuilder: (_, i) {
                      final t = candidates[i];
                      final on = _picked.contains(t.id);
                      return GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() {
                            if (on) {
                              _picked.remove(t.id);
                            } else {
                              _picked.add(t.id);
                            }
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          decoration: BoxDecoration(
                            color: on ? AppColors.ink : Colors.white.withValues(alpha: 0.6),
                            borderRadius: const BorderRadius.all(AppRadii.md),
                            border: Border.all(color: on ? AppColors.ink : AppColors.ink10),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 36, height: 36,
                                decoration: BoxDecoration(
                                  color: (on ? Colors.white : AppColors.terra400).withValues(alpha: on ? 0.15 : 0.10),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(Icons.table_restaurant_outlined,
                                  size: 18,
                                  color: on ? Colors.white : AppColors.terra600),
                              ),
                              const SizedBox(width: 12),
                              Expanded(child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(t.id, style: AppTypography.bodyMd.copyWith(
                                    color: on ? Colors.white : AppColors.ink,
                                    fontWeight: FontWeight.w600,
                                  )),
                                  Text('${t.seats} seats · ${t.state.name}',
                                    style: AppTypography.caption.copyWith(
                                      color: on ? Colors.white.withValues(alpha: 0.7) : AppColors.ink70,
                                    )),
                                ],
                              )),
                              Icon(
                                on ? Icons.check_circle : Icons.radio_button_unchecked,
                                color: on ? Colors.white : AppColors.ink30,
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
                AppSpacing.lg, AppSpacing.lg + MediaQuery.of(context).viewPadding.bottom),
              child: Row(
                children: [
                  Expanded(child: LiquidSecondaryButton(
                    label: 'Split back',
                    leadingIcon: Icons.call_split,
                    onPressed: () => Navigator.of(context).pop(),
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: LiquidPrimaryButton(
                    label: 'Merge',
                    fullWidth: true,
                    leadingIcon: Icons.merge_type,
                    onPressed: _picked.isEmpty ? null : () {
                      HapticFeedback.heavyImpact();
                      final list = ref.read(tablesProvider);
                      ref.read(tablesProvider.notifier).state = [
                        for (final t in list)
                          if (t.id == widget.origin.id)
                            RestaurantTable(
                              id: t.id, serverId: t.serverId,
                              seats: newSeats, floor: t.floor,
                              state: TableState.mine,
                              waiterName: t.waiterName, coverCount: t.coverCount,
                              bill: t.bill, note: 'Merged with ${_picked.join(", ")}',
                            )
                          else if (_picked.contains(t.id))
                            null
                          else t,
                      ].whereType<RestaurantTable>().toList();
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
