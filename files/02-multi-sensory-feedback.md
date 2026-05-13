# Agent Prompt 02 — Multi-Sensory Feedback

**Priority:** #2 (top-of-roadmap impact — restaurant noise drowns visual-only feedback)
**Effort:** 2 days
**Touches:** `lib/motion/feedback_kind.dart`, `lib/motion/feedback_service.dart` (both new),
4 screen files (modifications), `assets/audio/` (4 new files)
**Parallel-safe with:** Prompt 01 (no shared files), Prompt 04 (no shared files)
**Conflicts with:** none

---

## Context

Restaurants are loud. A waiter firing a KOT on a Friday-night packed dining
room cannot rely on visual confirmation alone — they're already looking at the
next table by the time the screen flashes. Top-tier mobile apps (Apple Pay,
Stripe, Duolingo) fire **visual + haptic + audio simultaneously** on the same
frame.

This prompt builds a single `FeedbackService` that coordinates all three
channels. Calling code says "this is a `FeedbackKind.kotFired` moment" and the
service plays the right combination automatically.

---

## What to Build

### File 1 (NEW): `lib/motion/feedback_kind.dart`

```dart
// ===== ANCHOR: FEEDBACK_KINDS =====
import 'package:flutter/services.dart';

/// Sealed union of every feedback moment in the app.
///
/// Each kind maps to a specific combination of haptic strength, audio asset,
/// and (where relevant) visual response. Use the sealed pattern so adding
/// a new feedback type forces exhaustive handling in [FeedbackService].
sealed class FeedbackKind {
  const FeedbackKind();
}

/// Light tactile tap. Used for: item add-to-cart, item remove, category switch,
/// general "I acknowledged your tap" confirmations.
final class FeedbackLight extends FeedbackKind {
  const FeedbackLight();
}

/// Medium tap. Used for: PIN key press, table card tap, menu tab switch.
final class FeedbackMedium extends FeedbackKind {
  const FeedbackMedium();
}

/// Heavy thump. Used for: KOT fire, send-to-kitchen confirmation, bill print.
/// This is the "you committed an action" feedback.
final class FeedbackHeavy extends FeedbackKind {
  const FeedbackHeavy();
}

/// Success notification — three-tier vibration + chime.
/// Used for: KOT successfully fired, payment received, order completed.
final class FeedbackSuccess extends FeedbackKind {
  const FeedbackSuccess();
}

/// Error notification — sharp double buzz + low tone.
/// Used for: wrong PIN, network failure, KOT print failure.
final class FeedbackError extends FeedbackKind {
  const FeedbackError();
}

/// Warning. Used for: nearing reconnect timeout, low-stock item selected.
final class FeedbackWarning extends FeedbackKind {
  const FeedbackWarning();
}

/// Selection — for cursor-style position changes (slider thumb, picker scroll).
final class FeedbackSelection extends FeedbackKind {
  const FeedbackSelection();
}

/// Maps a feedback kind to the corresponding [HapticFeedback] call.
/// Exhaustive — switch is on the sealed class so the compiler catches gaps.
extension FeedbackHaptic on FeedbackKind {
  Future<void> triggerHaptic() async {
    switch (this) {
      case FeedbackLight():
        await HapticFeedback.lightImpact();
      case FeedbackMedium():
        await HapticFeedback.mediumImpact();
      case FeedbackHeavy():
        await HapticFeedback.heavyImpact();
      case FeedbackSuccess():
        await HapticFeedback.mediumImpact();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await HapticFeedback.lightImpact();
      case FeedbackError():
        await HapticFeedback.heavyImpact();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await HapticFeedback.heavyImpact();
      case FeedbackWarning():
        await HapticFeedback.mediumImpact();
      case FeedbackSelection():
        await HapticFeedback.selectionClick();
    }
  }

  /// Audio asset key for this feedback. Null means no sound.
  String? get audioAsset {
    switch (this) {
      case FeedbackLight():
        return 'audio/tap_light.caf';
      case FeedbackMedium():
        return 'audio/tap_medium.caf';
      case FeedbackHeavy():
        return 'audio/tap_heavy.caf';
      case FeedbackSuccess():
        return 'audio/success_chime.caf';
      case FeedbackError():
        return 'audio/error_buzz.caf';
      case FeedbackWarning():
        return 'audio/warning_tone.caf';
      case FeedbackSelection():
        return null; // selection is haptic-only by design
    }
  }
}
// ===== END ANCHOR: FEEDBACK_KINDS =====
```

### File 2 (NEW): `lib/motion/feedback_service.dart`

