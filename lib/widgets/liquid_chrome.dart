// Reusable liquid-glass chrome: app bar, bottom nav, pills, FAB.

import 'package:flutter/material.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';
import 'liquid_glass_surface.dart';

/// Top app bar with liquid glass background.
class LiquidAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final Widget? leading;
  final List<Widget> actions;
  const LiquidAppBar({
    super.key,
    required this.title,
    this.leading,
    this.actions = const [],
  });

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: LiquidGlassSurface(
        borderRadius: const BorderRadius.all(AppRadii.md),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        blur: 24,
        thickness: 10,
        child: Row(
          children: [
            if (leading != null) leading!,
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: AppTypography.title, overflow: TextOverflow.ellipsis),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// Floating bottom navigation bar with sliding pill indicator.
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
    // Active pill: ink reads as near-black in light mode but vanishes against
    // dark surfaces — use terra as the active fill in dark (white fg works on both).
    final activeFill = palette.isDark ? AppColors.terra600 : AppColors.ink;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: LiquidGlassSurface(
        borderRadius: const BorderRadius.all(AppRadii.lg),
        padding: const EdgeInsets.all(6),
        blur: 28,
        thickness: 14,
        child: Row(
          children: [
            for (int i = 0; i < items.length; i++)
              Expanded(
                child: GestureDetector(
                  onTap: () => onTap(i),
                  child: SpringBuilder(
                    to: i == currentIndex ? 1.0 : 0.0,
                    spring: RestroSprings.snappy,
                    builder: (BuildContext _, double t, Widget? child) {
                      return Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color:
                              Color.lerp(Colors.transparent, activeFill, t),
                          borderRadius: const BorderRadius.all(AppRadii.sm),
                        ),
                        child: child,
                      );
                    },
                    child: Column(
                      children: [
                        Icon(
                          items[i].icon,
                          size: 22,
                          color: i == currentIndex
                              ? Colors.white
                              : palette.ink70,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          items[i].label,
                          style: AppTypography.micro.copyWith(
                            color: i == currentIndex
                                ? Colors.white
                                : palette.ink50,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
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

/// Small status pill (connection, badges, status chips).
class LiquidPill extends StatelessWidget {
  final Widget child;
  final Color? tint;
  const LiquidPill({super.key, required this.child, this.tint});

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      borderRadius: const BorderRadius.all(AppRadii.pill),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      blur: 18,
      thickness: 8,
      skipBlur: true, // chip-sized — real backdrop blur is GPU cost for nothing
      tint: tint,
      child: DefaultTextStyle.merge(
        style: AppTypography.caption.copyWith(fontWeight: FontWeight.w600),
        child: child,
      ),
    );
  }
}

/// Primary CTA — solid terra with rim-light treatment and press feedback.
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
            gradient: enabled
                ? const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [AppColors.terra400, AppColors.terra600],
                  )
                : null,
            color: enabled ? null : context.palette.ink10,
            borderRadius: const BorderRadius.all(AppRadii.md),
            boxShadow: enabled ? AppShadows.terraGlow : null,
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

/// Secondary / ghost — translucent liquid glass with press feedback.
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
        child: LiquidGlassSurface(
          borderRadius: const BorderRadius.all(AppRadii.md),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          blur: 16,
          thickness: 8,
          skipBlur: true, // button-sized — skip the saveLayer-forcing blur
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.leadingIcon != null) ...[
                Icon(widget.leadingIcon, color: context.palette.ink, size: 20),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyMd
                        .copyWith(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
