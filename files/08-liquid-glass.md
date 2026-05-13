# Agent Prompt 08 — Liquid Glass

**Priority:** #8 (premium feel — applies polish across surfaces)
**Effort:** 5 days
**Touches:** `lib/motion/liquid_glass.dart` (new), 4 widget files (modifications)
**Parallel-safe with:** Prompts 04, 05, 06, 07, 09 (no shared files)
**Depends on:** Prompt 01 (uses `RestroSprings` for highlight follow), Prompt 09 (gyroscope shared)

---

## Context

Apple's iOS 26 Liquid Glass is the successor to flat glassmorphism. Glass
surfaces don't just sit there — they **bend toward touch**, **refract light**
based on device tilt, and gently pull the highlight toward the finger.

Flutter doesn't have a built-in Liquid Glass widget. This prompt builds one
using `BackdropFilter` for the blur layer and a custom-tracked radial highlight
that follows the pointer (mouse, finger, or gyroscope tilt).

---

## What to Build

### File 1 (MODIFY): `pubspec.yaml`

Inside `dependencies:`:

```yaml
sensors_plus: ^6.1.0
```

(This is also required by Prompt 09; if 09 already added it, leave it.)

### File 2 (NEW): `lib/motion/liquid_glass.dart`

```dart
// ===== ANCHOR: LG_IMPORTS =====
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'springs.dart';
// ===== END ANCHOR: LG_IMPORTS =====

// ===== ANCHOR: LG_SOURCE =====
/// Which input drives the highlight position.
sealed class LiquidGlassSource {
  const LiquidGlassSource();
}

/// Highlight follows the pointer (mouse on desktop, primary touch on mobile).
final class LiquidGlassPointer extends LiquidGlassSource {
  const LiquidGlassPointer();
}

/// Highlight follows the device's gyroscope tilt — useful for ambient surfaces
/// that don't take direct input (e.g. splash backgrounds, card resting state).
final class LiquidGlassGyro extends LiquidGlassSource {
  const LiquidGlassGyro({this.intensity = 1.0});
  final double intensity;
}

/// Highlight stays centred. Used as a fallback / for accessibility (reduced motion).
final class LiquidGlassStatic extends LiquidGlassSource {
  const LiquidGlassStatic();
}
// ===== END ANCHOR: LG_SOURCE =====

// ===== ANCHOR: LG_WIDGET =====
/// A Liquid Glass surface.
///
/// Renders a blurred-translucent backing with a moving radial highlight that
/// tracks the chosen [source]. On touch (pointer source), the entire surface
/// gently scales toward the touch point — the "surface tension" effect.
class LiquidGlass extends StatefulWidget {
  const LiquidGlass({
    required this.child,
    this.source = const LiquidGlassPointer(),
    this.blurSigma = 24,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.tint = const Color(0x0DFFE3B5),
    this.highlightColor = const Color(0x66FFB964),
    this.highlightRadius = 200,
    this.enableSurfaceTension = true,
    super.key,
  });

  final Widget child;
  final LiquidGlassSource source;
  final double blurSigma;
  final BorderRadius borderRadius;
  final Color tint;
  final Color highlightColor;
  final double highlightRadius;
  final bool enableSurfaceTension;

  @override
  State<LiquidGlass> createState() => _LiquidGlassState();
}

class _LiquidGlassState extends State<LiquidGlass>
    with SingleTickerProviderStateMixin {
  Offset _highlightTarget = const Offset(0.5, 0.5);  // normalised 0..1
  Offset _highlightCurrent = const Offset(0.5, 0.5);
  bool _isPressed = false;
  Offset _pressTarget = const Offset(0.5, 0.5);

  late final AnimationController _follow;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  @override
  void initState() {
    super.initState();
    _follow = AnimationController.unbounded(vsync: this)..addListener(_onTick);
    _maybeSubscribeGyro();
  }

  @override
  void didUpdateWidget(covariant LiquidGlass oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source != oldWidget.source) {
      _gyroSub?.cancel();
      _gyroSub = null;
      _maybeSubscribeGyro();
    }
  }

  void _maybeSubscribeGyro() {
    final LiquidGlassSource src = widget.source;
    if (src is LiquidGlassGyro) {
      _gyroSub = gyroscopeEventStream().listen((GyroscopeEvent e) {
        // x → vertical tilt; y → horizontal tilt (axes vary by device orientation).
        final double nx = (0.5 + e.y * 0.08 * src.intensity).clamp(0.0, 1.0);
        final double ny = (0.5 + e.x * 0.08 * src.intensity).clamp(0.0, 1.0);
        _highlightTarget = Offset(nx, ny);
      });
    }
  }

  void _onTick() {
    // Spring-follow the highlight target.
    final double t = 0.18;
    final Offset next = Offset(
      _highlightCurrent.dx + (_highlightTarget.dx - _highlightCurrent.dx) * t,
      _highlightCurrent.dy + (_highlightTarget.dy - _highlightCurrent.dy) * t,
    );
    if ((next - _highlightCurrent).distance < 0.001) {
      _follow.stop();
    }
    setState(() {
      _highlightCurrent = next;
    });
  }

  void _ensureTicking() {
    if (!_follow.isAnimating) {
      _follow.repeat();
    }
  }

  void _handleHover(PointerEvent event, Size size) {
    if (widget.source is! LiquidGlassPointer) return;
    final double nx = (event.localPosition.dx / size.width).clamp(0.0, 1.0);
    final double ny = (event.localPosition.dy / size.height).clamp(0.0, 1.0);
    _highlightTarget = Offset(nx, ny);
    _ensureTicking();
  }

  void _handleHoverExit() {
    if (widget.source is! LiquidGlassPointer) return;
    _highlightTarget = const Offset(0.5, 0.5);
    _ensureTicking();
  }

  void _handleTouchDown(Offset local, Size size) {
    if (widget.source is! LiquidGlassPointer) return;
    final double nx = (local.dx / size.width).clamp(0.0, 1.0);
    final double ny = (local.dy / size.height).clamp(0.0, 1.0);
    setState(() {
      _isPressed = true;
      _pressTarget = Offset(nx, ny);
    });
    _highlightTarget = Offset(nx, ny);
    _ensureTicking();
  }

  void _handleTouchUp() {
    setState(() {
      _isPressed = false;
    });
  }

  @override
  void dispose() {
    _gyroSub?.cancel();
    _follow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = constraints.biggest;
        final double hx = _highlightCurrent.dx * size.width;
        final double hy = _highlightCurrent.dy * size.height;

        // Surface tension: micro-scale toward the press point.
        final Alignment scaleAlign = widget.enableSurfaceTension && _isPressed
            ? Alignment(_pressTarget.dx * 2 - 1, _pressTarget.dy * 2 - 1)
            : Alignment.center;

        return MouseRegion(
          onHover: (PointerHoverEvent e) => _handleHover(e, size),
          onExit: (_) => _handleHoverExit(),
          child: GestureDetector(
            onTapDown: (TapDownDetails d) => _handleTouchDown(d.localPosition, size),
            onTapUp: (_) => _handleTouchUp(),
            onTapCancel: _handleTouchUp,
            behavior: HitTestBehavior.translucent,
            child: ClipRRect(
              borderRadius: widget.borderRadius,
              child: AnimatedScale(
                scale: _isPressed ? 0.985 : 1.0,
                alignment: scaleAlign,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: Stack(
                  children: <Widget>[
                    // Backdrop blur layer.
                    Positioned.fill(
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(
                          sigmaX: widget.blurSigma,
                          sigmaY: widget.blurSigma,
                        ),
                        child: Container(color: widget.tint),
                      ),
                    ),
                    // Highlight radial gradient — follows the pointer / gyro.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _HighlightPainter(
                            center: Offset(hx, hy),
                            radius: widget.highlightRadius,
                            color: widget.highlightColor,
                          ),
                        ),
                      ),
                    ),
                    // Subtle inner border.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: widget.borderRadius,
                            border: Border.all(
                              color: const Color(0x29FFDCB4),
                              width: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Content.
                    widget.child,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HighlightPainter extends CustomPainter {
  _HighlightPainter({
    required this.center,
    required this.radius,
    required this.color,
  });

  final Offset center;
  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..shader = RadialGradient(
        colors: <Color>[color, color.withOpacity(0)],
        stops: const <double>[0.0, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _HighlightPainter oldDelegate) =>
      oldDelegate.center != center ||
      oldDelegate.radius != radius ||
      oldDelegate.color != color;
}
// ===== END ANCHOR: LG_WIDGET =====
```

