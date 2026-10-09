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
for a verified session. A network drop never ends the session: the app keeps
reconnecting and the connection banner shows a "Weak connection" or
"Offline · N queued" pill, with no deadline. `/disconnected` appears only when
the desk refuses the device (its token was rejected repeatedly); an
admin-initiated kick routes to `/force-disconnected`. See
[Offline & weak Wi-Fi](#offline--weak-wi-fi).

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
│  │  ├─ connection_banner.dart       # "Weak connection" / "Offline · N queued" pills
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
6. **Disconnect** — a weak or dropped link only shows a banner pill ("Weak
   connection" / "Offline · N queued") while the app keeps reconnecting; there
   is no countdown. `/disconnected` is reached only when the desk refuses the
   device. Admin kick → `/force-disconnected`
7. Both disconnect screens have **`Scan QR` as the primary action** — no
   stale-session shortcut back to `/auth`

## Offline & weak Wi-Fi

The connection layer never gives up and never ends a shift on its own:

- **Wi-Fi binding.** On Android the process is bound to the Wi-Fi network
  (`wifi_binding.dart`), so LAN traffic to the desk is not rerouted over mobile
  data when the access point has no internet. It is unbound on sign-out/unpair.
- **Keep-alive service.** While paired, a foreground service
  (`NetworkKeepAliveService`) holds the Wi-Fi and multicast locks so the radio
  does not power-save the socket to death with the screen off. It stops when the
  pairing is cleared or the app is swiped away.
- **Link monitor.** `ConnectionSupervisor` + `LinkMonitor` heartbeat the desk,
  treat one missed beat as suspicion rather than a verdict, and escalate
  (nudge the engine, rebuild the connection, rediscover the desk) forever with
  backoff. They stand down only when the desk refused the pairing, force-
  disconnected the device, or the user signed out.
- **Cold-start offline.** If the desk is unreachable at launch and the last
  confirmed operator session is still inside the desk's PIN grace window (and
  the biometric gate, when enabled, passes), the app opens on the cached
  floor, menu and orders, flagged as stale. A reachable desk takes over through
  the normal resume path and asks for the PIN if its own grace has run out.
- **Direct KOT printing.** With the desk's synced print routing, an order sent
  while offline is printed straight to the kitchen LAN printers from the phone
  (slip marked offline, with an `offline_ref`); the desk prints only the
  stations that failed when the order syncs.
- **Outbox.** Orders and KOTs taken offline are queued on the phone and drained
  automatically, in order and idempotently (one `client_request_id` per intent),
  once the session is verified again. Bills, payments, cancels, shifts and
  discounts need the desk and say so immediately instead of waiting.

## Counter, Gate and Bluetooth slips (1.3.0)

Three desk-driven modes. Each appears only when the desk turns it on, so with
every flag off and `operating_mode` absent the app is the table restaurant it
always was.

- **Counter (QSR mode).** `qsr_config.operating_mode: 'qsr'` puts a Counter
  tab first (Tables stay one tab away). Table-less orders are Takeaway or
  Standing (`counter_fulfillment_v1`).
  - **Pay & Fire** (`qsr_checkout_service.dart`) sends one `qsr:checkout`:
    the desk makes the order, fires its KOT, bills it, takes the payment and
    gives the token in one transaction. Money never queues: it needs the
    desk, and offers to park the cart without it.
  - **Fire KOT, pay at pickup** goes through `order:create` + `kot:send` and
    the outbox, so it still queues offline (as `Q-3`, turned into its token
    when it lands). The order screen's Collect bills it and opens the payment
    sheet later.
  - The desk's `qsr_payment_flow` (prepaid / postpaid / hybrid) decides which
    of the two a counter offers.
- **Parked drafts.** A cart or a half-made ticket sale can be parked on the
  phone (`parked_drafts_v1`, per operator and desk, 20 per kind, 7 days) and
  resumed, repriced against today's menu. A value the app cannot read is
  moved aside to `parked_drafts_v1.unreadable`, never deleted.
- **Gate (entry tickets).** `flag_entry_tickets` plus `flag_ticket_issue`
  and/or `flag_ticket_checkin` open the Gate tab.
  - Issue: `ticket:issue`, priced by the desk (`price_changed` asks before
    charging a new total).
  - Scan and check in: `ticket:check_in` with a 4 s per-code cooldown, one
    request in flight and a local `CDT:` filter. A ticket admits once; the
    desk is the only authority.
  - Recent: `ticket:recent`. Only users who can issue see a ticket's QR or
    reprint its slip, and each reprint is logged on the desk
    (`ticket:log_reprint`). A ticket's cover can pay food and drink bills in
    the payment sheet (`bill:payment` with `ticket_code`).
- **Bluetooth slips** (`bt_printer_service.dart`, `print_bluetooth_thermal`):
  ticket slips on a 58 or 80 mm printer, set up under Settings › Slip
  printer. The QR prints natively (or as an image, for printers that need
  it). Slips are kept in `pending_slips_v1` until they print (200 per
  operator and desk) and wiped when the phone is unpaired: they hold guests'
  names and admission codes.
- **Money that got no answer.** Pay & Fire, a ticket sale, a check-in and
  `bill:payment` are money events: an explicit 15 s ack, and one
  `client_request_id` per attempt, reused by every retry so the desk replays
  instead of charging twice.
  - An unanswered Pay & Fire or ticket sale is written to the phone before
    it is sent (`pending_checkout_v1`, `pending_issue_v1`, per operator and
    desk). Through a restart, a crash or a sign-out it is kept for up to
    48 hours (the desk's replay window): its operator gets the same request
    back to retry or drop. Another operator, or another desk, never sees it;
    older attempts, anyone's, are dropped from the phone.
  - When the desk's PIN grace runs out (`reauth_required`), the gate asks
    for the PIN once and resends the same request, or asks again for a read.
- **Without the desk.** The gate and the counter each show a strip saying
  what still works: nothing is sold or checked in; a Fire KOT still queues.

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
