# Agent Prompt 05 — Rive State Machine (Send-KOT Button)

**Priority:** #5 (sets the pattern for all future state-driven icons)
**Effort:** 5 days (3 dev + 2 designer for `.riv` files)
**Touches:** `lib/motion/rive_button.dart` (new), `lib/widgets/send_kot_button.dart` (new),
`assets/rive/send_kot_button.riv` (designer asset), `lib/screens/order_review_screen.dart` (modify)
**Parallel-safe with:** Prompt 06 (no shared files)
**Depends on:** Prompts 01, 02 (uses `RestroSprings` for fallback transitions, `FeedbackService` for haptic-on-state-change)

---

## Context

Lottie plays. Rive responds. A single `.riv` file holds idle → loading → success
→ error states with transitions baked in by the designer. The Flutter widget
just sets a boolean input; the file does the rest. Files are 50–80% smaller
than equivalent Lottie because they're binary-encoded.

This prompt builds the **Send-KOT button** — a single Rive asset that displays
four visible states without the developer writing animation code:

1. **Idle** — saffron gradient pill, paper-plane icon, "Send to Kitchen" label
2. **Loading** — pill flattens slightly, icon morphs into spinning ring
3. **Success** — pill turns cardamom green, ring morphs into checkmark, label "Sent!"
4. **Error** — pill turns masala red, ring morphs into X, label "Retry"

The designer authors the states in the Rive editor. The Flutter side ships the
file and binds inputs from app state.

---

## What to Build

### Part 1: Designer Brief (separate document, no code)

Before any Flutter code, the designer needs to receive this brief. The agent
should produce this as a markdown file at `design/RIVE_SEND_KOT_BUTTON_BRIEF.md`:

```markdown
# Rive Asset Brief — Send-KOT Button

## Output
`assets/rive/send_kot_button.riv` — Rive 2 file, max 24 KB.

## Artboard
- Name: `SendKotButton`
- Size: 280 × 56
- Background: transparent

## Color tokens (use Rive's Solid Colors)
- Saffron Bright: #FFB964
- Kesar: #FF7849
- Cardamom: #84A763
- Masala: #C1432E
- Tamarind: #8B4F2A
- White: #FFFFFF

## State Machine
Name: `Main`

### Inputs
- `fire` (trigger) — fires when user taps the button (idle → loading)
- `success` (trigger) — fires when KOT confirmed by admin (loading → success)
- `error` (trigger) — fires when KOT fails (loading → error)
- `reset` (trigger) — fires when retry tapped (error → idle, success → idle)

### States & Transitions

idle  ── fire ─→  loading
loading ── success ─→  success
loading ── error  ─→  error
success ── reset (auto, 2.5s) ─→ idle
error  ── reset ─→  idle

### Visual specs per state

**idle** (loop, 0s)
- Pill 280×56 with saffron→kesar gradient
- Centered icon: paper plane, 22×22, white
- Right of icon, 12px gap: text "Send to Kitchen", DM Sans semibold 14pt, white
- Subtle 1.5s breathing scale 1.00 → 1.02 → 1.00

**loading** (loop, 1.2s)
- Pill scales to 0.95, gradient shifts to tamarind→saffron-deep
- Icon morphs into a 22×22 ring with one quarter cut out, spinning 1 rev/sec
- Text changes to "Firing…", lower opacity (0.85)

**success** (one-shot, 0.9s)
- Pill snaps to cardamom→cardamom-dark gradient with overshoot scale 1.05 → 1.0
- Icon morphs into 18×12 checkmark (drawn via path)
- Text changes to "Sent!" with overshoot fade-in
- 6 spice-toned particles burst from the centre (radial, ease-out 0.6s)

**error** (one-shot, 0.6s)
- Pill shifts to masala→tamarind gradient
- Icon morphs into 18×18 X with horizontal shake (±2px, 3 oscillations)
- Text changes to "Retry"
- Single masala ripple expands from button edge

## Deliverable
- Single `.riv` file under 24 KB.
- One artboard, one state machine, four states, four triggers.
- All transitions baked — no Flutter-side animation needed.
- Test in Rive's runtime preview: every state visible by triggering each input.
```

