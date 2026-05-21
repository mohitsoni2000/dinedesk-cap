import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// Spring tokens used throughout Restro Operator.
class RestroSprings {
  const RestroSprings._();

  /// Gentle settle, no overshoot. Use for: card entrance, drawer open, list reveal.
  static const SpringDescription soft =
      SpringDescription(mass: 1.0, stiffness: 280.0, damping: 24.0);

  /// Tight, minimal overshoot (~3%). Use for: button press, PIN dot fill, cart badge.
  static const SpringDescription snappy =
      SpringDescription(mass: 1.0, stiffness: 400.0, damping: 22.0);

  /// ~15% overshoot, two-bounce settle. Use for: success states, celebrations.
  static const SpringDescription bouncy =
      SpringDescription(mass: 1.0, stiffness: 350.0, damping: 16.0);

  /// Heavy, slow — for large surfaces. Use for: sheet open, modal entrance.
  static const SpringDescription heavy =
      SpringDescription(mass: 2.5, stiffness: 180.0, damping: 22.0);
}

/// Drop-in replacement for [TweenAnimationBuilder] driven by a [SpringSimulation].
/// Interruption-safe: if [to] changes mid-flight, re-targets from current position+velocity.
class SpringBuilder extends StatefulWidget {
  const SpringBuilder({
    required this.to,
    required this.builder,
    this.from = 0.0,
    this.spring = RestroSprings.snappy,
    this.velocity = 0.0,
    this.child,
    super.key,
  });

  final double to;
  final double from;
  final SpringDescription spring;
  final double velocity;
  final Widget Function(BuildContext context, double value, Widget? child)
      builder;
  final Widget? child;

  @override
  State<SpringBuilder> createState() => _SpringBuilderState();
}

class _SpringBuilderState extends State<SpringBuilder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late SpringSimulation _simulation;
  double _currentValue = 0.0;
  double _currentVelocity = 0.0;

  @override
  void initState() {
    super.initState();
    _currentValue = widget.from;
    _controller = AnimationController.unbounded(vsync: this)
      ..addListener(_onTick);
    _simulation = SpringSimulation(
        widget.spring, widget.from, widget.to, widget.velocity);
    _controller.animateWith(_simulation);
  }

  void _onTick() {
    setState(() {
      _currentValue = _controller.value;
      _currentVelocity = _controller.velocity;
    });
  }

  @override
  void didUpdateWidget(covariant SpringBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.to != widget.to || oldWidget.spring != widget.spring) {
      _simulation = SpringSimulation(
          widget.spring, _currentValue, widget.to, _currentVelocity);
      _controller.animateWith(_simulation);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _currentValue, widget.child);
  }
}

/// Convenience extension for chaining springs onto common widget transforms.
extension SpringTransitions on Widget {
  Widget springScale({
    required double to,
    double from = 0.0,
    SpringDescription spring = RestroSprings.snappy,
    Key? key,
  }) {
    return SpringBuilder(
      key: key,
      from: from,
      to: to,
      spring: spring,
      builder: (BuildContext context, double value, Widget? child) {
        return Transform.scale(scale: value, child: child);
      },
      child: this,
    );
  }

  Widget springTranslateY({
    required double to,
    double from = 0.0,
    SpringDescription spring = RestroSprings.snappy,
    Key? key,
  }) {
    return SpringBuilder(
      key: key,
      from: from,
      to: to,
      spring: spring,
      builder: (BuildContext context, double value, Widget? child) {
        return Transform.translate(offset: Offset(0, value), child: child);
      },
      child: this,
    );
  }
}
