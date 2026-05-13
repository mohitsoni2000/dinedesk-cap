# Agent Prompt 03 — Hero Transitions

**Priority:** #3 (compounds with every other animation — must run after Spring Physics)
**Effort:** 3 days
**Touches:** `lib/motion/hero_tags.dart` (new), `lib/motion/morph_container.dart` (new),
6 screen files (Hero wraps + OpenContainer integration)
**Parallel-safe with:** Prompt 04 (no shared files)
**Depends on:** Prompt 01 must land first (uses `RestroSprings`)

---

## Context

The Spotify "album hero → sticky nav" pattern is now standard. Mark elements
with a shared name across screens, navigate, and the browser/SDK interpolates
position and size as one continuous shape. Users never lose context.

In Flutter this is solved by two primitives:

1. **`Hero` widget** — wrap an element on screen A and screen B with the same
   `tag`; the framework morphs between them during navigation.
2. **`OpenContainer`** (from `animations` package) — a card that "opens" into a
   full screen with a smooth zoom-and-fade, used for table → order builder.

This prompt centralises hero tags into a strict registry (no stringly-typed tags
sprinkled across the codebase) and wires every key shared element across the
boot + order flow.

---

## What to Build

### File 1 (NEW): `lib/motion/hero_tags.dart`

```dart
// ===== ANCHOR: HERO_TAGS =====
/// Centralised registry of every Hero tag used in the app.
///
/// Stringly-typed Hero tags scattered across screens are a maintenance nightmare.
/// Every shared element gets a typed factory here. Tags are deterministic so two
/// screens always agree on the same key.
///
/// Strict-mode constraints:
/// - No `dynamic`, no `Object` tags — every tag is a `String` built from typed inputs.
/// - No string concatenation at call sites — only factory methods on this class.
class HeroTags {
  const HeroTags._();

  /// Splash → QR scan: the Restro logo morphs from centre to top-corner mini-logo.
  static const String appLogo = 'hero.app-logo';

  /// QR scan → connecting: the saffron core circle morphs.
  static const String pairingCore = 'hero.pairing-core';

  /// Connecting → tables: the connection-success checkmark morphs to the
  /// connection indicator in the header.
  static const String connectionIndicator = 'hero.connection-indicator';

  /// Tables → order builder: the table number morphs from grid cell to header.
  /// Disambiguated by table id.
  static String tableNumber(String tableId) => 'hero.table-num.$tableId';

  /// Tables → order builder: the entire table card morphs to the order builder
  /// background. Disambiguated by table id.
  static String tableCard(String tableId) => 'hero.table-card.$tableId';

  /// Order builder → order review: the cart bar morphs to the review header.
  static const String cartBar = 'hero.cart-bar';

  /// Order builder → order review: the running total morphs.
  static const String orderTotal = 'hero.order-total';

  /// Order review → order success: the KOT badge morphs to the success checkmark
  /// position.
  static const String kotBadge = 'hero.kot-badge';

  /// Order success → tables: the success ring morphs back to the freshly-cleared
  /// table card. Disambiguated by table id.
  static String tableReturnRing(String tableId) => 'hero.table-return.$tableId';
}
// ===== END ANCHOR: HERO_TAGS =====
```

### File 2 (NEW): `lib/motion/morph_container.dart`

```dart
// ===== ANCHOR: MORPH_CONTAINER =====
import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'springs.dart';

/// A standardised [OpenContainer] preset for Restro.
///
/// Wraps a `closedBuilder` (the small card) and an `openBuilder` (the full screen
/// it morphs into). Use this instead of `Navigator.push` when the small card
/// is the entry-point UI for the larger screen.
///
/// Default transition duration matches a [RestroSprings.heavy] cycle.
class RestroMorph extends StatelessWidget {
  const RestroMorph({
    required this.closedBuilder,
    required this.openBuilder,
    this.closedColor = const Color(0x00000000),
    this.closedShape = const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(14)),
    ),
    this.transitionDuration = const Duration(milliseconds: 420),
    super.key,
  });

  /// Builds the closed state — usually the small card.
  final CloseContainerBuilder closedBuilder;

  /// Builds the full open screen.
  final OpenContainerBuilder<void> openBuilder;

  final Color closedColor;
  final ShapeBorder closedShape;
  final Duration transitionDuration;

  @override
  Widget build(BuildContext context) {
    return OpenContainer<void>(
      closedColor: closedColor,
      openColor: Theme.of(context).colorScheme.surface,
      closedShape: closedShape,
      closedElevation: 0,
      openElevation: 0,
      transitionType: ContainerTransitionType.fadeThrough,
      transitionDuration: transitionDuration,
      closedBuilder: closedBuilder,
      openBuilder: openBuilder,
    );
  }
}
// ===== END ANCHOR: MORPH_CONTAINER =====
```

