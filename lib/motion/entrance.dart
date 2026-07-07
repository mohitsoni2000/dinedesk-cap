// Entrance — iOS-style "settle in" reveal for content.
//
// Each item fades in while rising a few px and easing to rest. Give items an
// increasing [delay] to get the signature staggered cascade you see when an
// iOS screen's content lands (Mail, Settings, App Store lists).
//
//   Column(children: Entrance.stagger(rows));            // auto-cascade
//   Entrance(delay: Duration(milliseconds: 60), child: card);  // single item
//
// Runs once on first build; cheap (a single short controller per item) and
// self-disposing.

import 'package:flutter/widgets.dart';

class Entrance extends StatefulWidget {
  const Entrance({
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 420),
    this.offsetY = 14.0,
    this.curve = Curves.easeOutCubic,
    super.key,
  });

  final Widget child;
  final Duration delay;
  final Duration duration;
  final double offsetY;
  final Curve curve;

  /// Wrap a list of children with an increasing delay to produce a cascade.
  static List<Widget> stagger(
    List<Widget> children, {
    Duration step = const Duration(milliseconds: 55),
    Duration initialDelay = Duration.zero,
    double offsetY = 14.0,
    int maxStaggered = 12, // cap the cascade so long lists don't lag the reveal
  }) {
    return [
      for (int i = 0; i < children.length; i++)
        Entrance(
          // Same key identity as position so list updates don't re-trigger.
          delay: initialDelay +
              step * (i < maxStaggered ? i : maxStaggered),
          offsetY: offsetY,
          child: children[i],
        ),
    ];
  }

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _t =
      CurvedAnimation(parent: _c, curve: widget.curve);

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future<void>.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (_, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(
          offset: Offset(0, (1 - _t.value) * widget.offsetY),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}
