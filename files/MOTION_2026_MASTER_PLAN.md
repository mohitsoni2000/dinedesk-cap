# Restro Operator — 2026 Motion Implementation Master Plan

**Status:** Draft v1.0
**Targets:** Flutter 3.24+, Dart 3.5+, iOS 14+, Android 8+ (API 26+)
**Companion:** `OPERATOR_FLUTTER_APP_PLAN.md`, `OPERATOR_MOBILE_APP_MASTER_PLAN.md`
**Prompts:** `prompts/01-spring-physics.md` through `prompts/10-predictive-animation.md`

> All Dart code in this plan and its prompts follows the project's strict ruleset:
> **no `dynamic`** (only `Object?` at deserialization boundary), **no `as` casts** outside
> generated files, **sealed classes** for unions, **freezed** for immutable data,
> **no `!` operator** without mathematical guarantee, **no `??` fallbacks** for
> default values hiding architectural gaps.

---

## 1. Why This Plan Exists

The 2026 motion research file (`restro-2026-trends.html`) identified 12 cutting-edge
animation trends — Liquid Glass surface tension, spring physics, Rive state machines,
variable font kinetics, generative particles, multi-sensory feedback, etc.

This plan converts those trends into **shippable Flutter code** in 10 numbered
agent prompts, each runnable by a Claude Code agent in parallel where possible.
The prompts are self-contained — drop one into Claude Code, get production-ready
output.

---

## 2. Phased Roadmap

Ten trends, four weeks, six phases. Each phase has parallel-runnable prompts
where there are no shared files. Anchor-comment pattern (`// ===== ANCHOR: NAME =====`)
is used in any shared file to prevent merge conflicts.