### File 3 (MODIFY): `pubspec.yaml`

Add inside `dependencies:`:

```yaml
animations: ^2.0.11
```

### File 4 (MODIFY): `lib/motion/motion.dart` (barrel)

Add the export inside the existing ANCHOR block:

```dart
// ===== ANCHOR: EXPORTS =====
export 'springs.dart';
export 'feedback_kind.dart';
export 'feedback_service.dart';
export 'hero_tags.dart';
export 'morph_container.dart';
// ===== END ANCHOR: EXPORTS =====
```

---

## Integration — Wrap Screens with Hero / OpenContainer

### Screen 1: `lib/screens/splash_screen.dart`

Wrap the logo container in a `Hero`:

```dart
// Inside the splash logo widget
Hero(
  tag: HeroTags.appLogo,
  child: Container(
    width: 100,
    height: 100,
    decoration: ...,
    child: const Center(child: Text('R', style: ...)),
  ),
)
```

### Screen 2: `lib/screens/qr_scan_screen.dart`

The same `appLogo` tag, but rendered as a small top-corner badge during scan:

```dart
Positioned(
  top: 16,
  left: 16,
  child: Hero(
    tag: HeroTags.appLogo,
    child: Container(width: 32, height: 32, decoration: ...),
  ),
)
```

The framework morphs the 100×100 splash logo into the 32×32 corner badge.

### Screen 3: `lib/screens/connecting_screen.dart`

Wrap the central WiFi core:

```dart
Hero(
  tag: HeroTags.pairingCore,
  child: Container(
    width: 60, height: 60,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(colors: [...]),
    ),
    child: Icon(Icons.wifi),
  ),
)
```

### Screen 4: `lib/screens/tables_screen.dart`

Each table card uses `RestroMorph` to open the order builder:

```dart
RestroMorph(
  closedShape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(14)),
  ),
  closedBuilder: (BuildContext context, VoidCallback openContainer) {
    return GestureDetector(
      onTap: openContainer,
      child: TableCard(
        table: table,
        tableNumberHero: HeroTags.tableNumber(table.id),
      ),
    );
  },
  openBuilder: (BuildContext context, VoidCallback closeContainer) {
    return OrderBuilderScreen(tableId: table.id);
  },
)
```

Inside `TableCard`, wrap the table number in a `Hero`:

```dart
Hero(
  tag: tableNumberHero,
  flightShuttleBuilder: _scaleAndFadeShuttle, // see below
  child: Text(
    'T${table.number}',
    style: TextStyle(
      fontFamily: 'Fraunces',
      fontSize: 22,
      ...
    ),
  ),
)
```

### Screen 5: `lib/screens/order_builder_screen.dart`

Receiving end of the table number hero — render it in the header at a larger
size, with the same tag:

```dart
Hero(
  tag: HeroTags.tableNumber(widget.tableId),
  flightShuttleBuilder: _scaleAndFadeShuttle,
  child: Text(
    'T${widget.tableId} · Garden',
    style: TextStyle(fontFamily: 'Fraunces', fontSize: 18, ...),
  ),
)
```

Also wrap the cart bar:

```dart
Hero(
  tag: HeroTags.cartBar,
  child: OrderCartBar(...),
)
```

### Screen 6: `lib/screens/order_review_screen.dart`

Receive the `cartBar` hero — render the same bar widget at the top of the review:

```dart
Hero(
  tag: HeroTags.cartBar,
  child: OrderCartBar(showAsHeader: true),
)
```

And wrap the order total:

```dart
Hero(
  tag: HeroTags.orderTotal,
  child: Text('₹$total', style: ...),
)
```

### Screen 7: `lib/screens/order_success_screen.dart`

Receive the KOT badge hero on the way in, then morph back to the table on
auto-dismiss:

```dart
Hero(
  tag: HeroTags.kotBadge,
  child: const SuccessRing(),
)
```

---

## Shared Element Shuttle Builder

For text that changes size dramatically during the flight (e.g. table number
goes from a 22-point body to an 18-point header), provide a custom
`flightShuttleBuilder` that fades between the two. Add this helper to
`morph_container.dart`:

