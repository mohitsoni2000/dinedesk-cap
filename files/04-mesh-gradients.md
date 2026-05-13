# Agent Prompt 04 — Animated Mesh Gradients

**Priority:** #4 (visual upgrade visible from across a busy room)
**Effort:** 2 days
**Touches:** `lib/motion/mesh_gradient.dart` (new), `lib/widgets/table_card.dart`,
`lib/screens/splash_screen.dart`, `lib/screens/order_success_screen.dart`
**Parallel-safe with:** Prompts 01, 02, 03 (no shared files)
**Depends on:** Prompt 01 must land first (uses `RestroSprings` for state transitions)

---

## Context

Solid colours and linear gradients are giving way to multi-tone radial meshes
that slowly drift. Figma, Adobe, Apple, and Vercel all use them. The
restaurant-context twist: meshes become a **data channel**.

A table card's mesh is cardamom-cool when freshly empty, drifts warm-saffron at
20–40 minutes occupied, and pulses masala-red beyond 60 minutes. The waiter
reads occupancy heat without reading numbers.

Flutter 3.27+ has experimental native `MeshGradient` via Skia. Until that's
stable, this prompt stacks 2–3 radial gradients with `BlendMode` for the same
effect — 60fps on Redmi Note 12 confirmed.

---

## What to Build

### File 1 (NEW): `lib/motion/mesh_gradient.dart`

