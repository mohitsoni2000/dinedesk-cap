# Advanced UX Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 6 high-impact features to dinedesk-cap — swipe-to-add, optimistic KOT UI, table timer, Riverpod select() optimization, long-press quick menu, and haptic language — making the waiter app faster and more tactile.

**Architecture:** All 6 features are independent and implemented in one session. The existing `FeedbackService` + `FeedbackKind` system (in `lib/motion/`) is the haptic foundation — extended, not replaced. `CartLine` gets a `SyncStatus` field for optimistic KOT tracking. `RestaurantTable` gets `occupiedSince` for the timer.

**Tech Stack:** Flutter 3.24+, Riverpod 2.5, `shared_preferences`, `flutter/services.dart` (HapticFeedback), existing `FeedbackService`/`FeedbackKind` sealed classes.

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `lib/data/providers.dart` | Modify | Add `SyncStatus` enum, `CartLine.syncStatus`, `RestaurantTable.occupiedSince`, `hapticEnabledProvider` |
| `lib/motion/feedback_kind.dart` | Modify | Add `FeedbackDragTick` sealed class |
| `lib/motion/feedback_service.dart` | Modify | Accept `Ref`, gate haptics behind `hapticEnabledProvider` |
| `lib/screens/settings_screen.dart` | Modify | `_SettingsNotifier.setHapticEnabled` updates `hapticEnabledProvider` |
| `lib/services/sync_service.dart` | Modify | Stamp/clear `occupiedSince` via SharedPreferences when table enters/leaves `mine` state |
| `lib/screens/tables_screen.dart` | Modify | Add `StreamBuilder` for 1-min timer tick, timer chip on `_TableCard`, `select()` per card |
| `lib/screens/order_builder_screen.dart` | Modify | Add `_SwipeToAddWrapper`, long-press on `_ItemRow`, haptic calls |
| `lib/screens/order_review_screen.dart` | Modify | ⚠️ badge + retry banner for failed KOT lines, long-press on cart lines |
| `lib/widgets/send_kot_button.dart` | Modify | Optimistic send: mark lines pending, fire in background, handle timeout |
| `lib/widgets/item_detail_sheet.dart` | Modify | Add `autoFocusNote` param + `_noteFocusNode` |
| `lib/widgets/quick_action_tile.dart` | **New** | Shared `_QuickActionTile` widget used by both order builder and review screens |
| `lib/widgets/root_shell.dart` | Modify | `select()` on `connectionProvider` |

---

## Task 1: Data Model Additions

**Files:**
- Modify: `lib/data/providers.dart`

- [ ] **Step 1: Add `hapticEnabledProvider` to providers.dart**

  Open `lib/data/providers.dart`. Find the `// ─────────────── Auth ───────────────` section near the bottom. Add this block directly above it:

  ```dart
  // Haptic enabled flag — mirrors SharedPreferences 'setting_haptic'.
  // Updated by _SettingsNotifier in settings_screen.dart on every toggle.
  final hapticEnabledProvider = StateProvider<bool>((_) => true);
  ```

- [ ] **Step 2: Add `SyncStatus` enum to providers.dart**

  Find the line `enum OrderStatus { sent, modified, cancelled, paid }` (near top of providers.dart, around line 16). Add immediately after it:

  ```dart
  // Tracks optimistic sync state for cart lines during KOT send.
  enum SyncStatus { synced, pending, failed }
  ```

- [ ] **Step 3: Add `syncStatus` field to `CartLine`**

  Find the `CartLine` class. Add the field after `final String? variationName;`:

  ```dart
  final SyncStatus syncStatus;
  ```

  Update the default constructor to include it with default `SyncStatus.synced`:

  ```dart
  CartLine({
    required this.item,
    required this.qty,
    this.mods = const [],
    this.selectedOptions = const [],
    this.modsExtra = 0,
    this.itemNote = '',
    this.variationId,
    this.variationName,
    this.syncStatus = SyncStatus.synced,  // ← add this
  }) : uid = _nextUid++;
  ```

  Update `CartLine._clone` constructor:

  ```dart
  CartLine._clone({
    required this.uid,
    required this.item,
    required this.qty,
    required this.mods,
    required this.selectedOptions,
    required this.modsExtra,
    required this.itemNote,
    this.variationId,
    this.variationName,
    this.syncStatus = SyncStatus.synced,  // ← add this
  });
  ```

  Update `CartLine.copyWith` to include `syncStatus`:

  ```dart
  CartLine copyWith({
    int? qty,
    List<String>? mods,
    List<SelectedOption>? selectedOptions,
    double? modsExtra,
    String? itemNote,
    String? variationId,
    String? variationName,
    SyncStatus? syncStatus,  // ← add this
  }) =>
      CartLine._clone(
        uid: uid,
        item: item,
        qty: qty ?? this.qty,
        mods: mods ?? this.mods,
        selectedOptions: selectedOptions ?? this.selectedOptions,
        modsExtra: modsExtra ?? this.modsExtra,
        itemNote: itemNote ?? this.itemNote,
        variationId: variationId ?? this.variationId,
        variationName: variationName ?? this.variationName,
        syncStatus: syncStatus ?? this.syncStatus,  // ← add this
      );
  ```