### File 3 (MODIFY): `lib/motion/motion.dart`

Add to EXPORTS anchor:

```dart
export 'liquid_glass.dart';
```

---

## Integration

### Integration 1: `lib/widgets/cart_bar.dart`

Wrap the cart bar in a `LiquidGlass`:

```dart
@override
Widget build(BuildContext context) {
  return LiquidGlass(
    source: const LiquidGlassPointer(),
    borderRadius: const BorderRadius.only(
      topLeft: Radius.circular(20),
      topRight: Radius.circular(20),
    ),
    blurSigma: 30,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      child: Row(/* … existing cart bar content … */),
    ),
  );
}
```

### Integration 2: `lib/widgets/connection_banner.dart`

```dart
LiquidGlass(
  source: const LiquidGlassGyro(intensity: 0.5),
  borderRadius: const BorderRadius.all(Radius.circular(14)),
  child: /* … banner content … */,
)
```

Gyro source — the banner subtly catches light as the operator's phone moves.

### Integration 3: `lib/widgets/glass_pill.dart`

Replace any existing static glass pill with `LiquidGlass`:

```dart
LiquidGlass(
  source: const LiquidGlassPointer(),
  borderRadius: BorderRadius.circular(100),
  highlightRadius: 80,
  child: Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    child: child,
  ),
)
```

