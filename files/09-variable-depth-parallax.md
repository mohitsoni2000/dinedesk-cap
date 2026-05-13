# Agent Prompt 09 — Variable Depth Parallax

**Priority:** #9 (premium polish — niche but memorable)
**Effort:** 2 days
**Touches:** `lib/motion/depth_parallax.dart` (new), `lib/widgets/item_detail_sheet.dart` (modify), `lib/screens/splash_screen.dart` (modify)
**Parallel-safe with:** Prompts 04, 05, 06, 07, 10 (no shared files)
**Depends on:** Prompt 01 (springs), Prompt 08 (shares `sensors_plus` dependency)

---

## Context

Apple TV 2026 uses the Neural Engine to auto-split 2D artwork into layers in
real-time, producing 3D parallax depth on a flat screen. For mobile without
Neural Engine: layer manually and respond to device tilt.

For Restro: when an operator opens the item detail sheet (food image + label),
three layers (background blur / food image / label) shift at different
velocities as the phone tilts. The food image appears to "float" off the screen.
Same treatment on the splash logo.

This is a polish feature — skip on a tight timeline. But once shipped, every
demo of the app pulls a "whoa" reaction.

---

## What to Build

### File 1 (MODIFY): `pubspec.yaml`

Confirm `sensors_plus: ^6.1.0` is present (added in Prompt 08; if 08 hasn't
landed yet, add it now):

```yaml
sensors_plus: ^6.1.0
```

### File 2 (NEW): `lib/motion/depth_parallax.dart`

```dart
// ===== ANCHOR: DEPTH_IMPORTS =====
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
// ===== END ANCHOR: DEPTH_IMPORTS =====

// ===== ANCHOR: DEPTH_LAYER =====
/// A single layer in a [DepthParallaxStack].
///
/// `depth` determines how strongly this layer responds to device tilt.
/// 0.0 = no movement (anchored — used for the background); 1.0 = maximum
/// movement (used for the foreground "popped" layer).
@immutable
class DepthLayer {
  const DepthLayer({
    required this.child,
    required this.depth,
  }) : assert(depth >= 0 && depth <= 1, 'depth must be in [0..1]');

  final Widget child;
  final double depth;
}
// ===== END ANCHOR: DEPTH_LAYER =====

// ===== ANCHOR: DEPTH_STACK =====
/// A parallax stack driven by the device gyroscope.
///
/// Each [DepthLayer] is translated by `(tilt.x, tilt.y) * depth * maxOffset`.
/// The tilt is smoothed to avoid jitter from accelerometer noise.
///
/// Use 3 layers for the canonical "background / middle / foreground" pattern.
/// Order in [layers] matters — earlier layers paint behind later ones.
class DepthParallaxStack extends StatefulWidget {
  const DepthParallaxStack({
    required this.layers,
    this.maxOffset = 16,
    this.smoothing = 0.18,
    super.key,
  });

  /// Painted bottom-to-top. Lower depth = further back.
  final List<DepthLayer> layers;

  /// Maximum translation in logical pixels at depth=1.0 and full tilt.
  final double maxOffset;

  /// Smoothing factor for gyroscope input. Lower = smoother but laggier.
  final double smoothing;

  @override
  State<DepthParallaxStack> createState() => _DepthParallaxStackState();
}

class _DepthParallaxStackState extends State<DepthParallaxStack>
    with SingleTickerProviderStateMixin {
  StreamSubscription<GyroscopeEvent>? _sub;
  late final Ticker _ticker;

  // Raw target from gyro integration. Damped over time so it returns to centre.
  double _targetX = 0;
  double _targetY = 0;
  // Smoothed current values used for rendering.
  double _currentX = 0;
  double _currentY = 0;

  static const double _decay = 0.92; // returns to centre when phone is still

  @override
  void initState() {
    super.initState();
    _sub = gyroscopeEventStream().listen(_onGyro);
    _ticker = createTicker(_onTick)..start();
  }

  void _onGyro(GyroscopeEvent e) {
    // Integrate angular velocity into a tilt offset. Multiplied by a small
    // factor so the stack doesn't fly off-screen during normal motion.
    _targetX += e.y * 0.05;
    _targetY += e.x * 0.05;
    _targetX = _targetX.clamp(-1.0, 1.0);
    _targetY = _targetY.clamp(-1.0, 1.0);
  }

  void _onTick(Duration _) {
    // Decay the target gently toward zero (centre) so the stack settles
    // when the phone is still.
    _targetX *= _decay;
    _targetY *= _decay;

    // Smooth-follow the target.
    _currentX += (_targetX - _currentX) * widget.smoothing;
    _currentY += (_targetY - _currentY) * widget.smoothing;

    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respect reduced-motion preference.
    final bool reducedMotion = MediaQuery.of(context).disableAnimations;
    final double effX = reducedMotion ? 0 : _currentX;
    final double effY = reducedMotion ? 0 : _currentY;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (final DepthLayer layer in widget.layers)
          Transform.translate(
            offset: Offset(
              effX * widget.maxOffset * layer.depth,
              effY * widget.maxOffset * layer.depth,
            ),
            child: layer.child,
          ),
      ],
    );
  }
}
// ===== END ANCHOR: DEPTH_STACK =====
```

### File 3 (MODIFY): `lib/motion/motion.dart`

Add to EXPORTS anchor:

