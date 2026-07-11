

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
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final SpringDescription spring;
  final HitTestBehavior behavior;
  final bool enabled;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final active =
        widget.enabled && (widget.onTap != null || widget.onLongPress != null);
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: active ? (_) => _set(true) : null,
      onTapUp: active ? (_) => _set(false) : null,
      onTapCancel: active ? () => _set(false) : null,
      onTap: widget.enabled ? widget.onTap : null,
      onLongPress: widget.enabled ? widget.onLongPress : null,
      child: SpringBuilder(
        from: 1.0,
        to: _pressed ? widget.pressedScale : 1.0,
        spring: widget.spring,
        builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
        child: widget.child,
      ),
    );
  }
}
