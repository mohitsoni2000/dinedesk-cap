import 'package:flutter/material.dart';
import '../theme/tokens.dart';

/// Standard bottom-sheet drag handle.
///
/// Single source of truth — this exact Container was previously copy-pasted
/// into every sheet. Size and color come from design tokens.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: AppControlSizes.sheetHandleWidth,
      height: AppControlSizes.sheetHandleHeight,
      decoration: BoxDecoration(
        color: AppColors.ink30,
        borderRadius:
            BorderRadius.circular(AppControlSizes.sheetHandleHeight / 2),
      ),
    );
  }
}
