import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'pin_pad.dart';
import 'sheet_handle.dart';

class PinVerifySheet {
  static Future<bool?> show(BuildContext context, {required String action}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.42),
      builder: (_) => _PinVerifySheet(action: action),
    );
  }
}

class _PinVerifySheet extends ConsumerStatefulWidget {
  final String action;
  const _PinVerifySheet({required this.action});
  @override
  ConsumerState<_PinVerifySheet> createState() => _PinVerifySheetState();
}

class _PinVerifySheetState extends ConsumerState<_PinVerifySheet> {
  final List<String> _pin = [];
  String? _error;
  bool _submitting = false;

  static const _actionLabels = {
    'kot': 'Send KOT',
    'cancel_order': 'Cancel Order',
    'generate_bill': 'Generate Bill',
    'payment': 'Accept Payment',
    'kot_edit': 'Edit KOT',
    'quick_settle': 'Quick Settle',
    'hold': 'Hold Order',
    'table_shift': 'Shift Table',
    'table_merge': 'Merge Tables',
    'kot_reprint': 'Reprint KOT',
    'bill_reprint': 'Reprint Bill',
    'rename_table': 'Rename Table',
    'resync': 'Resume Session',
  };

  String get _actionLabel => _actionLabels[widget.action] ?? widget.action;

  void _press(String key) {
    if (_submitting) return;
    setState(() {
      _error = null;
      if (_pin.length < 4) {
        _pin.add(key);
      }
    });
    if (_pin.length == 4) {
      Future.delayed(const Duration(milliseconds: 180), _verify);
    }
  }

  void _delete() {
    if (_submitting) return;
    setState(() {
      _error = null;
      if (_pin.isNotEmpty) _pin.removeLast();
    });
  }

  void _verify() {
    if (_pin.length < 4) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    HapticFeedback.mediumImpact();

    final pin = _pin.join();
    final socket = ref.read(socketServiceProvider);
    socket.emit('operator:verify', {'pin': pin}, onAck: (response) {
      if (!mounted) return;
      if (response['kind'] == 'success') {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _submitting = false;
          _error = response['message']?.toString() ?? 'Invalid PIN';
          _pin.clear();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = context.sheetBottomInset;

    return AppSurface(
      borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
      padding: EdgeInsets.zero,
      // The keypad alone is ~270px, so on a short viewport this content can
      // outgrow the sheet. Scrolling costs nothing at normal heights — the
      // content simply doesn't reach the scroll threshold.
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottomPad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: const SheetHandle(),
            ),
            const SizedBox(height: 16),
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: context.palette.terraSoft,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.lock_outline,
                  color: AppColors.terraDeep, size: 24),
            ),
            const SizedBox(height: 12),
            const Text('Verify PIN', style: AppTypography.sheetTitle),
            const SizedBox(height: 4),
            Text(
              'Enter your PIN to $_actionLabel',
              style: AppTypography.caption,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (i) {
                final filled = i < _pin.length;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled ? AppColors.terra : Colors.transparent,
                    border: Border.all(
                      color: filled ? AppColors.terra : context.palette.ink30,
                      width: 1.5,
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 6),
            Text('4-digit PIN',
                style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style:
                      AppTypography.caption.copyWith(color: AppColors.danger)),
            ],
            const SizedBox(height: 16),
            PinPad(
              onKeyPress: _press,
              onForgot: () => showForgotPinDialog(context),
              onDelete: _delete,
              enabled: !_submitting,
              rowVerticalPadding: 5,
              keyVerticalPadding: 16,
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(false),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('Cancel',
                    style: AppTypography.bodyMd
                        .copyWith(color: context.palette.ink70)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