### Part 2 (NEW): `lib/motion/rive_button.dart`

```dart
// ===== ANCHOR: RIVE_BUTTON_IMPORTS =====
import 'package:flutter/material.dart';
import 'package:rive/rive.dart';
import 'feedback_kind.dart';
import 'feedback_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ===== END ANCHOR: RIVE_BUTTON_IMPORTS =====

// ===== ANCHOR: RIVE_BUTTON_STATE =====
/// Sealed union of Rive-button visible states. Drives which trigger to fire.
sealed class RiveButtonPhase {
  const RiveButtonPhase();
}

final class RiveButtonIdle extends RiveButtonPhase {
  const RiveButtonIdle();
}

final class RiveButtonLoading extends RiveButtonPhase {
  const RiveButtonLoading();
}

final class RiveButtonSuccess extends RiveButtonPhase {
  const RiveButtonSuccess();
}

final class RiveButtonError extends RiveButtonPhase {
  const RiveButtonError();
}
// ===== END ANCHOR: RIVE_BUTTON_STATE =====

// ===== ANCHOR: RIVE_BUTTON_WIDGET =====
/// Wraps a Rive state-machine asset as a stateful button.
///
/// The parent owns the [phase] — this widget only renders and binds inputs.
/// On phase changes, the widget fires the corresponding Rive trigger.
class RiveButton extends ConsumerStatefulWidget {
  const RiveButton({
    required this.assetPath,
    required this.stateMachineName,
    required this.phase,
    required this.onTap,
    this.width = 280,
    this.height = 56,
    this.semanticLabel,
    super.key,
  });

  /// Asset path, e.g. 'assets/rive/send_kot_button.riv'.
  final String assetPath;

  /// State machine name inside the artboard. For Send-KOT: 'Main'.
  final String stateMachineName;

  /// The current desired phase. Changes drive triggers.
  final RiveButtonPhase phase;

  /// Fires only when phase is [RiveButtonIdle] or [RiveButtonError].
  final VoidCallback onTap;

  final double width;
  final double height;
  final String? semanticLabel;

  @override
  ConsumerState<RiveButton> createState() => _RiveButtonState();
}

class _RiveButtonState extends ConsumerState<RiveButton> {
  StateMachineController? _controller;
  SMITrigger? _fireInput;
  SMITrigger? _successInput;
  SMITrigger? _errorInput;
  SMITrigger? _resetInput;

  void _onRiveInit(Artboard artboard) {
    final StateMachineController? controller =
        StateMachineController.fromArtboard(artboard, widget.stateMachineName);
    if (controller == null) {
      // Designer didn't ship the expected state-machine name. Fail visibly in
      // debug; in release we render a static button.
      assert(false, 'Rive state machine "${widget.stateMachineName}" not found '
          'in ${widget.assetPath}.');
      return;
    }
    artboard.addController(controller);
    _controller = controller;
    _fireInput = controller.findInput<bool>('fire') as SMITrigger?;
    _successInput = controller.findInput<bool>('success') as SMITrigger?;
    _errorInput = controller.findInput<bool>('error') as SMITrigger?;
    _resetInput = controller.findInput<bool>('reset') as SMITrigger?;
    _syncPhase();
  }

  @override
  void didUpdateWidget(covariant RiveButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase) {
      _syncPhase();
    }
  }

  void _syncPhase() {
    switch (widget.phase) {
      case RiveButtonIdle():
        _resetInput?.fire();
      case RiveButtonLoading():
        _fireInput?.fire();
      case RiveButtonSuccess():
        _successInput?.fire();
        ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
      case RiveButtonError():
        _errorInput?.fire();
        ref.read(feedbackServiceProvider).fire(const FeedbackError());
    }
  }

  bool get _canTap => widget.phase is RiveButtonIdle || widget.phase is RiveButtonError;

  void _handleTap() {
    if (!_canTap) return;
    ref.read(feedbackServiceProvider).fire(const FeedbackHeavy());
    widget.onTap();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticLabel ?? 'Send to kitchen',
      button: true,
      child: GestureDetector(
        onTap: _handleTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: RiveAnimation.asset(
            widget.assetPath,
            stateMachines: <String>[widget.stateMachineName],
            onInit: _onRiveInit,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
// ===== END ANCHOR: RIVE_BUTTON_WIDGET =====
```