- [ ] **Step 4: Add `occupiedSince` to `RestaurantTable`**

  Find `RestaurantTable`. Add the field after `final int kotCount;`:

  ```dart
  final DateTime? occupiedSince;
  ```

  Add to the `const RestaurantTable({...})` constructor (after `this.kotCount = 0,`):

  ```dart
  this.occupiedSince,
  ```

  Add `occupiedSince` to the `copyWith` method. First add the parameter (after `int? kotCount,`):

  ```dart
  Object? occupiedSince = _absent,
  ```

  Then add to the returned `RestaurantTable(...)` call (after `kotCount: kotCount ?? this.kotCount,`):

  ```dart
  occupiedSince: occupiedSince == _absent
      ? this.occupiedSince
      : occupiedSince as DateTime?,
  ```

- [ ] **Step 5: Add `setSyncStatus` method to `CartNotifier`**

  Find `CartNotifier`. Add after the `clear()` method:

  ```dart
  void setSyncStatusAll(SyncStatus status) {
    state = [for (final l in state) l.copyWith(syncStatus: status)];
  }

  void setSyncStatusFailed() {
    state = [
      for (final l in state)
        if (l.syncStatus == SyncStatus.pending)
          l.copyWith(syncStatus: SyncStatus.failed)
        else
          l,
    ];
  }

  void retryFailed() {
    state = [
      for (final l in state)
        if (l.syncStatus == SyncStatus.failed)
          l.copyWith(syncStatus: SyncStatus.pending)
        else
          l,
    ];
  }
  ```

- [ ] **Step 6: Verify compile**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  flutter analyze lib/data/providers.dart 2>&1 | grep -E "error|warning"
  ```

  Expected: no output (clean).

- [ ] **Step 7: Commit**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  git add lib/data/providers.dart
  git commit -m "feat: add SyncStatus, CartLine.syncStatus, RestaurantTable.occupiedSince, hapticEnabledProvider"
  ```

---

## Task 2: Extend FeedbackService — Haptic Gate + DragTick

**Files:**
- Modify: `lib/motion/feedback_kind.dart`
- Modify: `lib/motion/feedback_service.dart`
- Modify: `lib/screens/settings_screen.dart`

- [ ] **Step 1: Add `FeedbackDragTick` to feedback_kind.dart**

  Open `lib/motion/feedback_kind.dart`. After `final class FeedbackSelection`:

  ```dart
  final class FeedbackDragTick extends FeedbackKind {
    const FeedbackDragTick();
  }
  ```

  In the `triggerHaptic()` extension method, add a case before the closing brace:

  ```dart
  case FeedbackDragTick():
    await HapticFeedback.selectionClick();
  ```

- [ ] **Step 2: Give FeedbackService a Ref and haptic gate**

  Open `lib/motion/feedback_service.dart`. Change `FeedbackService` to accept a `Ref`:

  ```dart
  import 'package:flutter_riverpod/flutter_riverpod.dart';
  import '../data/providers.dart';
  ```

  Change the class definition and constructor:

  ```dart
  class FeedbackService {
    FeedbackService(this._ref);

    final Ref _ref;
    // ... rest of fields unchanged
  ```

  In the `fire()` method, add the haptic gate at the top:

  ```dart
  void fire(FeedbackKind kind) {
    if (!_initialized) return;
    final hapticOn = _ref.read(hapticEnabledProvider);
    if (hapticOn) unawaited(kind.triggerHaptic());
    // audio portion unchanged below
    final String? asset = kind.audioAsset;
    if (asset != null) {
      final AudioPlayer player = _pool[_nextPlayer];
      _nextPlayer = (_nextPlayer + 1) % _poolSize;
      unawaited(_playAsset(player, asset));
    }
  }
  ```

  Update `feedbackServiceProvider` to pass the ref:

  ```dart
  final Provider<FeedbackService> feedbackServiceProvider =
      Provider<FeedbackService>((Ref ref) {
    final service = FeedbackService(ref);
    ref.onDispose(() => service.dispose());
    return service;
  });
  ```

- [ ] **Step 3: Wire settings toggle to hapticEnabledProvider**

  Open `lib/screens/settings_screen.dart`. In `_SettingsNotifier.setHapticEnabled(bool v)`, add the provider update.

  The `_SettingsNotifier` constructor takes no ref. Change it to take a `Ref`:

  ```dart
  class _SettingsNotifier extends StateNotifier<_SettingsState> {
    _SettingsNotifier(this._ref) : super(const _SettingsState()) {
      _load();
    }

    final Ref _ref;
  ```

  In `setHapticEnabled(bool v)`, after `await prefs.setBool('setting_haptic', v);` add:

  ```dart
  _ref.read(hapticEnabledProvider.notifier).state = v;
  ```

  In `_load()`, after setting `state = _SettingsState(...)`, add:

  ```dart
  _ref.read(hapticEnabledProvider.notifier).state =
      prefs.getBool('setting_haptic') ?? true;
  ```

  Update `_settingsProvider` to pass ref:

  ```dart
  final _settingsProvider =
      StateNotifierProvider<_SettingsNotifier, _SettingsState>(
    (ref) => _SettingsNotifier(ref),
  );
  ```

  Add the import for providers at the top of settings_screen.dart:

  ```dart
  import '../data/providers.dart';
  ```

