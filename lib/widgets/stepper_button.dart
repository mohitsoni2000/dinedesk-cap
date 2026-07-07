import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import 'liquid_glass_surface.dart';

/// Shared quantity stepper button (+ / −).
///
/// One implementation for every qty control in the app — previously the
/// review screen and item-detail sheet each had their own copy with
/// different hit areas. Guarantees the AppTouchTargets.control (48px)
/// touch target regardless of visual size.
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

  /// Keep firing while held: 500ms threshold, then every 150ms.
  final bool repeatOnHold;

  /// Frosted-glass look (cart rows) vs solid white circle (sheets).
  final bool glass;

  /// Disable when the caller already fires its own feedback per tap.
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
        ? LiquidGlassSurface(
            borderRadius: BorderRadius.circular(14),
            blur: 14,
            thickness: 6,
            skipBlur: true, // tiny surface — backdrop blur is pure GPU cost
            child: SizedBox(
              width: 30,
              height: 30,
              child: Center(
                child: Icon(widget.icon,
                    size: AppIconSizes.control, color: AppColors.ink),
              ),
            ),
          )
        : Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.7),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.ink10),
            ),
            child: Icon(widget.icon,
                size: AppIconSizes.standard, color: AppColors.ink),
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