```dart
// ===== ANCHOR: FEEDBACK_SERVICE =====
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'feedback_kind.dart';

/// Coordinates haptic + audio firing for a [FeedbackKind].
///
/// Service is a singleton via Riverpod. Audio is preloaded in [init()] so
/// the first KOT fire of the shift isn't delayed by asset load.
///
/// Settings (mute audio, mute haptic) are pulled from user preferences
/// — but those are out of scope for this prompt. For now, both are always on.
class FeedbackService {
  FeedbackService();

  // Pool of audio players. Pre-allocated so we don't construct one per fire.
  final List<AudioPlayer> _pool = <AudioPlayer>[];
  int _nextPlayer = 0;
  static const int _poolSize = 3;

  bool _initialized = false;

  /// Preload audio players. Call once at app boot (e.g. in [main]).
  Future<void> init() async {
    if (_initialized) return;
    for (int i = 0; i < _poolSize; i++) {
      final AudioPlayer p = AudioPlayer();
      await p.setReleaseMode(ReleaseMode.stop);
      _pool.add(p);
    }
    _initialized = true;
  }

  /// Fire a feedback. Haptic + audio run concurrently — do not await separately.
  ///
  /// Strict: this is fire-and-forget at the call site. Errors in audio
  /// playback do not throw; they log silently.
  void fire(FeedbackKind kind) {
    if (!_initialized) return;
    // Haptic runs on a platform channel — fire-and-forget.
    unawaited(kind.triggerHaptic());

    // Audio: round-robin through the pool to allow overlapping plays.
    final String? asset = kind.audioAsset;
    if (asset != null) {
      final AudioPlayer player = _pool[_nextPlayer];
      _nextPlayer = (_nextPlayer + 1) % _poolSize;
      unawaited(_playAsset(player, asset));
    }
  }

  Future<void> _playAsset(AudioPlayer player, String asset) async {
    try {
      await player.stop();
      await player.play(AssetSource(asset));
    } catch (e) {
      // Audio failures are non-fatal. Haptic still fired.
      // ignore: avoid_print
      print('FeedbackService: audio play failed for $asset — $e');
    }
  }

  Future<void> dispose() async {
    for (final AudioPlayer p in _pool) {
      await p.dispose();
    }
    _pool.clear();
    _initialized = false;
  }
}

/// Shim for `unawaited` since the dart:async one requires importing dart:async.
void unawaited(Future<void> future) {}
// ===== END ANCHOR: FEEDBACK_SERVICE =====

// ===== ANCHOR: FEEDBACK_PROVIDER =====
/// Riverpod provider for the singleton service.
final Provider<FeedbackService> feedbackServiceProvider =
    Provider<FeedbackService>((ProviderRef<FeedbackService> ref) {
  final FeedbackService service = FeedbackService();
  ref.onDispose(() => service.dispose());
  return service;
});
// ===== END ANCHOR: FEEDBACK_PROVIDER =====
```

### File 3 (MODIFY): `pubspec.yaml`

Add inside `dependencies:` block:

```yaml
audioplayers: ^6.1.0
```

And register the audio assets:

```yaml
flutter:
  assets:
    - assets/audio/
```

### File 4 (NEW assets): `assets/audio/`

The agent should produce six audio files. If the agent cannot synthesise audio,
generate placeholders by recording 200ms of silence labelled correctly. The
restaurant designer / sound team will replace them later. Required files:

- `assets/audio/tap_light.caf` — 80ms soft mid-frequency click (~600Hz)
- `assets/audio/tap_medium.caf` — 100ms mid-frequency click (~440Hz)
- `assets/audio/tap_heavy.caf` — 120ms low thump (~180Hz)
- `assets/audio/success_chime.caf` — 320ms warm two-note chime (C5 → G5)
- `assets/audio/error_buzz.caf` — 200ms low descending tone (~120Hz)
- `assets/audio/warning_tone.caf` — 200ms single sustained tone (~330Hz)

If `.caf` is not generable, use `.mp3` or `.wav` and update the asset paths in
`feedback_kind.dart` accordingly.

### File 5 (MODIFY): `lib/main.dart`

