# Flutter ↔ Electron Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add item variations + missing feature flags to Flutter app, ensure backend sends variations with menu sync

**Architecture:** Extend Flutter data models + Socket.IO sync, backend already has variations table

**Tech Stack:** Flutter, Dart, Socket.IO, Riverpod, Angular/Electron backend

---

## File Map

### Flutter (dinedesk-cap)
| File | Change |
|------|--------|
| `lib/models/feature_flags.dart` | Add 4 missing flags |
| `lib/models/server_models.dart` | Add `variation_id`/`variation_name` to `ServerOrderItem`, add `variations` to `ServerMenuItem` |
| `lib/services/sync_service.dart` | Parse `variations` in menu sync, handle variation fields in orders |

### Electron Backend (restro-desktop)
| File | Change |
|------|--------|
| `electron/ipc/handlers.ts` | Ensure menu sync includes `variations` array + `item_variations` flag |

---

## Tasks

### Task 1: Add missing feature flags to Flutter

**Files:**
- Modify: `lib/models/feature_flags.dart:29-58` (add fields)
- Modify: `lib/models/feature_flags.dart:60-100` (add fromMap parsing)

- [ ] **Step 1: Add flag fields to FeatureFlags class**

Add these fields after `predictiveMotion` (line 28):
```dart
final bool itemVariations;
final bool waiterAssignment;
final bool manualEntry;
final bool kotEdit;
```

- [ ] **Step 2: Add default values in constructor**

Add defaults after `predictiveMotion: false` (line 57):
```dart
this.itemVariations = false,
this.waiterAssignment = false,
this.manualEntry = false,
this.kotEdit = false,
```

- [ ] **Step 3: Add fromMap parsing**

Add these lines after `predictiveMotion: flag('flag_predictive_motion')` (line 98):
```dart
itemVariations: flag('item_variations'),
waiterAssignment: flag('waiter_assignment'),
manualEntry: flag('manual_entry'),
kotEdit: flag('kot_edit'),
```

- [ ] **Step 4: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/models/feature_flags.dart
git commit -m "feat: add item_variations, waiter_assignment, manual_entry, kot_edit flags"
```

---

### Task 2: Add variation fields to ServerOrderItem

**Files:**
- Modify: `lib/models/server_models.dart:183-225` (ServerOrderItem)

- [ ] **Step 1: Add variation fields to ServerOrderItem class**

After `final String? kotStatus;` (line 194), add:
```dart
final String? variationId;
final String? variationName;
```

- [ ] **Step 2: Update constructor parameters**

After `this.kotStatus,` (line 207), add:
```dart
this.variationId,
this.variationName,
```

- [ ] **Step 3: Update fromMap factory**

After `kotStatus: m['kot_status']?.toString(),` (line 222), add:
```dart
variationId: m['variation_id']?.toString(),
variationName: m['variation_name']?.toString(),
```

- [ ] **Step 4: Commit**

```bash
git add lib/models/server_models.dart
git commit -m "feat: add variation_id and variation_name to ServerOrderItem"
```

---

### Task 3: Add variations to ServerMenuItem

**Files:**
- Modify: `lib/models/server_models.dart` (ServerMenuItem)

- [ ] **Step 1: Create ServerItemVariation class**

Add after `ServerMenuOption` class (after line 350):
```dart
// ─────────────── Server Item Variation ───────────────

class ServerItemVariation {
  final String id;
  final String itemId;
  final String name;
  final double price;
  final int sortOrder;

  const ServerItemVariation({
    required this.id,
    required this.itemId,
    required this.name,
    required this.price,
    required this.sortOrder,
  });

