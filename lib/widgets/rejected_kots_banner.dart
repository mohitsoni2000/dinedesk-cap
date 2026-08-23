import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/rejected_kots.dart';
import '../motion/motion.dart';
import '../services/kot_queue_service.dart';
import '../theme/tokens.dart';

class RejectedKotsBanner extends ConsumerWidget {
  final Widget child;
  const RejectedKotsBanner({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rejected = ref.watch(rejectedKotsProvider);
    if (rejected.isEmpty) return child;

    return Stack(
      children: [
        child,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _RejectedBar(
                count: rejected.length,
                onTap: () => _openSheet(context),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static void _openSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const RejectedKotsSheet(),
    );
  }
}

class _RejectedBar extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _RejectedBar({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = count == 1
        ? '1 KOT never reached the kitchen'
        : '$count KOTs never reached the kitchen';

    return Pressable(
      onTap: onTap,
      semanticLabel: '$label. Open for details.',
      child: Container(
        constraints: const BoxConstraints(
          minHeight: AppTouchTargets.minimum,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.danger,
          borderRadius: const BorderRadius.all(AppRadii.md),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: AppTypography.bodyMd.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: Colors.white, size: 20),
          ],
        ),
      ),
    );
  }
}

class RejectedKotsSheet extends ConsumerWidget {
  const RejectedKotsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rejected = ref.watch(rejectedKotsProvider);
    final palette = context.palette;

    return Container(
      decoration: BoxDecoration(
        color: palette.elevated,
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Not sent to the kitchen',
                style: AppTypography.sheetTitle.copyWith(color: palette.ink)),
            const SizedBox(height: 6),
            Text(
              'The desk refused these rounds. Re-enter them, or tell the '
              'kitchen directly — then acknowledge below.',
              style: AppTypography.caption.copyWith(color: palette.ink70),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: rejected.length,
                separatorBuilder: (_, __) =>
                    Divider(height: 16, color: palette.ink10),
                itemBuilder: (_, i) => _RejectedRow(rejected: rejected[i]),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: Pressable(
                semanticLabel: 'Acknowledge and clear',
                onTap: () async {
                  await ref
                      .read(rejectedKotsProvider.notifier)
                      .acknowledgeAll();
                  if (context.mounted) Navigator.of(context).pop();
                },
                child: Container(
                  constraints: const BoxConstraints(
                    minHeight: AppTouchTargets.cta,
                  ),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: palette.ink,
                    borderRadius: const BorderRadius.all(AppRadii.md),
                  ),
                  child: Text(
                    'I have handled these',
                    style: AppTypography.bodyMd.copyWith(
                      color: palette.paper,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RejectedRow extends ConsumerWidget {
  final RejectedKot rejected;
  const _RejectedRow({required this.rejected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final orderId = rejected.payload['order_id']?.toString() ?? '';

    final order = ref
        .watch(activeOrdersProvider)
        .where((o) => o.id == orderId)
        .firstOrNull;
    final slot = order == null
        ? null
        : (order.roomId.isNotEmpty ? order.roomId : order.tableId);

    final at = rejected.rejectedAt;
    final time = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                slot != null && slot.isNotEmpty
                    ? slot
                    : (order?.orderNumber.isNotEmpty == true
                        ? 'Order ${order!.orderNumber}'
                        : 'Order ${_short(orderId)}'),
                style: AppTypography.bodyMd
                    .copyWith(color: palette.ink, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(rejected.reason,
                  style:
                      AppTypography.caption.copyWith(color: AppColors.danger)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Text(time, style: AppTypography.caption.copyWith(color: palette.ink50)),
      ],
    );
  }

  static String _short(String id) =>
      id.length <= 8 ? id : '…${id.substring(id.length - 6)}';
}