Initialise `FeedbackService` before `runApp`:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final ProviderContainer container = ProviderContainer();
  final FeedbackService feedback = container.read(feedbackServiceProvider);
  await feedback.init();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const RestroOperatorApp(),
    ),
  );
}
```

---

## Integration — Wire `FeedbackService` Into Screens

Use the Riverpod provider. Pattern:

```dart
class _MyWidgetState extends ConsumerState<MyWidget> {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        ref.read(feedbackServiceProvider).fire(const FeedbackHeavy());
        _doActualThing();
      },
      child: ...,
    );
  }
}
```

### Mapping — where each feedback kind fires

| Screen / Widget | Action | FeedbackKind |
|---|---|---|
| `auth_screen.dart` | Numpad key press | `FeedbackMedium()` |
| `auth_screen.dart` | PIN complete & correct | `FeedbackSuccess()` |
| `auth_screen.dart` | PIN wrong | `FeedbackError()` |
| `qr_scan_screen.dart` | Scan success | `FeedbackSuccess()` |
| `qr_scan_screen.dart` | Scan invalid token | `FeedbackError()` |
| `tables_screen.dart` | Table card tap | `FeedbackMedium()` |
| `order_builder_screen.dart` | Item add-to-cart | `FeedbackLight()` |
| `order_builder_screen.dart` | Item remove from cart | `FeedbackLight()` |
| `order_builder_screen.dart` | Category tab switch | `FeedbackSelection()` |
| `order_review_screen.dart` | Swipe-to-delete item | `FeedbackMedium()` |
| `order_review_screen.dart` | Send KOT button tap | `FeedbackHeavy()` |
| `order_success_screen.dart` | Screen enter | `FeedbackSuccess()` |
| `connection_banner.dart` | Reconnect grace 30s remaining | `FeedbackWarning()` |
| `disconnected_screen.dart` | Force-rescan button tap | `FeedbackMedium()` |

### Don't double-fire

If a button is wrapped in an `InkWell` or `Material` with its own ripple,
do not add a separate `FeedbackMedium` — let the Material default haptic stand,
or replace the InkWell with a `GestureDetector` + explicit feedback.

---

## Testing

### Unit test (NEW): `test/motion/feedback_service_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:restro_operator/motion/feedback_kind.dart';
import 'package:restro_operator/motion/feedback_service.dart';

void main() {
  group('FeedbackKind', () {
    test('all kinds map to a haptic without throwing', () async {
      final List<FeedbackKind> all = <FeedbackKind>[
        const FeedbackLight(),
        const FeedbackMedium(),
        const FeedbackHeavy(),
        const FeedbackSuccess(),
        const FeedbackError(),
        const FeedbackWarning(),
        const FeedbackSelection(),
      ];
      for (final FeedbackKind kind in all) {
        await kind.triggerHaptic();
      }
    });

    test('audio asset paths are valid keys or null', () {
      const List<FeedbackKind> all = <FeedbackKind>[
        FeedbackLight(),
        FeedbackMedium(),
        FeedbackHeavy(),
        FeedbackSuccess(),
        FeedbackError(),
        FeedbackWarning(),
        FeedbackSelection(),
      ];
      for (final FeedbackKind k in all) {
        final String? asset = k.audioAsset;
        if (asset != null) {
          expect(asset, startsWith('audio/'));
          expect(asset, endsWith('.caf'));
        }
      }
    });
  });
}
```

### Manual QA on device

- Tap PIN keys rapidly — each tap should produce a single crisp haptic (not double-fire).
- Enter wrong PIN — phone should vibrate twice with a low buzz audio.
- Fire a KOT — should produce a strong haptic + success chime, perceivable even with phone in pocket on a noisy floor.
- Mute the phone — haptic should still fire (audio respects system mute, haptic does not).
- iOS only: confirm `caf` files play; if they don't, fall back to `.mp3` and update asset paths.

---

## Acceptance Criteria

- [ ] `lib/motion/feedback_kind.dart` exists with sealed `FeedbackKind` + 7 subtypes
- [ ] `lib/motion/feedback_service.dart` exists with `FeedbackService` and Riverpod provider
- [ ] 6 audio assets in `assets/audio/`, registered in `pubspec.yaml`
- [ ] `FeedbackService.init()` called in `main()` before `runApp()`
- [ ] All 14 integration points wired per the mapping table
- [ ] `flutter analyze` returns 0 errors / 0 warnings
- [ ] `flutter test test/motion/feedback_service_test.dart` passes
- [ ] Manual QA passes on at least one iOS + one Android device
- [ ] No `dynamic`, no `as` casts, no `!` operator in new code
- [ ] Switch on `FeedbackKind` is exhaustive (compiler enforces — sealed class)
- [ ] APK size increase < 200 KB (audio files alone)

---

## Strict Dart Conventions Reminder

- No `dynamic` anywhere
- No `as` casts outside generated files
- Sealed classes for all unions (`FeedbackKind`)
- No `!` operator without guarantee
- No `??` fallbacks for default values
- `const` everywhere it compiles
- Anchor comments at top of public service / sealed hierarchy
