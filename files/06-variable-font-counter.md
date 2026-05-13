# Agent Prompt 06 — Variable Font Kinetic Counter

**Priority:** #6 (quick win — 1 day, high brand-differentiator value)
**Effort:** 1 day
**Touches:** `lib/motion/kinetic_counter.dart` (new), `assets/fonts/Fraunces*.ttf`,
3 screen modifications
**Parallel-safe with:** Prompts 04, 05, 07, 08 (no shared files)
**Depends on:** Prompt 01 (uses spring physics for axis transitions)

---

## Context

Static fonts are out. Variable fonts have **axes** — weight, optical size,
SOFT (rounded edges), WONK (quirky italics), slant. As a number changes,
animate the axis instead of swapping fonts.

For the cart total counter: ₹0 at idle is a clean upright 350-weight Fraunces.
As items accumulate, the weight subtly climbs and the italic angle creeps in,
peaking at ₹2,500+ with a confident italic 600-weight. The total *feels*
heavier and more emphatic as it grows — pure typographic motion.

Apple's redesigned typography, Stripe's micro-text, Adobe's variable type push,
Figma's variable font support — all 2026 standard.

---

## What to Build

### File 1 (NEW asset): `assets/fonts/Fraunces[opsz,SOFT,WONK,wght].ttf`

