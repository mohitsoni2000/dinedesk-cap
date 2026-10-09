import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/currency.dart';
import '../data/providers.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';
import 'stepper_button.dart';

/// One cart line with its quantity steppers, as the review and the counter
/// checkout show it: name, choices, note, unit price, line total, and the
/// line's sync state. [index] is the line's place in [cartProvider].
class CartRow extends ConsumerWidget {
  final CartLine line;
  final int index;
  const CartRow({super.key, required this.line, required this.index});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: VegMark(isVeg: line.item.isVeg),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.item.name, style: AppTypography.bodyMd),
                if (line.mods.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    line.mods.join(' · '),
                    style: AppTypography.caption.copyWith(
                      color: context.palette.ink70,
                    ),
                  ),
                ],
                if (line.itemNote.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    '"${line.itemNote}"',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.terra600,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  formatRupeesCompact(line.item.price + line.modsExtra),
                  style: AppTypography.caption,
                ),
              ],
            ),
          ),
          if (line.item.isWeighed) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: context.palette.ink05,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${line.weight ?? 0} ${line.item.measureUnit ?? ''}',
                style:
                    AppTypography.bodyMd.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ] else ...[
            StepperButton(
              icon: Icons.remove,
              glass: true,
              repeatOnHold: true,
              haptics: false,
              onTap: () {
                ref
                    .read(feedbackServiceProvider)
                    .fire(const FeedbackSelection());
                ref.read(cartProvider.notifier).setQtyAt(index, line.qty - 1);
              },
            ),
            SizedBox(
              width: 32,
              child: Center(
                child: Text(
                  '${line.qty}',
                  style: AppTypography.title.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            StepperButton(
              icon: Icons.add,
              glass: true,
              repeatOnHold: true,
              haptics: false,
              onTap: () {
                ref
                    .read(feedbackServiceProvider)
                    .fire(const FeedbackSelection());
                ref.read(cartProvider.notifier).setQtyAt(index, line.qty + 1);
              },
            ),
          ],
          const SizedBox(width: 12),
          SizedBox(
            width: 70,
            child: Text(
              formatRupeesCompact(line.lineTotal),
              style: AppTypography.title,
              textAlign: TextAlign.right,
            ),
          ),
          if (line.syncStatus == SyncStatus.pending) ...[
            const SizedBox(width: 8),
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ] else if (line.syncStatus == SyncStatus.failed) ...[
            const SizedBox(width: 8),
            const Icon(
              Icons.warning_amber_rounded,
              size: 16,
              color: AppColors.warn,
            ),
          ],
        ],
      ),
    );
  }
}

/// The veg / non-veg mark (green or red dot in a square).
class VegMark extends StatelessWidget {
  final bool isVeg;
  const VegMark({super.key, required this.isVeg});
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