```dart
// ===== ANCHOR: MESH_IMPORTS =====
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'springs.dart';
// ===== END ANCHOR: MESH_IMPORTS =====

// ===== ANCHOR: MESH_PALETTE =====
/// A two- or three-point radial palette used by [MeshGradient].
///
/// Each point is a colour with a normalised position [0..1] in both axes.
/// `intensity` is multiplied with the colour's alpha during render.
@immutable
class MeshPoint {
  const MeshPoint({
    required this.color,
    required this.x,
    required this.y,
    this.intensity = 1.0,
    this.radius = 0.6,
  });

  final Color color;
  final double x;
  final double y;
  final double intensity;
  final double radius;

  MeshPoint copyWith({
    Color? color,
    double? x,
    double? y,
    double? intensity,
    double? radius,
  }) {
    return MeshPoint(
      color: color ?? this.color,
      x: x ?? this.x,
      y: y ?? this.y,
      intensity: intensity ?? this.intensity,
      radius: radius ?? this.radius,
    );
  }

  static MeshPoint lerp(MeshPoint a, MeshPoint b, double t) {
    return MeshPoint(
      color: Color.lerp(a.color, b.color, t) ?? a.color,
      x: a.x + (b.x - a.x) * t,
      y: a.y + (b.y - a.y) * t,
      intensity: a.intensity + (b.intensity - a.intensity) * t,
      radius: a.radius + (b.radius - a.radius) * t,
    );
  }
}

/// A named, state-driven mesh palette.
///
/// The Restro app uses three presets for table heat (cool/warm/hot), one for
/// splash, and one for success. Add new presets here rather than in widget code.
sealed class MeshPalette {
  const MeshPalette();

  List<MeshPoint> get points;

  static const MeshPalette cool = _CoolMesh();
  static const MeshPalette warm = _WarmMesh();
  static const MeshPalette hot = _HotMesh();
  static const MeshPalette splash = _SplashMesh();
  static const MeshPalette success = _SuccessMesh();
  static const MeshPalette failure = _FailureMesh();
}

final class _CoolMesh extends MeshPalette {
  const _CoolMesh();
  @override
  List<MeshPoint> get points => const <MeshPoint>[
        MeshPoint(color: Color(0x4D84A763), x: 0.2, y: 0.3, radius: 0.6),
        MeshPoint(color: Color(0x336B9BB8), x: 0.8, y: 0.7, radius: 0.5),
      ];
}

final class _WarmMesh extends MeshPalette {
  const _WarmMesh();
  @override
  List<MeshPoint> get points => const <MeshPoint>[
        MeshPoint(color: Color(0x66E8B94A), x: 0.2, y: 0.3, radius: 0.6),
        MeshPoint(color: Color(0x4DF59E3A), x: 0.8, y: 0.7, radius: 0.55),
      ];
}

final class _HotMesh extends MeshPalette {
  const _HotMesh();
  @override
  List<MeshPoint> get points => const <MeshPoint>[
        MeshPoint(color: Color(0x80FF7849), x: 0.2, y: 0.3, radius: 0.65, intensity: 1.0),
        MeshPoint(color: Color(0x80C1432E), x: 0.8, y: 0.7, radius: 0.55, intensity: 1.0),
      ];
}

final class _SplashMesh extends MeshPalette {
  const _SplashMesh();
  @override
  List<MeshPoint> get points => const <MeshPoint>[
        MeshPoint(color: Color(0x66F59E3A), x: 0.5, y: 0.3, radius: 0.55),
        MeshPoint(color: Color(0x4DFF7849), x: 0.3, y: 0.7, radius: 0.5),
        MeshPoint(color: Color(0x33C1432E), x: 0.8, y: 0.8, radius: 0.45),
      ];
}

final class _SuccessMesh extends MeshPalette {
  const _SuccessMesh();
  @override
  List<MeshPoint> get points => const <MeshPoint>[
        MeshPoint(color: Color(0x6684A763), x: 0.5, y: 0.4, radius: 0.6),
        MeshPoint(color: Color(0x33F59E3A), x: 0.3, y: 0.7, radius: 0.5),
      ];
}

final class _FailureMesh extends MeshPalette {
  const _FailureMesh();
  @override
  List<MeshPoint> get points => const <MeshPoint>[
        MeshPoint(color: Color(0x66C1432E), x: 0.4, y: 0.4, radius: 0.6),
        MeshPoint(color: Color(0x338B4F2A), x: 0.7, y: 0.7, radius: 0.5),
      ];
}
// ===== END ANCHOR: MESH_PALETTE =====

// ===== ANCHOR: MESH_WIDGET =====
/// An animated mesh gradient.
///
/// - The mesh **drifts** slowly via internal animation, never staying static.
/// - When [palette] changes, the points are spring-interpolated to the new
///   palette over `transitionDuration`.
/// - GPU-accelerated: uses `BackdropFilter`-free composited gradients.
class MeshGradient extends StatefulWidget {
  const MeshGradient({
    required this.palette,
    this.driftSeconds = 12,
    this.transitionDuration = const Duration(milliseconds: 700),
    this.child,
    super.key,
  });

  final MeshPalette palette;
  final int driftSeconds;
  final Duration transitionDuration;
  final Widget? child;

  @override
  State<MeshGradient> createState() => _MeshGradientState();
}

class _MeshGradientState extends State<MeshGradient>
    with TickerProviderStateMixin {
  late final AnimationController _driftController;
  late final AnimationController _transitionController;

  List<MeshPoint> _currentPoints = const <MeshPoint>[];
  List<MeshPoint> _targetPoints = const <MeshPoint>[];

  @override
  void initState() {
    super.initState();
    _currentPoints = widget.palette.points;
    _targetPoints = widget.palette.points;

    _driftController = AnimationController(
      vsync: this,
      duration: Duration(seconds: widget.driftSeconds),
    )..repeat(reverse: true);

    _transitionController = AnimationController(
      vsync: this,
      duration: widget.transitionDuration,
    );
  }

  @override
  void didUpdateWidget(covariant MeshGradient oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.palette != widget.palette) {
      _currentPoints = _interpolatedPoints();
      _targetPoints = widget.palette.points;
      _transitionController
        ..reset()
        ..forward();
    }
  }

  List<MeshPoint> _interpolatedPoints() {
    final double t = Curves.easeInOut.transform(_transitionController.value);
    final int count = math.min(_currentPoints.length, _targetPoints.length);
    return List<MeshPoint>.generate(count, (int i) {
      return MeshPoint.lerp(_currentPoints[i], _targetPoints[i], t);
    });
  }

  @override
  void dispose() {
    _driftController.dispose();
    _transitionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[_driftController, _transitionController]),
      builder: (BuildContext context, Widget? child) {
        final List<MeshPoint> live = _interpolatedPoints();
        final double driftPhase = _driftController.value;
        return CustomPaint(
          painter: _MeshPainter(
            points: live,
            driftPhase: driftPhase,
          ),
          child: child,
        );
      },
      child: widget.child ?? const SizedBox.expand(),
    );
  }
}

class _MeshPainter extends CustomPainter {
  _MeshPainter({required this.points, required this.driftPhase});

  final List<MeshPoint> points;
  final double driftPhase;

  @override
  void paint(Canvas canvas, Size size) {
    // Drift amplitude: 8% of the smaller dimension.
    final double drift = math.min(size.width, size.height) * 0.08;
    final double angle = driftPhase * 2 * math.pi;

    for (final MeshPoint point in points) {
      final double cx = (point.x + math.cos(angle) * 0.04) * size.width;
      final double cy = (point.y + math.sin(angle) * 0.04) * size.height;
      final double radius = math.max(size.width, size.height) * point.radius;
      final Color tinted = point.color.withOpacity(
        (point.color.opacity * point.intensity).clamp(0.0, 1.0),
      );
      final Paint paint = Paint()
        ..shader = RadialGradient(
          colors: <Color>[tinted, tinted.withOpacity(0)],
          stops: const <double>[0.0, 1.0],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: radius))
        ..blendMode = BlendMode.plus;
      canvas.drawRect(Offset.zero & size, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MeshPainter oldDelegate) =>
      oldDelegate.driftPhase != driftPhase || oldDelegate.points != points;
}
// ===== END ANCHOR: MESH_WIDGET =====

// ===== ANCHOR: HEAT_PALETTE_HELPER =====
/// Helper: maps occupancy minutes to a [MeshPalette] heat tier.
///
/// Thresholds are restaurant-tuned defaults; expose via settings later.
MeshPalette meshPaletteForOccupancyMinutes(int minutes) {
  if (minutes < 20) return MeshPalette.cool;
  if (minutes < 60) return MeshPalette.warm;
  return MeshPalette.hot;
}
// ===== END ANCHOR: HEAT_PALETTE_HELPER =====
```

