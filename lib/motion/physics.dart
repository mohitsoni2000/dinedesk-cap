// physics.dart — playful, physics-driven micro-interactions.
//
// 2026 motion language in one file: squash-&-stretch, decaying-oscillation
// wobbles, gravity drops, rubber-band drags, 3D tilt, spring page
// transitions, and a lightweight shimmer. Zero packages; everything runs on
// [SpringSimulation] and respects `MediaQuery.disableAnimations`.
//
// Quick map:
//   JellyTap        → tap targets (cards, chips, keys): squash on press,
//                     jelly overshoot on release
//   Boing           → programmatic pop for badges / stat bumps
//                     (BoingController.fire())
//   Wiggle          → attention wobble when `trigger` changes (READY chip)
//   GravityDrop     → entrance that falls in and bounces (success check,
//                     empty states)
//   RubberBand      → drag-me-and-I-snap-back toy physics (logo, paired chip)
//   TiltOnTouch     → subtle 3D tilt following the finger
//   Shimmer         → skeleton loading sweep
//   AttentionPulse  → soft repeating scale+glow (READY chips)
//   SpringPageTransitionsBuilder → shared-axis spring route transition
//   SpringCurve / springTo()     → helpers to spring anything

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../theme/tokens.dart';
import 'springs.dart';

/// True when heavy motion should be skipped — performance mode, a detected
/// low-tier device, or OS reduce-motion. Every widget here honours it.
bool reduceMotion(BuildContext context) => AppPerf.reduceEffects(context);

/// Drive any [AnimationController] with a real spring.
extension SpringRun on AnimationController {
  TickerFuture springTo(
    double target, {
    SpringDescription spring = RestroSprings.snappy,
    double velocity = 0,
  }) =>
      animateWith(SpringSimulation(spring, value, target, velocity));
}

/// A [Curve] sampled from a real [SpringSimulation] — gives Tween/implicit
/// animations a natural overshoot. Values may exceed 1.0; clamp for opacity.
class SpringCurve extends Curve {
  SpringCurve({SpringDescription spring = RestroSprings.snappy})
      : _sim = SpringSimulation(spring, 0, 1, 0);

  final SpringSimulation _sim;
  static const double _settleSeconds = 0.55;

  @override
  double transformInternal(double t) => _sim.x(t * _settleSeconds);
}

// ─────────────────────────────────────────────────────────────── JellyTap ──

/// Squash-and-stretch tap target: presses squish (wider + shorter), release
/// springs back with a jelly wobble. Wrap cards, chips, pin keys, nav icons.
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

  /// Max squash as a fraction of scale (0.07 ⇒ 1.07× wide, 0.93× tall).
  final double amount;
  final bool enabled;

  /// Hook your haptics/audio here (e.g. feedbackService.fire(...)).
  final VoidCallback? onPressFeedback;

  @override
  State<JellyTap> createState() => _JellyTapState();
}

