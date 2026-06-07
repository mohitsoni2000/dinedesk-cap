# Flutter ↔ Electron Sync + Deployment Design

**Date:** 2026-06-04
**Status:** Draft

---

## Context

**restro-desktop** (Angular + Electron):
- Full-featured desktop POS running on restaurant's local machine
- Backend: Electron main process + SQLite + Socket.IO operator namespace
- Recently added: item_variations, KOT edit, waiter assignment, manual entry

**dinedesk-cap** (Flutter iOS/Android):
- Mobile waiter app (waiter-cap) connecting via Socket.IO to Electron backend
- Real-time sync via `SyncService` + Riverpod state management
- Missing: item_variations support, latest feature flags

**Goal:** Full feature parity + deploy Flutter app to same server

---

## What's Already Synced

| Feature | Flutter Support | Notes |
|---------|-----------------|-------|
| Tables (CRUD, status) | ✅ | `table:updated` broadcast |
| Orders (create, update, cancel) | ✅ | `order:*` events |
| KOT (send, print) | ✅ | `kot:sent` |
| Bills (generate, pay) | ✅ | `bill:*` |
| Discounts | ✅ | `discount:applied` |
| Feature flags (basic) | ✅ | `flags:updated` |
| Menu sync | ✅ | `menu:updated` |
| Fast-add items | ✅ | `fast-add:updated` |
| Table merge/shift/link | ✅ | `table:*` events |
| Operator presence | ✅ | `operator:online/offline` |
| Force disconnect | ✅ | `force:disconnect` |

---

## Gaps: Feature Parity

### 1. Item Variations (NEW)
- **Backend:** `item_variations` table + `variation_id` on order_items, bill_items
- **Missing in Flutter:**
  - `ServerMenuItem` needs `variations` field
  - Menu sync needs to include `variations` list per item
  - Order builder needs variation picker in quick-add
  - Cart item needs `variation_id` + `variation_name`
  - Order emit needs to include `variation_id` in items

### 2. KOT Edit (NEW)
- **Backend:** `order:update` with `items_add`/`items_remove` types for modifications
- **Flutter:** Already has `KotEditSheet` + `operatorPinKotEdit` flag
- **Status:** ✅ Implemented, needs verification with backend

### 3. New Feature Flags
- `item_variations` — missing from `FeatureFlags` model
- `waiter_assignment` — missing
- `manual_entry` — missing
- `kot_edit` — missing (has `operatorPinKotEdit` but not `flag_kot_edit`)

### 4. Order Item Structure
- **Backend sends:** `item_id`, `item_name`, `variation_id`, `variation_name`, `selected_options`, `quantity`, `unit_price`, `total_price`, `item_type`
- **Flutter receives:** needs `variation_id`, `variation_name` fields in `ServerOrderItem`

### 5. Menu Sync Enhancement
- Menu data needs `variations` array per item
- `item_option_groups` + `item_options` already supported

---

## Architecture: Deployment

### Current Setup
```
Electron (localhost:3000)
  └── Socket.IO /operator namespace
       ├── Angular (desktop operator/admin)
       └── Flutter (waiter mobile) — connect via IP (e.g., http://192.168.1.x:3000)
```

### Issue: Flutter on mobile needs server IP, not localhost
- When Electron runs on restaurant's machine at `192.168.1.100:3000`
- Flutter app configured with that IP to connect
- Works on same LAN, not cloud

### Deployment Option A: Local Network (Current)
- Flutter connects to Electron's Socket.IO on local IP
- No cloud deployment needed
- Both apps run on same restaurant network
- **Pros:** Zero hosting cost, low latency, works offline
- **Cons:** No remote access, need static IP or hostname

### Deployment Option B: Cloud Backend (Future)
- Separate Node.js backend deployed to cloud
- Both Electron + Flutter connect to cloud
- Requires refactoring Electron's backend logic
- **Deferred for now**

---

## Scope for This Implementation

**Phase 1: Feature Parity (Flutter updates)**
1. Add missing feature flags (`item_variations`, `waiter_assignment`, `manual_entry`, `kot_edit`)
2. Add `variation_id` + `variation_name` to `ServerMenuItem` and `ServerOrderItem`
3. Update menu sync to receive and parse `variations` array
4. Update order emit to send `variation_id` with items
5. Add variation picker UI in quick-add (optional, for Phase 2)

**Phase 2: Deployment Config**
1. Document how to set server IP in Flutter app
2. Provide setup guide for restaurant network

---

## Data Flow: Item Variations

```
Backend (Electron)
  ├── items table has variations[]
  ├── menu sync includes variations[]
  └── order:create with { items: [{ ..., variation_id }] }
        └── Flutter receives → stores in ServerOrderItem
        └── Backend stores in order_items.variation_id
```

---

## Files to Update (Flutter)

| File | Change |
|------|--------|
| `models/feature_flags.dart` | Add `item_variations`, `waiter_assignment`, `manual_entry`, `kot_edit` flags |
| `models/server_models.dart` | Add `variation_id`, `variation_name` to `ServerMenuItem` + `ServerOrderItem` |
| `services/sync_service.dart` | Handle `variations` in menu parsing |
| `services/socket_service.dart` | (no changes needed) |
| `screens/order_builder_screen.dart` | Include `variation_id` when emitting items |

---

## Files to Update (Electron Backend)

| File | Change |
|------|--------|
| `electron/ipc/handlers.ts` | Ensure menu sync includes `variations` array |
| `electron/services/sync.service.ts` | (already sends variations?) |
| `electron/services/orders.service.ts` | Handle `variation_id` in order item parsing |

---

## Testing Checklist

- [ ] Flutter connects to Electron and receives menu with variations
- [ ] Order placed with variation selected → stored in order_items
- [ ] KOT print shows variation name
- [ ] Bill shows variation name
- [ ] New flags visible in Flutter app

---

## Out of Scope

- Cloud backend deployment (Phase 2, future)
- Flutter variation picker UI (Phase 2, future)
- Refactoring Electron's operator gateway architecture

---

## Recommendation

**Start with Phase 1:** Add feature flags + variation fields to Flutter, verify sync works with current Electron backend.

No major architecture changes needed — Flutter already has the sync infrastructure. Just need to extend the data models.