- [ ] **Step 4: Verify compile**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  flutter analyze lib/motion/ lib/screens/settings_screen.dart 2>&1 | grep -E "error|warning"
  ```

  Expected: no output.

- [ ] **Step 5: Commit**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  git add lib/motion/feedback_kind.dart lib/motion/feedback_service.dart lib/screens/settings_screen.dart
  git commit -m "feat: extend FeedbackService with haptic gate + FeedbackDragTick"
  ```

---

## Task 3: Table Timer

**Files:**
- Modify: `lib/services/sync_service.dart`
- Modify: `lib/screens/tables_screen.dart`

- [ ] **Step 1: Add SharedPreferences import to sync_service.dart if missing**

  Open `lib/services/sync_service.dart`. Check for `shared_preferences` import. If absent, add:

  ```dart
  import 'package:shared_preferences/shared_preferences.dart';
  ```

- [ ] **Step 2: Add `_stampTableTimer` and `_clearTableTimer` helpers to SyncService**

  Find `class SyncService`. Add these two private methods inside the class (near other private helpers):

  ```dart
  static const _timerKeyPrefix = 'table_timer_';

  Future<void> _stampTableTimer(String serverId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_timerKeyPrefix$serverId';
    if (prefs.containsKey(key)) return; // already stamped — preserve original
    await prefs.setString(key, DateTime.now().toIso8601String());
  }

  Future<void> _clearTableTimer(String serverId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_timerKeyPrefix$serverId');
  }

  Future<DateTime?> _loadTableTimer(String serverId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_timerKeyPrefix$serverId');
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }
  ```

- [ ] **Step 3: Call stamp/clear fire-and-forget in `_serverTableToLocal`**

  Find the `_serverTableToLocal` method. After computing `localState`, add stamp/clear calls as fire-and-forget (do NOT await — keeping the method synchronous):

  ```dart
  // Stamp timer when table becomes ours; clear when it leaves.
  if (localState == TableState.mine) {
    _stampTableTimer(serverId); // unawaited — keeps method synchronous
  } else {
    _clearTableTimer(serverId); // unawaited
  }
  ```

  The `RestaurantTable` is constructed with `occupiedSince: null` (sync_service stays fully synchronous). The screen loads timer data separately in `initState`.

- [ ] **Step 3b: Load timers in `_TablesScreenState.initState`**

  Open `lib/screens/tables_screen.dart`. Add `_timerMap` local state to `_TablesScreenState`:

  ```dart
  Map<String, DateTime> _timerMap = {};

  @override
  void initState() {
    super.initState();
    _loadTimers();
  }

  Future<void> _loadTimers() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, DateTime>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith('table_timer_')) continue;
      final serverId = key.replaceFirst('table_timer_', '');
      final raw = prefs.getString(key);
      if (raw != null) {
        final dt = DateTime.tryParse(raw);
        if (dt != null) map[serverId] = dt;
      }
    }
    if (mounted) setState(() => _timerMap = map);
  }
  ```

  Add the SharedPreferences import at the top of tables_screen.dart:

  ```dart
  import 'package:shared_preferences/shared_preferences.dart';
  ```

  In the `GridView.builder`, pass `_timerMap[t.serverId]` to `_TableCard`:

  ```dart
  _TableCard(
    table: t,
    occupiedSince: _timerMap[t.serverId],  // ← add
    isLoading: _openingTable && _openingTableId == t.serverId,
    onTap: () => _onTableTap(t),
    onLongPress: ...,
  );
  ```

  Update `_TableCard` to accept `occupiedSince: DateTime?` as a parameter instead of reading from `table.occupiedSince`:

  ```dart
  class _TableCard extends ConsumerWidget {
    final RestaurantTable table;
    final DateTime? occupiedSince;  // ← add
    final bool isLoading;
    final VoidCallback onTap;
    final VoidCallback? onLongPress;
    const _TableCard({
      required this.table,
      this.occupiedSince,  // ← add
      required this.isLoading,
      required this.onTap,
      this.onLongPress,
    });
  ```

  In `_TableCard.build()`, use `occupiedSince` (the parameter) instead of `table.occupiedSince` in the timer chip logic.