```dart
// ===== ANCHOR: SHUTTLE_HELPERS =====
/// Standard shuttle that interpolates fade between the two sides during flight.
/// Use for text or elements whose visual character differs at endpoints.
Widget restroFadeShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final Widget fromHero = fromHeroContext.widget is Hero
      ? (fromHeroContext.widget as Hero).child
      : const SizedBox.shrink();
  final Widget toHero = toHeroContext.widget is Hero
      ? (toHeroContext.widget as Hero).child
      : const SizedBox.shrink();
  return AnimatedBuilder(
    animation: animation,
    builder: (BuildContext context, Widget? _) {
      return Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Opacity(opacity: 1 - animation.value, child: fromHero),
          Opacity(opacity: animation.value, child: toHero),
        ],
      );
    },
  );
}
// ===== END ANCHOR: SHUTTLE_HELPERS =====
```

> Note: this is the **single** place in the codebase that uses an `as` cast on
> `Hero`. The cast is mathematically safe — the hero contexts are guaranteed to
> wrap a `Hero` widget. Document the cast with a comment per the strict rules.

Update each `Hero(...)` that needs character-changing morph to pass
`flightShuttleBuilder: restroFadeShuttle`.

---

## Testing

### Widget test (NEW): `test/motion/hero_tags_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:restro_operator/motion/motion.dart';

void main() {
  group('HeroTags', () {
    test('all static tags are unique', () {
      const Set<String> tags = <String>{
        HeroTags.appLogo,
        HeroTags.pairingCore,
        HeroTags.connectionIndicator,
        HeroTags.cartBar,
        HeroTags.orderTotal,
        HeroTags.kotBadge,
      };
      // If any duplicate, the set has fewer entries than the literal.
      expect(tags.length, 6);
    });

    test('table number tags disambiguate by id', () {
      expect(HeroTags.tableNumber('T1'), isNot(equals(HeroTags.tableNumber('T2'))));
      expect(HeroTags.tableNumber('T1'), startsWith('hero.table-num.'));
    });

    test('table return ring tags do not collide with table card tags', () {
      expect(
        HeroTags.tableReturnRing('T1'),
        isNot(equals(HeroTags.tableCard('T1'))),
      );
    });
  });
}
```

### Widget test (NEW): `test/screens/table_to_order_morph_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro_operator/screens/tables_screen.dart';

void main() {
  testWidgets('Tapping a table card opens order builder with hero morph',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: TablesScreen()));
    await tester.tap(find.text('T1'));
    await tester.pump(const Duration(milliseconds: 100)); // mid-flight
    await tester.pump(const Duration(milliseconds: 400)); // settle
    expect(find.text('T1 · Garden'), findsOneWidget);
  });
}
```

### Manual QA

- Tap a table card from the tables screen → the card should expand smoothly into
  the order builder, not snap-cut.
- The "T1" text on the table card should glide to its position in the order
  header (slightly larger font, top of screen).
- From order builder → review, the cart bar at the bottom should slide up to the
  top of the review screen, growing slightly.
- After firing KOT, the success ring should morph back to a freshly-cleared
  table card when the screen auto-dismisses.

---

## Acceptance Criteria

- [ ] `lib/motion/hero_tags.dart` exists with `HeroTags` registry
- [ ] `lib/motion/morph_container.dart` exists with `RestroMorph` + `restroFadeShuttle`
- [ ] `animations: ^2.0.11` added to `pubspec.yaml`
- [ ] All 7 listed integration points wrap their elements in `Hero` with the
      correct tag from `HeroTags`
- [ ] `RestroMorph` is used on every table card on the tables screen
- [ ] `flutter analyze` returns 0 errors on strict rules
- [ ] Both new tests pass
- [ ] Manual QA: 4 morph transitions work smoothly on device (60fps)
- [ ] No `dynamic` anywhere in new code
- [ ] The one `as` cast in `restroFadeShuttle` is annotated with a comment
      explaining mathematical safety
- [ ] `grep -rn "Hero(tag:" lib/screens/` finds zero stringly-typed tags — all use `HeroTags.*`

---

## Strict Dart Conventions Reminder

- No `dynamic`
- No `as` casts (the one exception in `restroFadeShuttle` MUST have an explanatory comment)
- No `??` fallbacks for default values
- `const` everywhere it compiles
- Anchor comments at top of public hierarchy
