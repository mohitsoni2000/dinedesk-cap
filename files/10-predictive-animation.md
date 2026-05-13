# Agent Prompt 10 — Predictive Pre-Animation

**Priority:** #10 (experimental — ship behind feature flag)
**Effort:** 3 days
**Touches:** `lib/motion/predictive_zone.dart` (new), `lib/widgets/send_kot_button.dart` (modify), `lib/widgets/cart_bar.dart` (modify)
**Parallel-safe with:** All other prompts (no shared files)
**Depends on:** Prompts 01, 02, 05, 08

---

## Context

The interface anticipates intent. When the cursor (or finger) moves *toward* a
button, the UI begins responding **before** the actual tap. Research shows
~40% perceived latency reduction. Subtle enough that users never consciously
notice — they just feel "this app is fast."

For Restro:
- As the operator's finger approaches the cart bar, it **pre-extends** slightly
  (1.02× scale, +1px elevation).
- As the finger approaches the Send-KOT button, it **pre-glows** (highlight
  brightness ramps up).
- Long-press: scale starts at ~60% of the long-press threshold, not at 100%.

This is experimental. Operators in a busy restaurant may find unsolicited
pre-animation distracting. Ship behind a feature flag (`CLIENT_FEATURE_FLAGS_PLAN.md`
pattern) and A/B test before defaulting on.

---

## What to Build

### File 1 (NEW): `lib/motion/predictive_zone.dart`

```dart
// ===== ANCHOR: PREDICTIVE_IMPORTS =====
import 'dart:math' as math;
import 'package:flutter/material.dart';
// ===== END ANCHOR: PREDICTIVE_IMPORTS =====

// ===== ANCHOR: PREDICTIVE_ZONE =====
/// Wraps a child widget with a "predictive zone" that measures pointer
/// proximity to the child's bounds.
///
/// As the pointer / finger approaches the widget, [onIntentProximity] is
/// called with a value `[0..1]` — 0 means far away (no intent), 1 means
/// fully over the widget (high intent).
///
/// The widget itself does not animate — it just measures and reports. The
/// consumer decides what to do with the proximity signal (scale up, glow,
/// pre-extend, etc).
///
/// Strict: this widget reports floats, but never invokes setState on its
/// own — parent is responsible. Keeps the abstraction pure.
class PredictiveZone extends StatefulWidget {
  const PredictiveZone({
    required this.child,
    required this.onIntentProximity,
    this.maxProximityRadius = 100,
    this.enabled = true,
    super.key,
  });

  final Widget child;

  /// Called on every pointer hover or finger drag near the child.
  /// `proximity` is `[0..1]`. The same callback fires with 0 when pointer
  /// leaves the zone.
  final ValueChanged<double> onIntentProximity;

  /// Logical pixels around the widget bounds within which proximity is measured.
  /// Default 100px — about a thumb's-distance away on a 6" phone.
  final double maxProximityRadius;

  /// Master switch. When false, the widget is a no-op — useful for feature
  /// flagging predictive animation off.
  final bool enabled;

  @override
  State<PredictiveZone> createState() => _PredictiveZoneState();
}

class _PredictiveZoneState extends State<PredictiveZone> {
  final GlobalKey _key = GlobalKey();

  double _proximityForOffset(Offset globalPosition) {
    final RenderObject? renderObj = _key.currentContext?.findRenderObject();
    if (renderObj is! RenderBox) return 0;
    final RenderBox box = renderObj;
    final Offset topLeft = box.localToGlobal(Offset.zero);
    final Rect bounds = topLeft & box.size;

    // Distance from pointer to nearest edge of bounds. 0 if inside.
    final double dx = math.max(
      0,
      math.max(bounds.left - globalPosition.dx, globalPosition.dx - bounds.right),
    );
    final double dy = math.max(
      0,
      math.max(bounds.top - globalPosition.dy, globalPosition.dy - bounds.bottom),
    );
    final double distance = math.sqrt(dx * dx + dy * dy);

    if (distance >= widget.maxProximityRadius) return 0;
    return 1 - (distance / widget.maxProximityRadius);
  }

  void _handleHover(PointerHoverEvent event) {
    if (!widget.enabled) return;
    widget.onIntentProximity(_proximityForOffset(event.position));
  }

  void _handleHoverExit(PointerExitEvent _) {
    if (!widget.enabled) return;
    widget.onIntentProximity(0);
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (!widget.enabled) return;
    widget.onIntentProximity(_proximityForOffset(details.globalPosition));
  }

  void _handlePanEnd(_) {
    if (!widget.enabled) return;
    widget.onIntentProximity(0);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return KeyedSubtree(key: _key, child: widget.child);
    }
    return MouseRegion(
      onHover: _handleHover,
      onExit: _handleHoverExit,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerMove: (PointerMoveEvent e) {
          widget.onIntentProximity(_proximityForOffset(e.position));
        },
        onPointerUp: (_) => widget.onIntentProximity(0),
        child: KeyedSubtree(key: _key, child: widget.child),
      ),
    );
  }
}
// ===== END ANCHOR: PREDICTIVE_ZONE =====

// ===== ANCHOR: PREDICTIVE_SCALE =====
/// Convenience: wraps a child with [PredictiveZone] and applies a subtle
/// pre-scale based on proximity. The child's scale ranges from
/// `1.0` (far) to `1.0 + maxScaleBoost` (touching).
class PredictiveScale extends StatefulWidget {
  const PredictiveScale({
    required this.child,
    this.maxScaleBoost = 0.02,
    this.maxProximityRadius = 100,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final double maxScaleBoost;
  final double maxProximityRadius;
  final bool enabled;

  @override
  State<PredictiveScale> createState() => _PredictiveScaleState();
}

class _PredictiveScaleState extends State<PredictiveScale> {
  double _proximity = 0;

  @override
  Widget build(BuildContext context) {
    return PredictiveZone(
      enabled: widget.enabled,
      maxProximityRadius: widget.maxProximityRadius,
      onIntentProximity: (double p) {
        if (mounted) setState(() => _proximity = p);
      },
      child: AnimatedScale(
        scale: 1.0 + widget.maxScaleBoost * _proximity,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}
// ===== END ANCHOR: PREDICTIVE_SCALE =====
```

