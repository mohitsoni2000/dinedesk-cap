# Restro · Operator (Flutter)

iOS 26 Liquid Glass mobile POS for **Indian restaurant** waiters. Order-taking
companion that pairs over local WiFi with the RestroApp Electron desktop admin.

## Run

```bash
flutter pub get
flutter run
```

Min Flutter `3.24` / Dart `3.5`. Tested on iOS + Android. `lib/` sits at the
repo root — there is no `flutter/` subdirectory.

> The first run requires camera permission for QR pairing (`Info.plist`
> `NSCameraUsageDescription` / Android `CAMERA`). The current build prompts on
> first scan attempt.

## Architecture

This is the **operator phone** half of RestroApp. It is a **thin client** —
the Electron admin desktop (`restro-desktop`) holds all restaurant data; this
app connects over a local-LAN Socket.IO channel and holds no offline state
beyond the in-flight cart.

```
Operator phone (this app)              Admin desktop (Electron)
┌───────────────────────┐              ┌──────────────────────────┐
│  Flutter UI            │  socket.io  │  operator.gateway.ts      │
│  Riverpod stores       │ ◄─────────► │  /operator namespace      │
│  In-memory cart only   │     LAN     │  JWT + PIN session guard  │
└───────────────────────┘              │  better-sqlite3 — Bills,  │
                                        │  GST, KOT, rooms, offers  │
                                        └──────────────────────────┘
```

Pair flow: `/splash → /scan → /connecting → /auth → /tables`

QR pairing hands the app a `{host, port, token}` triple; `SocketService.connect()`
opens a `socket_io_client` connection to `http://host:port/operator` with the
token in the auth payload, then `operator:verify` exchanges the operator's PIN
for a verified session. A network drop starts a 2-minute reconnect grace
(countdown banner). If it expires, the user is sent to `/disconnected` and
must re-pair via QR. An admin-initiated kick routes to `/force-disconnected`.

## Stack

| Layer | Choice |
|---|---|
| State | `flutter_riverpod` |
| Routing | `go_router` (Navigator 2.0, `StatefulShellRoute` tab shell) |
| Realtime | `socket_io_client` → desktop's `/operator` namespace |
| Glass | `liquid_glass_renderer` |
| QR scan | `mobile_scanner` |
| Local prefs | `shared_preferences` (session token, last-paired host) |
| ₹ format | `intl` (Indian locale grouping) |

All restaurant data — tables, rooms, menu, addon groups, offers, active
orders, KOT history — arrives over the socket as a single initial-sync
payload on connect, then stays live via per-event broadcasts
(`order:created`, `kot:sent`, `bill:generated`, `offer:applied`, …) consumed
in `lib/services/sync_service.dart`. There is no REST layer and no local
database; every screen reads from Riverpod `StateProvider`s that
`sync_service.dart` keeps in sync with the desktop.

## Folder structure

```
.
├─ pubspec.yaml
├─ lib/
│  ├─ main.dart
│  ├─ router.dart                     # go_router — tab shell + push routes
│  ├─ theme/                          # AppColors / AppRadii / AppTypography / AppShadows
│  ├─ data/
│  │  ├─ providers.dart               # all Riverpod state: tables, rooms, cart,
│  │  │                               # menu, offers, history, connection…
│  │  ├─ currency.dart                # ₹ formatter (Indian locale)
│  │  └─ table_open_intent.dart       # resolves table/room tap → route + action
│  ├─ models/
│  │  ├─ server_models.dart           # raw wire-shape parsers (ServerTable,
│  │  │                               # ServerOrder, ServerRoom, BroadcastEnvelope…)
│  │  └─ feature_flags.dart           # mirrors restro-desktop's DbRestaurantConfig
│  ├─ services/
│  │  ├─ socket_service.dart          # socket_io_client connect + operator:verify
│  │  ├─ sync_service.dart            # applies initial sync + all broadcast listeners
│  │  ├─ session_service.dart         # persisted pairing/session token
│  │  └─ pin_guard.dart               # re-PIN gate for sensitive actions
│  ├─ widgets/
│  │  ├─ liquid_glass_surface.dart
│  │  ├─ liquid_chrome.dart           # AppBar / BottomNav / Pill / Buttons
│  │  ├─ liquid_mesh_background.dart
│  │  ├─ app_card.dart
│  │  ├─ item_detail_sheet.dart       # variations + addon groups + weighed entry
│  │  ├─ discount_sheet.dart          # preset/custom % or flat discount
│  │  ├─ coupon_sheet.dart            # legacy discount-engine coupon entry
│  │  ├─ offers_sheet.dart            # browse/apply offers engine + coupon codes
│  │  ├─ payment_sheet.dart
│  │  ├─ customer_sheet.dart / customer_count_sheet.dart
│  │  ├─ table_merge_sheet.dart / table_link_sheet.dart / table_shift_sheet.dart
│  │  ├─ package_sheet.dart
│  │  ├─ kot_edit_sheet.dart / kot_history_sheet.dart
│  │  ├─ pin_pad.dart / pin_verify_sheet.dart
│  │  ├─ connection_banner.dart       # 2:00 reconnect countdown ring
│  │  ├─ ready_orders_banner.dart
│  │  ├─ confetti_burst.dart / animated_check_draw.dart
│  │  ├─ page_transitions.dart
│  │  └─ root_shell.dart              # bottom-nav tab shell
│  └─ screens/
│     ├─ splash_screen.dart
│     ├─ qr_scan_screen.dart          # mobile_scanner + brackets
│     ├─ connecting_screen.dart       # staged handshake
│     ├─ auth_screen.dart             # username + 4-6 PIN
│     ├─ tables_screen.dart           # floors, search, presence
│     ├─ rooms_screen.dart            # hotel rooms — parallel to tables_screen
│     ├─ order_builder_screen.dart    # shared by tables + rooms (isRoom flag)
│     ├─ order_review_screen.dart     # KOT preview, shared by tables + rooms
│     ├─ order_success_screen.dart
│     ├─ order_detail_screen.dart     # cancel, reprint, discount/coupon/offers, bill, pay
│     ├─ history_screen.dart          # status filters + tap → detail
│     ├─ disconnected_screen.dart     # 2-min timeout
│     ├─ force_disconnected_screen.dart # admin-kick → /scan
│     ├─ change_pin_screen.dart
│     ├─ profile_screen.dart          # KPIs + restaurant info
│     └─ settings_screen.dart
└─ assets/fonts/             # Inter + Cormorant Garamond ttfs
```

