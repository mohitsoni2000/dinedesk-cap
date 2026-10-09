import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The strip a desk-only screen shows while the desk is away, saying what
/// that means here (the gate cannot verify entries; the counter cannot take
/// a Pay & Fire). The connection pill says the desk is gone; this says what
/// still works without it.
class DeskOfflineStrip extends StatelessWidget {
  const DeskOfflineStrip({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.16),
        borderRadius: const BorderRadius.all(AppRadii.sm),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_outlined, color: AppColors.warn, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTypography.bodyMd.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the counter still does without the desk, for a cashier who may
/// [canCharge] (Pay & Fire) and [canFire] (Fire KOT, pay at pickup). Money
/// never queues; an order fired to be paid at pickup does.
String counterOfflineMessage({required bool canCharge, required bool canFire}) {
  if (canCharge && canFire) {
    return 'Desk unreachable – Pay & Fire waits for the desk; Fire KOT still '
        'goes, queued on this phone';
  }
  if (canCharge) {
    return 'Desk unreachable – Pay & Fire waits for the desk. Park the cart '
        'and charge it when the desk is back';
  }
  if (canFire) {
    return 'Desk unreachable – orders still go: they queue on this phone and '
        'send when the desk is back';
  }
  return 'Desk unreachable – nothing can be charged until it is back';
}