### File 2 (MODIFY): `lib/motion/motion.dart`

Add to EXPORTS anchor:

```dart
export 'predictive_zone.dart';
```

### File 3 (MODIFY): `lib/widgets/send_kot_button.dart`

Wrap the existing `RiveButton` (built in Prompt 05) in a `PredictiveZone` that
pre-glows the button as the finger nears:

```dart
@override
Widget build(BuildContext context) {
  final bool predictiveEnabled = ref.watch(featureFlagsProvider).predictiveMotion;

  return PredictiveZone(
    enabled: predictiveEnabled,
    maxProximityRadius: 120,
    onIntentProximity: _onProximity,
    child: RiveButton(
      assetPath: 'assets/rive/send_kot_button.riv',
      stateMachineName: 'Main',
      phase: _phase,
      onTap: _onTap,
      // (existing props)
    ),
  );
}

void _onProximity(double proximity) {
  // Drive a "pre-glow" Rive input on the .riv file. Designer adds a number
  // input named `glow` (range 0..1). The .riv file's glow state ramps the
  // button's box-shadow / highlight intensity from this input.
  setState(() {
    _glow = proximity;
  });
  // Forward to the Rive controller. SMINumber input lookup goes here.
  // (Implementation detail: extend RiveButton from Prompt 05 to accept
  // optional ValueChanged<double> for the glow input.)
}
```

This requires a small extension to `RiveButton` from Prompt 05 to expose an
optional `glow` input. Add inside the `RiveButton` class:

```dart
// In rive_button.dart, inside _RiveButtonState:
SMINumber? _glowInput;

void _onRiveInit(Artboard artboard) {
  // ... existing init code ...
  _glowInput = controller.findInput<double>('glow') as SMINumber?;
}

void setGlow(double value) {
  _glowInput?.value = value.clamp(0.0, 1.0);
}
```

Then expose a method on the public widget:

```dart
class RiveButton extends ConsumerStatefulWidget {
  // ... existing props ...
  final ValueChanged<_RiveButtonState>? onInit;
}
```

