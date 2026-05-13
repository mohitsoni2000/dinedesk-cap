# Real-Time Cap-Desktop Sync Design

**Date:** 2026-05-13
**Status:** Approved
**Scope:** Connect Flutter Cap (waiter) app to Electron Desktop POS via Socket.IO on LAN, with Admin Panel managing feature flags via internet.

---

## 1. System Architecture

```
Admin Panel (NestJS, internet)
  │
  │ Socket.IO Client (/device namespace)
  │ Feature flags, licensing, config
  ▼
Desktop (Electron POS) ── SQLite DB (single source of truth)
  │
  │ Socket.IO SERVER (NEW) on port 8080
  │ /operator namespace on LAN
  │
  ├── Cap 1 (Waiter: Riya)
  ├── Cap 2 (Waiter: Karan)
  └── Cap 3 (Waiter: Manoj)
```

**Key principles:**
- Desktop = single source of truth (SQLite DB)
- Cap never writes locally (except cart for offline preservation)
- All writes go through Desktop for validation
- Admin Panel connects to Desktop via internet (existing)
- Caps connect to Desktop via LAN WiFi (new)
- Feature flags flow: Admin → Desktop → All Caps (real-time)

---

## 2. QR Code & Pairing Flow

### Desktop Side — QR Generation

Admin Dashboard has a "Paired Devices" section showing all operators (role=operator):

| Name | PIN Status | QR Action | Connection |
|------|-----------|-----------|------------|
| Riya Sharma | PIN Set | [Show QR] | Connected (Cap1) |
| Karan Singh | PIN Set | [Show QR] | Not Connected |
| Manoj Kumar | No PIN | [Disabled] | Not Connected |

- Desktop auto-detects LAN IP (e.g., `192.168.1.5`)
- QR format: `restroapp://pair?host=<LAN_IP>&port=8080&token=<JWT>`
- JWT payload: `{ operator_id, operator_name, token_id (uuid), issued_at }`
- Token is session-based: valid until Desktop restarts or admin revokes
- Operator without PIN = QR disabled (PIN required for accountability)

### Cap Side — Pairing Flow

```
/splash (1.8s) → /scan (QR camera)
  → Scan QR → extract host, port, token
  → /connecting → Socket.IO connect to ws://<host>:<port>/operator with { token }
    → Desktop validates token → returns restaurant_info
  → /auth → Waiter enters 4-digit PIN
    → Socket event 'operator:verify' { pin }
    → Desktop verifies PIN belongs to operator_id from token
    → Success: operator profile + permissions + flags + initial data
    → Fail: error message, retry
  → /tables → fully connected, real-time sync active
```

### Session Management

- Token stored in SharedPreferences on Cap
- App reopen: try reconnect with stored token (skip QR scan)
  - Success → go to /auth (PIN verify)
  - Fail (token invalid / Desktop restarted) → go to /scan
- One operator = one device: second scan disconnects first device
- Admin can revoke token → Cap gets force:disconnect

---

## 3. Socket.IO Event Design

### Namespace: `/operator`

### Connection & Auth

| Direction | Event | Payload | Description |
|-----------|-------|---------|-------------|
| Cap → Desktop | `connect` | `{ auth: { token } }` | Socket connection |
| Cap → Desktop | `operator:verify` | `{ pin }` | PIN verification |
| Desktop → Cap | `operator:verified` | `{ operator, permissions, flags, restaurant_info }` | PIN success |
| Desktop → Cap | `operator:rejected` | `{ error }` | Wrong PIN |
| Desktop → Cap | `force:disconnect` | `{ reason }` | Admin kicked / duplicate login |

### Initial Data Sync (after PIN verified)

```
Desktop → Cap: 'sync:initial'
{
  tables, floors, menu: { categories, items, packages },
  discounts, coupons, customers, reservations,
  active_orders, flags
}
```

### Real-Time Events

**Tables:**

| Direction | Event | Payload |
|-----------|-------|---------|
| Desktop → All Caps | `table:updated` | `{ table_id, status, active_order_id, waiter }` |
| Desktop → All Caps | `table:shifted` | `{ from_table, to_table, order_id }` |

**Orders:**

| Direction | Event | Payload |
|-----------|-------|---------|
| Cap → Desktop | `order:create` | `{ table_id, items, customer_id?, notes }` |
| Cap → Desktop | `order:update` | `{ order_id, items_add, items_remove, notes }` |
| Cap → Desktop | `order:cancel` | `{ order_id, reason }` |
| Desktop → All Caps | `order:created` | `{ order }` |
| Desktop → All Caps | `order:updated` | `{ order }` |
| Desktop → All Caps | `order:cancelled` | `{ order_id }` |

**KOT:**

| Direction | Event | Payload |
|-----------|-------|---------|
| Cap → Desktop | `kot:send` | `{ order_id, items }` |
| Desktop → Sender | `kot:sent` | `{ kot_number, print_status }` |
| Desktop → All Caps | `kot:new` | `{ kot_number, order_id, table_id }` |

**Bills:**

