# Restro · Operator (Flutter)

iOS 26 Liquid Glass mobile POS for **Indian restaurant** waiters. Order-taking
companion that pairs over local WiFi with the RestroApp Electron desktop admin.

## Run

```bash
cd flutter
flutter pub get
flutter run
```

Min Flutter `3.24` / Dart `3.5`. Tested on iOS + Android.

> The first run requires camera permission for QR pairing (`Info.plist`
> `NSCameraUsageDescription` / Android `CAMERA`). The current build prompts on
> first scan attempt.

## Architecture

This is the **operator phone** half of RestroApp. It is a **thin client** —
the Electron admin desktop holds all restaurant data; this app submits orders
over a local WebSocket and holds no offline state.

```
Operator phone (this app)         Admin desktop (Electron)
┌──────────────────────┐          ┌──────────────────────┐
│  Flutter UI          │  WS+JWT  │  NestJS-style server │
│  Riverpod stores     │ ◄──────► │  better-sqlite3      │
│  In-memory cart only │   LAN    │  Bills, GST, KOT     │
└──────────────────────┘          └──────────────────────┘
```

Pair flow: `/splash → /scan → /connecting → /auth → /tables`

A network drop starts a 2-minute reconnect grace (countdown banner). If it
expires, the user is sent to `/disconnected` and must re-pair via QR.

## Stack

| Layer | Choice |
|---|---|
| State | `flutter_riverpod` |
| Routing | `go_router` (Navigator 2.0) |
| Glass | `liquid_glass_renderer` |
| QR scan | `mobile_scanner` |
| ₹ format | `intl` (Indian locale grouping) |
| Backend | Mock fixtures in `lib/data/providers.dart` — swap for WS repo |

> **Not yet wired:** `web_socket_channel`, `multicast_dns`, `flutter_secure_storage`,
> `device_info_plus`. These are part of the network/auth layer described in
> `OPERATOR_FLUTTER_APP_PLAN.md` and slot in behind the existing UI providers.

## Folder structure

```
flutter/
├─ pubspec.yaml
├─ lib/
│  ├─ main.dart
│  ├─ router.dart
│  ├─ theme/                  # AppColors / AppRadii / AppTypography / AppShadows
│  ├─ data/
│  │  ├─ providers.dart       # Indian menu, ₹ pricing, kitchenSection routing
│  │  └─ currency.dart        # ₹ formatter (Indian locale)
│  ├─ widgets/
│  │  ├─ liquid_glass_surface.dart
│  │  ├─ liquid_chrome.dart   # AppBar / BottomNav / Pill / Buttons
│  │  ├─ liquid_mesh_background.dart
│  │  ├─ app_card.dart
│  │  ├─ numeric_keyboard.dart
│  │  ├─ item_detail_sheet.dart       # spice + add-ons grouped
│  │  ├─ table_merge_sheet.dart
│  │  ├─ customer_count_sheet.dart    # NEW · 1-20 stepper
│  │  ├─ help_sheet.dart              # NEW · pairing help
│  │  ├─ order_submitting_overlay.dart # NEW · in-flight state
│  │  ├─ connection_banner.dart       # 2:00 countdown ring
│  │  ├─ confetti_burst.dart
│  │  ├─ animated_check_draw.dart
│  │  ├─ page_transitions.dart
│  │  └─ root_shell.dart
│  └─ screens/
│     ├─ splash_screen.dart
│     ├─ qr_scan_screen.dart          # NEW · mobile_scanner + brackets
│     ├─ connecting_screen.dart       # NEW · 3-stage handshake
│     ├─ auth_screen.dart             # username + 4-6 PIN
│     ├─ tables_screen.dart           # 4 floors, search, presence
│     ├─ order_builder_screen.dart    # search, veg dot, save & exit
│     ├─ order_review_screen.dart     # KOT preview, no Pay button
│     ├─ order_success_screen.dart
│     ├─ order_detail_screen.dart     # NEW · cancel + reprint
│     ├─ history_screen.dart          # status filters + tap → detail
│     ├─ disconnected_screen.dart     # NEW · 2-min timeout
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
- **No billing on phone**: there is no payment screen. Bill, GST, settlement
  all live on the admin desktop. The phone fires `kot.print` and walks away.
- **Modifiers grouped**: spice level (single-select radio, default Medium) +
  add-ons (multi-select with prices like Extra Cheese +₹60, Half Portion −₹50).
- **KOT format**: order success shows `KOT #4127`. Each kitchen section gets its
  own KOT printout on the admin desktop; the phone gets a single confirmation.

## Pairing & session flow

1. **Boot** — `/splash` (1.8s logo) → `/scan`
2. **Scan QR** — admin shows `restroapp://pair?token=xxx` rotating QR. Camera
   detects, validates schema, advances to `/connecting`
3. **Connecting** — 3 staged checks: `Finding restaurant…`, `Verifying device…`,
   `Almost there…`. Mock takes ~2.5s; real handshake does mDNS + WS open + JWT pair
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

## Wiring the real backend

The mock providers in `lib/data/providers.dart` are the seam. Each is
replaceable without touching screens:

```dart
// Today (mock)
final tablesProvider = StateProvider<List<RestaurantTable>>((_) => _tablesFixture);

// Tomorrow (WS-backed) — implement WsRepository per OPERATOR_FLUTTER_APP_PLAN.md
final tablesProvider = StreamProvider<List<RestaurantTable>>(
  (ref) => ref.read(wsRepoProvider).tablesStream(),
);
```

Pair flow plugs into `/connecting`'s mock `_tick()` — replace with the real
mDNS resolve + WS open + JWT pair sequence and route to `/auth` only on success.

## Demo helpers (Settings → Demo)

- **Simulate offline** switch — drops `connectionProvider` to offline; banner
  starts the 2-minute countdown for real
- **Disconnected screen** — direct preview of the timeout state
- **Force-disconnect screen** — direct preview of the admin-kick state

## What's next

The UI layer is feature-complete for the operator workflow. Outstanding work
is the **network/auth layer** (`OPERATOR_FLUTTER_APP_PLAN.md`):

- WS client + reconnect state machine
- mDNS resolver
- JWT pairing + session token rotation
- `flutter_secure_storage` for session persistence
- `device_info_plus` for hardware fingerprint
- Background heartbeat (15s ping) + 2-minute grace enforcement
- Replace mock providers with WS-backed equivalents

These are pure plumbing — the screens themselves don't need to change.