| Phase | Week | Trends | Parallelizable | Effort |
|---|---|---|---|---|
| 1 — Foundation | 1 | Spring Physics (#01) + Multi-Sensory Feedback (#02) | YES | 4 days |
| 2 — Spatial | 2 | Hero Transitions (#03) + Mesh Gradients (#04) | YES | 5 days |
| 3 — Identity | 3 | Rive State Machine (#05) + Variable Font Counter (#06) | YES | 6 days |
| 4 — Delight | 4 | Generative Particles (#07) + Liquid Glass (#08) | YES | 7 days |
| 5 — Premium | 5+ | Variable Depth Parallax (#09) + Predictive Animation (#10) | YES | 5 days |
| 6 — Polish | 5+ | Cross-cutting refinement pass, accessibility audit | NO | 3 days |

Total: ~30 working days for a single agent, **~3 weeks with 2–3 agents in parallel**.

---

## 3. Folder Structure Changes

```
flutter/
├── lib/
│   ├── motion/                          # NEW — all motion primitives
│   │   ├── springs.dart                 # Phase 1 — spring tokens + SpringBuilder
│   │   ├── feedback_service.dart        # Phase 1 — haptic + audio + visual coordinator
│   │   ├── feedback_kind.dart           # Phase 1 — sealed feedback union
│   │   ├── hero_tags.dart               # Phase 2 — centralised hero tag registry
│   │   ├── mesh_gradient.dart           # Phase 2 — animated mesh widget
│   │   ├── rive_button.dart             # Phase 3 — state-machine button wrapper
│   │   ├── kinetic_counter.dart         # Phase 3 — variable-font rupee counter
│   │   ├── particle_emitter.dart        # Phase 4 — newton_particles wrapper
│   │   ├── liquid_glass.dart            # Phase 4 — pointer-tracked glass widget
│   │   ├── depth_parallax.dart          # Phase 5 — gyroscope parallax stack
│   │   ├── predictive_zone.dart         # Phase 5 — pre-animation trigger zone
│   │   └── motion.dart                  # Public barrel export
│   ├── widgets/                         # MODIFIED — existing widgets use motion/
│   ├── screens/                         # MODIFIED — wrap key elements in Hero/etc.
│   └── design/
│       └── tokens.dart                  # MODIFIED — add motion duration tokens
├── assets/
│   ├── audio/                           # NEW — for FeedbackService
│   │   ├── tap_light.caf                # 80ms soft click — cart add
│   │   ├── tap_heavy.caf                # 120ms thump — KOT fire
│   │   ├── success_chime.caf            # 320ms warm chime — KOT success
│   │   └── error_buzz.caf               # 200ms low buzz — wrong PIN
│   ├── rive/                            # NEW — Rive state machine files
│   │   ├── send_kot_button.riv          # 4 states: idle/loading/success/error
│   │   ├── connection_indicator.riv     # 5 states: connected/reconnecting/... 
│   │   └── kot_printer.riv              # 3 states: queued/printing/printed
│   └── fonts/
│       ├── Fraunces[opsz,SOFT,WONK,wght].ttf   # NEW — variable font
│       └── BricolageGrotesque[opsz,wght].ttf   # NEW — variable font
└── pubspec.yaml                         # MODIFIED — see §4 below
```

---

## 4. Dependencies (single `pubspec.yaml` diff)

```yaml
dependencies:
  flutter:
    sdk: flutter
  # Existing — already in project
  flutter_riverpod: ^2.6.1
  go_router: ^14.6.2
  freezed_annotation: ^2.4.4
  web_socket_channel: ^3.0.1

  # === NEW for Phase 1: Foundation ===
  audioplayers: ^6.1.0           # Multi-sensory feedback audio playback

  # === NEW for Phase 2: Spatial ===
  animations: ^2.0.11            # OpenContainer for table → order builder morph

  # === NEW for Phase 3: Identity ===
  rive: ^0.13.20                 # State machine animations

  # === NEW for Phase 4: Delight ===
  newton_particles: ^0.2.4       # Generative particle system

  # === NEW for Phase 5: Premium ===
  sensors_plus: ^6.1.0           # Gyroscope for depth parallax

dev_dependencies:
  flutter_test:
    sdk: flutter
  freezed: ^2.5.7
  build_runner: ^2.4.13
  golden_toolkit: ^0.15.0        # Motion regression tests via goldens

flutter:
  uses-material-design: true
  assets:
    - assets/audio/
    - assets/rive/
  fonts:
    - family: Fraunces
      fonts:
        - asset: assets/fonts/Fraunces[opsz,SOFT,WONK,wght].ttf
    - family: BricolageGrotesque
      fonts:
        - asset: assets/fonts/BricolageGrotesque[opsz,wght].ttf
```

---

## 5. Strict Dart Conventions (applies to every prompt)

Every agent prompt repeats these. They are non-negotiable:

1. **No `dynamic`** — use `Object?` only at deserialization boundary, immediately wrap into typed model.
2. **No `as` casts** outside `*.g.dart` / `*.freezed.dart` generated files.
3. **Sealed classes** for all unions — no enums for state machines that carry data.
4. **Freezed** for immutable data classes — never hand-rolled `==`/`hashCode`.
5. **No `!` operator** without mathematical guarantee + comment explaining why.
6. **No `??` fallbacks** for "default values" hiding architectural gaps. `??` is allowed
   only when the null case is genuinely meaningless (e.g. unwrapping an explicitly-optional UI label).
7. **Explicit type annotations** on all top-level / class members. Local inference is fine.
8. **`const` everywhere** it compiles.
9. **Anchor comments** (`// ===== ANCHOR: NAME =====`) at the top of every public widget
   or service — enables parallel agent edits without merge conflicts.

---

## 6. Anchor Comment Pattern

For any file that more than one agent prompt edits, anchors mark insertion points:

```dart
// ===== ANCHOR: IMPORTS =====
import 'package:flutter/material.dart';
// ===== END ANCHOR: IMPORTS =====

// ===== ANCHOR: SPRING_TOKENS =====
class RestroSprings { /* … */ }
// ===== END ANCHOR: SPRING_TOKENS =====

// ===== ANCHOR: FEEDBACK_KINDS =====
sealed class FeedbackKind { /* … */ }
// ===== END ANCHOR: FEEDBACK_KINDS =====
```

Agents only edit between matching ANCHOR / END ANCHOR markers. No agent ever
removes or renames an anchor. Reviewers grep for orphaned anchors before merging.

---

## 7. How to Use the Agent Prompts

Each prompt in `prompts/` is **self-contained** — a Claude Code agent given the
prompt and access to the project should produce shippable code with no further
context.

### Sequential dispatch (single agent)

```
1. Open prompts/01-spring-physics.md
2. Paste contents into Claude Code with the flutter/ project context
3. Let agent implement, run tests, commit
4. Move to prompts/02-multi-sensory-feedback.md
5. Repeat
```

### Parallel dispatch (recommended — 2-3 agents)

Use the parallelizable table in §2. For Phase 1:

```
Agent A: prompts/01-spring-physics.md         (touches lib/motion/springs.dart + 8 widget files)
Agent B: prompts/02-multi-sensory-feedback.md (touches lib/motion/feedback_*.dart + 4 screens)
```

These touch zero shared files inside `lib/motion/`. The only shared touchpoints
are `pubspec.yaml` and `lib/motion/motion.dart` (the barrel export), both
controlled by ANCHOR comments. Either agent edits its own anchor block.

### Verifying an agent's output

Every prompt ends with an **Acceptance Criteria** checklist. Run it manually
before merging:

```
✅ flutter analyze → 0 errors, 0 warnings on strict rules
✅ flutter test → all existing tests pass + new motion tests pass
✅ No usage of `dynamic`, `as`, `??`-as-default, or `!` (grep)
✅ Anchor comments balanced (every ANCHOR has matching END ANCHOR)
✅ Acceptance items in the prompt manually verified on device
```

---

## 8. Prompt Index

| # | Trend | File | Priority Rank | Effort |
|---|---|---|---|---|
| 01 | Spring Physics | `prompts/01-spring-physics.md` | **1** | 2 days |
| 02 | Multi-Sensory Feedback | `prompts/02-multi-sensory-feedback.md` | **2** | 2 days |
| 03 | Hero Transitions | `prompts/03-hero-transitions.md` | **3** | 3 days |
| 04 | Mesh Gradients | `prompts/04-mesh-gradients.md` | **4** | 2 days |
| 05 | Rive State Machine | `prompts/05-rive-state-machine.md` | **5** | 5 days |
| 06 | Variable Font Counter | `prompts/06-variable-font-counter.md` | **6** | 1 day |
| 07 | Generative Particles | `prompts/07-generative-particles.md` | **7** | 2 days |
| 08 | Liquid Glass | `prompts/08-liquid-glass.md` | **8** | 5 days |
| 09 | Variable Depth Parallax | `prompts/09-variable-depth-parallax.md` | **9** | 2 days |
| 10 | Predictive Animation | `prompts/10-predictive-animation.md` | **10** | 3 days |

---

## 9. Cross-References

- Existing plan files this builds on:
  - `OPERATOR_FLUTTER_APP_PLAN.md` — base widget structure, screen routes
  - `OPERATOR_MOBILE_APP_MASTER_PLAN.md` — WS contracts that drive Rive state inputs
  - `WHITE_LABEL_BRANDING_PLAN.md` — mesh-gradient palette inherits from brand
  - `CLIENT_FEATURE_FLAGS_PLAN.md` — some advanced motion can be flag-gated
- 2026 trends research: `restro-2026-trends.html` (motion catalogue)
- Original motion system: `restro-operator-motion.html` (screen-by-screen reference)

---

## 10. Acceptance — Plan-Level

The plan is "done" when:

- [ ] All 10 prompts have been dispatched to agents and merged
- [ ] `flutter analyze` returns 0 errors on strict rules across the whole `lib/motion/`
- [ ] Golden tests exist for: spring snap, mesh-state shift, Rive state machine,
      hero transition, particle burst
- [ ] Manual QA on a mid-tier Android (Redmi Note 12) + iPhone 13 confirms 60fps
      on all four primary screens (`/scan`, `/tables`, `/order/:tableId`, `/order/:tableId/success`)
- [ ] Operator beta-tester feedback: "feels different" / "feels expensive" / "feels native"
- [ ] No regression in app startup time (< 3s to QR scanner on Redmi Note 12)
- [ ] No regression in APK size beyond +1.8 MB (audio + Rive + variable fonts budget)