```dart
export 'depth_parallax.dart';
```

---

## Integration

### Integration 1: `lib/widgets/item_detail_sheet.dart`

The item detail sheet currently shows: background panel → food image →
overlaid name/price labels. Wrap in `DepthParallaxStack`:

```dart
@override
Widget build(BuildContext context) {
  return ClipRRect(
    borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
    child: SizedBox(
      width: double.infinity,
      height: 320,
      child: DepthParallaxStack(
        maxOffset: 12,
        layers: <DepthLayer>[
          // Layer 1 (deepest): blurred mesh background.
          DepthLayer(
            depth: 0.3,
            child: MeshGradient(palette: MeshPalette.warm),
          ),
          // Layer 2 (mid): the food image.
          DepthLayer(
            depth: 0.6,
            child: Align(
              alignment: Alignment.center,
              child: Container(
                width: 160, height: 160,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(
                    colors: <Color>[Color(0xFFFFB964), Color(0xFFC97727)],
                  ),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(color: Color(0x55000000), blurRadius: 30, offset: Offset(0, 12)),
                  ],
                ),
              ),
            ),
          ),
          // Layer 3 (foreground): label + price, pops out the most.
          DepthLayer(
            depth: 1.0,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(item.name, style: kItemNameStyle),
                    const SizedBox(height: 2),
                    Text('₹${item.priceRupees}', style: kItemPriceStyle),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
```

### Integration 2: `lib/screens/splash_screen.dart`

Add depth to the splash logo:

```dart
DepthParallaxStack(
  maxOffset: 8,
  layers: <DepthLayer>[
    // Background mesh.
    const DepthLayer(
      depth: 0.2,
      child: MeshGradient(palette: MeshPalette.splash),
    ),
    // Glow ring (deepest moving layer).
    DepthLayer(
      depth: 0.5,
      child: Center(child: _SplashGlowRing()),
    ),
    // Logo + name (foreground).
    DepthLayer(
      depth: 1.0,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Hero(tag: HeroTags.appLogo, child: _SplashLogo()),
          const SizedBox(height: 28),
          const Text('Restro', style: kSplashTitleStyle),
        ],
      ),
    ),
  ],
)
```

---

## Performance Notes

- `gyroscopeEventStream()` emits ~60Hz on most devices. The `Ticker` runs at
  display refresh rate. Smoothing happens in `_onTick`, so the gyro callback
  is cheap.
- On low-end Android, parallax can drop the screen below 60fps. Mitigate by:
  - Skipping parallax on `<= API 26` devices via runtime check.
  - Reducing `maxOffset` from 16 → 10.
- The decay-to-centre logic prevents accumulated drift over time, which is
  the classic gyroscope-integration bug.

---

## Testing

### Unit test (NEW): `test/motion/depth_layer_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro_operator/motion/motion.dart';

void main() {
  group('DepthLayer', () {
    test('rejects depth outside [0..1]', () {
      expect(
        () => DepthLayer(depth: -0.1, child: const SizedBox()),
        throwsAssertionError,
      );
      expect(
        () => DepthLayer(depth: 1.5, child: const SizedBox()),
        throwsAssertionError,
      );
    });

    test('accepts valid depth', () {
      const DepthLayer layer = DepthLayer(depth: 0.5, child: SizedBox());
      expect(layer.depth, 0.5);
    });
  });

  testWidgets('DepthParallaxStack renders all layers',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DepthParallaxStack(
            layers: <DepthLayer>[
              DepthLayer(depth: 0.2, child: Text('back')),
              DepthLayer(depth: 0.6, child: Text('middle')),
              DepthLayer(depth: 1.0, child: Text('front')),
            ],
          ),
        ),
      ),
    );
    expect(find.text('back'), findsOneWidget);
    expect(find.text('middle'), findsOneWidget);
    expect(find.text('front'), findsOneWidget);
  });
}
```

### Manual QA

- Open the item detail sheet. Gently tilt the phone forward/back, left/right.
  The food image circle should drift opposite to the tilt; the label should
  drift further; the background mesh should stay nearly still.
- Set the phone flat on a table — within ~2 seconds, all layers should settle
  back to centre (decay-to-centre working).
- Enable "Reduce Motion" in OS settings — parallax should freeze (layers stop
  responding to gyro).
- Performance: hold the phone, walk briskly. The stack should never visibly
  jitter or stutter.

---

## Acceptance Criteria

- [ ] `lib/motion/depth_parallax.dart` exists with `DepthLayer` + `DepthParallaxStack`
- [ ] `lib/motion/motion.dart` exports it
- [ ] `sensors_plus: ^6.1.0` confirmed in `pubspec.yaml`
- [ ] 2 integration points wired (item detail sheet + splash)
- [ ] `MediaQuery.disableAnimations` respected
- [ ] Decay-to-centre prevents drift accumulation
- [ ] All tests pass
- [ ] Manual QA confirms smooth parallax on iOS + Android, no jitter
- [ ] 60fps on item detail sheet on Redmi Note 12
- [ ] No `dynamic`, no `as` casts, no `!` in new code

---

## Strict Dart Conventions Reminder

- `assert(depth >= 0 && depth <= 1, ...)` is the right pattern for depth
  validation — no `!` operator needed.
- No `dynamic`
- No `as` casts
- `const` everywhere it compiles
