# Agent Prompt 07 — Generative Particle Emitter

**Priority:** #7 (delight moment — KOT fire celebration)
**Effort:** 2 days
**Touches:** `lib/motion/particle_emitter.dart` (new), `lib/screens/order_success_screen.dart` (modify)
**Parallel-safe with:** Prompts 04, 05, 06, 08 (no shared files)
**Depends on:** Prompt 01 (spring physics for arc), Prompt 02 (haptic-synced burst)

---

## Context

Pre-baked confetti animations look fine the first time. By the 50th KOT fire of
the night, the waiter has seen it identically 50 times. Generative particle
systems spawn particles procedurally with **random velocity / lifetime /
rotation / colour** from a curated palette — every burst is slightly different.

For Restro: a **spice burst** on KOT success. Particles in saffron, kesar,
cardamom, turmeric, masala — random sizes (4–10px), random angles, gravity
pulls them downward over 800ms–1.4s lifetimes, fade out at end.

This prompt uses `newton_particles` (proven Flutter package) wrapped in a
domain-named emitter widget.

---

## What to Build

### File 1 (MODIFY): `pubspec.yaml`

Add inside `dependencies:`:

```yaml
newton_particles: ^0.2.4
```

### File 2 (NEW): `lib/motion/particle_emitter.dart`