### Integration 4: `lib/screens/qr_scan_screen.dart`

The status pill below the scan viewport. Same treatment — `LiquidGlassPointer`.

---

## Accessibility

If `MediaQuery.of(context).disableAnimations` is true, force
`LiquidGlassStatic` regardless of the requested source. Add this guard
inside `_LiquidGlassState.build`:

```dart
final LiquidGlassSource effectiveSource =
    MediaQuery.of(context).disableAnimations
        ? const LiquidGlassStatic()
        : widget.source;
```

Use `effectiveSource` everywhere instead of `widget.source`.

---

## Testing

### Widget test (NEW): `test/motion/liquid_glass_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro_operator/motion/motion.dart';

void main() {
  group('LiquidGlass', () {
    testWidgets('renders child', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200, height: 100,
              child: LiquidGlass(child: Text('Hello')),
            ),
          ),
        ),
      );
      expect(find.text('Hello'), findsOneWidget);
    });

    testWidgets('tap shrinks scale (surface tension)',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200, height: 100,
              child: LiquidGlass(child: Text('Tap me')),
            ),
          ),
        ),
      );
      final TestGesture gesture = await tester.createGesture();
      await gesture.down(tester.getCenter(find.byType(LiquidGlass)));
      await tester.pump(const Duration(milliseconds: 120));
      // Scale should be < 1.0 during press.
      final Element scaleEl = tester.element(find.byType(AnimatedScale));
      final AnimatedScale scaleWidget = scaleEl.widget as AnimatedScale;
      expect(scaleWidget.scale, lessThan(1.0));
      await gesture.up();
    });
  });
}
```

> The one `as` cast in the test (`scaleEl.widget as AnimatedScale`) is
> mathematically safe — the element is found by type. Document inline.

### Manual QA

- Hover the cursor over a `LiquidGlass`-wrapped cart bar on a desktop build —
  the highlight should follow the cursor smoothly (spring-easing, not snap).
- On a mobile device, touch and drag across a glass surface — highlight follows
  the finger, and on tap-down the entire surface micro-scales toward the touch.
- Tilt the device (gyro source) — highlight drifts subtly as the device moves.
- Enable "Reduce Motion" in OS settings — the highlight should stop tracking,
  staying centred. Surface tension scale should still work.
- Performance: 60fps on the cart bar with `LiquidGlass` while the order builder
  has 5+ items animating in (the only screen where multiple glass surfaces
  coincide).

---

## Acceptance Criteria

- [ ] `lib/motion/liquid_glass.dart` exists with sealed `LiquidGlassSource` and `LiquidGlass` widget
- [ ] `lib/motion/motion.dart` exports it
- [ ] `sensors_plus: ^6.1.0` in `pubspec.yaml`
- [ ] 4 integration points wired
- [ ] Accessibility guard respects `MediaQuery.disableAnimations`
- [ ] All tests pass
- [ ] Manual QA on iOS + Android device
- [ ] 60fps on cart bar + glass pills coexisting
- [ ] No `dynamic`, no `??`-as-default; the test's `as AnimatedScale` is
      documented inline
- [ ] Sealed `LiquidGlassSource` — switches are exhaustive

---

## Strict Dart Conventions Reminder

- Sealed `LiquidGlassSource`
- One documented `as` cast in test only
- No `!` operator
- `const` everywhere it compiles
- The single internal use of `??` (none, actually) — none allowed in new code