  factory ServerItemVariation.fromMap(Map<String, dynamic> m) {
    return ServerItemVariation(
      id: _toStr(m['id']),
      itemId: _toStr(m['item_id']),
      name: _toStr(m['name']),
      price: _toDouble(m['price']),
      sortOrder: _toInt(m['sort_order']),
    );
  }
}
```

- [ ] **Step 2: Add variations field to ServerMenuItem**

After `final List<ServerMenuOptionGroup> optionGroups;` (line 238), add:
```dart
final List<ServerItemVariation> variations;
```

- [ ] **Step 3: Update constructor**

After `this.optionGroups = const [],` (line 249), add:
```dart
this.variations = const [],
```

- [ ] **Step 4: Update fromMap factory**

After `optionGroups: const [],` (line 265), add:
```dart
variations: const [],
```

- [ ] **Step 5: Update copyWith**

After `List<ServerMenuOptionGroup>? optionGroups,` (line 270), add:
```dart
List<ServerItemVariation>? variations,
```

And after `optionGroups: optionGroups ?? this.optionGroups,` (line 281), add:
```dart
variations: variations ?? this.variations,
```

- [ ] **Step 6: Commit**

```bash
git add lib/models/server_models.dart
git commit -m "feat: add ServerItemVariation model and variations field to ServerMenuItem"
```

---

### Task 4: Update Flutter SyncService to handle variations

**Files:**
- Modify: `lib/services/sync_service.dart` (menu parsing + order item handling)

- [ ] **Step 1: Update _serverMenuItemToLocal to include variations**

In `sync_service.dart`, find `_serverMenuItemToLocal` method and update to parse variations:
```dart
MenuItem _serverMenuItemToLocal(ServerMenuItem si) {
  return MenuItem(
    // ... existing fields ...
    optionGroups: si.optionGroups
        .map((g) => MenuOptionGroup(
              id: g.id,
              itemId: g.itemId,
              name: g.name,
              isRequired: g.isRequired,
              minSelect: g.minSelect,
              maxSelect: g.maxSelect,
              options: g.options
                  .map((o) => MenuOption(
                        id: o.id,
                        groupId: o.groupId,
                        name: o.name,
                        priceModifier: o.priceModifier,
                      ))
                  .toList(),
            ))
        .toList(),
    // Add variations - update MenuItem to include variations field
    variations: si.variations
        .map((v) => MenuItemVariation(
              id: v.id,
              name: v.name,
              price: v.price,
            ))
        .toList(),
  );
}
```

Note: You may need to add `variations` field to your local `MenuItem` class in `lib/data/providers.dart`

- [ ] **Step 2: Check if MenuItem model needs variations field**

Look at `lib/data/providers.dart` for `class MenuItem`:
```dart
class MenuItem {
  // ...
  final List<MenuOptionGroup> optionGroups;
  // Add:
  final List<MenuItemVariation> variations;
}
```

- [ ] **Step 3: Create MenuItemVariation class if needed**

In `lib/data/providers.dart`, add:
```dart
class MenuItemVariation {
  final String id;
  final String name;
  final double price;

  const MenuItemVariation({
    required this.id,
    required this.name,
    required this.price,
  });
}
```

- [ ] **Step 4: Commit**

```bash
git add lib/services/sync_service.dart lib/data/providers.dart
git commit -m "feat: parse item variations in menu sync"
```

---

### Task 5: Ensure Electron backend sends variations with menu

**Files:**
- Modify: `electron/ipc/handlers.ts` (ensure menu sync includes variations)

- [ ] **Step 1: Find menu sync handler**

Look for `menu:get-all` or `menu:sync` handler in handlers.ts around line 2440-2500

- [ ] **Step 2: Check if variations are included**

Find where menu items are serialized for sync and ensure `variations` array is included:
```typescript
// Should include something like:
variations: itemVariations.map(v => ({
  id: v.id,
  item_id: v.item_id,
  name: v.name,
  price: v.price,
  sort_order: v.sort_order,
}))
```

- [ ] **Step 3: Verify items service has getVariations**

Check `electron/services/items.service.ts` has `getVariations(itemId)` method (already confirmed at line 103)

- [ ] **Step 4: Ensure item_variations flag is sent**

Check that `item_variations` flag is included in the feature flags sent to Flutter during sync

- [ ] **Step 5: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add electron/ipc/handlers.ts
git commit -m "feat: include item_variations in menu sync for Flutter app"
```

---

### Task 6: Update order emit to include variation_id

**Files:**
- Modify: `lib/services/socket_service.dart` or order emitting code in Flutter

- [ ] **Step 1: Find where orders are emitted**

Look for `emit('order:create'` or similar in the Flutter codebase:
```bash
grep -rn "order:create\|emit.*order" /Users/mohitsoni/Desktop/Workspace/dinedesk-cap/lib/
```

- [ ] **Step 2: Update item payload to include variation_id**

When emitting order items, ensure the payload includes:
```dart
'item_id': itemId,
'variation_id': variationId,  // Add this
'quantity': quantity,
'item_name': itemName,
'variation_name': variationName,  // Add this
// ... other fields
```

- [ ] **Step 3: Commit**

```bash
git add lib/services/*.dart
git commit -m "feat: include variation_id in order emit"
```

---

### Task 7: Update Electron backend to handle variation_id in orders

**Files:**
- Modify: `electron/services/orders.service.ts`

- [ ] **Step 1: Find order item parsing**

Look for where order items are parsed in `orders.service.ts`

- [ ] **Step 2: Add variation_id handling**

Ensure `variation_id` and `variation_name` are extracted from order item payload and stored

- [ ] **Step 3: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add electron/services/orders.service.ts
git commit -m "feat: store variation_id in order_items table"
```

---

## Testing Checklist

After implementation:
- [ ] Flutter connects to Electron and receives menu with variations
- [ ] Order placed with variation → variation_name appears in order
- [ ] KOT shows variation name
- [ ] Bills show variation name
- [ ] Feature flags visible in Flutter

---

## Out of Scope

- Flutter variation picker UI (for selecting variations when adding items)
- Cloud deployment
- Testing framework setup (use manual UI testing)