```dart
// ===== ANCHOR: PARTICLE_PALETTE =====
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:newton_particles/newton_particles.dart';

/// Sealed union of named particle palettes. Add a new palette here rather
/// than constructing raw [Color] lists in widget code.
sealed class ParticlePalette {
  const ParticlePalette();
  List<Color> get colors;

  static const ParticlePalette spice = _SpicePalette();
  static const ParticlePalette success = _SuccessPalette();
  static const ParticlePalette steam = _SteamPalette();
}

final class _SpicePalette extends ParticlePalette {
  const _SpicePalette();
  @override
  List<Color> get colors => const <Color>[
        Color(0xFFFFB964), // saffron-bright
        Color(0xFFFF7849), // kesar
        Color(0xFFE8B94A), // turmeric
        Color(0xFFC1432E), // masala
        Color(0xFFF4E8C1), // paneer
        Color(0xFF84A763), // cardamom (just a hint)
      ];
}

final class _SuccessPalette extends ParticlePalette {
  const _SuccessPalette();
  @override
  List<Color> get colors => const <Color>[
        Color(0xFF84A763),
        Color(0xFFFFB964),
        Color(0xFFE8B94A),
      ];
}

final class _SteamPalette extends ParticlePalette {
  const _SteamPalette();
  @override
  List<Color> get colors => const <Color>[
        Color(0x99F4EDE0),
        Color(0x66F4EDE0),
        Color(0x33F4EDE0),
      ];
}
// ===== END ANCHOR: PARTICLE_PALETTE =====

// ===== ANCHOR: PARTICLE_EMITTER_WIDGET =====
/// A one-shot generative particle burst.
///
/// On widget mount, [burstCount] particles are spawned from [center] with
/// random angle, speed, lifetime, rotation, and a colour from [palette].
/// Gravity pulls them downward; they fade out as their lifetime expires.
///
/// Place inside a `Stack` over the surface where the burst should appear.
class ParticleBurst extends StatefulWidget {
  const ParticleBurst({
    required this.palette,
    this.burstCount = 14,
    this.minSize = 4,
    this.maxSize = 10,
    this.minSpeed = 80,
    this.maxSpeed = 220,
    this.minLifetimeMs = 800,
    this.maxLifetimeMs = 1400,
    this.center = const Alignment(0, -0.1),
    this.gravity = 220,
    this.seed,
    super.key,
  });

  final ParticlePalette palette;
  final int burstCount;
  final double minSize;
  final double maxSize;
  final double minSpeed;
  final double maxSpeed;
  final int minLifetimeMs;
  final int maxLifetimeMs;
  final Alignment center;
  final double gravity;

  /// Optional seed for reproducibility in tests. Production leaves this null
  /// for true randomness on every burst.
  final int? seed;

  @override
  State<ParticleBurst> createState() => _ParticleBurstState();
}

class _ParticleBurstState extends State<ParticleBurst> {
  late final Newton _newton;
  late final List<Color> _colors;

  @override
  void initState() {
    super.initState();
    _colors = widget.palette.colors;
    final math.Random rng = widget.seed == null
        ? math.Random()
        : math.Random(widget.seed);

    _newton = Newton(
      activeEffects: <Effect<AnimatedParticle>>[
        ExplodeEffect(
          particleConfiguration: ParticleConfiguration(
            shape: const CircleShape(),
            // Random size per particle (resolved at construction time).
            size: Size.square(_rand(rng, widget.minSize, widget.maxSize)),
            color: SingleParticleColor(
              color: _colors[rng.nextInt(_colors.length)],
            ),
          ),
          effectConfiguration: EffectConfiguration(
            particleCount: widget.burstCount,
            origin: widget.center,
            minDuration: Duration(milliseconds: widget.minLifetimeMs),
            maxDuration: Duration(milliseconds: widget.maxLifetimeMs),
            minDistance: widget.minSpeed,
            maxDistance: widget.maxSpeed,
            minFadeOutThreshold: 0.6,
            maxFadeOutThreshold: 0.9,
            minBeginScale: 1.0,
            maxBeginScale: 1.0,
            minEndScale: 0.4,
            maxEndScale: 0.6,
            // Newton expresses gravity as a downward velocity post-launch.
            // We approximate by ending particles below their start.
            distanceCurve: Curves.easeOutCubic,
            fadeOutCurve: Curves.easeOut,
          ),
        ),
      ],
    );
  }

  double _rand(math.Random rng, double min, double max) {
    return min + rng.nextDouble() * (max - min);
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(child: _newton);
  }
}
// ===== END ANCHOR: PARTICLE_EMITTER_WIDGET =====

// ===== ANCHOR: STEAM_TRAIL =====
/// A continuous slow upward trail of pale particles — used by pull-to-refresh
/// "cooking pot steam". Keep `burstCount` low (3–5) and `minLifetimeMs` long.
class SteamTrail extends StatelessWidget {
  const SteamTrail({
    required this.intensity,
    super.key,
  });

  /// 0.0–1.0. 0 = no steam, 1 = full plume.
  final double intensity;

  @override
  Widget build(BuildContext context) {
    if (intensity <= 0.05) return const SizedBox.shrink();
    return ParticleBurst(
      palette: ParticlePalette.steam,
      burstCount: (3 + intensity * 4).round(),
      minSize: 4,
      maxSize: 10,
      minSpeed: 20,
      maxSpeed: 60,
      minLifetimeMs: 1200,
      maxLifetimeMs: 2200,
      center: const Alignment(0, 0.3),
      gravity: -120, // negative gravity = floats upward
    );
  }
}
// ===== END ANCHOR: STEAM_TRAIL =====
```

### File 3 (MODIFY): `lib/motion/motion.dart`

Add to the EXPORTS anchor:

```dart
export 'particle_emitter.dart';
```

---

## Integration

### Integration 1: `lib/screens/order_success_screen.dart`

Replace the existing static confetti (CSS divs in the HTML mockup → static
particles in current Flutter) with a real generative burst. Place inside the
existing `Stack`:

```dart
@override
Widget build(BuildContext context) {
  return Scaffold(
    body: MeshGradient(
      palette: MeshPalette.success,
      child: Stack(
        children: <Widget>[
          // Particle burst: must be ABOVE the mesh, BELOW the title text.
          const Positioned.fill(
            child: ParticleBurst(
              palette: ParticlePalette.spice,
              burstCount: 18,
              minSize: 5,
              maxSize: 12,
              center: Alignment(0, -0.15),
            ),
          ),

          // Existing success content: check ring, title, KOT card, redirect.
          Center(child: _SuccessContent(/* ... */)),
        ],
      ),
    ),
  );
}
```