- [ ] **Step 4: Add timer chip to `_TableCard` in tables_screen.dart**

  Open `lib/screens/tables_screen.dart`. Find `class _TableCard extends ConsumerWidget`.

  Add a helper method inside `_TableCard`:

  ```dart
  String? _timerLabel(DateTime? since) {
    if (since == null) return null;
    final mins = DateTime.now().difference(since).inMinutes;
    if (mins < 60) return '${mins}m';
    final h = mins ~/ 60;
    final m = mins % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  Color _timerColor(DateTime since) {
    final mins = DateTime.now().difference(since).inMinutes;
    if (mins < 30) return AppColors.success;
    if (mins < 60) return AppColors.amber;
    return AppColors.danger;
  }
  ```

  In `_TableCard.build()`, find where the table's content is rendered. Wrap the existing `Container` in a `Stack` and add the timer chip as a `Positioned` in the bottom-right corner:

  ```dart
  // Wrap existing Container in Stack:
  return GestureDetector(
    onTap: isLoading ? null : onTap,
    onLongPress: onLongPress,
    child: Hero(
      tag: HeroTags.tableCard(table.serverId),
      // ... existing flightShuttleBuilder ...
      child: Stack(
        children: [
          // Existing Container (full card) — no changes
          Container(
            // ... existing decoration and child unchanged ...
          ),
          // Timer chip — bottom right, only for mine tables
          if (table.state == TableState.mine && table.occupiedSince != null)
            Positioned(
              bottom: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: _timerColor(table.occupiedSince!).withValues(alpha: 0.15),
                  borderRadius: const BorderRadius.all(AppRadii.xs),
                  border: Border.all(
                    color: _timerColor(table.occupiedSince!).withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  _timerLabel(table.occupiedSince) ?? '',
                  style: AppTypography.micro.copyWith(
                    color: _timerColor(table.occupiedSince!),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
  ```

- [ ] **Step 5: Add StreamBuilder for per-minute timer tick in TablesScreen**

  In `_TablesScreenState.build()`, wrap the `GridView.builder` (or the entire `Expanded` child) in a `StreamBuilder`:

  ```dart
  Expanded(
    child: StreamBuilder<int>(
      stream: Stream.periodic(const Duration(minutes: 1), (i) => i),
      builder: (context, _) {
        // existing filtered.isEmpty check + GridView.builder exactly as before
        return filtered.isEmpty
            ? const Center(/* existing empty state */)
            : GridView.builder(/* existing — no changes inside */);
      },
    ),
  ),
  ```

  The stream triggers a rebuild every minute, which updates timer chip colors and labels.

- [ ] **Step 6: Verify compile**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  flutter analyze lib/services/sync_service.dart lib/screens/tables_screen.dart 2>&1 | grep -E "error|warning"
  ```

  Expected: no output.

- [ ] **Step 7: Commit**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  git add lib/services/sync_service.dart lib/screens/tables_screen.dart
  git commit -m "feat: add table timer — stamp occupiedSince on mine tables, color-coded chip on floor plan"
  ```

---

## Task 4: Riverpod `select()` Optimization

**Files:**
- Modify: `lib/screens/tables_screen.dart`
- Modify: `lib/screens/order_builder_screen.dart`
- Modify: `lib/screens/order_review_screen.dart`
- Modify: `lib/widgets/root_shell.dart`

- [ ] **Step 1: `_TableCard` — per-card select**

  `_TableCard` is already a `ConsumerWidget` that receives a `table` from its parent. The parent (grid `itemBuilder`) passes the already-filtered table directly. This is already optimal — no change needed here since each card instance only holds its own `RestaurantTable` value and doesn't watch `tablesProvider` itself.

  However, **the `linkGroupsProvider` watch inside `_TableCard.build()`** rebuilds every card when any group changes. Change it to select only whether this specific table is linked:

  ```dart
  // Before:
  final linkGroups = ref.watch(linkGroupsProvider);
  final isLinked = linkGroups.values.any((ids) => ids.contains(table.serverId));

  // After:
  final isLinked = ref.watch(
    linkGroupsProvider.select(
      (groups) => groups.values.any((ids) => ids.contains(table.serverId)),
    ),
  );
  ```

- [ ] **Step 2: `order_builder_screen.dart` — cart total and count**

  Find where `ref.watch(cartProvider)` is used and the total/count are derived. The screen has a large `build()` that does `final cart = ref.watch(cartProvider)` at the top — this is fine for the cart list itself (used in multiple places). 

  However, in the bottom cart button, the `cart.length` and cart total are used. Add targeted selectors for the two specific values used in the button's `Text` widget, so the button rebuilds only when these change rather than on every cart modification:

  In the cart button `Builder` or directly inside the `GestureDetector` child, extract with:

  ```dart
  // Wrap the cart bottom bar in a Builder with targeted selects:
  Builder(builder: (context) {
    final cartLen = ref.watch(cartProvider.select((c) => c.length));
    final cartTotal = ref.watch(cartProvider.select(
      (c) => c.fold(0.0, (s, l) => s + l.lineTotal),
    ));
    // use cartLen and cartTotal in the button text and KineticRupeeCounter
  }),
  ```

  Note: the main `cart` watch at the top of build is still needed for the cart list display — leave it. Only the bottom button benefits from the targeted select.

- [ ] **Step 3: `order_review_screen.dart` — subtotal**

  Find where `ref.watch(cartProvider)` feeds the subtotal row. Add a `select()` for just the subtotal value used in the totals summary:

  ```dart
  // In the totals section:
  final subtotal = ref.watch(
    cartProvider.select((c) => c.fold(0.0, (s, l) => s + l.lineTotal)),
  );
  ```

- [ ] **Step 4: `root_shell.dart` — connection label**

  Find `ref.watch(connectionProvider)` in `root_shell.dart`. Change any uses that only need `label` or `online` to:

  ```dart
  final connLabel = ref.watch(connectionProvider.select((c) => c.label));
  final connOnline = ref.watch(connectionProvider.select((c) => c.online));
  ```

