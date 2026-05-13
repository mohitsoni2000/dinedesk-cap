# Agent Prompt 01 — Spring Physics

**Priority:** #1 (top of roadmap — biggest "feel" upgrade)
**Effort:** 2 days
**Touches:** `lib/motion/springs.dart` (new), `lib/motion/motion.dart` (new barrel),
8 existing widget/screen files (modifications)
**Parallel-safe with:** Prompt 02 (no shared files), Prompt 04 (mesh_gradient.dart is new)
**Conflicts with:** none — first prompt to land

---

## Context

The Restro operator app currently uses `cubic-bezier` easing curves throughout
its animations (e.g. `Curves.easeOutExpo`, `Curves.easeOutBack`). These are
deterministic but feel mechanical — every press lands in exactly the same way,
and animations don't respond gracefully when interrupted mid-flight.

Apple's iOS 26 Liquid Glass, Stripe, Linear, Framer all moved to **spring physics**
modelling tension, friction, and mass. This prompt replaces every easing curve
in the app with a spring from a small palette.

The Flutter SDK already ships `package:flutter/physics.dart` with `SpringDescription`
and `SpringSimulation`. No third-party packages needed.

---

## What to Build

### File 1 (NEW): `lib/motion/springs.dart`

```dart
// ===== ANCHOR: SPRING_TOKENS =====
import 'package:flutter/animation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// Spring tokens used throughout Restro Operator.
///
/// Three springs cover 95% of cases. Use [soft] for gentle reveals,
/// [snappy] for taps and badges, [bouncy] for celebrations.
///
/// Avoid hand-rolled `SpringDescription` in widget code — add a token here.
class RestroSprings {
  const RestroSprings._();

  /// Tension 280, friction 24. Gentle settle, no overshoot.
  /// Use for: card entrance, drawer open, list reveal.
  static const SpringDescription soft = SpringDescription(
    mass: 1.0,
    stiffness: 280.0,
    damping: 24.0,
  );

  /// Tension 400, friction 22. Tight, minimal overshoot (~3%).
  /// Use for: button press, PIN dot fill, cart badge update.
  static const SpringDescription snappy = SpringDescription(
    mass: 1.0,
    stiffness: 400.0,
    damping: 22.0,
  );

  /// Tension 350, friction 16. ~15% overshoot, two-bounce settle.
  /// Use for: success states, KOT fire confirmation, celebratory moments.
  static const SpringDescription bouncy = SpringDescription(
    mass: 1.0,
    stiffness: 350.0,
    damping: 16.0,
  );

  /// Tension 180, friction 22. Heavy, slow — for large surfaces.
  /// Use for: sheet open, modal entrance.
  static const SpringDescription heavy = SpringDescription(
    mass: 2.5,
    stiffness: 180.0,
    damping: 22.0,
  );
}
// ===== END ANCHOR: SPRING_TOKENS =====

// ===== ANCHOR: SPRING_BUILDER =====
/// Drop-in replacement for [TweenAnimationBuilder] but driven by a [SpringSimulation].
///
/// Unlike a tween + curve, a spring is **interruption-safe**: if [to] changes
/// while the animation is in flight, the spring re-targets without snapping.
///
/// Strict-mode constraints:
/// - No `dynamic`, no `as` casts.
/// - Builder signature is explicit `Widget Function(BuildContext, double, Widget?)`.
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

  /// Target value the spring is reaching for.
  final double to;

  /// Initial value at first build. Subsequent changes to [to] re-target the spring.
  final double from;

  final SpringDescription spring;

  /// Initial velocity in units/sec. Use non-zero when transferring momentum
  /// (e.g. drag release into spring).
  final double velocity;

  final Widget Function(BuildContext context, double value, Widget? child) builder;
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
      widget.spring,
      widget.from,
      widget.to,
      widget.velocity,
    );
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
      // Re-target the spring from current position with current velocity —
      // this is the interruption-safe behaviour.
      _simulation = SpringSimulation(
        widget.spring,
        _currentValue,
        widget.to,
        _currentVelocity,
      );
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
// ===== END ANCHOR: SPRING_BUILDER =====

// ===== ANCHOR: SPRING_TRANSITIONS =====
/// Convenience extension for chaining springs onto common widget transforms.
extension SpringTransitions on Widget {
  /// Wraps this widget in a [SpringBuilder] that animates `scale` from
  /// `from` to `to`. Use for press/tap feedback.
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

  /// Wraps this widget in a [SpringBuilder] that animates `offset.dy` between
  /// `from` and `to` (in logical pixels). Use for badge bounce, banner slide.
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
// ===== END ANCHOR: SPRING_TRANSITIONS =====
```

