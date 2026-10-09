import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../app_surface.dart';
import '../liquid_chrome.dart';
import '../sheet_handle.dart';

/// Asks for a ticket by hand, for a torn or unreadable QR: the number on the
/// slip (`ET-042`, `42`) or the code under the QR. Returns it trimmed, as
/// typed (the desk reads every form), or null when dismissed.
class ManualTicketSheet {
  static Future<String?> show(BuildContext context) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (_) => const _ManualTicketSheet(),
    );
  }
}

class _ManualTicketSheet extends StatefulWidget {
  const _ManualTicketSheet();

  @override
  State<_ManualTicketSheet> createState() => _ManualTicketSheetState();
}

class _ManualTicketSheetState extends State<_ManualTicketSheet> {
  final TextEditingController _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  void _use() {
    final code = _typed.text.trim();
    if (code.isEmpty) return;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: AppSurface(
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + context.sheetBottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: SheetHandle()),
            const SizedBox(height: 16),
            const Text('Type the ticket', style: AppTypography.sheetTitle),
            const SizedBox(height: 4),
            Text("Today's ticket number (ET-042 or 42), or the code under the QR",
                style: context.palette.caption),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: context.palette.surface,
                borderRadius: const BorderRadius.all(AppRadii.sm),
                border: Border.all(color: context.palette.hairline, width: 1.5),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                key: const ValueKey<String>('manual-ticket-field'),
                controller: _typed,
                autofocus: true,
                maxLength: 64,
                style: AppTypography.title,
                cursorColor: AppColors.terra,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _use(),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: 'ET-042',
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(height: 12),
            LiquidPrimaryButton(
              label: 'Check in',
              leadingIcon: Icons.how_to_reg_outlined,
              fullWidth: true,
              onPressed: _use,
            ),
          ],
        ),
      ),
    );
  }
}
