# Multi-Steward Table Join

## Problem

Today a restaurant table is served by exactly one steward. For large parties this
is a bottleneck — a second steward can't formally help take orders or send KOTs
for a busy table without either taking full ownership away from the original
steward (via the existing table-shift flow) or working "invisibly" (the app
currently doesn't block editing another steward's table, it just never records
that a second person helped).

This spans two repos:
- **Backend**: `/Users/mohitsoni/Desktop/Workspace/restro-desktop/electron`
  (Electron app running a socket.io server; Node/TypeScript, raw SQLite via
  `better-sqlite3`, no ORM)
- **Client**: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap` (Flutter crew app)

## Current state (as verified in both repos)

- `tables` has no ownership column at all (`electron/database/schema.ts:162-174`).
- The only durable ownership signal is `orders.assigned_waiter_id`
  (`electron/database/schema.ts:1121`), a single nullable FK into the `waiters`
  roster table (a lightweight, name-based roster — **not** the same identity
  space as the authenticated `users`/`operatorId` used for permissions). It's
  set once, at order creation, via `OrdersService.assignWaiter()`
  (`electron/services/orders.service.ts:1439-1441`), called from
  `electron/server/operator.gateway.ts:639-642`.
- A second, unrelated, **ephemeral** single-holder concept exists:
  `presenceByTable` (`electron/server/operator.gateway.ts:73-108`), an in-memory
  `Map<tableId, PresenceEntry>` broadcasting `table:presence:updated`. Not
  persisted; disappears on disconnect. Not what we want for this feature (we
  want durable assignment, not "who's currently looking at this screen").
- A proven many-to-many pattern already exists for a *different* purpose —
  linking multiple tables together: `table_link_groups` /
  `table_link_group_members` (`electron/database/schema-additional.ts:2249-2266`,
  service in `electron/services/table-link.service.ts`). This is the template
  to copy.
- On the Flutter side, `ServerTable.operatorId` / `waiterName`
  (`lib/models/server_models.dart:29-83`) are **currently dead** — the
  backend's `TablesService.getAll()` never populates `operator_id` on table
  rows today, so these fields are always null in production. The client-side
  comparison logic that would use them already exists and is correct:
  `_mapTableStatus()` in `lib/services/sync_service.dart:842-860` computes
  `TableState.mine` vs `TableState.other` by comparing the logged-in
  operator's ID against the table's operator ID — it's just never been fed
  real data.
- `RestaurantTable.serverId` (`lib/data/providers.dart`) is **not** an
  owner/waiter field — it's the table's own backend-assigned ID. Not touched
  by this feature.
- Tapping into another steward's occupied table is **not currently blocked**
  (`lib/data/table_open_intent.dart` only blocks `dirty` tables) — you can
  already view/edit it. The gap is purely that nothing records you did.

## Decisions from design discussion

- Motivation: large parties need backup — a second steward should be able to
  help without taking over.
- Permissions: full parity. A joined steward can do everything the original
  steward can (add items, send KOTs, discount, close the bill).
- Join mechanism: self-serve, any steward can join, no PIN gate (unlike
  table-shift/table-merge which use `requirePinIfNeeded` client-side).
- No cap on joined stewards; no permanent "primary" distinction in the UI —
  once joined, everyone is equal.
- `orders.assigned_waiter_id` is kept in sync (for existing reports/receipts
  that read it) by auto-promoting the next-earliest joiner when the current
  primary leaves.

## Design

### A) Data model (backend)

New durable many-to-many table, mirroring `table_link_group_members`:

```sql
CREATE TABLE IF NOT EXISTS table_operators (
  table_id    TEXT NOT NULL REFERENCES tables(id) ON DELETE CASCADE,
  operator_id TEXT NOT NULL,          -- users(id), the authenticated steward
  joined_at   TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (table_id, operator_id)
);
CREATE INDEX IF NOT EXISTS idx_table_operators_operator ON table_operators(operator_id);
```

Added via a new `runTableOperatorsMigrations(db)` function, called from
`runAdditionalMigrations` in `electron/database/schema-additional.ts`
(same idempotent-migration pattern already used there).

New service `electron/services/table-operators.service.ts`
(`TableOperatorsService`), mirroring `TableLinkService`'s shape:
- `join(tableId, operatorId)` — `INSERT OR IGNORE`; if this table had zero
  operators before the insert, also call
  `orders.assignWaiter(activeOrderId, operatorId)` (via the existing method,
  resolving/creating a `waiters` row by the operator's display name, same as
  today's flow).
- `leave(tableId, operatorId)` — `DELETE`; if the leaving operator was the
  current `assigned_waiter_id`, look up the next-earliest remaining row by
  `joined_at` and call `assignWaiter()` with them (or `null` if none remain).
- `getOperatorsForTable(tableId)` / `getAllForTables(tableIds)` — read helpers
  used by `TablesService.getAll()`/`getById()` to attach an `operators` array
  (`[{operator_id, operator_name}]`, name resolved from `users`) to every
  table row/broadcast payload.

`TablesService` (`electron/services/tables.service.ts`):
- `getAll()`/`getById()` extended to include the new `operators` array.
- `shiftOrder()` — move `table_operators` rows from the source table_id to
  the destination table_id (not left behind).
- `mergeOrder()` — union the absorbed table's `table_operators` rows into the
  primary table's.
- Wherever a table transitions to `free` (bill paid / order closed/cancelled)
  — delete all `table_operators` rows for that table_id, so a new seating
  starts clean.

### B) Socket event contract

New entries in `src/app/shared/types/enums.ts` (shared between the Electron
backend and the Angular admin app):
- `SocketEvent.TABLE_JOIN = 'table:join'` — client emits `{ table_id }`.
  `operator_id` is **not** part of the payload; the handler derives it from
  the authenticated socket session, so a client can't join on someone else's
  behalf.
- `SocketEvent.TABLE_LEAVE = 'table:leave'` — same shape.
- No new broadcast channel — both extend the existing `table:updated`
  broadcast (`BroadcastEvent.TABLE_UPDATED`); the updated table row now
  carries the `operators` array like any other field. Clients that already
  listen for `table:updated` (`lib/services/sync_service.dart`) get this for
  free with a small parsing change.

Handler flow in `electron/server/operator.gateway.ts` (new `TABLE_JOIN` /
`TABLE_LEAVE` cases, same shape as the existing `TABLE_SHIFT` handler at
line 1334):
1. Validate payload via new Zod schemas in `electron/server/operator-schemas.ts`
   (`TableJoinPayloadSchema`/`TableLeavePayloadSchema`, `{ table_id: string }`).
2. Same `Role.WAITER` + `permissions.isTableAllowed` floor-auth check that
   shift/merge already use (baseline security; separate from the client-side
   PIN re-confirmation step, which we're intentionally skipping for join/leave).
3. Call `svc.tableOperators.join()`/`leave()`.
4. Re-fetch the table via `svc.tables.getById(tableId)`.
5. Broadcast `TABLE_UPDATED` floor-scoped (`broadcaster.toFloor`), same
   pattern as `broadcastOrderWithTables()`.
6. Ack the caller with the updated table.

### C) Client changes (Flutter)

- `ServerTable` (`lib/models/server_models.dart`): replace the dead singular
  `operatorId`/`waiterName` fields with `operatorIds: List<String>` /
  `operatorNames: List<String>`, parsed from the new `operators` array.
- `RestaurantTable` (`lib/data/providers.dart`): replace singular
  `waiterName` with `joinedOperators: List<TableOperator>`
  (`{id, name}` pairs). `serverId` (the table's own ID) is untouched.
- `_mapTableStatus()` (`lib/services/sync_service.dart:842-860`): change from
  an equality check to `.contains()` against the operators list — `mine` if
  the current operator ID is in the list (or the list is empty, same
  fallback as today), `other` if occupied and not in the list.
- New UI, `lib/screens/order_builder_screen.dart` header (currently
  "Serving · You"): show all joined stewards ("Serving · You, Priya"). If
  viewing another steward's table and not yet joined, show their name plus
  an inline **"Join to help"** chip — one tap emits `table:join`, no
  confirmation/PIN. A **"Leave"** action (header area or the existing "⋮"
  overflow menu) emits `table:leave`.
- Tables grid (`lib/screens/tables_screen.dart`): no structural change —
  "MINE"/"OTHER" badges and colors already exist and now reflect real data
  once the backend populates `operators`.

### D) Edge cases

- **Table freed**: `table_operators` cleared — new seating starts clean.
- **Shift**: operators move with the order to the destination table.
- **Merge**: operators from the absorbed table union into the primary table.
- **Last steward leaves an active table**: operators list goes empty → table
  falls back to "unclaimed" (existing default behavior — shows as `mine` for
  everyone, joinable, not freed or blocked).
- **Same steward, two devices**: `(table_id, operator_id)` primary key
  dedupes; joining twice is a no-op.
- **Durability**: unlike `presenceByTable`, this is persisted — a dropped
  connection or app restart does not remove someone from a table.
- **Permissions gap to verify during implementation**: need to confirm
  whether any existing backend action (void, discount, close bill) is
  currently gated specifically to `assigned_waiter_id` rather than just
  `Role.WAITER` + floor access. If so, that check must switch to "is this
  operator in `table_operators` for this table" to deliver the promised full
  parity. Not confirmed by the initial backend exploration — needs a
  targeted read of the permissions code before/during implementation.

### E) Rollout

- Backend: new idempotent migration, unit tests for
  `TableOperatorsService.join/leave` (including the auto-promote-primary
  case), and for `shiftOrder`/`mergeOrder`'s operator-list handling.
- Client: update `ServerTable`/`RestaurantTable` parsing, update/add tests
  around `_mapTableStatus()`.
- Manual QA: two devices/logins joining the same table and both seeing live
  updates; leave and rejoin; table-free clears operators; shift and merge
  correctly move/merge operator lists; the permissions gap above once
  resolved.

## Out of scope

- Changing how `presenceByTable`/`table:presence:updated` works — that
  ephemeral "who's currently viewing" concept stays as-is, separate from this
  durable "who's assigned to serve" concept.
- Any changes to the `waiters` roster table itself.
- Tip pooling / commission split logic — explicitly deferred per the "no
  primary distinction, not needed yet" decision during brainstorming.
