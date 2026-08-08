

import 'package:flutter/material.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';

class LiquidBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<LiquidNavItem> items;
  const LiquidBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.navBar,
        // The hairline separates the bar from the content. It used to also
        // cast a 20px upward shadow over whatever was scrolling beneath it.
        border: Border(top: BorderSide(color: palette.navHairline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              for (int i = 0; i < items.length; i++)
                Expanded(
                  child: Pressable(
                    onTap: () => onTap(i),
                    pressedScale: 0.88,
                    child: SpringBuilder(
                      to: i == currentIndex ? 1.0 : 0.0,
                      spring: RestroSprings.snappy,
                      builder: (BuildContext _, double t, Widget? child) {
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 52,
                              height: 29,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Color.lerp(Colors.transparent,
                                    context.palette.terraSoft, t),
                                borderRadius:
                                    const BorderRadius.all(AppRadii.pill),
                              ),
                              child: Icon(
                                items[i].icon,
                                size: 20,
                                color: Color.lerp(
                                    palette.ink50, AppColors.terraDeep, t),
                              ),
                            ),
                            const SizedBox(height: 3),
                            // Without this a long label like SETTINGS wraps at
                            // large font scales, and since only some tabs wrap
                            // the bar's tabs end up different heights. The
                            // icon above still identifies the tab.
                            Text(
                              items[i].label,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.navLabel.copyWith(
                                color: Color.lerp(
                                    palette.ink50, AppColors.terraDeep, t),
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class LiquidNavItem {
  final IconData icon;
  final String label;
  const LiquidNavItem({required this.icon, required this.label});
}

class LiquidPill extends StatelessWidget {
  final Widget child;
  final Color? tint;
  const LiquidPill({super.key, required this.child, this.tint});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: tint ?? context.palette.surface,
        borderRadius: const BorderRadius.all(AppRadii.pill),
        border: Border.all(color: context.palette.hairline),
      ),
      child: DefaultTextStyle.merge(
        style: AppTypography.caption.copyWith(fontWeight: FontWeight.w600),
        child: child,
      ),
    );
  }
}

class LiquidPrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? leadingIcon;
  final bool fullWidth;
  const LiquidPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.leadingIcon,
    this.fullWidth = false,
  });

  @override
  State<LiquidPrimaryButton> createState() => _LiquidPrimaryButtonState();
}

class _LiquidPrimaryButtonState extends State<LiquidPrimaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTap: widget.onPressed,
      child: SpringBuilder(
        from: 1.0,
        to: _pressed ? 0.97 : 1.0,
        spring: RestroSprings.snappy,
        builder: (BuildContext _, double scale, Widget? child) {
          return Transform.scale(scale: scale, child: child);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            // A flat brand fill, not a vertical terra400→terra600 ramp under
            // a two-layer terra glow.
            color: enabled ? AppColors.terra500 : context.palette.ink10,
            borderRadius: const BorderRadius.all(AppRadii.md),
          ),
          child: Row(
            mainAxisSize:
                widget.fullWidth ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.leadingIcon != null) ...[
                Icon(widget.leadingIcon,
                    color: enabled ? Colors.white : context.palette.ink30,
                    size: 20),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyMd.copyWith(
                        color: enabled ? Colors.white : context.palette.ink30,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LiquidSecondaryButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? leadingIcon;
  const LiquidSecondaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.leadingIcon,
  });

  @override
  State<LiquidSecondaryButton> createState() => _LiquidSecondaryButtonState();
}

class _LiquidSecondaryButtonState extends State<LiquidSecondaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTap: widget.onPressed,
      child: SpringBuilder(
        from: 1.0,
        to: _pressed ? 0.97 : 1.0,
        spring: RestroSprings.snappy,
        builder: (BuildContext _, double scale, Widget? child) {
          return Transform.scale(scale: scale, child: child);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: context.palette.isDark
                ? context.palette.surfaceWarm
                : context.palette.surface,
            borderRadius: const BorderRadius.all(AppRadii.md),
            border: Border.all(
                color: enabled
                    ? (context.palette.isDark
                        ? context.palette.ink30
                        : context.palette.hairline)
                    : context.palette.ink05),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.leadingIcon != null) ...[
                Icon(widget.leadingIcon,
                    color: enabled ? context.palette.ink : context.palette.ink30,
                    size: 20),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyMd.copyWith(
                        fontWeight: FontWeight.w600,
                        color: enabled
                            ? context.palette.ink
                            : context.palette.ink30)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