- [ ] **Step 5: Verify compile**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  flutter analyze lib/screens/order_builder_screen.dart lib/screens/order_review_screen.dart lib/screens/tables_screen.dart lib/widgets/root_shell.dart 2>&1 | grep -E "error|warning"
  ```

  Expected: no output.

- [ ] **Step 6: Commit**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  git add lib/screens/order_builder_screen.dart lib/screens/order_review_screen.dart lib/screens/tables_screen.dart lib/widgets/root_shell.dart
  git commit -m "perf: riverpod select() optimization — granular rebuilds in tables, builder, review, root_shell"
  ```

---

## Task 5: Swipe-to-Add

**Files:**
- Modify: `lib/screens/order_builder_screen.dart`

- [ ] **Step 1: Add `_needsSheet` helper to order_builder_screen.dart**

  In `order_builder_screen.dart`, add this helper function (as a top-level function or static method before `_ItemRow`):

  ```dart
  bool _itemNeedsSheet(MenuItem item) {
    return item.variations.isNotEmpty ||
        item.optionGroups.any((g) => g.isRequired || g.minSelect > 0);
  }
  ```

- [ ] **Step 2: Add `_SwipeToAddWrapper` widget**

  Add this class at the bottom of `order_builder_screen.dart`, before or after `_ItemRow`:

  **Note:** `_SwipeToAddWrapper` must NOT call `HapticFeedback` directly — that bypasses the haptic gate in `FeedbackService`. Instead, accept `onDragTick` and `onSwipeConfirm` callbacks from the parent (which has ref access).

  ```dart
  class _SwipeToAddWrapper extends StatefulWidget {
    final MenuItem item;
    final bool readOnly;
    final Widget child;
    final VoidCallback onAdd;
    final VoidCallback onOpenSheet;
    final VoidCallback onDragTick;      // ← parent fires feedbackService.FeedbackDragTick
    final VoidCallback onSwipeConfirm;  // ← parent fires feedbackService.FeedbackMedium

    const _SwipeToAddWrapper({
      required this.item,
      required this.readOnly,
      required this.child,
      required this.onAdd,
      required this.onOpenSheet,
      required this.onDragTick,
      required this.onSwipeConfirm,
    });

    @override
    State<_SwipeToAddWrapper> createState() => _SwipeToAddWrapperState();
  }

  class _SwipeToAddWrapperState extends State<_SwipeToAddWrapper>
      with SingleTickerProviderStateMixin {
    double _dragOffset = 0;
    bool _thresholdCrossed = false;
    late AnimationController _snapBack;
    late Animation<double> _snapAnimation;

    static const _maxDrag = 80.0;
    static const _threshold = 0.40; // 40% of maxDrag

    @override
    void initState() {
      super.initState();
      _snapBack = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 220),
      );
      _snapAnimation = Tween<double>(begin: 0, end: 0).animate(
        CurvedAnimation(parent: _snapBack, curve: Curves.easeOutCubic),
      )..addListener(() => setState(() => _dragOffset = _snapAnimation.value));
    }

    @override
    void dispose() {
      _snapBack.dispose();
      super.dispose();
    }

    void _onDragUpdate(DragUpdateDetails d) {
      if (widget.readOnly) return;
      setState(() {
        _dragOffset = (_dragOffset + d.delta.dx).clamp(0, _maxDrag);
      });
      final crossed = _dragOffset >= _maxDrag * _threshold;
      if (crossed && !_thresholdCrossed) {
        _thresholdCrossed = true;
        widget.onDragTick(); // fires feedbackService.fire(FeedbackDragTick()) in parent
      } else if (!crossed && _thresholdCrossed) {
        _thresholdCrossed = false;
      }
    }

    void _onDragEnd(DragEndDetails _) {
      if (_thresholdCrossed) {
        if (_itemNeedsSheet(widget.item)) {
          widget.onOpenSheet();
        } else {
          widget.onSwipeConfirm(); // fires feedbackService.fire(FeedbackMedium()) in parent
          widget.onAdd();
        }
      }
      _thresholdCrossed = false;
      _snapAnimation = Tween<double>(begin: _dragOffset, end: 0).animate(
        CurvedAnimation(parent: _snapBack, curve: Curves.easeOutCubic),
      )..addListener(() => setState(() => _dragOffset = _snapAnimation.value));
      _snapBack
        ..reset()
        ..forward();
    }

    @override
    Widget build(BuildContext context) {
      return GestureDetector(
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        child: Stack(
          children: [
            // Green reveal layer — visible behind the sliding card
            Positioned.fill(
              child: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 20),
                decoration: const BoxDecoration(
                  color: AppColors.success,
                  borderRadius: BorderRadius.all(AppRadii.sm),
                ),
                child: Opacity(
                  opacity: (_dragOffset / _maxDrag).clamp(0, 1),
                  child: const Icon(Icons.add, color: Colors.white, size: 22),
                ),
              ),
            ),
            // Card slides right
            Transform.translate(
              offset: Offset(_dragOffset, 0),
              child: widget.child,
            ),
          ],
        ),
      );
    }
  }
  ```

