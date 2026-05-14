# Motion 2026 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 2026 motion primitives (spring physics, multi-sensory feedback, hero transitions, Rive state machine, variable font counter, depth parallax, predictive animation) to the Restro Operator Flutter app.

**Architecture:** 7 of the 10 original prompts, adapted to the actual codebase. Prompts 04 (Mesh Gradients), 07 (Particles), 08 (Liquid Glass) skipped — existing `liquid_mesh_background.dart`, `confetti_burst.dart`, and `liquid_glass_surface.dart` already cover those features. All new code lives in `lib/motion/` with a barrel export. Package name is `restro` (not `restro_operator`). No `freezed` dependency.

**Tech Stack:** Flutter 3.24+, Dart 3.5+, Riverpod, go_router, `flutter/physics.dart` (SDK), audioplayers, animations, rive, sensors_plus

**Skipped Prompts (already implemented):**
- Prompt 04 (Mesh Gradients) → `lib/widgets/liquid_mesh_background.dart`
- Prompt 07 (Generative Particles) → `lib/widgets/confetti_burst.dart`
- Prompt 08 (Liquid Glass) → `lib/widgets/liquid_glass_surface.dart` + `lib/widgets/liquid_chrome.dart`

---

## Phase 1 — Foundation (Parallel: Tasks 1 + 2)

### Task 1: Spring Physics (Prompt 01)

**Files:**
- Create: `lib/motion/springs.dart`
- Create: `lib/motion/motion.dart`
- Create: `test/motion/springs_test.dart`
- Modify: `lib/widgets/connection_banner.dart:81-89`
- Modify: `lib/screens/splash_screen.dart:44-49`
- Modify: `lib/screens/order_success_screen.dart:55-61`
- Modify: `lib/widgets/liquid_chrome.dart:165-167,229-230`

- [ ] **Step 1: Create `lib/motion/springs.dart`**

```dart
import 'package:flutter/animation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// Spring tokens used throughout Restro Operator.
///
/// Four springs cover 95% of cases. Use [soft] for gentle reveals,
/// [snappy] for taps and badges, [bouncy] for celebrations,
/// [heavy] for sheets and modals.
class RestroSprings {
  const RestroSprings._();

  static const SpringDescription soft = SpringDescription(
    mass: 1.0, stiffness: 280.0, damping: 24.0,
  );

  static const SpringDescription snappy = SpringDescription(
    mass: 1.0, stiffness: 400.0, damping: 22.0,
  );

  static const SpringDescription bouncy = SpringDescription(
    mass: 1.0, stiffness: 350.0, damping: 16.0,
  );

  static const SpringDescription heavy = SpringDescription(
    mass: 2.5, stiffness: 180.0, damping: 22.0,
  );
}

/// Drop-in replacement for [TweenAnimationBuilder] driven by a [SpringSimulation].
/// Interruption-safe: if [to] changes mid-flight, the spring re-targets
/// from current position with current velocity.
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
      widget.spring, widget.from, widget.to, widget.velocity,
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
      _simulation = SpringSimulation(
        widget.spring, _currentValue, widget.to, _currentVelocity,
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

/// Convenience extension for chaining springs onto common widget transforms.
extension SpringTransitions on Widget {
  Widget springScale({
    required double to,
    double from = 0.0,
    SpringDescription spring = RestroSprings.snappy,
    Key? key,
  }) {
    return SpringBuilder(
      key: key, from: from, to: to, spring: spring,
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
      key: key, from: from, to: to, spring: spring,
      builder: (BuildContext context, double value, Widget? child) {
        return Transform.translate(offset: Offset(0, value), child: child);
      },
      child: this,
    );
  }
}
```

- [ ] **Step 2: Create `lib/motion/motion.dart` barrel**

```dart
export 'springs.dart';
```

- [ ] **Step 3: Create `test/motion/springs_test.dart`**

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/motion/motion.dart';

