import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../theme/tokens.dart';
import 'springs.dart';

bool reduceMotion(BuildContext context) => AppPerf.reduceEffects(context);

extension SpringRun on AnimationController {
  TickerFuture springTo(
    double target, {
    SpringDescription spring = RestroSprings.snappy,
    double velocity = 0,
  }) =>
      animateWith(SpringSimulation(spring, value, target, velocity));
}

class SpringCurve extends Curve {
  SpringCurve({SpringDescription spring = RestroSprings.snappy})
      : _sim = SpringSimulation(spring, 0, 1, 0);

  final SpringSimulation _sim;
  static const double _settleSeconds = 0.55;

  @override
  double transformInternal(double t) => _sim.x(t * _settleSeconds);
}

class JellyTap extends StatefulWidget {
  const JellyTap({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.amount = 0.07,
    this.enabled = true,
    this.onPressFeedback,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  final double amount;
  final bool enabled;

  final VoidCallback? onPressFeedback;

  @override
  State<JellyTap> createState() => _JellyTapState();
}

class _JellyTapState extends State<JellyTap>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;

  AnimationController _ensure() {
    final existing = _c;
    if (existing != null) return existing;
    final created = AnimationController.unbounded(vsync: this, value: 0);

    created.addListener(_onTick);
    _c = created;
    return created;
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _down(_) {
    if (!widget.enabled) return;
    widget.onPressFeedback?.call();
    if (reduceMotion(context)) return;
    _ensure().springTo(1, spring: RestroSprings.soft);
  }

  void _release({bool cancelled = false}) {
    if (!widget.enabled) return;
    if (reduceMotion(context)) {
      _c?.value = 0;
    } else {
      _ensure().springTo(0, spring: RestroSprings.bouncy, velocity: -9);
    }
    if (!cancelled) widget.onTap?.call();
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _c;

    final Widget body = controller == null || controller.value == 0
        ? widget.child
        : Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..scaleByDouble(
                1 + widget.amount * controller.value.clamp(-1.5, 1.5),
                1 - widget.amount * controller.value.clamp(-1.5, 1.5),
                1,
                1,
              ),
            child: widget.child,
          );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _down,
      onTapUp: (_) => _release(),
      onTapCancel: () => _release(cancelled: true),
      onLongPress: widget.onLongPress,
      child: body,
    );
  }
}

class BoingController {
  _BoingState? _state;
  void fire([double power = 1.0]) => _state?._fire(power);
}

class Boing extends StatefulWidget {
  const Boing({required this.controller, required this.child, super.key});

  final BoingController controller;
  final Widget child;

  @override
  State<Boing> createState() => _BoingState();
}

class _BoingState extends State<Boing> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: 0);

  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
  }

  void _fire(double power) {
    if (!mounted || reduceMotion(context)) return;
    _c.value = power.clamp(0.2, 2.0);
    _c.springTo(0, spring: RestroSprings.bouncy);
  }

  @override
  void didUpdateWidget(covariant Boing old) {
    super.didUpdateWidget(old);
    old.controller._state = null;
    widget.controller._state = this;
  }

  @override
  void dispose() {
    widget.controller._state = null;
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) => Transform.scale(
          scale: 1 + 0.22 * _c.value,
          child: child,
        ),
      );
}

class Wiggle extends StatefulWidget {
  const Wiggle({
    required this.trigger,
    required this.child,
    this.maxAngle = 0.055,
    super.key,
  });

  final int trigger;
  final Widget child;
  final double maxAngle;

  @override
  State<Wiggle> createState() => _WiggleState();
}

class _WiggleState extends State<Wiggle> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: 0);

  @override
  void didUpdateWidget(covariant Wiggle old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger && !reduceMotion(context)) {
      _c.value = 0;
      _c.animateWith(SpringSimulation(RestroSprings.bouncy, 0, 0, 28));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) => Transform.rotate(
          angle: _c.value.clamp(-1.0, 1.0) * widget.maxAngle,
          child: child,
        ),
      );
}

class GravityDrop extends StatefulWidget {
  const GravityDrop({
    required this.child,
    this.dropHeight = 90,
    this.delay = Duration.zero,
    super.key,
  });

  final Widget child;
  final double dropHeight;
  final Duration delay;

  @override
  State<GravityDrop> createState() => _GravityDropState();
}

class _GravityDropState extends State<GravityDrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: -1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (reduceMotion(context)) {
        _c.value = 0;
        return;
      }
      if (widget.delay > Duration.zero) {
        await Future<void>.delayed(widget.delay);
        if (!mounted) return;
      }
      _c.animateWith(SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 620, damping: 13.5),
        -1,
        0,
        -2.5,
      ));
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) {
          final v = _c.value;
          return Opacity(
            opacity: (1 + v).clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, v * widget.dropHeight),
              child: child,
            ),
          );
        },
      );
}

class RubberBand extends StatefulWidget {
  const RubberBand({
    required this.child,
    this.resistance = 0.55,
    this.maxDrag = 64,
    super.key,
  });

  final Widget child;

  final double resistance;
  final double maxDrag;