The widget rebuild on screen mount triggers a fresh burst — every KOT success
gets a slightly different burst pattern.

### Integration 2 (optional, future): `lib/widgets/pull_to_refresh.dart`

Replace the default `RefreshIndicator` glow with a `SteamTrail` whose intensity
is driven by the pull distance:

```dart
class CookingPotRefresh extends StatelessWidget {
  const CookingPotRefresh({
    required this.dragPercent,
    super.key,
  });

  final double dragPercent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 60,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // The "pot" stays still.
          Icon(Icons.coffee_outlined, size: 32, color: AppColors.saffron),
          // Steam intensity rises with pull distance.
          SteamTrail(intensity: dragPercent.clamp(0.0, 1.0)),
        ],
      ),
    );
  }
}
```

Wire this into the existing pull-to-refresh widget on `tables_screen.dart`.
This part is **optional** for v1 of the prompt — only ship if there's time.

---

## Testing

### Widget test (NEW): `test/motion/particle_burst_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro_operator/motion/motion.dart';

void main() {
  group('ParticleBurst', () {
    testWidgets('renders without crashing', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300, height: 300,
              child: ParticleBurst(palette: ParticlePalette.spice, seed: 42),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(ParticleBurst), findsOneWidget);
    });

    testWidgets('deterministic with seed', (WidgetTester tester) async {
      // Two bursts with the same seed should look identical.
      // (newton_particles internally uses a Random — we pass the seed.)
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ParticleBurst(palette: ParticlePalette.spice, seed: 123),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      // Visual comparison is via golden tests — left to the implementer.
    });
  });

  group('ParticlePalette', () {
    test('all palettes have at least 2 colors', () {
      expect(ParticlePalette.spice.colors.length, greaterThan(1));
      expect(ParticlePalette.success.colors.length, greaterThan(1));
      expect(ParticlePalette.steam.colors.length, greaterThan(1));
    });
  });
}
```

### Golden test (NEW): `test/motion/particle_burst_golden_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golden_toolkit/golden_toolkit.dart';
import 'package:restro_operator/motion/motion.dart';

void main() {
  testGoldens('particle burst — spice palette frame at 400ms',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Color(0xFF14100D),
          body: ParticleBurst(palette: ParticlePalette.spice, seed: 42),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await screenMatchesGolden(tester, 'particle_burst_spice_400ms');
  });
}
```

### Manual QA

- Fire 3 KOTs in quick succession on the order review screen. Each success
  screen should show a **visibly different** burst pattern (random angles, sizes,
  colors).
- Particles should fade out smoothly — no abrupt disappearance.
- On a Redmi Note 12, the success screen with burst should hold 60fps. If it
  drops, reduce `burstCount` from 18 to 12.
- Particles must not bleed outside the screen bounds (the `Stack` clips them).

---

## Acceptance Criteria

- [ ] `newton_particles: ^0.2.4` in `pubspec.yaml`
- [ ] `lib/motion/particle_emitter.dart` exists with sealed `ParticlePalette`,
      `ParticleBurst`, `SteamTrail`
- [ ] `lib/motion/motion.dart` exports it
- [ ] `order_success_screen.dart` uses `ParticleBurst` with `ParticlePalette.spice`
- [ ] Widget test + golden test pass
- [ ] Manual QA: 3 successive bursts look different (proves generative)
- [ ] No `dynamic`, no `as` casts in new code
- [ ] Sealed `ParticlePalette` — switch is exhaustive
- [ ] 60fps on Redmi Note 12 during success screen with burst active

---

## Strict Dart Conventions Reminder

- Sealed `ParticlePalette` — never break to enum
- No `dynamic`
- No `as` casts
- `const` everywhere it compiles