Download the variable font file from
[Google Fonts → Fraunces](https://fonts.google.com/specimen/Fraunces) — the
**static-build TTF** doesn't work; specifically download the **variable TTF**
with all four axes (`opsz`, `SOFT`, `WONK`, `wght`).

Place at `assets/fonts/Fraunces[opsz,SOFT,WONK,wght].ttf`.

### File 2 (MODIFY): `pubspec.yaml`

Inside the `fonts:` block:

```yaml
flutter:
  fonts:
    - family: Fraunces
      fonts:
        - asset: assets/fonts/Fraunces[opsz,SOFT,WONK,wght].ttf
```

### File 3 (NEW): `lib/motion/kinetic_counter.dart`

```dart
// ===== ANCHOR: KINETIC_COUNTER_IMPORTS =====
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'springs.dart';
// ===== END ANCHOR: KINETIC_COUNTER_IMPORTS =====

// ===== ANCHOR: COUNTER_AXIS_MAP =====
/// Maps a normalised value [0..1] to a set of font variations.
/// Used to drive the visual character of [KineticRupeeCounter] based on the
/// magnitude of the current value.
@immutable
class CounterAxisMap {
  const CounterAxisMap({
    required this.weight,
    required this.soft,
    required this.wonk,
    required this.opticalSize,
    required this.italicSlant,
  });

  final double weight;        // 100–900
  final double soft;          // 0–100
  final double wonk;          // 0–1
  final double opticalSize;   // 9–144
  final double italicSlant;   // 0–1 — drives FontStyle decision

  /// Linear interpolation between two axis maps. Used by the spring builder.
  static CounterAxisMap lerp(CounterAxisMap a, CounterAxisMap b, double t) {
    return CounterAxisMap(
      weight: a.weight + (b.weight - a.weight) * t,
      soft: a.soft + (b.soft - a.soft) * t,
      wonk: a.wonk + (b.wonk - a.wonk) * t,
      opticalSize: a.opticalSize + (b.opticalSize - a.opticalSize) * t,
      italicSlant: a.italicSlant + (b.italicSlant - a.italicSlant) * t,
    );
  }

  /// The "₹0" rest-state map. Clean upright, mid-weight.
  static const CounterAxisMap idle = CounterAxisMap(
    weight: 350,
    soft: 30,
    wonk: 0,
    opticalSize: 144,
    italicSlant: 0,
  );

  /// The "₹500+" growing-cart map. Light italic, slightly bolder.
  static const CounterAxisMap growing = CounterAxisMap(
    weight: 450,
    soft: 60,
    wonk: 0.5,
    opticalSize: 144,
    italicSlant: 0.6,
  );

  /// The "₹2500+" big-order map. Confident italic, heavier weight.
  static const CounterAxisMap heavy = CounterAxisMap(
    weight: 600,
    soft: 100,
    wonk: 1,
    opticalSize: 144,
    italicSlant: 1,
  );

  /// Picks an axis map based on the rupee amount.
  static CounterAxisMap forAmount(double rupees) {
    if (rupees < 500) {
      return CounterAxisMap.lerp(idle, growing, rupees / 500);
    }
    if (rupees < 2500) {
      return CounterAxisMap.lerp(growing, heavy, (rupees - 500) / 2000);
    }
    return heavy;
  }
}
// ===== END ANCHOR: COUNTER_AXIS_MAP =====

// ===== ANCHOR: KINETIC_RUPEE_COUNTER =====
/// A kinetic ₹ counter.
///
/// Two things animate when [amount] changes:
/// 1. The displayed digits roll up/down with a spring (no snap).
/// 2. The font's variation axes morph to match the magnitude (heavier, more italic).
///
/// Indian locale grouping (`12,34,567`) is applied via [NumberFormat.decimalPattern].
class KineticRupeeCounter extends StatelessWidget {
  const KineticRupeeCounter({
    required this.amount,
    this.fontSize = 36,
    this.color = const Color(0xFFF4EDE0),
    this.duration = const Duration(milliseconds: 600),
    super.key,
  });

  /// Current rupee amount.
  final double amount;
  final double fontSize;
  final Color color;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final NumberFormat fmt = NumberFormat.decimalPattern('en_IN');
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: amount, end: amount),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (BuildContext context, double rolled, Widget? _) {
        final CounterAxisMap axes = CounterAxisMap.forAmount(rolled);
        return Text(
          '₹${fmt.format(rolled.round())}',
          style: TextStyle(
            fontFamily: 'Fraunces',
            fontSize: fontSize,
            color: color,
            height: 1.0,
            letterSpacing: -fontSize * 0.025,
            fontStyle: axes.italicSlant > 0.5 ? FontStyle.italic : FontStyle.normal,
            fontVariations: <FontVariation>[
              FontVariation('wght', axes.weight),
              FontVariation('SOFT', axes.soft),
              FontVariation('WONK', axes.wonk),
              FontVariation('opsz', axes.opticalSize),
            ],
            fontFeatures: const <FontFeature>[
              FontFeature.tabularFigures(),
            ],
          ),
        );
      },
    );
  }
}
// ===== END ANCHOR: KINETIC_RUPEE_COUNTER =====

// ===== ANCHOR: KINETIC_KOT_NUMBER =====
/// Variant: kinetic KOT number. Always italic+wonky for character — but the
/// weight pops in on first reveal.
class KineticKotNumber extends StatefulWidget {
  const KineticKotNumber({
    required this.number,
    this.fontSize = 48,
    super.key,
  });

  final int number;
  final double fontSize;

  @override
  State<KineticKotNumber> createState() => _KineticKotNumberState();
}

class _KineticKotNumberState extends State<KineticKotNumber>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (BuildContext context, Widget? _) {
        final double t = _animation.value;
        return Text(
          '#${widget.number.toString().padLeft(4, '0')}',
          style: TextStyle(
            fontFamily: 'Fraunces',
            fontSize: widget.fontSize,
            color: const Color(0xFFFFB964),
            fontStyle: FontStyle.italic,
            fontVariations: <FontVariation>[
              FontVariation('wght', 300 + 300 * t),
              FontVariation('SOFT', 100 * t),
              FontVariation('WONK', t),
              FontVariation('opsz', 144),
            ],
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        );
      },
    );
  }
}
// ===== END ANCHOR: KINETIC_KOT_NUMBER =====
```

### File 4 (MODIFY): `lib/motion/motion.dart`

Add to the EXPORTS anchor:

```dart
export 'kinetic_counter.dart';
```

### File 5 (MODIFY): `pubspec.yaml`

Confirm `intl` is in `dependencies:`:

```yaml
intl: ^0.19.0
```

---

## Integration

### Integration 1: `lib/screens/order_builder_screen.dart`

Replace the static cart-bar total text:

```dart
// BEFORE
Text(
  '₹${total.toStringAsFixed(0)}',
  style: const TextStyle(fontSize: 18, fontFamily: 'Fraunces'),
)

// AFTER
KineticRupeeCounter(amount: total, fontSize: 18)
```

### Integration 2: `lib/screens/order_review_screen.dart`

Replace the order-summary total:

```dart
Hero(
  tag: HeroTags.orderTotal,
  child: KineticRupeeCounter(amount: total, fontSize: 32),
)
```

### Integration 3: `lib/screens/order_success_screen.dart`

Replace the KOT number display:

```dart
KineticKotNumber(number: kotNumber, fontSize: 48)
```

---

## Testing

### Widget test (NEW): `test/motion/kinetic_counter_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro_operator/motion/motion.dart';

void main() {
  group('CounterAxisMap', () {
    test('idle map is correct', () {
      expect(CounterAxisMap.idle.weight, 350);
      expect(CounterAxisMap.idle.italicSlant, 0);
    });

    test('lerp at t=0 returns first map values', () {
      final CounterAxisMap mid = CounterAxisMap.lerp(
        CounterAxisMap.idle,
        CounterAxisMap.heavy,
        0,
      );
      expect(mid.weight, equals(CounterAxisMap.idle.weight));
    });

    test('lerp at t=1 returns second map values', () {
      final CounterAxisMap mid = CounterAxisMap.lerp(
        CounterAxisMap.idle,
        CounterAxisMap.heavy,
        1,
      );
      expect(mid.weight, equals(CounterAxisMap.heavy.weight));
    });

    test('forAmount(0) returns idle map', () {
      final CounterAxisMap a = CounterAxisMap.forAmount(0);
      expect(a.weight, equals(CounterAxisMap.idle.weight));
    });

    test('forAmount(2500) returns heavy map', () {
      final CounterAxisMap a = CounterAxisMap.forAmount(2500);
      expect(a.weight, equals(CounterAxisMap.heavy.weight));
    });
  });

  group('KineticRupeeCounter', () {
    testWidgets('renders Indian-locale grouped numbers',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: KineticRupeeCounter(amount: 1234567)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('₹12,34,567'), findsOneWidget);
    });
  });
}
```

### Manual QA

- Open order builder. Add items one by one. Watch the cart-bar total counter:
  - At ₹0: clean upright Fraunces, mid weight.
  - At ₹500: subtle italic creeping in, slightly bolder.
  - At ₹2,500+: confident italic, noticeably heavier, WONK kicks in (look at the
    "₹" symbol — should curl).
- The transition between axis maps must be smooth — no font-swap snap.
- KOT success screen: the `#0427` number should fade in with axes growing from
  light upright → bold italic-wonky over 800ms.