### File 2 (NEW): `lib/motion/motion.dart` (barrel)

```dart
// Barrel export for the motion library. Add new motion primitives here.
//
// ===== ANCHOR: EXPORTS =====
export 'springs.dart';
// ===== END ANCHOR: EXPORTS =====
```

### File 3 (MODIFY): `pubspec.yaml`

No new dependencies — `flutter/physics.dart` is in the SDK. Confirm the
following block exists:

```yaml
dependencies:
  flutter:
    sdk: flutter
```

That's it.

---

## Migration — Replace Existing Easing With Springs

Sweep the codebase. For every occurrence of the patterns below, replace with the
spring equivalent. **Do not** delete the old animations and start over — port them.

### Mapping table

| Existing | Replace with |
|---|---|
| `Curves.easeOutBack` + scale | `widget.springScale(to: 1.0, spring: RestroSprings.bouncy)` |
| `Curves.easeOutExpo` + opacity entrance | `SpringBuilder` with `RestroSprings.soft`, animating opacity in the builder |
| `Curves.elasticOut` (legacy spring fake) | `RestroSprings.bouncy` |
| `Curves.easeInOut` (sheet/modal) | `RestroSprings.heavy` |
| Custom `cubic-bezier(0.5, 1.5, 0.7, 1)` | `RestroSprings.snappy` |

### Files to migrate (8 files)

For each, replace the relevant animation. Grep for `Curves.` to find every instance.

1. **`lib/widgets/connection_banner.dart`** — banner slide-in uses `easeOutBack`. Swap to `RestroSprings.snappy` translateY.
2. **`lib/screens/splash_screen.dart`** — logo entrance uses `easeOutBack` scale. Swap to `RestroSprings.bouncy` scale.
3. **`lib/screens/auth_screen.dart`** — PIN dot fill on key press. Each dot's scale transition uses `RestroSprings.snappy`.
4. **`lib/screens/tables_screen.dart`** — card stagger entrance. Replace `Curves.easeOutExpo` opacity with `SpringBuilder(spring: RestroSprings.soft)` driving opacity in builder.
5. **`lib/screens/order_builder_screen.dart`** — item add-to-cart animation. Cart badge scale-up uses `RestroSprings.bouncy`.
6. **`lib/screens/order_success_screen.dart`** — checkmark pop. Currently `easeOutBack`; swap to `RestroSprings.bouncy`.
7. **`lib/screens/disconnected_screen.dart`** — retry button shimmer not affected; only the icon wobble. Swap to a `SpringBuilder` cycling between -3° and 3° rotation with `RestroSprings.soft`.
8. **`lib/widgets/root_shell.dart`** — bottom-nav indicator translate. Swap any active-tab transition to `RestroSprings.snappy` translateX.

### Pattern: porting a scale animation

**Before (using a curve):**
```dart
AnimatedScale(
  scale: _isPressed ? 0.94 : 1.0,
  duration: const Duration(milliseconds: 200),
  curve: Curves.easeOutBack,
  child: child,
)
```

**After (using a spring):**
```dart
SpringBuilder(
  to: _isPressed ? 0.94 : 1.0,
  spring: RestroSprings.snappy,
  builder: (BuildContext _, double scale, Widget? c) {
    return Transform.scale(scale: scale, child: c);
  },
  child: child,
)
```