### File 2 (MODIFY): `lib/motion/motion.dart`

Add inside the existing EXPORTS anchor:

```dart
export 'mesh_gradient.dart';
```

---

## Integration

### Integration 1: `lib/widgets/table_card.dart`

Wrap the existing table card body in a `MeshGradient`:

```dart
@override
Widget build(BuildContext context) {
  return ClipRRect(
    borderRadius: const BorderRadius.all(Radius.circular(14)),
    child: MeshGradient(
      palette: table.isEmpty
          ? MeshPalette.cool
          : meshPaletteForOccupancyMinutes(table.occupancyMinutes),
      driftSeconds: 14,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Hero(
              tag: HeroTags.tableNumber(table.id),
              child: Text('T${table.number}', style: ...),
            ),
            _TableMeta(table: table),
          ],
        ),
      ),
    ),
  );
}
```

The palette switches automatically as the table's occupancy minutes climb — the
mesh spring-transitions between cool → warm → hot.

### Integration 2: `lib/screens/splash_screen.dart`

Replace the existing static `_SplashMesh` widget with a `MeshGradient`:

```dart
return MeshGradient(
  palette: MeshPalette.splash,
  driftSeconds: 16,
  child: Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Hero(tag: HeroTags.appLogo, child: SplashLogo()),
        const SizedBox(height: 28),
        Text('Restro', style: ...),
        ...
      ],
    ),
  ),
);
```

### Integration 3: `lib/screens/order_success_screen.dart`

Wrap the screen body in a success-palette mesh:

```dart
return MeshGradient(
  palette: MeshPalette.success,
  driftSeconds: 10,
  child: SafeArea(
    child: Stack(
      children: <Widget>[
        // existing success content (check, title, KOT card, etc.)
      ],
    ),
  ),
);
```

### Integration 4: `lib/screens/disconnected_screen.dart`

```dart
return MeshGradient(
  palette: MeshPalette.failure,
  driftSeconds: 8,
  child: ...,
);
```

---

## Testing

### Unit test (NEW): `test/motion/mesh_gradient_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro_operator/motion/motion.dart';