void main() {
  group('SpringBuilder', () {
    testWidgets('settles at target value', (WidgetTester tester) async {
      double captured = -1.0;
      await tester.pumpWidget(
        SpringBuilder(
          from: 0.0, to: 1.0, spring: RestroSprings.snappy,
          builder: (BuildContext _, double v, Widget? __) {
            captured = v;
            return const SizedBox.shrink();
          },
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect(captured, closeTo(1.0, 0.005));
    });

    testWidgets('bouncy spring overshoots target', (WidgetTester tester) async {
      double maxObserved = 0.0;
      await tester.pumpWidget(
        SpringBuilder(
          from: 0.0, to: 1.0, spring: RestroSprings.bouncy,
          builder: (BuildContext _, double v, Widget? __) {
            if (v > maxObserved) maxObserved = v;
            return const SizedBox.shrink();
          },
        ),
      );
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
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
              from: 0.0, to: targetValue, spring: RestroSprings.soft,
              builder: (BuildContext _, double v, Widget? __) => const SizedBox.shrink(),
            );
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      setStateOuter(() { targetValue = 0.5; });
      await tester.pumpAndSettle(const Duration(seconds: 2));
    });
  });
}
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/motion/springs_test.dart`
Expected: 3 tests pass

- [ ] **Step 5: Migrate `connection_banner.dart` — replace AnimatedSlide + AnimatedOpacity with SpringBuilder**

In `lib/widgets/connection_banner.dart`, replace the `AnimatedSlide` + `AnimatedOpacity` block (lines 81-89) with:

```dart
// Replace AnimatedSlide + AnimatedOpacity with SpringBuilder
child: SpringBuilder(
  from: 1.0,
  to: conn.online ? 0.0 : 1.0,
  spring: RestroSprings.snappy,
  builder: (BuildContext _, double value, Widget? child) {
    return Transform.translate(
      offset: Offset(0, -80 * (1 - value)),
      child: Opacity(opacity: value, child: child),
    );
  },
  child: TickerMode(
    enabled: !conn.online,
    child: SafeArea(
```

Add import: `import '../motion/motion.dart';`

- [ ] **Step 6: Migrate `splash_screen.dart` — replace FadeTransition + ScaleTransition with SpringBuilder**

Replace the `AnimationController` + `CurvedAnimation` pattern with `SpringBuilder`. The screen still uses a delayed trigger, but the visual interpolation is spring-driven.

Replace `_SplashScreenState` to use `SpringBuilder` instead of `FadeTransition` + `ScaleTransition`. Change `SingleTickerProviderStateMixin` to regular `State`. Add a `_show` bool that triggers after initState. The `SpringBuilder` drives scale + opacity in its builder.

Add import: `import '../motion/motion.dart';`

- [ ] **Step 7: Migrate `order_success_screen.dart` — replace SlideTransition with SpringBuilder**

Replace the `CurvedAnimation(curve: Curves.easeOutCubic)` driving `SlideTransition` (line 55-74) with a `SpringBuilder` that drives translate + fade. Keep the 500ms delay via the existing `_show` pattern.

Add import: `import '../motion/motion.dart';`

- [ ] **Step 8: Migrate `liquid_chrome.dart` — replace AnimatedScale on buttons with SpringBuilder**

In `LiquidPrimaryButton` (line 165-167), replace:
```dart
child: AnimatedScale(
  scale: _pressed ? 0.97 : 1.0,
  duration: const Duration(milliseconds: 100),
```
with:
```dart
child: SpringBuilder(
  to: _pressed ? 0.97 : 1.0,
  spring: RestroSprings.snappy,
  builder: (BuildContext _, double scale, Widget? child) {
    return Transform.scale(scale: scale, child: child);
  },
```

Same for `LiquidSecondaryButton` (line 229-230).

Add import: `import '../motion/motion.dart';`

- [ ] **Step 9: Run flutter analyze**

Run: `flutter analyze`
Expected: 0 errors

- [ ] **Step 10: Commit**

```bash
git add lib/motion/ test/motion/ lib/widgets/connection_banner.dart lib/screens/splash_screen.dart lib/screens/order_success_screen.dart lib/widgets/liquid_chrome.dart
git commit -m "feat(motion): add spring physics foundation and migrate 5 files from Curves.* to springs"
```

---

### Task 2: Multi-Sensory Feedback (Prompt 02)

**Files:**
- Create: `lib/motion/feedback_kind.dart`
- Create: `lib/motion/feedback_service.dart`
- Create: `test/motion/feedback_service_test.dart`
- Create: `assets/audio/` (6 placeholder files)
- Modify: `lib/motion/motion.dart`
- Modify: `pubspec.yaml`
- Modify: `lib/main.dart`
- Modify: 6 screen files (integration points)

**Note:** Audio `.caf` files cannot be generated by code. Create empty placeholder files. Sound designer replaces them later.

- [ ] **Step 1: Add `audioplayers` to pubspec.yaml**

Add under `dependencies:`:
```yaml
audioplayers: ^6.1.0
```

Add under `flutter: assets:`:
```yaml
- assets/audio/
```

- [ ] **Step 2: Create placeholder audio files**

```bash
mkdir -p assets/audio
for f in tap_light tap_medium tap_heavy success_chime error_buzz warning_tone; do
  touch assets/audio/$f.mp3
done
```

Using `.mp3` instead of `.caf` for cross-platform compatibility.

- [ ] **Step 3: Create `lib/motion/feedback_kind.dart`**

Sealed `FeedbackKind` with 7 subtypes: `FeedbackLight`, `FeedbackMedium`, `FeedbackHeavy`, `FeedbackSuccess`, `FeedbackError`, `FeedbackWarning`, `FeedbackSelection`. Each maps to haptic + audio asset path via extensions.

Audio paths use `.mp3` extension instead of `.caf`.

- [ ] **Step 4: Create `lib/motion/feedback_service.dart`**

`FeedbackService` with audio player pool (size 3), round-robin playback, fire-and-forget pattern. Riverpod `feedbackServiceProvider`.

- [ ] **Step 5: Update `lib/motion/motion.dart` barrel**

```dart
export 'springs.dart';
export 'feedback_kind.dart';
export 'feedback_service.dart';
```

- [ ] **Step 6: Update `lib/main.dart` to init FeedbackService**

Change from:
```dart
void main() => runApp(const ProviderScope(child: RestroApp()));
```
to:
```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  final feedback = container.read(feedbackServiceProvider);
  await feedback.init();
  runApp(UncontrolledProviderScope(
    container: container,
    child: const RestroApp(),
  ));
}
```

- [ ] **Step 7: Create `test/motion/feedback_service_test.dart`**

Tests: all kinds map to haptic without throwing, audio asset paths are valid or null.

- [ ] **Step 8: Wire feedback into screens**

| Screen | Action | Kind |
|---|---|---|
| `auth_screen.dart` | Numpad key press | `FeedbackMedium()` |
| `auth_screen.dart` | PIN correct | `FeedbackSuccess()` |
| `auth_screen.dart` | PIN wrong | `FeedbackError()` |
| `tables_screen.dart` | Table card tap | `FeedbackMedium()` |
| `order_builder_screen.dart` | Item add-to-cart (+) | `FeedbackLight()` |
| `order_builder_screen.dart` | Category tab switch | `FeedbackSelection()` |
| `order_review_screen.dart` | Send KOT | `FeedbackHeavy()` |
| `order_success_screen.dart` | Screen enter | `FeedbackSuccess()` |
| `connection_banner.dart` | 30s remaining | `FeedbackWarning()` |

Pattern: `ref.read(feedbackServiceProvider).fire(const FeedbackHeavy());`

- [ ] **Step 9: Run tests + analyze**

Run: `flutter test test/motion/feedback_service_test.dart && flutter analyze`
Expected: all pass, 0 errors

- [ ] **Step 10: Commit**

```bash
git add lib/motion/feedback_kind.dart lib/motion/feedback_service.dart lib/motion/motion.dart lib/main.dart assets/audio/ pubspec.yaml test/motion/feedback_service_test.dart lib/screens/ lib/widgets/connection_banner.dart
git commit -m "feat(motion): add multi-sensory feedback service with haptic + audio coordination"
```

---

## Phase 2 — Spatial (Depends on Task 1)

### Task 3: Hero Transitions (Prompt 03)

**Files:**
- Create: `lib/motion/hero_tags.dart`
- Create: `lib/motion/morph_container.dart`
- Create: `test/motion/hero_tags_test.dart`
- Modify: `lib/motion/motion.dart`
- Modify: `pubspec.yaml` (add `animations: ^2.0.11`)
- Modify: `lib/screens/splash_screen.dart`
- Modify: `lib/screens/qr_scan_screen.dart`
- Modify: `lib/screens/connecting_screen.dart`
- Modify: `lib/screens/tables_screen.dart`
- Modify: `lib/screens/order_builder_screen.dart`
- Modify: `lib/screens/order_success_screen.dart`

- [ ] **Step 1: Add `animations` to pubspec.yaml**

```yaml
animations: ^2.0.11
```

- [ ] **Step 2: Create `lib/motion/hero_tags.dart`**

Centralised registry of all Hero tags. Static strings for known elements, factory methods with table ID for per-table tags.

- [ ] **Step 3: Create `lib/motion/morph_container.dart`**

`RestroMorph` wrapping `OpenContainer` + `restroFadeShuttle` helper for text morph during flight. The one `as Hero` cast in `restroFadeShuttle` is documented as mathematically safe.

- [ ] **Step 4: Update barrel + create test**

Add exports to `motion.dart`. Create `test/motion/hero_tags_test.dart` — test tag uniqueness and disambiguation.

- [ ] **Step 5: Wire Hero tags into screens**

Replace existing stringly-typed `Hero(tag: 'table-${table.id}')` patterns in `tables_screen.dart` and `order_builder_screen.dart` with `HeroTags.tableCard(tableId)`.

Add `HeroTags.appLogo` to splash + QR scan. Add `HeroTags.pairingCore` to connecting screen.

- [ ] **Step 6: Run tests + analyze, commit**

```bash
flutter test test/motion/hero_tags_test.dart && flutter analyze
git commit -m "feat(motion): add hero transitions with centralised tag registry and OpenContainer morph"
```

---

## Phase 3 — Identity (Parallel: Tasks 4 + 5)

### Task 4: Rive State Machine — Send KOT Button (Prompt 05)

**Files:**
- Create: `lib/motion/rive_button.dart`
- Create: `lib/widgets/send_kot_button.dart`
- Create: `design/RIVE_SEND_KOT_BUTTON_BRIEF.md`
- Create: `assets/rive/send_kot_button.riv` (placeholder)
- Create: `test/motion/rive_button_test.dart`
- Modify: `lib/motion/motion.dart`
- Modify: `pubspec.yaml` (add `rive: ^0.13.20`)
- Modify: `lib/screens/order_review_screen.dart`

**Note:** Requires designer to author the `.riv` file. Ship with a placeholder (empty artboard). The button still functions — it renders as an empty box until the real asset arrives.

- [ ] **Step 1: Add `rive` to pubspec.yaml, register assets**

```yaml
rive: ^0.13.20
```
```yaml
flutter:
  assets:
    - assets/rive/
```

- [ ] **Step 2: Create placeholder .riv and designer brief**

```bash
mkdir -p assets/rive design
touch assets/rive/send_kot_button.riv
```

Write `design/RIVE_SEND_KOT_BUTTON_BRIEF.md` with the designer brief from Prompt 05.

- [ ] **Step 3: Create `lib/motion/rive_button.dart`**

Sealed `RiveButtonPhase` (Idle/Loading/Success/Error) + `RiveButton` widget that binds Rive triggers. The `as SMITrigger?` casts are documented as required by Rive's API.

- [ ] **Step 4: Create `lib/widgets/send_kot_button.dart`**

`SendKotButton` + `SendKotButtonController` wrapping `RiveButton` for KOT-specific lifecycle.

- [ ] **Step 5: Update barrel, create test**

Export `rive_button.dart`. Create `test/motion/rive_button_test.dart`.

- [ ] **Step 6: Wire into `order_review_screen.dart`**

Replace the current submit button with `SendKotButton`. Adapt `_submit()` to use `SendKotButtonController.confirmSuccess()` / `confirmError()`.

- [ ] **Step 7: Run tests + analyze, commit**

```bash
flutter analyze && flutter test test/motion/rive_button_test.dart
git commit -m "feat(motion): add Rive state-machine Send KOT button with 4-state lifecycle"
```

---

### Task 5: Variable Font Kinetic Counter (Prompt 06)

**Files:**
- Create: `lib/motion/kinetic_counter.dart`
- Create: `test/motion/kinetic_counter_test.dart`
- Modify: `lib/motion/motion.dart`
- Modify: `pubspec.yaml` (font registration)
- Modify: `lib/screens/order_builder_screen.dart`
- Modify: `lib/screens/order_success_screen.dart`

**Note:** Requires downloading Fraunces variable TTF from Google Fonts (the variable build with opsz, SOFT, WONK, wght axes). If font not available, the widget still renders with default font.

- [ ] **Step 1: Download Fraunces variable font**

Download from Google Fonts → Fraunces → Download family → extract the variable TTF.
Place at `assets/fonts/Fraunces[opsz,SOFT,WONK,wght].ttf`.

Register in `pubspec.yaml`:
```yaml
- family: Fraunces
  fonts:
    - asset: assets/fonts/Fraunces[opsz,SOFT,WONK,wght].ttf
```

- [ ] **Step 2: Create `lib/motion/kinetic_counter.dart`**

`CounterAxisMap` (maps rupee amount to font variation axes) + `KineticRupeeCounter` (animated ₹ counter with axis morphing) + `KineticKotNumber` (bold italic reveal for KOT number).

Indian locale grouping via `NumberFormat.decimalPattern('en_IN')`.

- [ ] **Step 3: Update barrel, create test**

Export `kinetic_counter.dart`. Create `test/motion/kinetic_counter_test.dart` — test `CounterAxisMap.lerp`, `forAmount`, and Indian locale formatting.

- [ ] **Step 4: Wire into screens**

- `order_builder_screen.dart`: Replace cart total text with `KineticRupeeCounter(amount: cartTotal, fontSize: 18)`
- `order_success_screen.dart`: Replace KOT number with `KineticKotNumber`

- [ ] **Step 5: Run tests + analyze, commit**

```bash
flutter test test/motion/kinetic_counter_test.dart && flutter analyze
git commit -m "feat(motion): add variable font kinetic counter with axis morphing"
```

---

## Phase 4 — Premium (Parallel: Tasks 6 + 7)

### Task 6: Variable Depth Parallax (Prompt 09)

**Files:**
- Create: `lib/motion/depth_parallax.dart`
- Create: `test/motion/depth_parallax_test.dart`
- Modify: `lib/motion/motion.dart`
- Modify: `pubspec.yaml` (add `sensors_plus: ^6.1.0`)
- Modify: `lib/widgets/item_detail_sheet.dart`
- Modify: `lib/screens/splash_screen.dart`

- [ ] **Step 1: Add `sensors_plus` to pubspec.yaml**

```yaml
sensors_plus: ^6.1.0
```

- [ ] **Step 2: Create `lib/motion/depth_parallax.dart`**

`DepthLayer` (child + depth 0..1) + `DepthParallaxStack` (gyroscope-driven multi-layer parallax with smoothing, decay-to-centre, and reduced-motion accessibility guard).

- [ ] **Step 3: Update barrel, create test**

Export `depth_parallax.dart`. Create `test/motion/depth_parallax_test.dart` — test depth validation and layer rendering.

- [ ] **Step 4: Wire into screens**

- `item_detail_sheet.dart`: Wrap detail header in `DepthParallaxStack` with 3 layers (background, content, label)
- `splash_screen.dart`: Add depth layers to splash logo

- [ ] **Step 5: Run tests + analyze, commit**

```bash
flutter test test/motion/depth_parallax_test.dart && flutter analyze
git commit -m "feat(motion): add gyroscope depth parallax with 3-layer stack"
```

---

### Task 7: Predictive Pre-Animation (Prompt 10)

**Files:**
- Create: `lib/motion/predictive_zone.dart`
- Create: `test/motion/predictive_zone_test.dart`
- Modify: `lib/motion/motion.dart`
- Modify: `lib/models/feature_flags.dart` (add `predictiveMotion` flag)

**Note:** This is experimental. Ships behind a feature flag (`predictiveMotion`, default `false`). Integration into `send_kot_button.dart` and cart bar deferred until flag infrastructure is tested.

- [ ] **Step 1: Create `lib/motion/predictive_zone.dart`**

`PredictiveZone` (measures pointer proximity to child bounds, reports 0..1) + `PredictiveScale` (convenience wrapper that applies subtle scale based on proximity). Both respect `enabled` flag.

- [ ] **Step 2: Add `predictiveMotion` flag to `FeatureFlags`**

In `lib/models/feature_flags.dart`, add:
```dart
final bool predictiveMotion;
```
Default `false`. Add to constructor and `fromMap`.

- [ ] **Step 3: Update barrel, create test**

Export `predictive_zone.dart`. Create `test/motion/predictive_zone_test.dart` — test disabled state and child rendering.

- [ ] **Step 4: Run tests + analyze, commit**

```bash
flutter test test/motion/predictive_zone_test.dart && flutter analyze
git commit -m "feat(motion): add predictive pre-animation zone behind feature flag"
```

---

## Phase 5 — Polish

### Task 8: Final Verification & Cleanup

- [ ] **Step 1: Run full test suite**

```bash
flutter test
```

- [ ] **Step 2: Run flutter analyze**

```bash
flutter analyze
```

- [ ] **Step 3: Verify no forbidden patterns in new code**

```bash
grep -rn 'dynamic' lib/motion/
grep -rn ' as ' lib/motion/ | grep -v '.g.dart' | grep -v '.freezed.dart'
```

Only allowed: `as SMITrigger?` in `rive_button.dart` (documented).

- [ ] **Step 4: Verify remaining Curves.* are only in justified files**

```bash
grep -rn 'Curves\.' lib/
```

Expected: only in `animated_check_draw.dart`, `page_transitions.dart`, `connecting_screen.dart`, `tables_screen.dart` (color AnimatedContainer), `order_builder_screen.dart` (color AnimatedContainer), `liquid_chrome.dart` (bottom nav color).

- [ ] **Step 5: Verify barrel exports all motion files**

`lib/motion/motion.dart` should export:
```dart
export 'springs.dart';
export 'feedback_kind.dart';
export 'feedback_service.dart';
export 'hero_tags.dart';
export 'morph_container.dart';
export 'rive_button.dart';
export 'kinetic_counter.dart';
export 'depth_parallax.dart';
export 'predictive_zone.dart';
```

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "chore(motion): final verification pass — all 7 motion prompts implemented"
```

---

## Dependency Graph

```
Task 1 (Springs) ──┬──→ Task 3 (Hero) ──→ Task 4 (Rive) ──→ Task 7 (Predictive)
                    │                       Task 5 (Counter) ─┘
Task 2 (Feedback) ──┘                       Task 6 (Parallax) ─┘
```

Tasks 1 + 2 are parallel (Phase 1).
Task 3 depends on Task 1.
Tasks 4 + 5 are parallel (Phase 3), both depend on Task 1.
Tasks 6 + 7 are parallel (Phase 4), both depend on Task 1.
Task 8 depends on all.

## New Dependencies Summary

```yaml
# pubspec.yaml additions
audioplayers: ^6.1.0     # Task 2 — multi-sensory feedback
animations: ^2.0.11      # Task 3 — hero transitions (OpenContainer)
rive: ^0.13.20           # Task 4 — Rive state machine
sensors_plus: ^6.1.0     # Task 6 — gyroscope parallax
```

## New Assets Summary

```
assets/audio/tap_light.mp3        # Placeholder — Task 2
assets/audio/tap_medium.mp3       # Placeholder — Task 2
assets/audio/tap_heavy.mp3        # Placeholder — Task 2
assets/audio/success_chime.mp3    # Placeholder — Task 2
assets/audio/error_buzz.mp3       # Placeholder — Task 2
assets/audio/warning_tone.mp3     # Placeholder — Task 2
assets/rive/send_kot_button.riv   # Placeholder — Task 4
assets/fonts/Fraunces[...].ttf    # Download from Google Fonts — Task 5
```