- [ ] **Step 3: Wrap `_ItemRow` with `_SwipeToAddWrapper` in the menu list**

  In the menu `ListView` builder (inside the `for (final entry in sections.entries)` loop), find where `_ItemRow` is used:

  ```dart
  _ItemRow(
    item: entry.value[i],
    onAdd: () { ... },
    onTap: () => ItemDetailSheet.show(context, entry.value[i]),
  ),
  ```

  Wrap it:

  ```dart
  _SwipeToAddWrapper(
    item: entry.value[i],
    readOnly: _readOnly,
    onAdd: () {
      ref.read(feedbackServiceProvider).fire(const FeedbackLight());
      ref.read(cartProvider.notifier).add(entry.value[i]);
      ref.read(recentItemsProvider.notifier).track(entry.value[i]);
    },
    onOpenSheet: () => ItemDetailSheet.show(context, entry.value[i]),
    child: _ItemRow(
      item: entry.value[i],
      onAdd: () {
        ref.read(feedbackServiceProvider).fire(const FeedbackLight());
        ref.read(cartProvider.notifier).add(entry.value[i]);
        ref.read(recentItemsProvider.notifier).track(entry.value[i]);
      },
      onTap: () => ItemDetailSheet.show(context, entry.value[i]),
    ),
  ),
  ```

- [ ] **Step 4: Verify compile**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  flutter analyze lib/screens/order_builder_screen.dart 2>&1 | grep -E "error|warning"
  ```

  Expected: no output.

- [ ] **Step 5: Commit**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  git add lib/screens/order_builder_screen.dart
  git commit -m "feat: swipe-to-add on menu item cards — green reveal, spring back, haptic threshold tick"
  ```

---

## Task 6: Long-press Quick Menu

**Files:**
- Modify: `lib/screens/order_builder_screen.dart`
- Modify: `lib/screens/order_review_screen.dart`
- Modify: `lib/widgets/item_detail_sheet.dart`

- [ ] **Step 1: Add `autoFocusNote` to `ItemDetailSheet`**

  Open `lib/widgets/item_detail_sheet.dart`. Add the parameter to `ItemDetailSheet`:

  ```dart
  class ItemDetailSheet extends ConsumerStatefulWidget {
    final MenuItem item;
    final bool autoFocusNote;  // ← add
    const ItemDetailSheet({super.key, required this.item, this.autoFocusNote = false});

    static Future<void> show(BuildContext context, MenuItem item, {bool autoFocusNote = false}) {
      return showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.32),
        builder: (_) => ItemDetailSheet(item: item, autoFocusNote: autoFocusNote),
      );
    }
  }
  ```

  In `_ItemDetailSheetState`, add a `FocusNode`:

  ```dart
  final FocusNode _noteFocusNode = FocusNode();

  @override
  void dispose() {
    _noteFocusNode.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // existing initState code unchanged ...
    if (widget.autoFocusNote) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _noteFocusNode.requestFocus();
      });
    }
  }
  ```

  Wire the `FocusNode` to the note `TextField`:

  ```dart
  TextField(
    focusNode: _noteFocusNode,  // ← add
    decoration: const InputDecoration(
      border: InputBorder.none,
      hintText: 'Allergies, prep notes…',
    ),
    onChanged: (v) => _note = v,
    maxLines: 2,
  ),
  ```

- [ ] **Step 2: Add `_showItemQuickMenu` in order_builder_screen.dart**

  Add this method to `_OrderBuilderScreenState`:

  ```dart
  void _showItemQuickMenu(BuildContext context, MenuItem item) {
    ref.read(feedbackServiceProvider).fire(const FeedbackMedium());
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: AppRadii.md),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Expanded(child: Text(item.name, style: AppTypography.title)),
                    Text(formatRupeesCompact(item.price), style: AppTypography.caption),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.ink10),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.add_circle_outline,
                      label: 'Add',
                      onTap: () {
                        Navigator.of(context).pop();
                        if (_itemNeedsSheet(item)) {
                          ItemDetailSheet.show(context, item);
                        } else {
                          ref.read(feedbackServiceProvider).fire(const FeedbackLight());
                          ref.read(cartProvider.notifier).add(item);
                          ref.read(recentItemsProvider.notifier).track(item);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.info_outline,
                      label: 'Details',
                      onTap: () {
                        Navigator.of(context).pop();
                        ItemDetailSheet.show(context, item);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.edit_note,
                      label: 'Add + Note',
                      onTap: () {
                        Navigator.of(context).pop();
                        ItemDetailSheet.show(context, item, autoFocusNote: true);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
  ```

  The `_QuickActionTile` widget lives in `lib/widgets/quick_action_tile.dart` (created in Task 6 Step 0). Import it:

  ```dart
  import '../widgets/quick_action_tile.dart';
  ```

  Use `QuickActionTile` (public, no underscore) in the Row children.