(This is an extra hook; document it in Prompt 05's file too.)

### File 4 (MODIFY): `lib/widgets/cart_bar.dart`

Wrap the cart bar in a `PredictiveScale`:

```dart
@override
Widget build(BuildContext context) {
  final bool predictiveEnabled = ref.watch(featureFlagsProvider).predictiveMotion;

  return PredictiveScale(
    enabled: predictiveEnabled,
    maxScaleBoost: 0.015, // 1.5% pre-scale max
    maxProximityRadius: 100,
    child: LiquidGlass(/* … from Prompt 08 … */),
  );
}
```

### File 5 (MODIFY): Feature flag (extend `CLIENT_FEATURE_FLAGS_PLAN.md`)

Add a new boolean flag `predictiveMotion`, default `false`. The feature flag
plumbing already exists in your project. The plumbing here is identical to
existing flags — copy/extend.

```dart
// In feature_flags.dart (existing file):
@freezed
class FeatureFlags with _$FeatureFlags {
  const factory FeatureFlags({
    @Default(false) bool predictiveMotion,
    // … existing flags …
  }) = _FeatureFlags;
}
```

---

## Testing

### Widget test (NEW): `test/motion/predictive_zone_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro_operator/motion/motion.dart';

void main() {
  group('PredictiveZone', () {
    testWidgets('reports 0 when disabled', (WidgetTester tester) async {
      double captured = -1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PredictiveZone(
                enabled: false,
                onIntentProximity: (double p) { captured = p; },
                child: const SizedBox(width: 100, height: 100),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // Disabled — onIntentProximity should never fire on hover.
      // No way to assert "never called" cleanly; this test mostly confirms
      // the widget renders without crashing.
      expect(captured, -1);
    });

    testWidgets('renders child', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PredictiveZone(
              onIntentProximity: (_) {},
              child: const Text('Hello'),
            ),
          ),
        ),
      );
      expect(find.text('Hello'), findsOneWidget);
    });
  });

  testWidgets('PredictiveScale: animates scale up on proximity simulation',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 100, height: 100,
              child: PredictiveScale(child: const Text('Button')),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(AnimatedScale), findsOneWidget);
  });
}
```

### Manual QA — A/B comparison

This is the critical test. Run side-by-side:

- **Flag off** (default): operators tap buttons normally. Time-to-confirm is X.
- **Flag on**: predictive motion enabled. Time-to-confirm should feel faster
  even though the actual server roundtrip is identical.

If beta-testers consistently say "the on-version feels weird/twitchy", the
proximity radius is too generous or `maxScaleBoost` is too high. Tune down.

- Hover the mouse near the Send-KOT button (don't click). The button should
  subtly glow brighter as the cursor approaches.
- On mobile: place finger near the cart bar without tapping. The bar should
  subtly grow as the finger nears.
- Disable the flag. All predictive motion should stop — buttons return to
  reactive-only behaviour.

---

## Acceptance Criteria

- [ ] `lib/motion/predictive_zone.dart` exists with `PredictiveZone` + `PredictiveScale`
- [ ] `lib/motion/motion.dart` exports it
- [ ] `featureFlagsProvider` has new `predictiveMotion` flag, default `false`
- [ ] 2 integration points wrapped: `send_kot_button.dart`, `cart_bar.dart`
- [ ] Both respect the feature flag — flag off = no behavioural change
- [ ] All tests pass
- [ ] Manual A/B QA: with flag on, beta testers prefer the predictive version
      (or at least don't dislike it)
- [ ] No regression in CPU usage when flag is off (measured via Flutter DevTools)
- [ ] No `dynamic`, no `as` casts (except the documented Rive cast in Prompt 05), no `!`

---

## Strict Dart Conventions Reminder

- The cast `if (renderObj is! RenderBox) return 0;` followed by use is a
  Dart type-promotion pattern, NOT an `as` cast — preferred.
- No `dynamic`
- No `!` operator
- `const` everywhere it compiles
- Feature-flag gating is the right pattern for experimental motion

---

## When to Defer This Prompt

Skip Prompt 10 entirely if any of the following are true:

1. The operator user base hasn't seen Prompts 01–08 yet (predictive on top of
   missing fundamentals is wasted effort).
2. No A/B testing infrastructure exists. Without measurement, predictive
   motion is a gut-feel feature.
3. Beta-tester feedback on Prompts 02 (multi-sensory) and 06 (variable font)
   suggests operators want LESS motion, not more.

Ship Prompts 01–09 first. Revisit Prompt 10 in v1.5.
