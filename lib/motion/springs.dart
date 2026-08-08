import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

class RestroSprings {
  const RestroSprings._();

  static const SpringDescription soft =
      SpringDescription(mass: 1.0, stiffness: 280.0, damping: 24.0);

  static const SpringDescription snappy =
      SpringDescription(mass: 1.0, stiffness: 400.0, damping: 22.0);

  static const SpringDescription bouncy =
      SpringDescription(mass: 1.0, stiffness: 350.0, damping: 16.0);

  static const SpringDescription heavy =
      SpringDescription(mass: 2.5, stiffness: 180.0, damping: 22.0);
}

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
    // The initial value goes through the constructor, not a `..value =`
    // cascade. Setting it via the cascade notifies listeners, and _onTick
    // reads `_controller` — which the cascade has not yet assigned to this
    // `late final` field, so every SpringBuilder in the tree threw
    // LateInitializationError on mount.
    _controller = AnimationController.unbounded(
      vsync: this,
      value: widget.from,
    )..addListener(_onTick);

    // Only run a simulation when there is actually somewhere to travel.
    //
    // This used to call `animateWith` unconditionally on mount. A `Pressable`
    // at rest is `from == to == 1.0` — a spring from a value to itself — but
    // starting it still spun up the ticker and scheduled a frame. Pressable
    // wraps buttons, cards and glass chrome in 21 places, so every row that
    // mounted during a scroll scheduled a frame it had no intention of
    // painting differently. That is a direct contribution to scroll jank on
    // slow devices, for zero visible motion.
    if (widget.from != widget.to || widget.velocity != 0) {
      _simulation = SpringSimulation(
          widget.spring, widget.from, widget.to, widget.velocity);
      _controller.animateWith(_simulation);
    } else {
      _simulation =
          SpringSimulation(widget.spring, widget.from, widget.to, 0);
    }
  }

  void _onTick() {
    _currentValue = _controller.value;
    _currentVelocity = _controller.velocity;
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
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) =>
          widget.builder(context, _controller.value, widget.child),
    );
  }
}

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
