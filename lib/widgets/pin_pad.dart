// Shared PIN numeric pad widget used by auth_screen and pin_verify_sheet.
//
// Keys: 1-9, 0, del, submit.
// Row vertical padding is configurable via [rowVerticalPadding] to allow
// the auth screen (more space) and verify sheet (compact) to tune sizing.

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'liquid_glass_surface.dart';

class PinPad extends StatelessWidget {
  final void Function(String key) onKeyPress;
  final VoidCallback? onSubmit;
  final VoidCallback onDelete;

  /// Vertical padding applied to each key row. Defaults to 6 (auth screen).
  final double rowVerticalPadding;

  /// Vertical padding inside each key cell. Defaults to 18 (auth screen).
  final double keyVerticalPadding;

  const PinPad({
    super.key,
    required this.onKeyPress,
    this.onSubmit,
    required this.onDelete,
    this.rowVerticalPadding = 6,
    this.keyVerticalPadding = 18,
  });

  static const _keys = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['submit', '0', 'del'],
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final row in _keys)
          Padding(
            padding: EdgeInsets.symmetric(vertical: rowVerticalPadding),
            child: Row(
              children: [
                for (final k in row) Expanded(child: _buildKey(k)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildKey(String k) {
    if (k == 'submit') {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: LiquidGlassSurface(
          borderRadius: const BorderRadius.all(AppRadii.md),
          variant: LiquidGlassVariant.terra,
          padding: EdgeInsets.symmetric(vertical: keyVerticalPadding),
          onTap: onSubmit,
          child: const Center(
            child: Icon(Icons.arrow_forward_rounded, color: AppColors.terra600),
          ),
        ),
      );
    }
    if (k == 'del') {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: LiquidGlassSurface(
          borderRadius: const BorderRadius.all(AppRadii.md),
          padding: EdgeInsets.symmetric(vertical: keyVerticalPadding),
          onTap: onDelete,
          child: const Center(
            child: Icon(Icons.backspace_outlined, color: AppColors.ink),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: LiquidGlassSurface(
        borderRadius: const BorderRadius.all(AppRadii.md),
        padding: EdgeInsets.symmetric(vertical: keyVerticalPadding),
        onTap: () => onKeyPress(k),
        child: Center(
          child: Text(k, style: AppTypography.headline),
        ),
      ),
    );
  }
}