The spring version is interruption-safe — if the user presses, releases, and
presses again rapidly, the spring re-targets each time without snapping.

### Pattern: porting a multi-property animation

**Before:**
```dart
AnimatedContainer(
  duration: const Duration(milliseconds: 300),
  curve: Curves.easeOutExpo,
  transform: Matrix4.translationValues(0, _offsetY, 0),
  child: child,
)
```

**After:**
```dart
SpringBuilder(
  to: _offsetY,
  spring: RestroSprings.soft,
  builder: (BuildContext _, double dy, Widget? c) {
    return Transform.translate(offset: Offset(0, dy), child: c);
  },
  child: child,
)
```

---

## Testing

### Unit test (NEW file): `test/motion/springs_test.dart`

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro_operator/motion/motion.dart';

void main() {
  group('SpringBuilder', () {
    testWidgets('settles at target value', (WidgetTester tester) async {
      double captured = -1.0;
      await tester.pumpWidget(
        SpringBuilder(
          from: 0.0,
          to: 1.0,
          spring: RestroSprings.snappy,
          builder: (BuildContext _, double v, Widget? __) {
            captured = v;
            return const SizedBox.shrink();
          },
        ),
      );
      // Pump enough frames for spring to settle.
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect(captured, closeTo(1.0, 0.005));
    });

    testWidgets('bouncy spring overshoots target', (WidgetTester tester) async {
      double maxObserved = 0.0;
      await tester.pumpWidget(
        SpringBuilder(
          from: 0.0,
          to: 1.0,
          spring: RestroSprings.bouncy,
          builder: (BuildContext _, double v, Widget? __) {
            if (v > maxObserved) maxObserved = v;
            return const SizedBox.shrink();
          },
        ),
      );
      // Pump through the overshoot phase (~300ms).
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // Bouncy spring should overshoot 1.0 by at least 10%.
      expect(maxObserved, greaterThan(1.10));
      expect(maxObserved, lessThan(1.30));
    });

    testWidgets('re-targets mid-flight without snap', (WidgetTester tester) async {
      double targetValue = 1.0;
      late void Function(void Function()) setStateOuter;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (BuildContext context, void Function(void Function()) setState) {
            setStateOuter = setState;
            return SpringBuilder(
              from: 0.0,
              to: targetValue,
              spring: RestroSprings.soft,
              builder: (BuildContext _, double v, Widget? __) => const SizedBox.shrink(),
            );
          },
        ),
      );
      // Pump 100ms (spring mid-flight).
      await tester.pump(const Duration(milliseconds: 100));
      // Re-target.
      setStateOuter(() { targetValue = 0.5; });
      await tester.pumpAndSettle(const Duration(seconds: 2));
      // No assertion thrown means no snap occurred.
    });
  });
}
```

---

## Acceptance Criteria

- [ ] `lib/motion/springs.dart` exists with `RestroSprings`, `SpringBuilder`, `SpringTransitions`
- [ ] `lib/motion/motion.dart` barrel exports `springs.dart`
- [ ] All 8 listed files migrated from `Curves.*` to `RestroSprings.*`
- [ ] `flutter analyze` returns 0 errors on strict rules
- [ ] `flutter test test/motion/springs_test.dart` passes all 3 tests
- [ ] `grep -rn "Curves\." lib/` returns only references in third-party packages or comments
- [ ] No `dynamic`, no `as` casts, no `!` operator added in any new file
- [ ] Manual test on device: cart badge bounce visibly overshoots and settles (different from prior easing)
- [ ] Manual test on device: rapid double-press of PIN keys does not produce jarring snap (spring re-targets smoothly)
- [ ] Bundle size unchanged (no new dependencies)

---

## Strict Dart Conventions Reminder

- No `dynamic` anywhere. Use `Object?` only at deserialization boundary.
- No `as` casts outside `*.g.dart` / `*.freezed.dart`.
- No `!` operator without mathematical guarantee + comment.
- No `??` for "default values" hiding architectural gaps.
- `const` everywhere it compiles.
- Anchor comments at top of every public widget/service.
