

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

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
    return AppSurface(
      borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
      padding: EdgeInsets.fromLTRB(
          20, 12, 20, 28 + MediaQuery.of(context).viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: const SheetHandle(),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: context.palette.tableFreeBg,
                  borderRadius: const BorderRadius.all(AppRadii.xs),
                  border: Border.all(
                      color: AppColors.success.withValues(alpha: 0.32)),
                ),
                child: Text(widget.table.id,
                    style: AppTypography.caption
                        .copyWith(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              const Text('How many guests?', style: AppTypography.sheetTitle),
            ],
          ),
          const SizedBox(height: 4),
          Text('${widget.table.seats} seats available',
              style: AppTypography.caption),
          const SizedBox(height: 24),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StepperBtn(
                  icon: Icons.remove,
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
                    color: overSeated ? AppColors.warn : context.palette.ink,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              _StepperBtn(
                  icon: Icons.add,
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

          Wrap(
            spacing: 8,
            runSpacing: 8,
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
  const _StepperBtn(
      {required this.icon, required this.onTap, required this.enabled});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: enabled ? AppColors.terra : context.palette.ink05,
          shape: BoxShape.circle,
          boxShadow: enabled ? AppShadows.terraGlow : null,
        ),
        child: Icon(icon,
            color: enabled ? Colors.white : context.palette.ink30, size: 22),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip(
      {required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? context.palette.terraSoft : palette.surface,
          borderRadius: const BorderRadius.all(AppRadii.pill),
          border: Border.all(
              color: selected ? AppColors.terra : context.palette.hairline,
              width: selected ? 1.5 : 1),
        ),
        child: Text(label,
            style: AppTypography.bodyMd.copyWith(
              color: selected ? AppColors.terraDeep : palette.ink,
              fontWeight: FontWeight.w600,
            )),
      ),
    );
  }
}