| Direction | Event | Payload |
|-----------|-------|---------|
| Cap → Desktop | `bill:generate` | `{ order_id }` |
| Cap → Desktop | `bill:payment` | `{ bill_id, payments[] }` |
| Desktop → Sender | `bill:generated` | `{ bill }` |
| Desktop → Sender | `bill:paid` | `{ bill_id, status }` |
| Desktop → All Caps | `bill:status` | `{ bill_id, table_id, status }` |

**Discounts:**

| Direction | Event | Payload |
|-----------|-------|---------|
| Cap → Desktop | `discount:apply` | `{ order_id, discount_id?, custom? }` |
| Desktop → Sender | `discount:applied` | `{ order_id, discount_details }` |
| Desktop → Sender | `discount:rejected` | `{ error }` |

**Customers:**

| Direction | Event | Payload |
|-----------|-------|---------|
| Cap → Desktop | `customer:search` | `{ query }` |
| Cap → Desktop | `customer:create` | `{ name, phone, ... }` |
| Desktop → Sender | `customer:results` | `{ customers[] }` |
| Desktop → Sender | `customer:created` | `{ customer }` |

**Feature Flags & Menu (from Admin via Desktop):**

| Direction | Event | Payload |
|-----------|-------|---------|
| Desktop → All Caps | `flags:updated` | `{ flags }` |
| Desktop → All Caps | `menu:updated` | `{ categories, items, packages }` |
| Desktop → All Caps | `reservation:updated` | `{ reservation }` |

**Print:**

| Direction | Event | Payload |
|-----------|-------|---------|
| Cap → Desktop | `print:kot` | `{ order_id }` |
| Cap → Desktop | `print:bill` | `{ bill_id }` |
| Desktop → Sender | `print:status` | `{ type, status, error? }` |

**Errors:**

| Direction | Event | Payload |
|-----------|-------|---------|
| Desktop → Cap | `error:validation` | `{ event, message }` |
| Desktop → Cap | `error:permission` | `{ event, message }` |
| Desktop → Cap | `error:conflict` | `{ event, message }` |

### Room Structure

```
/operator namespace
  ├── room: "all"              → all connected Caps (broadcasts)
  ├── room: "operator:<id>"    → specific operator (direct messages)
  └── room: "table:<id>"       → Caps watching a specific table
```

---

## 4. Desktop Local Server Implementation

### New files in Electron

```
electron/server/
  ├── operator-server.ts       // Socket.IO server setup, port 8080
  ├── operator.gateway.ts      // Event handlers
  ├── qr-manager.ts            // QR generation per operator
  ├── session-manager.ts       // Token create/validate/revoke
  └── sync-broadcaster.ts      // Broadcast helper for rooms
```

### Server Lifecycle

1. Electron app starts → start Socket.IO server on port 8080
2. Auto-detect LAN IP
3. Server ready for Cap connections
4. App quit → server stops, all Caps disconnected

### Integration with Existing Services

Existing services (orders.service.ts, bills.service.ts, etc.) are reused. After each DB write, a broadcast call is added:

```
Angular UI → IPC → service.ts → SQLite DB → broadcast to Caps
Cap → Socket event → service.ts → SQLite DB → broadcast to all Caps + IPC to Angular
```

No business logic duplication.

### QR Manager

- `generateQR(operatorId)` → create JWT, build `restroapp://pair?...` URL
- `revokeToken(operatorId)` → invalidate, send force:disconnect
- `getConnectedDevices()` → list all connected Caps

### Session Manager

- One operator = one device at a time
- `authenticate(socket, token)` → verify JWT, disconnect old socket if exists
- `verifyPin(operatorId, pin)` → call auth.service.pinLogin, return operator + flags
- `disconnect(operatorId)` → remove session, emit force:disconnect

### Sync Broadcaster

- `toAll(event, data)` → room "all"
- `toOperator(operatorId, event, data)` → room "operator:<id>"
- `toTableWatchers(tableId, event, data)` → room "table:<id>"

### Admin Flag Relay

Existing `socket-sync.service.ts` listens for `config:push` from admin backend. On receive:
1. Update local DB with new flags
2. Call `syncBroadcaster.toAll('flags:updated', newFlags)`
3. All Caps get updated flags instantly

---

## 5. Cap (Flutter) Integration Architecture

### New Dependencies

```yaml
socket_io_client: ^3.0.2        # Socket.IO client
shared_preferences: ^2.2.3      # Store token for reconnect
connectivity_plus: ^6.0.5       # WiFi status monitoring
```

### New File Structure

