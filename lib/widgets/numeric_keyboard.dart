import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tokens.dart';
import 'pin_pad.dart';

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

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: PinPad.maxWidth),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            children: [
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      for (final k in row) Expanded(child: _key(context, k)),
                    ],
                  ),
                ),
              if (onSubmit != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      onSubmit!();
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: const BoxDecoration(
                        color: AppColors.terra,
                        borderRadius: BorderRadius.all(AppRadii.md),
                        boxShadow: AppShadows.terraGlow,
                      ),
                      child: Center(
                        child: Text(
                          submitLabel,
                          style: AppTypography.bodyMd.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _key(BuildContext context, String k) {
    if (k.isEmpty) return const SizedBox(height: 56);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: _NumKey(
        onTap: () => _press(k),
        child: k == 'del'
            ? Icon(Icons.backspace_outlined, color: context.palette.ink)
            : Text(
                k,
                style: AppTypography.headline
                    .copyWith(fontWeight: FontWeight.w500),
              ),
      ),
    );
  }
}

class _NumKey extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _NumKey({required this.child, required this.onTap});

  @override
  State<_NumKey> createState() => _NumKeyState();
}

class _NumKeyState extends State<_NumKey> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(vertical: 16),
        transform: Matrix4.diagonal3Values(
            _pressed ? 0.96 : 1.0, _pressed ? 0.96 : 1.0, 1.0),
        transformAlignment: Alignment.center,
        decoration: BoxDecoration(
          color: _pressed ? context.palette.terraSoft : context.palette.surface,
          borderRadius: const BorderRadius.all(AppRadii.md),
          border: Border.all(color: context.palette.hairline),
        ),
        child: Center(child: widget.child),
      ),
    );
  }
}