> **The single `as SMITrigger?` cast** is mathematically necessary because
> `findInput<bool>` returns `SMIInput<bool>?` and Rive's `SMITrigger` extends
> `SMIInput<bool>`. The cast is documented inline and unavoidable per Rive's
> public API.

### Part 3 (NEW): `lib/widgets/send_kot_button.dart`

```dart
// ===== ANCHOR: SEND_KOT_BUTTON =====
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../motion/motion.dart';

/// High-level wrapper around [RiveButton] specifically for KOT firing.
///
/// Owns the phase state machine; transitions are driven by the parent screen
/// calling [SendKotButtonController] methods.
class SendKotButton extends ConsumerStatefulWidget {
  const SendKotButton({
    required this.controller,
    required this.onFire,
    super.key,
  });

  final SendKotButtonController controller;
  final Future<void> Function() onFire;

  @override
  ConsumerState<SendKotButton> createState() => _SendKotButtonState();
}

class _SendKotButtonState extends ConsumerState<SendKotButton> {
  RiveButtonPhase _phase = const RiveButtonIdle();

  @override
  void initState() {
    super.initState();
    widget.controller._attach(this);
  }

  @override
  void dispose() {
    widget.controller._detach();
    super.dispose();
  }

  void _setPhase(RiveButtonPhase phase) {
    setState(() {
      _phase = phase;
    });
  }

  Future<void> _onTap() async {
    if (_phase is! RiveButtonIdle && _phase is! RiveButtonError) return;
    _setPhase(const RiveButtonLoading());
    try {
      await widget.onFire();
      // Caller is responsible for advancing to success / error via controller.
    } catch (_) {
      _setPhase(const RiveButtonError());
    }
  }

  @override
  Widget build(BuildContext context) {
    return RiveButton(
      assetPath: 'assets/rive/send_kot_button.riv',
      stateMachineName: 'Main',
      phase: _phase,
      onTap: _onTap,
      semanticLabel: switch (_phase) {
        RiveButtonIdle() => 'Send to kitchen',
        RiveButtonLoading() => 'Sending to kitchen',
        RiveButtonSuccess() => 'Sent to kitchen',
        RiveButtonError() => 'Retry send to kitchen',
      },
    );
  }
}

/// External handle for advancing button state in response to server events.
class SendKotButtonController {
  _SendKotButtonState? _state;

  void _attach(_SendKotButtonState s) {
    _state = s;
  }

  void _detach() {
    _state = null;
  }

  void confirmSuccess() {
    _state?._setPhase(const RiveButtonSuccess());
    // Auto-return to idle after 2.5s — matches Rive's internal timing.
    Future<void>.delayed(const Duration(milliseconds: 2500), () {
      _state?._setPhase(const RiveButtonIdle());
    });
  }

  void confirmError() {
    _state?._setPhase(const RiveButtonError());
  }

  void reset() {
    _state?._setPhase(const RiveButtonIdle());
  }
}
// ===== END ANCHOR: SEND_KOT_BUTTON =====
```

### Part 4 (MODIFY): `lib/screens/order_review_screen.dart`

Replace the existing "Send KOT" button with `SendKotButton`:

```dart
class _OrderReviewScreenState extends ConsumerState<OrderReviewScreen> {
  final SendKotButtonController _kotButton = SendKotButtonController();

  Future<void> _fireKot() async {
    final WsClient ws = ref.read(wsClientProvider);
    final Result<KotConfirmed, KotError> result =
        await ws.fireKot(tableId: widget.tableId, items: _cart.items);
    switch (result) {
      case Success(value: final KotConfirmed _):
        _kotButton.confirmSuccess();
        await Future<void>.delayed(const Duration(seconds: 1));
        if (mounted) {
          context.push('/order/${widget.tableId}/success');
        }
      case Failure(error: final KotError _):
        _kotButton.confirmError();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // ... rest of screen ...
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          child: SendKotButton(
            controller: _kotButton,
            onFire: _fireKot,
          ),
        ),
      ),
    );
  }
}
```

