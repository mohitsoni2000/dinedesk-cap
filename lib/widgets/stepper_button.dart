import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

class StepperButton extends StatefulWidget {
  const StepperButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.repeatOnHold = false,
    this.glass = false,
    this.haptics = true,
  });

  final IconData icon;
  final VoidCallback onTap;

  final bool repeatOnHold;

  final bool glass;

  final bool haptics;

  @override
  State<StepperButton> createState() => _StepperButtonState();
}

class _StepperButtonState extends State<StepperButton> {
  Timer? _timer;

  void _fire() {
    if (widget.haptics) HapticFeedback.selectionClick();
    widget.onTap();
  }

  void _startRepeat() {
    _fire();
    _timer = Timer(const Duration(milliseconds: 500), () {
      _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
        _fire();
      });
    });
  }

  void _stopRepeat() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopRepeat();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visual = widget.glass
        ? Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: context.palette.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: context.palette.hairline),
            ),
            child: Icon(widget.icon,
                size: AppIconSizes.control, color: context.palette.ink),
          )
        : Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: context.palette.surface,
              shape: BoxShape.circle,
              border: Border.all(color: context.palette.hairline),
            ),
            child: Icon(widget.icon,
                size: AppIconSizes.standard, color: context.palette.ink),
          );

    return GestureDetector(
      onTap: _fire,
      onLongPressStart: widget.repeatOnHold ? (_) => _startRepeat() : null,
      onLongPressEnd: widget.repeatOnHold ? (_) => _stopRepeat() : null,
      onLongPressCancel: widget.repeatOnHold ? _stopRepeat : null,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: AppTouchTargets.control,
        height: AppTouchTargets.control,
        child: Center(child: visual),
      ),
    );
  }
}
