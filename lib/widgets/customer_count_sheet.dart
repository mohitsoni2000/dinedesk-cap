// Customer Count Sheet — slides up when a free table is tapped.
//
// Operator picks how many guests are seating, then proceeds to the order
// builder. Returns the chosen count or null if cancelled.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/liquid_chrome.dart';

class CustomerCountSheet {
  static Future<int?> show(BuildContext context, RestaurantTable table) {
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => _CustomerCountSheet(table: table),
    );
  }
}

class _CustomerCountSheet extends StatefulWidget {
  final RestaurantTable table;
  const _CustomerCountSheet({required this.table});
  @override
  State<_CustomerCountSheet> createState() => _CustomerCountSheetState();
}

class _CustomerCountSheetState extends State<_CustomerCountSheet> {
  late int _count = (widget.table.seats / 2).ceil().clamp(1, 20);

  void _set(int v) {
    if (v < 1 || v > 20) return;
    HapticFeedback.selectionClick();
    setState(() => _count = v);
  }

  @override
  Widget build(BuildContext context) {
    final overSeated = _count > widget.table.seats;
    return LiquidGlassSurface(
      blur: 30, thickness: 14,
      borderRadius: const BorderRadius.vertical(top: AppRadii.lg),
      padding: EdgeInsets.fromLTRB(20, 12, 20,
        28 + MediaQuery.of(context).viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: AppColors.ink30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.tableFreeBg,
                  borderRadius: const BorderRadius.all(AppRadii.xs),
                  border: Border.all(
                    color: AppColors.success.withValues(alpha: 0.32)),
                ),
                child: Text(widget.table.id,
                  style: AppTypography.caption.copyWith(
                    fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              const Text('How many guests?', style: AppTypography.title),
            ],
          ),
          const SizedBox(height: 4),
          Text('${widget.table.seats} seats available',
            style: AppTypography.caption),
          const SizedBox(height: 24),

          // Big stepper.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StepperBtn(icon: Icons.remove,
                onTap: () => _set(_count - 1),
                enabled: _count > 1),
              const SizedBox(width: 24),
              SizedBox(
                width: 80,
                child: Text(
                  '$_count',
                  textAlign: TextAlign.center,
                  style: AppTypography.displayLg.copyWith(
                    fontSize: 56,
                    color: overSeated ? AppColors.warn : AppColors.ink,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              _StepperBtn(icon: Icons.add,
                onTap: () => _set(_count + 1),
                enabled: _count < 20),
            ],
          ),
          const SizedBox(height: 8),
          if (overSeated)
            Center(
              child: Text(
                'Over capacity — confirm with manager',
                style: AppTypography.caption.copyWith(color: AppColors.warn),
              ),
            ),
          const SizedBox(height: 16),

          // Quick-pick chips.
          Wrap(
            spacing: 8, runSpacing: 8,
            children: [
              for (final n in [1, 2, 3, 4, 5, 6, 8])
                _Chip(
                  label: '$n',
                  selected: _count == n,
                  onTap: () => _set(n),
                ),
            ],
          ),
          const SizedBox(height: 24),

          Row(
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
                  label: 'Start order',
                  fullWidth: true,
                  leadingIcon: Icons.arrow_forward,
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    Navigator.of(context).pop(_count);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepperBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;
  const _StepperBtn({required this.icon, required this.onTap, required this.enabled});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 56, height: 56,
        decoration: BoxDecoration(
          gradient: enabled
            ? const LinearGradient(colors: [AppColors.terra400, AppColors.terra600])
            : null,
          color: enabled ? null : AppColors.ink05,
          shape: BoxShape.circle,
          boxShadow: enabled ? AppShadows.terraGlow : null,
        ),
        child: Icon(icon,
          color: enabled ? Colors.white : AppColors.ink30, size: 22),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : Colors.white.withValues(alpha: 0.6),
          borderRadius: const BorderRadius.all(AppRadii.pill),
          border: Border.all(color: selected ? AppColors.ink : AppColors.ink10),
        ),
        child: Text(label,
          style: AppTypography.bodyMd.copyWith(
            color: selected ? Colors.white : AppColors.ink,
            fontWeight: FontWeight.w600,
          )),
      ),
    );
  }
}