- [ ] **Step 3: Wire long-press onto `_ItemRow` in the menu list**

  In the same `for (final entry in sections.entries)` loop where `_SwipeToAddWrapper` was added, add `onLongPress` to the outer `GestureDetector` or integrate into `_SwipeToAddWrapper`. The cleanest approach: update `_ItemRow` to accept `onLongPress`:

  ```dart
  // Change _ItemRow class signature:
  class _ItemRow extends StatelessWidget {
    final MenuItem item;
    final VoidCallback onAdd;
    final VoidCallback onTap;
    final VoidCallback? onLongPress;  // ← add
    const _ItemRow({
      required this.item,
      required this.onAdd,
      required this.onTap,
      this.onLongPress,  // ← add
    });
  ```

  In `_ItemRow.build()`, change `InkWell` to include `onLongPress`:

  ```dart
  return InkWell(
    onTap: unavailable ? null : onTap,
    onLongPress: unavailable ? null : onLongPress,  // ← add
    child: // ... rest unchanged
  ```

  In the menu list, pass the long-press handler to `_ItemRow` (inside `_SwipeToAddWrapper.child`). Also wire the haptic callbacks into `_SwipeToAddWrapper`:

  ```dart
  _SwipeToAddWrapper(
    item: entry.value[i],
    readOnly: _readOnly,
    onDragTick: () => ref.read(feedbackServiceProvider).fire(const FeedbackDragTick()),
    onSwipeConfirm: () => ref.read(feedbackServiceProvider).fire(const FeedbackMedium()),
    onAdd: () {
      ref.read(feedbackServiceProvider).fire(const FeedbackLight());
      ref.read(cartProvider.notifier).add(entry.value[i]);
      ref.read(recentItemsProvider.notifier).track(entry.value[i]);
    },
    onOpenSheet: () => ItemDetailSheet.show(context, entry.value[i]),
    child: _ItemRow(
      item: entry.value[i],
      onAdd: () {
        ref.read(feedbackServiceProvider).fire(const FeedbackLight());
        ref.read(cartProvider.notifier).add(entry.value[i]);
        ref.read(recentItemsProvider.notifier).track(entry.value[i]);
      },
      onTap: () => ItemDetailSheet.show(context, entry.value[i]),
      onLongPress: _readOnly ? null : () => _showItemQuickMenu(context, entry.value[i]),
    ),
  ),
  ```

- [ ] **Step 4: Add long-press quick menu for cart lines in order_review_screen.dart**

  Find where cart lines are displayed in `order_review_screen.dart`. Add a `_showCartLineMenu` method to the review screen state:

  ```dart
  void _showCartLineMenu(BuildContext context, CartLine line, int index) {
    ref.read(feedbackServiceProvider).fire(const FeedbackMedium());
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: AppRadii.md),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(line.item.name, style: AppTypography.title),
              ),
              const Divider(height: 1, color: AppColors.ink10),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.add,
                      label: '+1',
                      onTap: () {
                        Navigator.of(context).pop();
                        ref.read(feedbackServiceProvider).fire(const FeedbackLight());
                        ref.read(cartProvider.notifier).setQtyAt(index, line.qty + 1);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.remove,
                      label: '−1',
                      onTap: () {
                        Navigator.of(context).pop();
                        ref.read(feedbackServiceProvider).fire(const FeedbackLight());
                        ref.read(cartProvider.notifier).setQtyAt(index, line.qty - 1);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.delete_outline,
                      label: 'Remove',
                      onTap: () {
                        Navigator.of(context).pop();
                        ref.read(feedbackServiceProvider).fire(const FeedbackError());
                        ref.read(cartProvider.notifier).removeAt(index);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
  ```

  Note: `_QuickAction` defined in order_builder_screen.dart is private. Either copy the class to order_review_screen.dart under the same private name, or extract it to a shared widget file (`lib/widgets/quick_action_tile.dart`). Simplest: copy the definition into order_review_screen.dart.

  Wire `onLongPress` on each cart line `GestureDetector` or `InkWell` in the review screen's cart list:

  ```dart
  // Find the cart line row widget — add onLongPress:
  GestureDetector(
    onLongPress: () => _showCartLineMenu(context, cart[i], i),
    child: // existing cart line row
  ),
  ```

- [ ] **Step 5: Verify compile**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  flutter analyze lib/screens/order_builder_screen.dart lib/screens/order_review_screen.dart lib/widgets/item_detail_sheet.dart 2>&1 | grep -E "error|warning"
  ```

  Expected: no output.

- [ ] **Step 6: Commit**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  git add lib/screens/order_builder_screen.dart lib/screens/order_review_screen.dart lib/widgets/item_detail_sheet.dart
  git commit -m "feat: long-press quick menu on menu items and cart lines + autoFocusNote on ItemDetailSheet"
  ```

---

## Task 7: Optimistic KOT Send

**Files:**
- Modify: `lib/screens/order_review_screen.dart`
- Modify: `lib/widgets/send_kot_button.dart`