void main() {
  group('MeshPoint.lerp', () {
    test('returns a at t=0', () {
      const MeshPoint a = MeshPoint(color: Color(0xFFFF0000), x: 0.0, y: 0.0);
      const MeshPoint b = MeshPoint(color: Color(0xFF00FF00), x: 1.0, y: 1.0);
      final MeshPoint mid = MeshPoint.lerp(a, b, 0.0);
      expect(mid.x, equals(0.0));
      expect(mid.color, equals(const Color(0xFFFF0000)));
    });

    test('returns b at t=1', () {
      const MeshPoint a = MeshPoint(color: Color(0xFFFF0000), x: 0.0, y: 0.0);
      const MeshPoint b = MeshPoint(color: Color(0xFF00FF00), x: 1.0, y: 1.0);
      final MeshPoint mid = MeshPoint.lerp(a, b, 1.0);
      expect(mid.x, equals(1.0));
      expect(mid.color, equals(const Color(0xFF00FF00)));
    });
  });

  group('meshPaletteForOccupancyMinutes', () {
    test('returns cool for fresh tables', () {
      expect(meshPaletteForOccupancyMinutes(0), MeshPalette.cool);
      expect(meshPaletteForOccupancyMinutes(19), MeshPalette.cool);
    });
    test('returns warm for mid-occupancy', () {
      expect(meshPaletteForOccupancyMinutes(20), MeshPalette.warm);
      expect(meshPaletteForOccupancyMinutes(59), MeshPalette.warm);
    });
    test('returns hot beyond an hour', () {
      expect(meshPaletteForOccupancyMinutes(60), MeshPalette.hot);
      expect(meshPaletteForOccupancyMinutes(120), MeshPalette.hot);
    });
  });

  testWidgets('MeshGradient renders without error', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 200, height: 200,
          child: MeshGradient(palette: MeshPalette.warm),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(MeshGradient), findsOneWidget);
  });
}
```

### Golden test (NEW): `test/motion/mesh_gradient_golden_test.dart`

Use `golden_toolkit` to capture mesh palettes:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golden_toolkit/golden_toolkit.dart';
import 'package:restro_operator/motion/motion.dart';

void main() {
  testGoldens('mesh palettes — cool / warm / hot', (WidgetTester tester) async {
    final DeviceBuilder builder = DeviceBuilder()
      ..overrideDevicesForAllScenarios(devices: <Device>[Device.phone])
      ..addScenario(
        widget: const SizedBox(width: 200, height: 200, child: MeshGradient(palette: MeshPalette.cool)),
        name: 'cool',
      )
      ..addScenario(
        widget: const SizedBox(width: 200, height: 200, child: MeshGradient(palette: MeshPalette.warm)),
        name: 'warm',
      )
      ..addScenario(
        widget: const SizedBox(width: 200, height: 200, child: MeshGradient(palette: MeshPalette.hot)),
        name: 'hot',
      );
    await tester.pumpDeviceBuilder(builder);
    await screenMatchesGolden(tester, 'mesh_palettes');
  });
}
```

### Manual QA

- On the tables screen, watch a table sit for a minute (use a debug mock with
  fast-forward) — the card's mesh should drift visibly and the palette should
  shift cool → warm at the 20-minute boundary, warm → hot at the 60-minute
  boundary, all spring-smooth.
- On the splash screen, the mesh should drift over 16 seconds (one cycle).
- Performance: open Flutter DevTools → Performance overlay. Confirm 60fps on a
  tables screen full of mesh cards on a mid-tier Android device. If <55fps,
  drop `driftSeconds` on table cards to 16 or higher.

---

## Acceptance Criteria

- [ ] `lib/motion/mesh_gradient.dart` exists with `MeshPoint`, `MeshPalette`
      sealed hierarchy, `MeshGradient` widget, and `meshPaletteForOccupancyMinutes` helper
- [ ] `lib/motion/motion.dart` exports `mesh_gradient.dart`
- [ ] 4 integration points wired: `table_card.dart`, `splash_screen.dart`,
      `order_success_screen.dart`, `disconnected_screen.dart`
- [ ] `flutter analyze` → 0 errors
- [ ] All unit tests pass
- [ ] Golden test passes on first generation, locked in
- [ ] Manual QA: tables screen at 60fps on Redmi Note 12
- [ ] Palette transition (cool → warm) is visibly smooth, no snap
- [ ] No `dynamic`, no `as` casts, no `??`-as-default in new code
- [ ] Sealed class `MeshPalette` is exhaustive in any `switch`

---

## Strict Dart Conventions Reminder

- Sealed `MeshPalette` — never break by adding a fallthrough enum
- No `dynamic` in `_MeshPainter`
- No `as` casts
- `??` allowed only in `Color.lerp(...) ?? a.color` — null is genuinely meaningless there (lerp returns null only when both inputs are null)
- `const` everywhere it compiles