### Verifying axes work

If the axes don't visibly change, the font file may be wrong (Google Fonts ships
multiple builds). Confirm:

```bash
fc-scan assets/fonts/Fraunces*.ttf | grep -i axis
```

You should see all four axes (`opsz`, `SOFT`, `WONK`, `wght`). If only `wght`
appears, you have the partial build — re-download the full variable TTF.

---

## Acceptance Criteria

- [ ] `assets/fonts/Fraunces[opsz,SOFT,WONK,wght].ttf` exists in repo
- [ ] `lib/motion/kinetic_counter.dart` exists with `CounterAxisMap`,
      `KineticRupeeCounter`, `KineticKotNumber`
- [ ] `lib/motion/motion.dart` exports it
- [ ] Font registered in `pubspec.yaml` with correct file name
- [ ] 3 integration points wired
- [ ] All counter tests pass
- [ ] Manual QA — counter visibly morphs axes on device as amount changes
- [ ] No `dynamic`, no `as` casts, no `!` operator in new code
- [ ] Indian-locale grouping correct: `1234567` → `₹12,34,567` (not `1,234,567`)

---

## Strict Dart Conventions Reminder

- No `dynamic`
- No `as` casts
- No `!` operator
- `const` everywhere it compiles
- `FontFeature.tabularFigures()` so digit width doesn't jitter as numbers roll
