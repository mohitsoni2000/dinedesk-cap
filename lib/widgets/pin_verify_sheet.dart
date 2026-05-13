// PIN Re-verification Sheet — confirms the operator's identity before
// sensitive actions like KOT send, cancel order, bill generation, payment.
//
// Returns true if PIN verified, false if cancelled.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/pin_pad.dart';

class PinVerifySheet {
  /// Opens the PIN verification bottom sheet.
  /// [action] describes what action requires verification (displayed to user).
  /// Returns true if PIN verified, false if dismissed/cancelled.
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
  };

  String get _actionLabel =>
      _actionLabels[widget.action] ?? widget.action;

  void _press(String key) {
    if (_submitting) return;
    setState(() {
      _error = null;
      if (_pin.length < 6) {
        _pin.add(key);
      }
    });
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
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;

    return LiquidGlassSurface(
      blur: 30,
      thickness: 14,
      borderRadius: const BorderRadius.vertical(top: AppRadii.lg),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottomPad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.ink30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Lock icon.
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.terra500.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.lock_outline,
                color: AppColors.terra600, size: 24),
          ),
          const SizedBox(height: 12),

          const Text('Verify PIN', style: AppTypography.title),
          const SizedBox(height: 4),
          Text(
            'Enter your PIN to $_actionLabel',
            style: AppTypography.caption,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),

          // PIN dots.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(6, (i) {
              final filled = i < _pin.length;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.symmetric(horizontal: 6),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled ? AppColors.terra500 : Colors.transparent,
                  border: Border.all(
                    color: filled ? AppColors.terra500 : AppColors.ink30,
                    width: 1.5,
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 6),
          Text('4\u20136 digit PIN',
              style: AppTypography.micro.copyWith(letterSpacing: 1.4)),

          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: AppTypography.caption.copyWith(color: AppColors.danger)),
          ],

          const SizedBox(height: 16),

          // Numeric pad — compact sizing (rowVerticalPadding: 5, keyVerticalPadding: 16).
          PinPad(
            onKeyPress: _press,
            onSubmit: _verify,
            onDelete: _delete,
            rowVerticalPadding: 5,
            keyVerticalPadding: 16,
          ),

          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => Navigator.of(context).pop(false),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('Cancel',
                  style: AppTypography.bodyMd.copyWith(color: AppColors.ink70)),
            ),
          ),
        ],
      ),
    );
  }
}
