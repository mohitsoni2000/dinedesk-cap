# DineDesk Cap — Advanced UX Features Design
**Date:** 2026-06-07  
**Scope:** 6 high-impact features for the Flutter waiter app  
**Approach:** All 6 in one implementation session (Approach A)

---

## Overview

Six independent improvements that collectively make DineDesk Cap faster, more tactile, and more intelligent for waiters on the restaurant floor. Features are grouped by layer but implemented together.

---

## Feature 1: Haptic Language

### Goal
Centralize all vibration feedback into a single `HapticService` so every action in the app has a consistent, meaningful haptic signature. Makes the app feel alive and premium.

### New File
`lib/services/haptic_service.dart`

### API

```dart
class HapticService {
  // Reads hapticEnabled from SharedPreferences before firing.
  static Future<void> addToCart() async        // lightImpact
  static Future<void> swipeConfirm() async     // mediumImpact
  static Future<void> longPressActivate() async // mediumImpact
  static Future<void> sendKot() async          // heavyImpact
  static Future<void> paymentSuccess() async   // heavy + 120ms + heavy (double pulse)
  static Future<void> error() async            // vibrate()
  static Future<void> navigate() async         // selectionClick
  static Future<void> dragTick() async         // selectionClick (fires at swipe thresholds)
}
```

### Constraint
All methods check `SharedPreferences.getBool('setting_haptic') ?? true` before calling `HapticFeedback`. If disabled, they are no-ops. This respects the setting already implemented in `settings_screen.dart`.

### Migration
Replace all ad-hoc `HapticFeedback.*` calls across the codebase with `HapticService.*` equivalents. Existing calls are in: `item_detail_sheet.dart`, `order_builder_screen.dart`, `send_kot_button.dart`, `order_review_screen.dart`.

---

## Feature 2: Swipe-to-Add

### Goal
Swipe right on any menu item card → add 1 qty instantly. Fastest possible item entry — zero taps.

### Implementation

New widget: `_SwipeToAddWrapper` — wraps each menu item card in `order_builder_screen.dart`.

**Gesture mechanics:**
- `GestureDetector` with `onHorizontalDragUpdate` + `onHorizontalDragEnd`
- Track horizontal offset in local state (`_dragOffset`)
- Clamp drag to max 80px (card width × 0.4 ≈ threshold)
- Threshold: 40% of card width (≈ 80px on standard screen)

**Visual feedback:**
- Behind the card: `AppColors.success` background with `Icons.add` icon
- Card slides right revealing the green layer as drag progresses
- At threshold crossing → `HapticService.dragTick()` fires
- Release past threshold → `HapticService.swipeConfirm()` + add item + spring-back animation
- Release before threshold → rubber-band back, nothing added

**Spring-back animation:**
- `AnimationController` with `duration: AppMotion.fast (180ms)`
- Curve: `AppMotion.entrance` (easeOutCubic)
- Card snaps back to 0 offset after add or release

**Edge cases:**
- Item has `variations` → swipe opens `ItemDetailSheet` instead of direct add (cannot assume default variation)
- Item has required option groups (`group.isRequired || group.minSelect > 0`) → same, open sheet
- `_readOnly` mode → swipe gesture disabled, no feedback
- Item already at cart max qty (if applicable) → no add, show brief error haptic

### Files Changed
- `lib/screens/order_builder_screen.dart` — add `_SwipeToAddWrapper`, wire into item list builder

---

## Feature 3: Long-press Quick Menu

### Goal
Long-press any menu item → compact action sheet appears. Fewer taps for power users. Replaces the need to open full `ItemDetailSheet` for simple actions.

### Menu item long-press (in order builder)

Triggers `HapticService.longPressActivate()` then shows a compact bottom sheet (140px, `mainAxisSize: MainAxisSize.min`):

```
┌─────────────────────────────────────────┐
│  Chicken 65  ·  ₹220                   │
│  ─────────────────────────────────────  │
│  [+ Add]    [View Details]    [+ Note]  │
└─────────────────────────────────────────┘
```

- **Add** (`Icons.add`): Direct add if no required variations/options, else opens sheet
- **View Details** (`Icons.info_outline`): Opens `ItemDetailSheet`
- **Add with Note** (`Icons.edit_note`): Opens `ItemDetailSheet(item: item, autoFocusNote: true)` — `ItemDetailSheet` needs a new optional `bool autoFocusNote = false` parameter that calls `FocusScope.of(context).requestFocus(_noteFocusNode)` in `initState`