### Part 5 (MODIFY): `pubspec.yaml`

Add inside `dependencies:`:

```yaml
rive: ^0.13.20
```

And register the asset:

```yaml
flutter:
  assets:
    - assets/rive/
```

### Part 6 (MODIFY): `lib/motion/motion.dart`

Add inside the EXPORTS anchor:

```dart
export 'rive_button.dart';
```

---

## Testing

### Widget test (NEW): `test/motion/rive_button_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:restro_operator/motion/motion.dart';

void main() {
  group('RiveButton', () {
    testWidgets('renders without crashing for each phase',
        (WidgetTester tester) async {
      for (final RiveButtonPhase phase in <RiveButtonPhase>[
        const RiveButtonIdle(),
        const RiveButtonLoading(),
        const RiveButtonSuccess(),
        const RiveButtonError(),
      ]) {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: Scaffold(
                body: RiveButton(
                  assetPath: 'assets/rive/send_kot_button.riv',
                  stateMachineName: 'Main',
                  phase: phase,
                  onTap: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
      }
    });

    testWidgets('onTap fires only in idle and error phases',
        (WidgetTester tester) async {
      int taps = 0;
      Widget build(RiveButtonPhase phase) => ProviderScope(
            child: MaterialApp(
              home: Scaffold(
                body: RiveButton(
                  assetPath: 'assets/rive/send_kot_button.riv',
                  stateMachineName: 'Main',
                  phase: phase,
                  onTap: () => taps++,
                ),
              ),
            ),
          );

      await tester.pumpWidget(build(const RiveButtonIdle()));
      await tester.tap(find.byType(RiveButton));
      expect(taps, 1);

      await tester.pumpWidget(build(const RiveButtonLoading()));
      await tester.tap(find.byType(RiveButton));
      expect(taps, 1); // no increment — loading state ignores taps

      await tester.pumpWidget(build(const RiveButtonError()));
      await tester.tap(find.byType(RiveButton));
      expect(taps, 2);
    });
  });
}
```

### Manual QA

- Tap Send KOT on the order review screen → button morphs to loading, spinner
  visible, label changes to "Firing…", heavy haptic fires.
- Wait for server response → button morphs to success cardamom-green, checkmark
  draws, success chime + medium-light haptic pattern fires.
- Force a network error → button morphs to masala-red with X icon, retry label,
  error buzz fires. Tap again → re-attempts fire.
- File size on disk: `ls -lh assets/rive/send_kot_button.riv` should be under
  24 KB. If larger, designer needs to optimize.

---

## Acceptance Criteria

- [ ] `design/RIVE_SEND_KOT_BUTTON_BRIEF.md` exists and is handed to designer
- [ ] `assets/rive/send_kot_button.riv` ships (placeholder if designer not done yet — see fallback below)
- [ ] `lib/motion/rive_button.dart` exists with sealed `RiveButtonPhase` and `RiveButton` widget
- [ ] `lib/widgets/send_kot_button.dart` exists with `SendKotButton` + `SendKotButtonController`
- [ ] `lib/motion/motion.dart` exports `rive_button.dart`
- [ ] `rive: ^0.13.20` in `pubspec.yaml`, `assets/rive/` registered
- [ ] `order_review_screen.dart` uses `SendKotButton` instead of any prior button
- [ ] Widget tests pass
- [ ] Manual QA — 4 states visible on device, haptic + audio fire per state
- [ ] No `dynamic` anywhere; the one `as SMITrigger?` cast is documented inline
- [ ] Exhaustive switch on `RiveButtonPhase` everywhere it's used

### Fallback (until designer ships the .riv)

The Rive runtime gracefully renders a blank artboard if the asset is missing.
For the dev-loop, ship a 1×1 transparent `.riv` placeholder so `flutter run`
doesn't throw. The button still functions — it just looks like an empty box
until the real asset arrives.

---

## Strict Dart Conventions Reminder

- Sealed `RiveButtonPhase` — every switch must be exhaustive
- One documented `as SMITrigger?` cast in `rive_button.dart` (Rive API requirement)
- No `dynamic`
- No `!` operator
- `const` everywhere it compiles
