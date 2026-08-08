

import 'package:flutter/widgets.dart';
import 'springs.dart';

class Pressable extends StatefulWidget {
  const Pressable({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.96,
    this.spring = RestroSprings.snappy,
    this.behavior = HitTestBehavior.opaque,
    this.enabled = true,
    this.semanticLabel,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final SpringDescription spring;
  final HitTestBehavior behavior;
  final bool enabled;

  /// What a screen reader should announce.
  ///
  /// Pressable is the app's universal tappable — buttons, cards, chips, table
  /// tiles, nav items all route through it — and it was a bare
  /// [GestureDetector]. GestureDetector does publish a tap action, so a
  /// screen reader knew something was tappable, but it published no `button`
  /// flag and no label. For anything whose child is text that degrades
  /// gracefully; for an icon-only control it announced nothing usable.
  ///
  /// Leave this null when the child already carries its own text — the label
  /// would be read twice. Set it whenever the meaning lives in an icon.
  final String? semanticLabel;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  /// Stays false until the first press.
  ///
  /// A `SpringBuilder` carries an AnimationController and a ticker. Mounting
  /// one for every Pressable in the tree meant a controller per button, per
  /// card, per glass surface — allocated and disposed again on every scroll
  /// recycle, all to hold the value 1.0. Until a finger lands there is
  /// nothing to spring, so the child is returned bare.
  bool _everPressed = false;

  void _set(bool v) {
    if (_pressed == v) return;
    setState(() {
      _pressed = v;
      if (v) _everPressed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final active =
        widget.enabled && (widget.onTap != null || widget.onLongPress != null);
    final Widget detector = GestureDetector(
      behavior: widget.behavior,
      onTapDown: active ? (_) => _set(true) : null,
      onTapUp: active ? (_) => _set(false) : null,
      onTapCancel: active ? () => _set(false) : null,
      onTap: widget.enabled ? widget.onTap : null,
      onLongPress: widget.enabled ? widget.onLongPress : null,
      child: _everPressed
          ? SpringBuilder(
              from: 1.0,
              to: _pressed ? widget.pressedScale : 1.0,
              spring: widget.spring,
              builder: (_, scale, child) =>
                  Transform.scale(scale: scale, child: child),
              child: widget.child,
            )
          : widget.child,
    );

    // `button: true` so it is announced as a control rather than as loose
    // text, and `enabled` so a disabled one is announced as unavailable
    // instead of silently doing nothing.
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.semanticLabel,
      child: detector,
    );
  }
}
