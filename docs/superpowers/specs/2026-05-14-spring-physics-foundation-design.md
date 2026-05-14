# Spring Physics Foundation — Design Spec

**Date:** 2026-05-14
**Status:** Approved
**Scope:** Prompt 01 (Spring Physics) adapted to actual codebase
**Effort:** ~1.5 days
**Dependencies added:** None (uses `flutter/physics.dart` from SDK)

---

## Goal

Replace mechanical `Curves.*` easing animations with spring physics throughout
the Restro Operator app. Springs are interruption-safe (re-target mid-flight
without snapping) and produce organic overshoot-and-settle motion that feels
premium and native.

This is the motion foundation — all subsequent motion prompts (02–10) build on
`RestroSprings` tokens defined here.

---

## New Files

### 1. `lib/motion/springs.dart`

Contains three public APIs:

**`RestroSprings`** — 4 spring tokens covering 95% of use cases:

| Token | Stiffness | Damping | Mass | Overshoot | Use for |
|---|---|---|---|---|---|
| `soft` | 280 | 24 | 1.0 | None | Card entrance, drawer open, list reveal |
| `snappy` | 400 | 22 | 1.0 | ~3% | Button press, PIN dot fill, cart badge |
| `bouncy` | 350 | 16 | 1.0 | ~15% | Success states, KOT fire, celebrations |
| `heavy` | 180 | 22 | 2.5 | None | Sheet open, modal entrance |

**`SpringBuilder`** — `StatefulWidget` that replaces `TweenAnimationBuilder`.
Drives a `SpringSimulation` via an unbounded `AnimationController`. When `to`
changes mid-flight, the spring re-targets from current position and velocity —
no snap.

**`SpringTransitions`** — Extension on `Widget` with convenience methods:
- `.springScale(to:, spring:)` — wraps in `SpringBuilder` + `Transform.scale`
- `.springTranslateY(to:, spring:)` — wraps in `SpringBuilder` + `Transform.translate`

### 2. `lib/motion/motion.dart`

Barrel export: `export 'springs.dart';`

---

## Migration Map

### Files to migrate (5 files, 7 animation sites)

#### `lib/widgets/connection_banner.dart`

- **Line 82:** `AnimatedSlide(offset: ..., curve: Curves.easeOutCubic)`
  - Replace with `SpringBuilder(to: ..., spring: RestroSprings.snappy)` driving `Transform.translate`
- **Line 88:** `AnimatedOpacity` paired with slide
  - Drive opacity from the same `SpringBuilder` value (0→1 maps to hidden→visible)

#### `lib/screens/splash_screen.dart`

- **Line 45:** `CurvedAnimation(curve: Curves.easeOut)` driving `FadeTransition`
- **Line 48:** `CurvedAnimation(curve: Curves.easeOutCubic)` driving `ScaleTransition`
  - Replace both with a single `SpringBuilder(from: 0, to: 1, spring: RestroSprings.bouncy)` driving scale + opacity in the builder. The `AnimationController` stays for timing, but the visual interpolation is spring-driven.
  - Approach: Replace `FadeTransition` + `ScaleTransition` with `SpringBuilder` that builds `Opacity` + `Transform.scale`.

#### `lib/screens/order_success_screen.dart`

- **Line 61:** `CurvedAnimation(curve: Curves.easeOutCubic)` driving `SlideTransition`
  - Replace with `SpringBuilder(from: 0, to: 1, spring: RestroSprings.soft)` driving translate + opacity. The `_txt` AnimationController triggers the spring start via a boolean flag after the 500ms delay.

#### `lib/widgets/liquid_chrome.dart`

- **Line 167:** `AnimatedScale(scale: _pressed ? 0.97 : 1.0)` in `LiquidPrimaryButton`
  - Replace with `SpringBuilder(to: _pressed ? 0.97 : 1.0, spring: RestroSprings.snappy)` + `Transform.scale`. This makes rapid tap-release cycles silky instead of linear.
- **Line 229:** Same pattern in `LiquidSecondaryButton`
  - Same replacement.

### Files kept as-is (4 files, justified)

| File | Line | Pattern | Justification |
|---|---|---|---|
| `animated_check_draw.dart` | 41 | `Curves.elasticOut.transform()` | Drawing interpolation inside `CustomPainter`, not a widget animation. One-shot pop+draw sequence — elastic curve is the correct tool. |
| `page_transitions.dart` | 23–24 | `CurvedAnimation(easeOutCubic/easeIn)` | go_router owns the `Animation<double>`. Can't inject spring without custom `Curve` wrapper, losing re-targeting. Addressed by Prompt 03 (Hero Transitions). |
| `connecting_screen.dart` | 211 | `CurvedAnimation(easeOut)` | Repeating pulse ring. Springs settle at a target; they don't loop. `easeOut` on a repeating controller is correct. |
| `tables_screen.dart` | 307 | `AnimatedContainer(curve: easeOutCubic)` | Pure color transition (floor tab bg). Spring overshoot on color has no perceptual benefit. |
| `order_builder_screen.dart` | 309 | `AnimatedContainer(curve: easeOutCubic)` | Pure color transition (section chip bg). Same reasoning. |
| `liquid_chrome.dart` | 75 | `AnimatedContainer(curve: easeOutCubic)` | Pure color transition (bottom nav active bg). Same reasoning. |

---

## Testing

### New file: `test/motion/springs_test.dart`

Three widget tests:

1. **Settles at target** — `SpringBuilder(from: 0, to: 1, spring: snappy)` → `pumpAndSettle` → value `closeTo(1.0, 0.005)`
2. **Bouncy overshoots** — `SpringBuilder(spring: bouncy)` → pump 40 frames → max observed `> 1.10` and `< 1.30`
3. **Re-targets mid-flight** — Change `to` after 100ms → `pumpAndSettle` → no assertion thrown (no snap)

Import: `package:restro/motion/motion.dart`

---

## Acceptance Criteria

- [ ] `lib/motion/springs.dart` exists with `RestroSprings`, `SpringBuilder`, `SpringTransitions`
- [ ] `lib/motion/motion.dart` barrel exports `springs.dart`
- [ ] 5 files migrated (7 animation sites) per migration map above
- [ ] 4 files kept as-is per justification table
- [ ] `flutter analyze` passes (0 errors)
- [ ] `flutter test test/motion/springs_test.dart` passes all 3 tests
- [ ] No `dynamic`, no `as` casts, no `!` operator in new code
- [ ] Remaining `Curves.*` in codebase are only in the justified keep-as-is files

## What this does NOT include

- No new dependencies in `pubspec.yaml`
- No `freezed` adoption (master plan assumed it existed; it doesn't)
- No anchor comments (designed for parallel agents; this is a single-pass implementation)
- No audio, Rive, or font assets (those are Prompts 02–06)

---

## Codebase Adaptations from Original Prompt 01

| Prompt 01 says | Reality | Adaptation |
|---|---|---|
| Package: `restro_operator` | Package: `restro` | Use `package:restro/motion/motion.dart` |
| Path: `flutter/lib/motion/` | Path: `lib/motion/` | Drop `flutter/` prefix |
| Migrate `auth_screen.dart` | No `Curves.*` found | Skip |
| Migrate `disconnected_screen.dart` | No `Curves.*` found | Skip |
| Migrate `root_shell.dart` | No `Curves.*` found | Skip |
| Not listed | `liquid_chrome.dart` has `AnimatedScale` | Add to migration |
| Not listed | `connecting_screen.dart` pulse | Keep — repeating animation |
| `freezed` in deps | Not in project | No freezed usage |