### Cart item long-press (in order review)

Long-press on a cart line in `order_review_screen.dart`:

```
┌─────────────────────────────────────────┐
│  Butter Naan  ×2  ·  ₹120              │
│  ─────────────────────────────────────  │
│  [+1]   [−1]   [Edit Note]   [Remove]  │
└─────────────────────────────────────────┘
```

- **+1**: Increment qty in `cartProvider`
- **−1**: Decrement qty (removes line if qty reaches 0)
- **Edit Note**: Opens note editing dialog
- **Remove**: Removes entire cart line (with `HapticService.error()` on removal)

### Files Changed
- `lib/screens/order_builder_screen.dart` — long-press on menu item cards
- `lib/screens/order_review_screen.dart` — long-press on cart line cards

---

## Feature 4: Table Timer

### Goal
Show time elapsed since a table was occupied on the floor plan. Color-coded to help waiters spot forgotten or slow tables.

### Data Model

Add field to `RestaurantTable` (in `lib/data/providers.dart`):
```dart
final DateTime? occupiedSince;
```

### Population Strategy (client-side, no server changes required)

- `sync_service.dart`: when a table transitions to `TableState.mine` and `occupiedSince` is null → stamp `DateTime.now()` and persist to `SharedPreferences` keyed `table_timer_<serverId>`
- When table transitions away from `mine` (to `free`, `dirty`, `other`) → clear the stamp from SharedPreferences and set `occupiedSince = null`
- On app restart → during `applyInitialSync()`, load persisted timestamps from SharedPreferences for all tables currently in `mine` state

### Display

On each table card in `tables_screen.dart`, bottom-right corner chip (only shown when `state == TableState.mine && occupiedSince != null`):

| Elapsed | Color | Example |
|---|---|---|
| < 30 min | `AppColors.success` | `14m` |
| 30–60 min | `AppColors.amber` | `47m` |
| > 60 min | `AppColors.danger` | `1h 12m` |

### Timer Updates

`TablesScreen` uses a `StreamBuilder<int>` over `Stream.periodic(const Duration(minutes: 1)).map((_) => 0)`. This triggers a rebuild of only the timer chips every minute. No new provider — display-only refresh. The stream is created inline in `build()` so no `dispose()` cleanup needed.

### Files Changed
- `lib/data/providers.dart` — `RestaurantTable.occupiedSince` field + `copyWith`
- `lib/services/sync_service.dart` — stamp/clear logic + SharedPreferences persistence
- `lib/screens/tables_screen.dart` — timer chip display + periodic stream

---

## Feature 5: Riverpod `select()` Optimization

### Goal
Replace broad `ref.watch(provider)` calls with `ref.watch(provider.select(...))` so only the widgets that actually depend on changed data rebuild. Zero behavior change — pure performance.

### Optimization Sites

| File | Widget | Before | After |
|---|---|---|---|
| `tables_screen.dart` | Floor grid | `ref.watch(tablesProvider)` → rebuilds all cards | Each `_TableCard` watches `tablesProvider.select((t) => t.firstWhere(...))` |
| `order_builder_screen.dart` | Cart button label | `ref.watch(cartProvider)` (full) | `.select((c) => (c.length, c.totalPrice))` — tuple |
| `order_builder_screen.dart` | Cart count badge | Same full watch | `.select((c) => c.length)` |
| `order_builder_screen.dart` | Notes row | `ref.watch(orderNotesProvider)` (acceptable, string) | Already minimal — no change |
| `order_review_screen.dart` | Subtotal row | `ref.watch(cartProvider)` (full) | `.select((c) => c.subtotal)` |
| `root_shell.dart` | Connection banner | `ref.watch(connectionProvider)` | `.select((c) => (c.online, c.label))` |

### Key Pattern

For `_TableCard`, extract it as a `ConsumerWidget` (or use `Consumer` inline) so each card has its own `ref` scope and only rebuilds when its specific table data changes:

