import 'package:flutter/material.dart';
import '../theme/tokens.dart';

class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: AppControlSizes.sheetHandleWidth,
      height: AppControlSizes.sheetHandleHeight,
      decoration: BoxDecoration(
        color: context.palette.ink30,
        borderRadius:
            BorderRadius.circular(AppControlSizes.sheetHandleHeight / 2),
      ),
    );
  }
}