## Indian POS specifics

- **Currency**: ₹ only, with `en_IN` lakh/crore grouping (`formatRupeesCompact`)
- **Veg/non-veg dot** (FSSAI): green/red square dot on every menu item + cart line
- **Kitchen sections**: each menu item carries `kitchenSection` —
  `tandoor` / `curry` / `south` / `chinese` / `beverages` / `tikka`. Order Review
  shows a **KOT preview** grouped by these so the operator can confirm split
  before submitting.
- **Billing lives on the phone too**: `order_detail_screen.dart` can generate
  the bill, apply a discount/coupon/offer, and collect payment — all via the
  same operator gateway the admin desktop uses. GST and settlement math stay
  server-side; the phone only submits actions and renders the result.
- **Weighed items**: menu items with a `measure_unit` (e.g. per-kg mutton)
  prompt for weight instead of quantity; price = `(base + mods) × weight`.
- **Modifiers**: variation → option groups (spice level etc., single/multi-select)
  → addon groups (Extra Cheese +₹60, Half Portion −₹50) — all server-defined
  per item, joined client-side from the initial sync payload.
- **Offers & coupons**: the offers engine (category/item discount, BOGO,
  scheduled, coupon-gated) is browsed/applied from `offers_sheet.dart`; the
  older flat/percentage discount + legacy coupon flow lives alongside it in
  `discount_sheet.dart` / `coupon_sheet.dart`.
- **Hotel rooms**: `rooms_screen.dart` is a parallel flow to tables — room
  orders use `order_type: 'room'` + `room_id` instead of a table, skip
  presence/table-link concepts, and share the same builder/review/success
  screens via an `isRoom` flag.
- **KOT format**: order success shows `KOT #4127`. Each kitchen section gets its
  own KOT printout on the admin desktop; the phone gets a single confirmation
  and can trigger a reprint from order history.

## Pairing & session flow

1. **Boot** — `/splash` (1.8s logo) → `/scan`
2. **Scan QR** — admin shows `restroapp://pair?token=xxx` rotating QR. Camera
   detects, validates schema, advances to `/connecting`
3. **Connecting** — 3 staged checks (`Finding restaurant…`, `Verifying device…`,
   `Almost there…`) while `SocketService.connect()` opens the Socket.IO
   connection to the desktop's `/operator` namespace with the pairing token
4. **Auth** — username + PIN (4-6 digit). Restaurant name + admin device shown
   so operator can confirm correct pairing
5. **Tables** — main app starts. `/tables`, `/history`, `/profile`, `/settings`
   live in the persistent shell with the connection banner overlay
6. **Disconnect** — banner shows `Reconnecting · 1:47 remaining`. At 0:00 →
   `/disconnected` (timeout). Admin kick → `/force-disconnected`
7. Both disconnect screens have **`Scan QR` as the primary action** — no
   stale-session shortcut back to `/auth`

## Liquid Glass guidelines (HIG-aligned)

Glass goes on **floating chrome only** — app bar, bottom nav, pills, FABs,
modals, ghost buttons. Cards / list rows / dense content stay **solid**
(`AppCard`) for legibility. Use `LiquidGlassSurface` for any new floating
surface — it bundles tint + rim-light + specular sweep.

## How data flows

`lib/data/providers.dart` holds every `StateProvider` the UI reads —
`tablesProvider`, `roomsProvider`, `menuProvider`, `offersProvider`,
`activeOrdersProvider`, `historyProvider`, etc. Screens never talk to the
socket directly for *reads*; they watch these providers. `sync_service.dart`
is the only writer:

- On connect, `applyInitialSync()` parses the single sync payload
  (tables/rooms/menu/addon groups/offers/active orders/history) and seeds
  every provider.
- After that, one `_socket.on(...)` listener per broadcast event
  (`order:created`, `order:updated`, `kot:sent`, `bill:generated`,
  `bill:paid`, `discount:applied`, `offer:applied`, `table:shifted`,
  `flags:updated`, …) patches the relevant providers in place.

Screens *write* by calling `socketService.emit('some:event', payload, onAck: ...)`
(or `emitAck` for a `Future`-based call) and letting the ack response feed
back into `sync_service.dart` via `applyOrderAck(...)`. There is no local
mutation of order state outside that path — this keeps the phone consistent
with the desktop and with any other paired device.

## Demo helpers (Settings → Demo)

- **Simulate offline** switch — drops `connectionProvider` to offline; banner
  starts the 2-minute countdown for real
- **Disconnected screen** — direct preview of the timeout state
- **Force-disconnect screen** — direct preview of the admin-kick state