  @override
  State<RubberBand> createState() => _RubberBandState();
}

class _RubberBandState extends State<RubberBand>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: 0);
  Offset _dir = Offset.zero;
  Offset _drag = Offset.zero;

  void _update(DragUpdateDetails d) {
    if (reduceMotion(context)) return;
    _c.stop();
    _drag += d.delta;
    final raw = _drag * widget.resistance;
    final len = raw.distance;
    final eased = widget.maxDrag * (1 - math.exp(-len / widget.maxDrag));
    setState(() {
      _dir = len == 0 ? Offset.zero : raw / len;
      _c.value = eased;
    });
  }

  void _end(DragEndDetails d) {
    _drag = Offset.zero;
    final v = d.velocity.pixelsPerSecond.distance / 40;
    _c.springTo(0,
        spring: RestroSprings.bouncy, velocity: -v.clamp(0, 40).toDouble());
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onPanUpdate: _update,
        onPanEnd: _end,
        onPanCancel: () => _end(DragEndDetails()),
        child: AnimatedBuilder(
          animation: _c,
          child: widget.child,
          builder: (context, child) => Transform.translate(
            offset: _dir * _c.value,
            child: child,
          ),
        ),
      );
}

class TiltOnTouch extends StatefulWidget {
  const TiltOnTouch({
    required this.child,
    this.maxTilt = 0.09,
    super.key,
  });

  final Widget child;
  final double maxTilt;

  @override
  State<TiltOnTouch> createState() => _TiltOnTouchState();
}

class _TiltOnTouchState extends State<TiltOnTouch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _release =
      AnimationController.unbounded(vsync: this, value: 1);
  Offset _tilt = Offset.zero;
  Offset _from = Offset.zero;

  void _move(Offset local, Size size) {
    if (reduceMotion(context)) return;
    _release.stop();
    _release.value = 1;
    setState(() {
      _tilt = Offset(
        ((local.dx / size.width) * 2 - 1).clamp(-1, 1),
        ((local.dy / size.height) * 2 - 1).clamp(-1, 1),
      );
    });
  }

  void _end() {
    _from = _tilt;
    _release.value = 1;
    _release
        .springTo(0, spring: RestroSprings.snappy)
        .whenCompleteOrCancel(() => _tilt = Offset.zero);
  }

  @override
  void dispose() {
    _release.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;

          return Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) => _move(e.localPosition, size),
            onPointerMove: (e) => _move(e.localPosition, size),
            onPointerUp: (_) => _end(),
            onPointerCancel: (_) => _end(),
            child: AnimatedBuilder(
              animation: _release,
              child: widget.child,
              builder: (context, child) {
                final t = _release.isAnimating || _release.value != 1
                    ? _from * _release.value.clamp(0.0, 1.0)
                    : _tilt;
                return Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.0016)
                    ..rotateX(-t.dy * widget.maxTilt)
                    ..rotateY(t.dx * widget.maxTilt),
                  child: child,
                );
              },
            ),
          );
        },
      );
}

class Shimmer extends StatelessWidget {
  const Shimmer({
    required this.child,
    this.baseColor,
    this.highlightColor,
    this.period = const Duration(milliseconds: 1400),
    super.key,
  });

  final Widget child;
  final Color? baseColor;
  final Color? highlightColor;
  final Duration period;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base =
        baseColor ?? (dark ? const Color(0x14F5EEE3) : const Color(0x0D1A130C));
    return ColorFiltered(
      colorFilter: ColorFilter.mode(base, BlendMode.srcATop),
      child: child,
    );
  }
}

class AttentionPulse extends StatefulWidget {
  const AttentionPulse({
    required this.child,
    this.glowColor,
    this.scale = 1.045,
    this.period = const Duration(milliseconds: 1600),
    super.key,
  });

  final Widget child;
  final Color? glowColor;
  final double scale;
  final Duration period;

  @override
  State<AttentionPulse> createState() => _AttentionPulseState();
}

class _AttentionPulseState extends State<AttentionPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.period);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
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
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_c.value);

        return Transform.scale(
          scale: 1 + (widget.scale - 1) * t,
          child: child,
        );
      },
    );
  }
}

class SpringPageTransitionsBuilder extends PageTransitionsBuilder {
  const SpringPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduceMotion(context)) {
      return FadeTransition(opacity: animation, child: child);
    }

    final spring = CurvedAnimation(
      parent: animation,
      curve: SpringCurve(spring: RestroSprings.snappy),
      reverseCurve: Curves.easeInCubic,
    );
    final fade = CurvedAnimation(
      parent: animation,
      curve: const Interval(0, 0.6, curve: Curves.easeOut),
    );
    final drift = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.easeInOut,
    );

    return AnimatedBuilder(
      animation: Listenable.merge([spring, fade, drift]),
      child: child,
      builder: (context, child) {
        final v = spring.value;
        return Opacity(
          opacity: fade.value.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - v) * 14 - drift.value * 10),
            child: Transform.scale(
              scale: (0.985 + 0.015 * v) - drift.value * 0.02,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
