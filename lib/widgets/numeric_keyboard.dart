// Custom numeric keyboard — used for covers, qty, payment amount.
//
// Glass keys, haptic press, configurable on-submit + decimal mode.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tokens.dart';
import 'liquid_glass_surface.dart';

class NumericKeyboard extends StatelessWidget {
  final void Function(String value) onChanged;
  final VoidCallback? onSubmit;
  final String value;
  final bool allowDecimal;
  final String submitLabel;

  const NumericKeyboard({
    super.key,
    required this.value,
    required this.onChanged,
    this.onSubmit,
    this.allowDecimal = false,
    this.submitLabel = 'Done',
  });

  void _press(String k) {
    HapticFeedback.selectionClick();
    if (k == 'del') {
      if (value.isEmpty) return;
      onChanged(value.substring(0, value.length - 1));
    } else if (k == '.') {
      if (!value.contains('.')) onChanged(value.isEmpty ? '0.' : '$value.');
    } else {
      // Strip leading zero unless we're entering a decimal.
      if (value == '0') {
        onChanged(k);
      } else {
        onChanged('$value$k');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      [allowDecimal ? '.' : '', '0', 'del'],
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  for (final k in row) Expanded(child: _key(k)),
                ],
              ),
            ),
          if (onSubmit != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: GestureDetector(
                onTap: () { HapticFeedback.mediumImpact(); onSubmit!(); },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [AppColors.terra400, AppColors.terra600],
                    ),
                    borderRadius: BorderRadius.all(AppRadii.md),
                    boxShadow: AppShadows.terraGlow,
                  ),
                  child: Center(
                    child: Text(
                      submitLabel,
                      style: AppTypography.bodyMd.copyWith(
                        color: Colors.white, fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _key(String k) {
    if (k.isEmpty) return const SizedBox(height: 56);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: LiquidGlassSurface(
        borderRadius: const BorderRadius.all(AppRadii.md),
        padding: const EdgeInsets.symmetric(vertical: 16),
        blur: 18,
        thickness: 8,
        onTap: () => _press(k),
        child: Center(
          child: k == 'del'
              ? const Icon(Icons.backspace_outlined, color: AppColors.ink)
              : Text(
                  k,
                  style: AppTypography.headline.copyWith(fontWeight: FontWeight.w500),
                ),
        ),
      ),
    );
  }
}