```dart
// Before: one watch rebuilds 20 cards
final tables = ref.watch(tablesProvider);

// After: each card widget watches only its own slice
// Use firstWhereOrNull (from collection package) to avoid StateError if table removed mid-session
final table = ref.watch(
  tablesProvider.select((list) => list.firstWhereOrNull((t) => t.serverId == widget.serverId)),
);
// Guard: if table == null, return const SizedBox.shrink()
```

### Files Changed
- `lib/screens/tables_screen.dart`
- `lib/screens/order_builder_screen.dart`
- `lib/screens/order_review_screen.dart`
- `lib/widgets/root_shell.dart`

---

## Feature 6: Optimistic UI (KOT Send)

### Goal
KOT send feels instant — waiter sees success immediately, not after socket round-trip. Failed sends stay visible with a ⚠️ badge and a retry banner.

### Scope
KOT send only. Order creation stays synchronous (one-time action, lag acceptable).

### Data Model

Add to `CartLine` (in `lib/data/providers.dart`):
```dart
enum SyncStatus { synced, pending, failed }

// In CartLine:
final SyncStatus syncStatus;
```

Default is `SyncStatus.synced` for normal cart adds. Only items going through optimistic KOT send get `pending`/`failed`.

### KOT Send Flow

**In `send_kot_button.dart` (or wherever KOT send is triggered):**

1. Snapshot current cart lines
2. Mark snapshot lines as `SyncStatus.pending` in `cartProvider`
3. Show success animation immediately (navigate / clear UI)
4. Fire `socket.emitAck('kot:send', {...})` in background
5. On ack `kind == 'success'` → mark lines `SyncStatus.synced`
6. On ack failure / timeout → mark lines `SyncStatus.failed`

### Failed State UI

In `order_review_screen.dart`:

- Cart lines with `SyncStatus.failed` → amber ⚠️ icon badge on the right side of the cart line
- Sticky amber banner at top of review screen: *"Sync failed — tap to retry"*
- Tap banner → re-fires socket for `.failed` lines only
- On retry success → clears failed status, banner disappears

Lines with `SyncStatus.pending` show a subtle loading spinner badge instead of ⚠️.

### Timeout
If no ack received within 8 seconds → treat as failed (mark `SyncStatus.failed`).

### Files Changed
- `lib/data/providers.dart` — `SyncStatus` enum + `CartLine.syncStatus` field
- `lib/widgets/send_kot_button.dart` — optimistic send logic + timeout
- `lib/screens/order_review_screen.dart` — ⚠️ badges + retry banner

---

## Implementation Order

Within the single session, implement in this order to avoid conflicts:

1. `HapticService` (foundation — all other features reference it)
2. `CartLine.syncStatus` + `SyncStatus` enum (data model — needed by optimistic UI)
3. `RestaurantTable.occupiedSince` (data model — needed by timer)
4. Riverpod `select()` pass (no behavior change, safe to do early)
5. Table timer (display + sync_service stamping)
6. Swipe-to-add (new widget in order builder)
7. Long-press quick menu (order builder + review)
8. Optimistic UI KOT send (ties together model + haptics + UI)

---

## Non-Goals (Explicit Out-of-Scope)

- Dark mode (separate spec exists)
- Offline queue for failed orders (separate, complex)
- AI upsell suggestions (needs server-side data)
- Seat-level split billing (separate feature)
- Tablet two-panel layout (separate spec)

---

## Files Modified Summary

| File | Type | Reason |
|---|---|---|
| `lib/services/haptic_service.dart` | New | Centralized haptic language |
| `lib/data/providers.dart` | Modified | `SyncStatus` enum, `CartLine.syncStatus`, `RestaurantTable.occupiedSince` |
| `lib/services/sync_service.dart` | Modified | Table timer stamp/clear + SharedPreferences |
| `lib/screens/tables_screen.dart` | Modified | Timer chip + `select()` + periodic stream |
| `lib/screens/order_builder_screen.dart` | Modified | Swipe-to-add, long-press, haptic calls, `select()` |
| `lib/screens/order_review_screen.dart` | Modified | ⚠️ badges, retry banner, long-press cart, `select()` |
| `lib/widgets/send_kot_button.dart` | Modified | Optimistic send + timeout |
| `lib/widgets/root_shell.dart` | Modified | `select()` on connection |
| `lib/widgets/item_detail_sheet.dart` | Modified | `autoFocusNote` param + `_noteFocusNode` |