```
lib/
  ├── services/                       # NEW
  │   ├── socket_service.dart         # Socket.IO connection manager
  │   ├── session_service.dart        # Token storage, reconnect logic
  │   └── sync_service.dart           # Event handlers, data mapping
  │
  ├── models/                         # NEW (extract from providers.dart)
  │   ├── restaurant_table.dart
  │   ├── menu_item.dart
  │   ├── order.dart
  │   ├── kot.dart
  │   ├── bill.dart
  │   ├── operator.dart
  │   ├── customer.dart
  │   └── feature_flags.dart
  │
  ├── providers/                      # NEW (split from providers.dart)
  │   ├── connection_provider.dart    # socket status + WiFi
  │   ├── tables_provider.dart        # real-time tables from Desktop
  │   ├── menu_provider.dart          # synced menu
  │   ├── orders_provider.dart        # live orders
  │   ├── cart_provider.dart          # local cart (preserved offline)
  │   ├── operator_provider.dart      # authenticated operator
  │   ├── flags_provider.dart         # feature flags (controls UI)
  │   ├── customers_provider.dart
  │   └── reservations_provider.dart
```

### Socket Service

- `connect(host, port, token)` → Socket.IO connect to `/operator` namespace
- On `connect` → update connectionProvider
- On `disconnect` → start reconnect timer, show banner
- On `force:disconnect` → clear session, navigate to /scan

### Sync Service

Registers all event listeners after PIN verified. Maps socket events to Riverpod provider updates:
- `sync:initial` → populate all providers
- `table:updated` → update tablesProvider
- `order:created` → update ordersProvider
- `flags:updated` → update flagsProvider (UI rebuilds automatically)
- etc.

### Feature Flags Controlling UI

Widgets read `flagsProvider` and conditionally render:
- `flags.discounts` → show/hide discount button
- `flags.splitPayment` → show/hide split payment option
- `flags.reservations` → show/hide reservations tab
- `flags.customers` → show/hide customer search
- etc.

### Reconnect Flow

**Cold start:**
1. Check SharedPreferences for stored `{ host, port, token }`
2. Found → try socket connect → success → skip to /auth (PIN) → fail → /scan
3. Not found → /scan

**WiFi drop during session:**
1. Socket.IO auto-reconnect kicks in
2. Show "Reconnecting..." banner, cart preserved
3. WiFi back → auto-reconnect → re-auth with token → banner hides, continue
4. Token expired → redirect to /scan

---

## 6. Data Flow & Conflict Resolution

### Order Lifecycle

```
Cap: order:create → Desktop: validate + save → print KOT → broadcast to all Caps
Cap: order:update → Desktop: validate + update → print repeat KOT → broadcast
Cap: bill:generate → Desktop: calculate totals → print bill → broadcast
Cap: bill:payment → Desktop: record payment → update table status → broadcast
```

### Conflict Resolution

**Two waiters claim same table:**
- Desktop validates table is free before accepting order:create
- Second request rejected with `error:conflict`: "Table already taken by [name]"

**Stale menu (admin updated price):**
- Desktop broadcasts `menu:updated` to all Caps
- Cap rebuilds menu provider with new prices
- Cart recalculates automatically, toast shown

**Order submitted after reconnect:**
- Desktop validates current state:
  - Table still free → accept
  - Table taken → reject with conflict error
  - Item unavailable → partial reject, list unavailable items
  - Price changed → Desktop uses CURRENT price

**Key rules:**
1. Desktop = single source of truth (no split-brain)
2. Cap never writes locally (except cart)
3. Optimistic UI — Cap shows action immediately, rollback on error
4. Orders have `version` field — Desktop rejects stale updates
5. No offline order submission — cart preserved, but submit requires connection

---

## 7. Security & Permissions

### Socket Security Layers

1. **Token auth (on connect):** JWT verified → socket joins namespace. Invalid → disconnect.
2. **PIN verify (after connect):** Until PIN verified, only `operator:verify` accepted. All other events rejected.
3. **Per-event validation:** Every handler checks: operator.is_active, role permissions, feature flags, operator-specific limits.
4. **Rate limiting:** Max 60 events/minute per socket. Repeated failed PINs → 30sec lockout.

### PIN Re-verification

Controlled by Desktop config (`operator_pin_mode`):

**Per-action mode:**
- Cap sends sensitive event → Desktop checks `operator_pin_*` flag
- Flag ON → respond `pin:required { action }` → Cap shows PIN dialog → re-submit with PIN

**Session mode:**
- First PIN-protected action → verify PIN → start timer
- Within `operator_pin_session_minutes` → no re-verification
- Timer expires → next action requires PIN

### Discount Limits

- Each operator has `max_discount_pct` and `max_discount_flat`
- Desktop validates on `discount:apply` → reject if exceeds limit

### Force Disconnect Triggers

| Trigger | Reason |
|---------|--------|
| Admin deactivates operator | `account_deactivated` |
| Admin revokes device token | `token_revoked` |
| Same operator scans on new phone | `duplicate_login` |
| Desktop app shutting down | `server_shutdown` |
| License expired (from admin) | `license_expired` |

### Role Permissions from Cap

**Operator (waiter):**
- View tables/floors, create/update orders, send KOT, generate bills, collect payments
- Apply discounts (within limits), search/create customers, view reservations
- Cannot: void bills, manage users, change config, access reports

**Admin (if uses Cap):**
- Everything operator can do
- Void bills, override service charge/GST, no discount limits, skip PIN re-verification
