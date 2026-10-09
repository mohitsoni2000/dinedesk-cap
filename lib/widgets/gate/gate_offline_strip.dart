import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// The gate's "no desk" strip. The desk is the only authority on a ticket,
/// so without it nothing is sold or checked in; there is no local fallback.
class GateOfflineStrip extends StatelessWidget {
  const GateOfflineStrip({
    super.key,
    this.message = "Desk unreachable – can't verify entries",
  });

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
