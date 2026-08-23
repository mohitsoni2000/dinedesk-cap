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

  final String? semanticLabel;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

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

    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.semanticLabel,
      child: detector,
    );
  }
}
