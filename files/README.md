# Restro Operator · 2026 Motion Implementation

**Drop-in agent prompts for Claude Code to add cutting-edge 2026 animations to your Flutter operator app.**

---

## What's in here

```
motion-2026-implementation/
├── README.md                          # ← you are here
├── MOTION_2026_MASTER_PLAN.md         # Architecture, dependencies, phased roadmap
└── prompts/
    ├── 01-spring-physics.md           # 2 days · Priority #1 — replaces every easing curve
    ├── 02-multi-sensory-feedback.md   # 2 days · Priority #2 — haptic + audio + visual
    ├── 03-hero-transitions.md         # 3 days · Priority #3 — shared-element morphs
    ├── 04-mesh-gradients.md           # 2 days · Priority #4 — animated mesh backgrounds
    ├── 05-rive-state-machine.md       # 5 days · Priority #5 — state-driven Send-KOT button
    ├── 06-variable-font-counter.md    # 1 day  · Priority #6 — kinetic ₹ counter
    ├── 07-generative-particles.md     # 2 days · Priority #7 — KOT-success spice burst
    ├── 08-liquid-glass.md             # 5 days · Priority #8 — pointer-tracked surface tension
    ├── 09-variable-depth-parallax.md  # 2 days · Priority #9 — gyroscope 3-layer depth
    └── 10-predictive-animation.md     # 3 days · Priority #10 — pre-anim on intent (experimental)
```

Total effort if shipped sequentially: ~27 working days for one agent.
With 2–3 agents in parallel: ~3 weeks.

---

## How to use these prompts

### Step 1 — Read the master plan first

Open `MOTION_2026_MASTER_PLAN.md`. It covers:
- The new `lib/motion/` folder structure (10 new files)
- All `pubspec.yaml` dependencies in one diff
- Strict Dart conventions (no `dynamic`, no `as`, sealed classes, etc.)
- Anchor comment pattern for parallel-safe edits
- Acceptance criteria at the plan level

### Step 2 — Pick a phase

| Phase | Prompts | Parallel? |
|---|---|---|
| Foundation (week 1) | 01 + 02 | YES — no shared files |
| Spatial (week 2) | 03 + 04 | YES |
| Identity (week 3) | 05 + 06 | YES |
| Delight (week 4) | 07 + 08 | YES |
| Premium (week 5+) | 09 + 10 | YES |

**Always run Prompt 01 (Spring Physics) first** — others reference `RestroSprings`.

### Step 3 — Dispatch each prompt to Claude Code

Each prompt file is self-contained. Paste its full content into Claude Code with
access to your `flutter/` project directory.

```
You are a Claude Code agent. Implement the following prompt against the
restro-operator Flutter app at /home/<user>/restro-operator/. Run flutter
analyze and flutter test before declaring complete.

<paste prompt content here>
```

### Step 4 — Verify acceptance criteria

Each prompt ends with a checklist. Walk through it before merging:
- `flutter analyze` → 0 errors on strict rules
- `flutter test` → all new + existing tests pass
- No `dynamic`, no `as`, no `!`, no `??`-as-default (grep)
- Anchor comments balanced
- Manual QA items verified on device

### Step 5 — Repeat for the next prompt

When two prompts are parallel-safe (per the master plan table), dispatch them
to two agents simultaneously. They only share `pubspec.yaml` and
`lib/motion/motion.dart` (the barrel) — both controlled by ANCHOR comments
to avoid merge conflicts.

---

## Top 3 to ship this week

If you have one week and one developer, ship just these three. They're the
biggest impact-to-effort wins:

1. **Spring Physics** (Prompt 01) — 2 days. Every animation in the app
   instantly feels more alive.
2. **Multi-Sensory Feedback** (Prompt 02) — 2 days. KOT fires get a
   visceral 3-channel confirmation. Operators stop missing fires in noisy
   restaurants.
3. **Hero Transitions** (Prompt 03) — 3 days. Boot flow + order flow feel
   like one continuous app, not stitched-together screens.

Combined: 7 days. Result: app feels native, premium, and intentional.

---

## What's already done before these prompts

Per existing project state:

- Six Super Admin Panel screens designed (admin/server side, separate work)
- SaaS licensing system architecture defined
- Auto-update with electron-builder configured
- Six Claude Code agent plans (Reliability / Electron upgrade / Security / Native UX / DevOps) — Electron app side
- Three operator-app plan files (`OPERATOR_FLUTTER_APP_PLAN.md`,
  `OPERATOR_ADMIN_INTEGRATION_PLAN.md`, `OPERATOR_MOBILE_APP_MASTER_PLAN.md`)

These motion prompts build **on top of** the operator app structure, not
alongside it. The operator app should be functionally complete before motion
work begins — motion is the polish pass, not the foundation.

---

## What's NOT in these prompts

- **Audio asset production** — Prompt 02 requires 6 short audio files
  (tap_light, tap_medium, tap_heavy, success_chime, error_buzz, warning_tone).
  You'll need to either record/synthesise these yourself or commission a
  sound designer. Placeholders work for dev-loop.
- **Rive `.riv` file production** — Prompt 05 requires the designer to author
  the Send-KOT state machine in the Rive editor. Designer brief is included.
- **Variable font file** — Prompt 06 needs `Fraunces[opsz,SOFT,WONK,wght].ttf`
  from Google Fonts. The variable TTF, not the static build. Download instructions
  in the prompt.

---

## Questions before you start

- **Do I need to ship all 10?** No. The first 6 cover 90% of the perceived
  upgrade. Prompts 07–10 are polish. Prompt 10 is experimental.
- **Can I skip Prompt 01 and just do Prompt 06?** No. Prompts 03–10 reference
  `RestroSprings` from Prompt 01. The dependency chain is documented in each
  prompt's "Depends on" line.
- **Can two agents touch the same file?** Only via ANCHOR comments. The
  master plan §6 explains the pattern. Every shared file is annotated.
- **What if an agent breaks the strict Dart rules?** The prompts repeat the
  rules. If an agent introduces `dynamic` or `as` casts outside generated files,
  reject the PR and re-prompt with the violations highlighted.

---

## Cross-references

- Original motion design system: `restro-operator-motion.html`
- 2026 trend research with live demos: `restro-2026-trends.html`
- Existing operator-app architecture: `OPERATOR_FLUTTER_APP_PLAN.md`,
  `OPERATOR_MOBILE_APP_MASTER_PLAN.md`

---

Built for delegation. Each prompt is one paste away from production code.