class _JellyTapState extends State<JellyTap>
    with SingleTickerProviderStateMixin {
  /// Created on first press, not on mount.
  ///
  /// The tables floor puts one JellyTap per tile. With `late final ... =`
  /// the controller was constructed the first time `build` touched it, which
  /// is immediately — so a 60-tile floor allocated 60 controllers and 60
  /// ticker registrations, and churned them on every scroll recycle. Nothing
  /// squashes until a finger lands, so nothing needs to exist until then.
  AnimationController? _c;

  AnimationController _ensure() {
    final existing = _c;
    if (existing != null) return existing;
    final created = AnimationController.unbounded(vsync: this, value: 0);
    // The rebuild is driven by setState rather than an always-mounted
    // AnimatedBuilder, so an untouched tile carries no listener and no
    // extra element in the tree.
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
      // Negative velocity throws the spring past 0 → the jelly wobble.
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
    // At rest — which is every tile except the one under a thumb — the child
    // is returned untransformed. No AnimatedBuilder, no Matrix4 allocation,
    // no extra render object.
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

// ────────────────────────────────────────────────────────────────── Boing ──

/// Programmatic pop: `controller.fire()` makes the child boing (scale
/// overshoot with a decaying wobble). Perfect for a ₹ stat that just changed
/// or a badge count bump.
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

// ───────────────────────────────────────────────────────────────── Wiggle ──

/// Decaying-oscillation attention wobble. Bump [trigger] (any changing int)
/// and the child rings like a struck bell — a spring launched with pure
/// velocity around its rest point.
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

// ──────────────────────────────────────────────────────────── GravityDrop ──

/// Entrance that FALLS into place and bounces — stiff, under-damped spring
/// reads as gravity + landing. Use on the KOT success check, empty states,
/// or the demo confetti moment.
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

// ───────────────────────────────────────────────────────────── RubberBand ──

/// Toy physics: drag the child anywhere (with resistance), let go and it
/// snaps home with your fling velocity feeding the spring. Delightful on the
/// auth logo or the paired chip; harmless everywhere.
class RubberBand extends StatefulWidget {
  const RubberBand({
    required this.child,
    this.resistance = 0.55,
    this.maxDrag = 64,
    super.key,
  });

  final Widget child;

  /// 0..1 — how much of the finger travel the child follows.
  final double resistance;
  final double maxDrag;

  @override
  State<RubberBand> createState() => _RubberBandState();
}

class _RubberBandState extends State<RubberBand>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: 0);
  Offset _dir = Offset.zero; // unit-ish direction of current stretch
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
    _c.springTo(0, spring: RestroSprings.bouncy, velocity: -v.clamp(0, 40).toDouble());
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

// ──────────────────────────────────────────────────────────── TiltOnTouch ──

/// Subtle 3D card tilt that follows the finger; springs flat on release.
class TiltOnTouch extends StatefulWidget {
  const TiltOnTouch({
    required this.child,
    this.maxTilt = 0.09,
    super.key,
  });

  final Widget child;
  final double maxTilt; // radians

  @override
  State<TiltOnTouch> createState() => _TiltOnTouchState();
}

class _TiltOnTouchState extends State<TiltOnTouch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _release =
      AnimationController.unbounded(vsync: this, value: 1);
  Offset _tilt = Offset.zero; // x: rotY, y: rotX — normalized -1..1
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
          // Raw pointer events: never enters the gesture arena, so taps,
          // long-presses and scrollables above/below keep working — the
          // tilt is purely observational.
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

// ──────────────────────────────────────────────────────────────── Shimmer ──

/// Flat skeleton tint. Wrap grey placeholder shapes.
///
/// This was a sweeping shimmer: a [ShaderMask] over a three-stop
/// [LinearGradient] whose transform was driven by a repeating controller, so
/// a new shader was built and uploaded on every frame for every placeholder
/// on screen. It already had a flat fallback for reduced motion — that
/// fallback is now the only path, and the ticker is gone with it.
///
/// [highlightColor] and [period] are retained so the call sites keep reading
/// the way they did; there is no highlight to sweep and nothing to time.
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
    final base = baseColor ??
        (dark ? const Color(0x14F5EEE3) : const Color(0x0D1A130C));
    return ColorFiltered(
      colorFilter: ColorFilter.mode(base, BlendMode.srcATop),
      child: child,
    );
  }
}

// ───────────────────────────────────────────────────────── AttentionPulse ──

/// Soft repeating scale + glow — for READY chips and live badges.
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
    // `glowColor` is retained on the widget for source compatibility with the
    // call sites that still pass it; there is no glow to colour.
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_c.value);
        // The pulse is a scale now. It used to also breathe a coloured glow
        // (a BoxShadow whose blur and spread both animated, so the shadow was
        // re-blurred every frame); the scale alone reads as "look here".
        return Transform.scale(
          scale: 1 + (widget.scale - 1) * t,
          child: child,
        );
      },
    );
  }
}

// ─────────────────────────────────────────────── Spring page transitions ──

/// Shared-axis route transition on a real spring: incoming page rises 14px,
/// scales .985 → 1 with a hint of overshoot, and fades in; outgoing page
/// drifts back. Wired app-wide from [AppTheme] via [PageTransitionsTheme].
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
    // A plain fade still reads as a transition but costs one opacity layer
    // instead of a spring-driven transform stack.
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
        final v = spring.value; // may slightly overshoot 1 — that's the charm
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
