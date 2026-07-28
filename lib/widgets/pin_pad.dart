

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

Future<void> showForgotPinDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: context.palette.surface,
      title: const Text('Forgot your PIN?', style: AppTypography.title),
      content: const Text(
        'Operator PINs live on the admin desktop. Ask your manager to '
        'reset it from Staff → Operators.',
        style: AppTypography.bodyMd,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}

class PinPad extends StatelessWidget {
  final void Function(String key) onKeyPress;
  final VoidCallback onForgot;
  final VoidCallback onDelete;

  final double rowVerticalPadding;

  final double keyVerticalPadding;

  final bool enabled;

  const PinPad({
    super.key,
    required this.onKeyPress,
    required this.onForgot,
    required this.onDelete,
    this.rowVerticalPadding = 6,
    this.keyVerticalPadding = 18,
    this.enabled = true,
  });

  static const _keys = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['forgot', '0', 'del'],
  ];

  /// Keys are [Expanded], so without a ceiling the pad grows to whatever width
  /// it is handed — on a tablet that means single keys hundreds of points
  /// wide. Clamped here rather than at each call site so every caller gets it.
  static const double maxWidth = 380;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: AnimatedOpacity(
          opacity: enabled ? 1.0 : 0.45,
          duration: const Duration(milliseconds: 180),
          child: IgnorePointer(
            ignoring: !enabled,
            child: Column(
              children: [
                for (final row in _keys)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: rowVerticalPadding),
                    child: Row(
                      children: [
                        for (final k in row)
                          Expanded(child: _buildKey(context, k)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKey(BuildContext context, String k) {
    if (k == 'forgot') {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: _PinKey(
          keyVerticalPadding: keyVerticalPadding,
          onTap: onForgot,
          child: Text('Forgot?',
              style: AppTypography.caption.copyWith(
                fontWeight: FontWeight.w600,
                color: context.palette.ink50,
              )),
        ),
      );
    }
    if (k == 'del') {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: _PinKey(
          keyVerticalPadding: keyVerticalPadding,
          onTap: onDelete,
          child: Icon(Icons.backspace_outlined, color: context.palette.ink),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: _PinKey(
        keyVerticalPadding: keyVerticalPadding,
        onTap: () => onKeyPress(k),
        child: Text(k, style: AppTypography.headline),
      ),
    );
  }
}

class _PinKey extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double keyVerticalPadding;
  const _PinKey({
    required this.child,
    required this.onTap,
    required this.keyVerticalPadding,
  });

  @override
  State<_PinKey> createState() => _PinKeyState();
}

class _PinKeyState extends State<_PinKey> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: EdgeInsets.symmetric(vertical: widget.keyVerticalPadding),
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