- [ ] **Step 1: Add optimistic pending mark before KOT emit in `_runKotFlow`**

  Open `lib/screens/order_review_screen.dart`. Find `_runKotFlow` (the method that calls `emitAck('kot:send', ...)`). Around line 200 there's this pattern:

  ```dart
  final kotResponse = await socketService.emitAck(
    'kot:send', <String, dynamic>{'order_id': orderId},
  );
  ```

  Add optimistic mark BEFORE this `emitAck` call:

  ```dart
  // Mark all cart lines as pending BEFORE the socket emit
  ref.read(cartProvider.notifier).setSyncStatusAll(SyncStatus.pending);

  final kotResponse = await socketService.emitAck(
    'kot:send', <String, dynamic>{'order_id': orderId},
  );

  if (kotResponse['kind'] == 'error') {
    // Mark pending lines as failed — waiter sees ⚠️ badge
    ref.read(cartProvider.notifier).setSyncStatusFailed();
    return _OrderFlowStepResult(
      failedStep: _OrderFlowStep.kotSend,
      errorMessage: 'Failed to send KOT to kitchen — please retry',
    );
  }

  // KOT success — mark all synced
  ref.read(cartProvider.notifier).setSyncStatusAll(SyncStatus.synced);
  ref.read(syncServiceProvider).applyOrderAck(kotResponse, includeHistory: true);
  _kotSentOrderId = orderId;
  ```

- [ ] **Step 2: Add 8-second timeout to KOT emit**

  Wrap the `emitAck` call with a timeout:

  ```dart
  Map<String, dynamic> kotResponse;
  try {
    kotResponse = await socketService
        .emitAck('kot:send', <String, dynamic>{'order_id': orderId})
        .timeout(const Duration(seconds: 8));
  } on TimeoutException {
    ref.read(cartProvider.notifier).setSyncStatusFailed();
    return _OrderFlowStepResult(
      failedStep: _OrderFlowStep.kotSend,
      errorMessage: 'KOT send timed out — tap retry',
    );
  }
  ```

  Add the `dart:async` import at the top if not already present:

  ```dart
  import 'dart:async';
  ```

- [ ] **Step 3: Add ⚠️ badge to cart lines in review screen**

  Find the cart line list builder in `order_review_screen.dart`. Inside each cart line row widget, add a `SyncStatus` badge. Find where each cart line `l` is rendered — add after the line's trailing content:

  ```dart
  // Add sync status badge inside the cart line row:
  if (l.syncStatus == SyncStatus.pending)
    const SizedBox(
      width: 18, height: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.ink30),
    ),
  if (l.syncStatus == SyncStatus.failed)
    const Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.amber),
  ```

- [ ] **Step 4: Add retry banner**

  In `order_review_screen.dart` build method, add a conditional amber banner at the top of the cart section when any lines have `SyncStatus.failed`:

  ```dart
  // Add before the cart list:
  Builder(builder: (ctx) {
    final hasFailed = ref.watch(
      cartProvider.select((c) => c.any((l) => l.syncStatus == SyncStatus.failed)),
    );
    if (!hasFailed) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () async {
        ref.read(cartProvider.notifier).retryFailed();
        ref.read(feedbackServiceProvider).fire(const FeedbackMedium());
        // re-trigger the KOT flow for failed lines
        // simplest: navigate back to review (already on review screen)
        // or call a dedicated retry method
        // For now, show a snackbar prompting to tap Send KOT again:
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(
            content: Text('Tap "Send KOT" to retry'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.amber.withValues(alpha: 0.12),
          borderRadius: const BorderRadius.all(AppRadii.sm),
          border: Border.all(color: AppColors.amber.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.amber),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Some items failed to sync — tap to retry',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
            ),
            const Icon(Icons.chevron_right, size: 16, color: AppColors.ink30),
          ],
        ),
      ),
    );
  }),
  ```

- [ ] **Step 5: Verify compile**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  flutter analyze lib/screens/order_review_screen.dart lib/widgets/send_kot_button.dart 2>&1 | grep -E "error|warning"
  ```

  Expected: no output.

- [ ] **Step 6: Full project analyze**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  flutter analyze 2>&1 | grep -E "^.*error" | head -20
  ```

  Expected: no `error` lines.

- [ ] **Step 7: Commit**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  git add lib/screens/order_review_screen.dart lib/widgets/send_kot_button.dart
  git commit -m "feat: optimistic KOT send — pending badge, 8s timeout, failed ⚠️ badge, retry banner"
  ```

---

## Final Check

- [ ] **Run full flutter analyze**

  ```bash
  cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
  flutter analyze 2>&1 | grep -v "^$" | grep -v "info " | tail -5
  ```

  Expected: `0 issues found` or info-only.

- [ ] **Manual test checklist on device/simulator**

  - [ ] Floor plan: open a table marked `mine` → timer chip appears, color green
  - [ ] Wait 1 min → chip updates (or test by setting `occupiedSince` to 90 mins ago manually)
  - [ ] Order builder: swipe right on a menu item → green reveal, adds to cart, card springs back
  - [ ] Swipe item with variations → `ItemDetailSheet` opens instead of direct add
  - [ ] Long-press menu item → quick action sheet appears with 3 buttons
  - [ ] Long-press "Add + Note" → detail sheet opens with note field focused
  - [ ] Long-press cart item in review → +1/−1/Remove actions work
  - [ ] Toggle haptic off in Settings → all swipe/long-press/add haptics silent
  - [ ] Simulate KOT send failure → ⚠️ badges appear on affected lines
  - [ ] Tap retry banner → snackbar prompts to re-send
