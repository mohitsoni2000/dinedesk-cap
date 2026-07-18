# Multi-Steward Table Join Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any steward self-join an already-occupied table to help serve a large party, with full permission parity, while keeping `orders.assigned_waiter_id` in sync for existing reports/receipts.

**Architecture:** A new durable many-to-many `table_operators` table in the backend (mirroring the existing `table_link_group_members` pattern), two new socket events (`table:join`/`table:leave`) that extend the existing `table:updated` broadcast rather than inventing a new channel, and a client-side change from single-ID equality checks to list-membership checks for "MINE" vs "OTHER" table state.

**Tech Stack:** Backend: Node/TypeScript, socket.io, raw SQLite via `better-sqlite3`, Zod, Vitest. Client: Flutter/Dart, Riverpod, socket.io-client.

**Spec:** `docs/superpowers/specs/2026-07-18-multi-steward-table-join-design.md`

---

## Backend (`/Users/mohitsoni/Desktop/Workspace/restro-desktop`)

### Task 1: `table_operators` schema, auto-clear trigger, and type fields

Table-freeing happens via a raw `UPDATE tables SET status = 'free', active_order_id = NULL ...` scattered across 10+ call sites in `tables.service.ts` and `orders.service.ts`. Rather than touching every one (high regression risk for unrelated code), a SQLite trigger enforces "operators are cleared whenever a table becomes free" as a data-lifecycle invariant, regardless of which code path frees it.

**Files:**
- Modify: `electron/database/schema-additional.ts:1634` (add migration call), `:2249` area (add new migration function near `runLinkGroupMigrations`)
- Modify: `electron/database/types.ts:353-380` (add `operators` field to `DbTable`/`DbTableWithInfo`)
- Test: `electron/database/table-operators-migration.spec.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// electron/database/table-operators-migration.spec.ts
import { describe, expect, it, beforeEach } from 'vitest';
import Database from 'better-sqlite3';
import { runMigrations } from './schema';
import { runAdditionalMigrations } from './schema-additional';

let db: Database.Database;

describe('table_operators schema', () => {
  beforeEach(() => {
    db = new Database(':memory:');
    runMigrations(db);
    runAdditionalMigrations(db);
    db.prepare(
      `INSERT INTO users (id, name, username, password, role) VALUES ('op1', 'Priya', 'priya', 'x', 'waiter')`
    ).run();
    db.prepare(
      `INSERT INTO tables (id, name, capacity, status) VALUES ('t1', 'T1', 4, 'occupied')`
    ).run();
  });

  it('creates table_operators with a composite primary key that dedupes joins', () => {
    db.prepare(`INSERT INTO table_operators (table_id, operator_id) VALUES ('t1', 'op1')`).run();
    // Same (table_id, operator_id) again must be a no-op, not a constraint error,
    // when the caller uses INSERT OR IGNORE (which the service will).
    db.prepare(
      `INSERT OR IGNORE INTO table_operators (table_id, operator_id) VALUES ('t1', 'op1')`
    ).run();
    const rows = db.prepare(`SELECT * FROM table_operators WHERE table_id = 't1'`).all();
    expect(rows).toHaveLength(1);
  });

  it('auto-clears operators when the table transitions to free', () => {
    db.prepare(`INSERT INTO table_operators (table_id, operator_id) VALUES ('t1', 'op1')`).run();
    db.prepare(`UPDATE tables SET status = 'free', active_order_id = NULL WHERE id = 't1'`).run();
    const rows = db.prepare(`SELECT * FROM table_operators WHERE table_id = 't1'`).all();
    expect(rows).toHaveLength(0);
  });

  it('does not clear operators on updates that are not a free transition', () => {
    db.prepare(`INSERT INTO table_operators (table_id, operator_id) VALUES ('t1', 'op1')`).run();
    db.prepare(`UPDATE tables SET pos_x = 5 WHERE id = 't1'`).run();
    const rows = db.prepare(`SELECT * FROM table_operators WHERE table_id = 't1'`).all();
    expect(rows).toHaveLength(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx vitest run electron/database/table-operators-migration.spec.ts`
Expected: FAIL with `SqliteError: no such table: table_operators`

- [ ] **Step 3: Add the migration**

In `electron/database/schema-additional.ts`, add a new function right after `runLinkGroupMigrations` (which ends at line 2266, just before the `billCols` block that follows it in the same function — put this as its own new top-level function instead, immediately after that function's closing `}`):

```typescript
function runTableOperatorsMigrations(db: Database.Database): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS table_operators (
      table_id    TEXT NOT NULL REFERENCES tables(id) ON DELETE CASCADE,
      operator_id TEXT NOT NULL,
      joined_at   TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (table_id, operator_id)
    );

    CREATE INDEX IF NOT EXISTS idx_table_operators_operator
      ON table_operators(operator_id);

    -- Whenever a table transitions to 'free' (bill paid, order cancelled,
    -- shifted away, etc. -- there are 10+ call sites that do this raw UPDATE
    -- across tables.service.ts/orders.service.ts), drop its operators so a
    -- new seating starts clean. This is enforced at the DB level instead of
    -- touching every call site.
    CREATE TRIGGER IF NOT EXISTS trg_table_operators_clear_on_free
    AFTER UPDATE OF status ON tables
    WHEN NEW.status = 'free' AND OLD.status != 'free'
    BEGIN
      DELETE FROM table_operators WHERE table_id = NEW.id;
    END;
  `);
  console.log('[DB] table_operators table and free-clear trigger ensured');
}
```

Then in `runAdditionalMigrations`, right after line 1634 (`runLinkGroupMigrations(db);`), add:

```typescript
  runLinkGroupMigrations(db);

  runTableOperatorsMigrations(db);

```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx vitest run electron/database/table-operators-migration.spec.ts`
Expected: PASS (3 tests)

- [ ] **Step 5: Add the `operators` field to the shared types**

In `electron/database/types.ts`, add a new exported interface right before `DbTable` (line 353) and extend both `DbTable` and `DbTableWithInfo`:

```typescript
export interface TableOperator {
  operator_id: string;
  operator_name: string;
}

export interface DbTable {
  id: string;
  name: string;
  capacity: number;
  zone: string;
  floor_id: string;
  status: 'free' | 'occupied' | 'reserved' | 'cleaning';
  pos_x: number;
  pos_y: number;
  shape: 'rectangle' | 'circle';
  active_order_id: string | null;
  is_active: number;
  is_temporary: number;
  /** For rename-split temp tables: the floor of the table the order came from. */
  origin_floor_id: string | null;
  created_at: string;
  operators: TableOperator[];
}
```

(`DbTableWithInfo extends DbTable`, so it inherits `operators` automatically — no change needed there.)

- [ ] **Step 6: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add electron/database/schema-additional.ts electron/database/types.ts electron/database/table-operators-migration.spec.ts
git commit -m "feat: add table_operators join table with auto-clear-on-free trigger"
```

---

### Task 2: `TableOperatorsService`

**Files:**
- Create: `electron/services/table-operators.service.ts`
- Test: `electron/services/table-operators.service.spec.ts`

- [ ] **Step 1: Write the failing tests**

```typescript
// electron/services/table-operators.service.spec.ts
import { describe, expect, it, vi, beforeEach } from 'vitest';
import Database from 'better-sqlite3';
import { runMigrations } from '../database/schema';
import { runAdditionalMigrations } from '../database/schema-additional';

let testDb: Database.Database;

vi.mock('../database', () => ({
  getDb: () => testDb,
}));

async function loadService() {
  const { TableOperatorsService } = await import('./table-operators.service');
  return new TableOperatorsService();
}

function seed(db: Database.Database) {
  db.prepare(
    `INSERT INTO users (id, name, username, password, role) VALUES ('op1', 'Priya', 'priya', 'x', 'waiter')`
  ).run();
  db.prepare(
    `INSERT INTO users (id, name, username, password, role) VALUES ('op2', 'Rahul', 'rahul', 'x', 'waiter')`
  ).run();
  db.prepare(
    `INSERT INTO customers (id, name) VALUES ('cust1', 'walk-in')`
  ).run();
  db.prepare(
    `INSERT INTO tables (id, name, capacity, status, active_order_id) VALUES ('t1', 'T1', 4, 'occupied', 'ord1')`
  ).run();
  db.prepare(
    `INSERT INTO orders (id, order_number, order_type, status, customer_id, created_by, table_id)
     VALUES ('ord1', 'ORD-1', 'dine_in', 'placed', 'cust1', 'op1', 't1')`
  ).run();
}

describe('TableOperatorsService', () => {
  beforeEach(() => {
    testDb = new Database(':memory:');
    runMigrations(testDb);
    runAdditionalMigrations(testDb);
    seed(testDb);
  });

  it('join() adds the operator and sets them as the order primary waiter when they are first', async () => {
    const svc = await loadService();
    svc.join('t1', 'op1');

    const ops = svc.getOperatorsForTable('t1');
    expect(ops).toEqual([{ operator_id: 'op1', operator_name: 'Priya' }]);

    const order = testDb
      .prepare('SELECT assigned_waiter_id FROM orders WHERE id = ?')
      .get('ord1') as { assigned_waiter_id: string | null };
    const waiter = testDb
      .prepare('SELECT name FROM waiters WHERE id = ?')
      .get(order.assigned_waiter_id) as { name: string } | undefined;
    expect(waiter?.name).toBe('Priya');
  });

  it('join() is idempotent when the same operator joins twice', async () => {
    const svc = await loadService();
    svc.join('t1', 'op1');
    svc.join('t1', 'op1');
    expect(svc.getOperatorsForTable('t1')).toHaveLength(1);
  });

  it('join() adds a second operator without displacing the first from assigned_waiter_id', async () => {
    const svc = await loadService();
    svc.join('t1', 'op1');
    svc.join('t1', 'op2');

    expect(svc.getOperatorsForTable('t1')).toEqual([
      { operator_id: 'op1', operator_name: 'Priya' },
      { operator_id: 'op2', operator_name: 'Rahul' },
    ]);
    const order = testDb
      .prepare('SELECT assigned_waiter_id FROM orders WHERE id = ?')
      .get('ord1') as { assigned_waiter_id: string | null };
    const waiter = testDb
      .prepare('SELECT name FROM waiters WHERE id = ?')
      .get(order.assigned_waiter_id) as { name: string } | undefined;
    expect(waiter?.name).toBe('Priya');
  });

  it('leave() auto-promotes the next-earliest joiner to assigned_waiter_id', async () => {
    const svc = await loadService();
    svc.join('t1', 'op1');
    svc.join('t1', 'op2');
    svc.leave('t1', 'op1');

    expect(svc.getOperatorsForTable('t1')).toEqual([
      { operator_id: 'op2', operator_name: 'Rahul' },
    ]);
    const order = testDb
      .prepare('SELECT assigned_waiter_id FROM orders WHERE id = ?')
      .get('ord1') as { assigned_waiter_id: string | null };
    const waiter = testDb
      .prepare('SELECT name FROM waiters WHERE id = ?')
      .get(order.assigned_waiter_id) as { name: string } | undefined;
    expect(waiter?.name).toBe('Rahul');
  });

  it('leave() nulls assigned_waiter_id when the last operator leaves', async () => {
    const svc = await loadService();
    svc.join('t1', 'op1');
    svc.leave('t1', 'op1');

    expect(svc.getOperatorsForTable('t1')).toEqual([]);
    const order = testDb
      .prepare('SELECT assigned_waiter_id FROM orders WHERE id = ?')
      .get('ord1') as { assigned_waiter_id: string | null };
    expect(order.assigned_waiter_id).toBeNull();
  });

  it('getForTables() batches operators for multiple tables keyed by table_id', async () => {
    testDb.prepare(
      `INSERT INTO tables (id, name, capacity, status) VALUES ('t2', 'T2', 4, 'free')`
    ).run();
    const svc = await loadService();
    svc.join('t1', 'op1');

    const map = svc.getForTables(['t1', 't2']);
    expect(map.get('t1')).toEqual([{ operator_id: 'op1', operator_name: 'Priya' }]);
    expect(map.get('t2')).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx vitest run electron/services/table-operators.service.spec.ts`
Expected: FAIL with `Cannot find module './table-operators.service'`

- [ ] **Step 3: Write the implementation**

```typescript
// electron/services/table-operators.service.ts
import { getDb } from '../database';
import type { TableOperator } from '../database/types';
import { OrdersService } from './orders.service';
import { WaiterService } from './waiter.service';

export class TableOperatorsService {
  private readonly ordersService = new OrdersService();
  private readonly waiterService = new WaiterService();

  /** Adds `operatorId` to the table. No-op if already joined (INSERT OR IGNORE). */
  join(tableId: string, operatorId: string): void {
    const db = getDb();
    db.transaction(() => {
      db.prepare(
        'INSERT OR IGNORE INTO table_operators (table_id, operator_id) VALUES (?, ?)'
      ).run(tableId, operatorId);
      this._syncPrimaryWaiter(tableId);
    })();
  }

  /** Removes `operatorId` from the table and re-derives the primary waiter. */
  leave(tableId: string, operatorId: string): void {
    const db = getDb();
    db.transaction(() => {
      db.prepare(
        'DELETE FROM table_operators WHERE table_id = ? AND operator_id = ?'
      ).run(tableId, operatorId);
      this._syncPrimaryWaiter(tableId);
    })();
  }

  getOperatorsForTable(tableId: string): TableOperator[] {
    return getDb()
      .prepare(
        `SELECT tops.operator_id as operator_id, u.name as operator_name
         FROM table_operators tops
         JOIN users u ON u.id = tops.operator_id
         WHERE tops.table_id = ?
         ORDER BY tops.joined_at ASC`
      )
      .all(tableId) as TableOperator[];
  }

  /** Batched read for TablesService.getAll() -- one query for N tables, not N queries. */
  getForTables(tableIds: string[]): Map<string, TableOperator[]> {
    const map = new Map<string, TableOperator[]>();
    const ids = Array.from(new Set(tableIds));
    if (ids.length === 0) return map;

    const placeholders = ids.map(() => '?').join(', ');
    const rows = getDb()
      .prepare(
        `SELECT tops.table_id as table_id, tops.operator_id as operator_id, u.name as operator_name
         FROM table_operators tops
         JOIN users u ON u.id = tops.operator_id
         WHERE tops.table_id IN (${placeholders})
         ORDER BY tops.joined_at ASC`
      )
      .all(...ids) as Array<{ table_id: string; operator_id: string; operator_name: string }>;

    for (const row of rows) {
      const op: TableOperator = { operator_id: row.operator_id, operator_name: row.operator_name };
      const list = map.get(row.table_id);
      if (list) list.push(op);
      else map.set(row.table_id, [op]);
    }
    return map;
  }

  /**
   * Re-derives orders.assigned_waiter_id from the earliest-joined remaining
   * operator on this table (or null if none remain), so receipts/reports
   * always show a real active steward. Called after every join/leave.
   * assigned_waiter_id points at the name-based `waiters` roster, a
   * different identity space from `operator_id` (users.id) -- so we resolve
   * by name rather than comparing ids directly.
   */
  private _syncPrimaryWaiter(tableId: string): void {
    const db = getDb();
    const table = db
      .prepare('SELECT active_order_id FROM tables WHERE id = ?')
      .get(tableId) as { active_order_id: string | null } | undefined;
    if (table === undefined || table.active_order_id === null) return;

    const earliest = db
      .prepare(
        `SELECT u.name as name
         FROM table_operators tops
         JOIN users u ON u.id = tops.operator_id
         WHERE tops.table_id = ?
         ORDER BY tops.joined_at ASC LIMIT 1`
      )
      .get(tableId) as { name: string } | undefined;

    if (earliest === undefined) {
      this.ordersService.assignWaiter(table.active_order_id, null);
      return;
    }
    const steward = this.waiterService.getOrCreateByName(earliest.name);
    this.ordersService.assignWaiter(table.active_order_id, steward.id);
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx vitest run electron/services/table-operators.service.spec.ts`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add electron/services/table-operators.service.ts electron/services/table-operators.service.spec.ts
git commit -m "feat: add TableOperatorsService with join/leave and primary-waiter sync"
```

---

### Task 3: Attach operators in `TablesService.getAll()`/`getById()`

**Files:**
- Modify: `electron/services/tables.service.ts:1-30` (constructor/imports), `:145-166` (`getAll`), `:167-169` (`getById`)
- Test: `electron/services/tables.service.operators.spec.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// electron/services/tables.service.operators.spec.ts
import { describe, expect, it, vi, beforeEach } from 'vitest';
import Database from 'better-sqlite3';
import { runMigrations } from '../database/schema';
import { runAdditionalMigrations } from '../database/schema-additional';

let testDb: Database.Database;

vi.mock('../database', () => ({
  getDb: () => testDb,
}));

async function loadTablesService() {
  const { TablesService } = await import('./tables.service');
  return new TablesService();
}

describe('TablesService -- operators field', () => {
  beforeEach(() => {
    testDb = new Database(':memory:');
    runMigrations(testDb);
    runAdditionalMigrations(testDb);
    testDb.prepare(
      `INSERT INTO users (id, name, username, password, role) VALUES ('op1', 'Priya', 'priya', 'x', 'waiter')`
    ).run();
    testDb.prepare(
      `INSERT INTO tables (id, name, capacity, status) VALUES ('t1', 'T1', 4, 'occupied')`
    ).run();
    testDb.prepare(
      `INSERT INTO tables (id, name, capacity, status) VALUES ('t2', 'T2', 4, 'free')`
    ).run();
    testDb
      .prepare('INSERT INTO table_operators (table_id, operator_id) VALUES (?, ?)')
      .run('t1', 'op1');
  });

  it('getAll() includes an operators array per table, empty when none joined', async () => {
    const svc = await loadTablesService();
    const rows = svc.getAll();
    const t1 = rows.find((r) => r.id === 't1');
    const t2 = rows.find((r) => r.id === 't2');
    expect(t1?.operators).toEqual([{ operator_id: 'op1', operator_name: 'Priya' }]);
    expect(t2?.operators).toEqual([]);
  });

  it('getById() includes the operators array', async () => {
    const svc = await loadTablesService();
    const row = svc.getById('t1');
    expect(row?.operators).toEqual([{ operator_id: 'op1', operator_name: 'Priya' }]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx vitest run electron/services/tables.service.operators.spec.ts`
Expected: FAIL — `t1?.operators` is `undefined`, not the expected array

- [ ] **Step 3: Wire it up**

In `electron/services/tables.service.ts`, add the import near the top (alongside the existing `attachLiveOrderTotals` import):

```typescript
import { TableOperatorsService } from './table-operators.service';
```

Add a private instance inside the `TablesService` class, alongside the existing `ordersService` field:

```typescript
  private readonly ordersService = new OrdersService();
  private readonly tableOperatorsService = new TableOperatorsService();
```

Change `getAll()` to attach operators after the existing `attachLiveOrderTotals(rows)` call:

```typescript
  getAll(includeInactive: boolean = false): DbTableWithInfo[] {
    const db = getDb();
    const where = includeInactive ? '' : 'WHERE t.is_active = 1';
    const rows = db
      .prepare(
        `
      SELECT t.*,
        (SELECT COUNT(*) FROM order_items oi WHERE oi.order_id = t.active_order_id AND oi.kot_status != 'cancelled') as order_item_count,
        (SELECT o2.created_at FROM orders o2 WHERE o2.id = t.active_order_id) as order_created_at,
        (SELECT r.customer_name FROM reservations r WHERE r.table_id = t.id AND r.status = 'confirmed' AND datetime(r.reserved_at) > datetime('now') ORDER BY r.reserved_at ASC LIMIT 1) as reservation_customer,
        (SELECT r.reserved_at FROM reservations r WHERE r.table_id = t.id AND r.status = 'confirmed' AND datetime(r.reserved_at) > datetime('now') ORDER BY r.reserved_at ASC LIMIT 1) as reservation_time,
        (SELECT CAST((julianday('now') - julianday(MIN(oi3.kot_sent_at))) * 24 * 60 AS INTEGER) FROM order_items oi3 WHERE oi3.order_id = t.active_order_id AND oi3.kot_status = 'sent') as oldest_kot_minutes,
        (SELECT COUNT(*) FROM kot_records kr WHERE kr.order_id = t.active_order_id) as kot_count,
        (SELECT COUNT(*) FROM bills b WHERE b.order_id = t.active_order_id AND b.status = 'active') as active_bill_count
      FROM tables t ${where} ORDER BY t.pos_y, t.pos_x
    `
      )
      .all() as DbTableWithInfo[];

    attachLiveOrderTotals(rows);
    const operatorsByTable = this.tableOperatorsService.getForTables(rows.map((r) => r.id));
    for (const row of rows) {
      row.operators = operatorsByTable.get(row.id) ?? [];
    }
    return rows;
  }

  getById(id: string): DbTable | undefined {
    const row = getDb().prepare('SELECT * FROM tables WHERE id = ?').get(id) as
      | DbTable
      | undefined;
    if (row === undefined) return undefined;
    row.operators = this.tableOperatorsService.getOperatorsForTable(id);
    return row;
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx vitest run electron/services/tables.service.operators.spec.ts`
Expected: PASS (2 tests)

- [ ] **Step 5: Run the full existing tables/bills test suite to check for regressions**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx vitest run electron/services/tables.service electron/services/bills.service`
Expected: All existing tests still PASS (this task only adds a field, doesn't remove/rename anything existing)

- [ ] **Step 6: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add electron/services/tables.service.ts electron/services/tables.service.operators.spec.ts
git commit -m "feat: include operators array in TablesService.getAll/getById"
```

---

### Task 4: Move operators on `shiftOrder`

The from-table's operators must move to the to-table **before** the from-table's status flips to `'free'` — otherwise the Task 1 trigger deletes them before the move happens.

**Files:**
- Modify: `electron/services/tables.service.ts:321-364` (`shiftOrder`)
- Test: `electron/services/tables.service.shift-operators.spec.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// electron/services/tables.service.shift-operators.spec.ts
import { describe, expect, it, vi, beforeEach } from 'vitest';
import Database from 'better-sqlite3';
import { runMigrations } from '../database/schema';
import { runAdditionalMigrations } from '../database/schema-additional';

let testDb: Database.Database;

vi.mock('../database', () => ({
  getDb: () => testDb,
}));

async function loadTablesService() {
  const { TablesService } = await import('./tables.service');
  return new TablesService();
}

describe('TablesService.shiftOrder -- operator transfer', () => {
  beforeEach(() => {
    testDb = new Database(':memory:');
    runMigrations(testDb);
    runAdditionalMigrations(testDb);
    testDb.prepare(
      `INSERT INTO users (id, name, username, password, role) VALUES ('op1', 'Priya', 'priya', 'x', 'waiter')`
    ).run();
    testDb.prepare(
      `INSERT INTO customers (id, name) VALUES ('cust1', 'walk-in')`
    ).run();
    testDb.prepare(
      `INSERT INTO tables (id, name, capacity, status, active_order_id) VALUES ('t1', 'T1', 4, 'occupied', 'ord1')`
    ).run();
    testDb.prepare(
      `INSERT INTO tables (id, name, capacity, status) VALUES ('t2', 'T2', 4, 'free')`
    ).run();
    testDb.prepare(
      `INSERT INTO orders (id, order_number, order_type, status, customer_id, created_by, table_id)
       VALUES ('ord1', 'ORD-1', 'dine_in', 'placed', 'cust1', 'op1', 't1')`
    ).run();
    testDb
      .prepare('INSERT INTO table_operators (table_id, operator_id) VALUES (?, ?)')
      .run('t1', 'op1');
  });

  it('moves operators from the source table to the destination table', async () => {
    const svc = await loadTablesService();
    svc.shiftOrder('ord1', 't1', 't2', 'op1');

    const t1Ops = testDb.prepare('SELECT * FROM table_operators WHERE table_id = ?').all('t1');
    const t2Ops = testDb
      .prepare('SELECT operator_id FROM table_operators WHERE table_id = ?')
      .all('t2') as Array<{ operator_id: string }>;
    expect(t1Ops).toHaveLength(0);
    expect(t2Ops.map((r) => r.operator_id)).toEqual(['op1']);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx vitest run electron/services/tables.service.shift-operators.spec.ts`
Expected: FAIL — `t2Ops` is empty (operators were deleted by the free-clear trigger, never moved)

- [ ] **Step 3: Fix `shiftOrder`**

In `electron/services/tables.service.ts`, inside the `shiftOp` transaction in `shiftOrder` (currently starts with the `UPDATE orders SET table_id = ...` line), add the operator move as the **first** statement, before the from-table is set free:

```typescript
    const shiftOp = db.transaction(() => {
      db.prepare(
        'UPDATE table_operators SET table_id = ? WHERE table_id = ?'
      ).run(toTableId, fromTableId);
      db.prepare(
        "UPDATE orders SET table_id = ?, updated_at = datetime('now'), version = version + 1 WHERE id = ?"
      ).run(toTableId, orderId);
      db.prepare("UPDATE tables SET status = 'free', active_order_id = NULL WHERE id = ?").run(
        fromTableId
      );
      db.prepare("UPDATE tables SET status = 'occupied', active_order_id = ? WHERE id = ?").run(
        orderId,
        toTableId
      );
      db.prepare(
        'INSERT INTO table_shift_log (id, order_id, from_table_id, to_table_id, shifted_by, reason) VALUES (?, ?, ?, ?, ?, ?)'
      ).run(uuid(), orderId, fromTableId, toTableId, shiftedBy, reason ?? null);
    });
    shiftOp();
```

(The destination table is guaranteed free before this runs — `isTableAvailableForNewOrder` is checked just above — so it has no pre-existing `table_operators` rows to conflict with; a plain `UPDATE ... SET table_id` is safe, no `INSERT OR IGNORE` needed.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx vitest run electron/services/tables.service.shift-operators.spec.ts`
Expected: PASS

- [ ] **Step 5: Run the existing table-shift test suite to check for regressions**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx vitest run electron/services/tables.service`
Expected: All existing tests still PASS

- [ ] **Step 6: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add electron/services/tables.service.ts electron/services/tables.service.shift-operators.spec.ts
git commit -m "fix: move table_operators to destination table on shiftOrder"
```

---

### Task 5: Merge operators on `mergeOrder`

Same trigger-ordering concern as Task 4: union the source table's operators into the destination **before** the source table is set free.

**Files:**
- Modify: `electron/services/tables.service.ts:481-565` (`mergeOrder`)
- Test: `electron/services/tables.service.merge-operators.spec.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// electron/services/tables.service.merge-operators.spec.ts
import { describe, expect, it, vi, beforeEach } from 'vitest';
import Database from 'better-sqlite3';
import { runMigrations } from '../database/schema';
import { runAdditionalMigrations } from '../database/schema-additional';

let testDb: Database.Database;

vi.mock('../database', () => ({
  getDb: () => testDb,
}));

async function loadTablesService() {
  const { TablesService } = await import('./tables.service');
  return new TablesService();
}

describe('TablesService.mergeOrder -- operator union', () => {
  beforeEach(() => {
    testDb = new Database(':memory:');
    runMigrations(testDb);
    runAdditionalMigrations(testDb);
    testDb.prepare(
      `INSERT INTO users (id, name, username, password, role) VALUES ('op1', 'Priya', 'priya', 'x', 'waiter')`
    ).run();
    testDb.prepare(
      `INSERT INTO users (id, name, username, password, role) VALUES ('op2', 'Rahul', 'rahul', 'x', 'waiter')`
    ).run();
    testDb.prepare(
      `INSERT INTO customers (id, name) VALUES ('cust1', 'walk-in')`
    ).run();
    testDb.prepare(
      `INSERT INTO tables (id, name, capacity, status, active_order_id) VALUES ('src', 'T1', 4, 'occupied', 'ordSrc')`
    ).run();
    testDb.prepare(
      `INSERT INTO tables (id, name, capacity, status, active_order_id) VALUES ('dst', 'T2', 4, 'occupied', 'ordDst')`
    ).run();
    testDb.prepare(
      `INSERT INTO orders (id, order_number, order_type, status, customer_id, created_by, table_id)
       VALUES ('ordSrc', 'ORD-1', 'dine_in', 'placed', 'cust1', 'op1', 'src')`
    ).run();
    testDb.prepare(
      `INSERT INTO orders (id, order_number, order_type, status, customer_id, created_by, table_id)
       VALUES ('ordDst', 'ORD-2', 'dine_in', 'placed', 'cust1', 'op2', 'dst')`
    ).run();
    testDb
      .prepare('INSERT INTO table_operators (table_id, operator_id) VALUES (?, ?)')
      .run('src', 'op1');
    testDb
      .prepare('INSERT INTO table_operators (table_id, operator_id) VALUES (?, ?)')
      .run('dst', 'op2');
  });

  it('unions the source table operators into the destination table', async () => {
    const svc = await loadTablesService();
    svc.mergeOrder('ordSrc', 'ordDst', 'op2');

    const dstOps = testDb
      .prepare('SELECT operator_id FROM table_operators WHERE table_id = ? ORDER BY operator_id')
      .all('dst') as Array<{ operator_id: string }>;
    expect(dstOps.map((r) => r.operator_id)).toEqual(['op1', 'op2']);

    const srcOps = testDb.prepare('SELECT * FROM table_operators WHERE table_id = ?').all('src');
    expect(srcOps).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx vitest run electron/services/tables.service.merge-operators.spec.ts`
Expected: FAIL — `dstOps` only contains `['op2']`, `op1` was dropped by the free-clear trigger

- [ ] **Step 3: Fix `mergeOrder`**

In `electron/services/tables.service.ts`, inside the `db.transaction()` block in `mergeOrder`, add the union **before** the `if (srcOrder.table_id) { ...status = 'free'... }` block:

```typescript
      db.prepare(
        "UPDATE orders SET status = 'cancelled', notes = ?, updated_at = datetime('now'), version = version + 1 WHERE id = ?"
      ).run(`Merged into ${destTableName}`.trim(), sourceOrderId);

      if (srcOrder.table_id && destOrder.table_id) {
        db.prepare(
          `INSERT OR IGNORE INTO table_operators (table_id, operator_id)
           SELECT ?, operator_id FROM table_operators WHERE table_id = ?`
        ).run(destOrder.table_id, srcOrder.table_id);
      }

      if (srcOrder.table_id) {
        db.prepare("UPDATE tables SET status = 'free', active_order_id = NULL WHERE id = ?").run(
          srcOrder.table_id
        );
      }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx vitest run electron/services/tables.service.merge-operators.spec.ts`
Expected: PASS

- [ ] **Step 5: Run the existing merge test suite to check for regressions**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx vitest run electron/services/tables.service`
Expected: All existing tests still PASS

- [ ] **Step 6: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add electron/services/tables.service.ts electron/services/tables.service.merge-operators.spec.ts
git commit -m "fix: union table_operators into destination table on mergeOrder"
```

---

### Task 6: New socket events and payload schemas

**Files:**
- Modify: `src/app/shared/types/enums.ts:302-305` (`SocketEvent`)
- Modify: `electron/server/operator-schemas.ts:178-184` (payload schemas)

- [ ] **Step 1: Add the new `SocketEvent` entries**

In `src/app/shared/types/enums.ts`, change:

```typescript
  TABLE_SHIFT = 'table:shift',
  TABLE_MERGE = 'table:merge',
  TABLE_LINK = 'table:link',
  TABLE_UNLINK = 'table:unlink',

  TABLE_PRESENCE_JOIN = 'table:presence:join',
  TABLE_PRESENCE_LEAVE = 'table:presence:leave',
```

to:

```typescript
  TABLE_SHIFT = 'table:shift',
  TABLE_MERGE = 'table:merge',
  TABLE_LINK = 'table:link',
  TABLE_UNLINK = 'table:unlink',
  TABLE_JOIN = 'table:join',
  TABLE_LEAVE = 'table:leave',

  TABLE_PRESENCE_JOIN = 'table:presence:join',
  TABLE_PRESENCE_LEAVE = 'table:presence:leave',
```

(No new `BroadcastEvent`/`RendererChannel` entries — per the spec, join/leave extend the existing `TABLE_UPDATED`/`table:updated` broadcast rather than adding a new channel.)

- [ ] **Step 2: Add the payload schemas**

In `electron/server/operator-schemas.ts`, change:

```typescript
export const TablePresenceJoinSchema = z.object({
  table_id: z.string().min(1),
});

export const TablePresenceLeaveSchema = z.object({
  table_id: z.string().min(1),
});
```

to:

```typescript
export const TableJoinPayloadSchema = z.object({
  table_id: z.string().min(1),
});

export const TableLeavePayloadSchema = z.object({
  table_id: z.string().min(1),
});

export const TablePresenceJoinSchema = z.object({
  table_id: z.string().min(1),
});

export const TablePresenceLeaveSchema = z.object({
  table_id: z.string().min(1),
});
```

And add matching type exports near the existing `TablePresenceJoin`/`TablePresenceLeave` types:

```typescript
export type TableJoinPayload = z.infer<typeof TableJoinPayloadSchema>;
export type TableLeavePayload = z.infer<typeof TableLeavePayloadSchema>;
```

- [ ] **Step 3: Type-check**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx tsc --noEmit`
Expected: No new errors (these are additive-only enum/schema entries)

- [ ] **Step 4: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add src/app/shared/types/enums.ts electron/server/operator-schemas.ts
git commit -m "feat: add table:join/table:leave socket event and payload schemas"
```

---

### Task 7: Gateway handlers for `table:join` / `table:leave`

**Files:**
- Modify: `electron/server/operator.gateway.ts:23` (import), `:204-217` (`Services` interface + `services()`), insert new handlers after the `TABLE_MERGE` handler block (immediately before the `TABLE_PRESENCE_JOIN` handler, i.e. right after the closing of `TABLE_MERGE`'s `socket.on(...)` at the point shown in the investigation, around line ~1497)

- [ ] **Step 1: Register the service**

In `electron/server/operator.gateway.ts`, add the import near the other service imports:

```typescript
import { TableOperatorsService } from '../services/table-operators.service';
```

Add it to the `Services` interface:

```typescript
interface Services {
  readonly orders: OrdersService;
  readonly tables: TablesService;
  readonly kot: KotService;
  readonly bills: BillsService;
  readonly payments: PaymentsService;
  readonly customers: CustomersService;
  readonly discounts: DiscountsService;
  readonly cancellations: CancellationsService;
  readonly packages: PackagesService;
  readonly reservations: ReservationsService;
  readonly floors: FloorsService;
  readonly tableLinks: TableLinkService;
  readonly tableOperators: TableOperatorsService;
  readonly waiters: WaiterService;
  readonly rooms: RoomsService;
  readonly offers: OffersService;
}
```

And instantiate it in `services()`:

```typescript
      tableLinks: new TableLinkService(),
      tableOperators: new TableOperatorsService(),
      waiters: new WaiterService(),
```

- [ ] **Step 2: Add the handlers**

Add the two new handlers immediately after the `TABLE_MERGE` handler's closing `});` and before the `TABLE_PRESENCE_JOIN` handler:

```typescript
    socket.on(SocketEvent.TABLE_JOIN, (rawData: unknown, ack?: AckFn) => {
      const parsed = TableJoinPayloadSchema.safeParse(rawData);
      if (!parsed.success) {
        if (ack !== undefined) return ack(fail('Invalid payload'));
        return;
      }
      const session = sessionManager.getSession(operatorId);
      if (!requireVerified(session, socket, SocketEvent.TABLE_JOIN, ack)) return;

      const { table_id } = parsed.data;
      if (!permissions.isTableAllowed(operatorId, table_id)) {
        if (ack !== undefined) return ack(fail('This table is on a floor you cannot serve'));
        return;
      }

      try {
        const svc = services();
        svc.tableOperators.join(table_id, operatorId);
        const updatedTable = svc.tables.getById(table_id);
        if (ack !== undefined) ack(ok({ table: updatedTable }));
        const floorId = floorIdForTable(table_id, svc);
        if (updatedTable !== undefined) {
          broadcaster.toFloor(floorId, BroadcastEvent.TABLE_UPDATED, updatedTable);
        }
      } catch (err: unknown) {
        const msg = errorMessage(err);
        if (ack !== undefined) return ack(fail(msg));
        socket.emit(BroadcastEvent.ERROR_VALIDATION, {
          event: SocketEvent.TABLE_JOIN,
          message: msg,
        });
      }
    });

    socket.on(SocketEvent.TABLE_LEAVE, (rawData: unknown, ack?: AckFn) => {
      const parsed = TableLeavePayloadSchema.safeParse(rawData);
      if (!parsed.success) {
        if (ack !== undefined) return ack(fail('Invalid payload'));
        return;
      }
      const session = sessionManager.getSession(operatorId);
      if (!requireVerified(session, socket, SocketEvent.TABLE_LEAVE, ack)) return;

      const { table_id } = parsed.data;
      if (!permissions.isTableAllowed(operatorId, table_id)) {
        if (ack !== undefined) return ack(fail('This table is on a floor you cannot serve'));
        return;
      }

      try {
        const svc = services();
        svc.tableOperators.leave(table_id, operatorId);
        const updatedTable = svc.tables.getById(table_id);
        if (ack !== undefined) ack(ok({ table: updatedTable }));
        const floorId = floorIdForTable(table_id, svc);
        if (updatedTable !== undefined) {
          broadcaster.toFloor(floorId, BroadcastEvent.TABLE_UPDATED, updatedTable);
        }
      } catch (err: unknown) {
        const msg = errorMessage(err);
        if (ack !== undefined) return ack(fail(msg));
        socket.emit(BroadcastEvent.ERROR_VALIDATION, {
          event: SocketEvent.TABLE_LEAVE,
          message: msg,
        });
      }
    });
```

Add the schema imports alongside the existing `TablePresenceJoinSchema`/`TablePresenceLeaveSchema` imports at the top of the file:

```typescript
  TableJoinPayloadSchema,
  TableLeavePayloadSchema,
```

- [ ] **Step 3: Type-check**

Run: `cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npx tsc --noEmit`
Expected: No errors

- [ ] **Step 4: Manual smoke test**

Start the Electron app in dev mode (`cd /Users/mohitsoni/Desktop/Workspace/restro-desktop && npm run dev` or the project's existing dev script — check `package.json` if this differs), open an order on a table from one logged-in session, then from a second session/tab emit `table:join` with that table's id via the browser devtools console (`socket.emit('table:join', { table_id: '<id>' }, console.log)`) and confirm the ack returns the table with a 2-entry `operators` array, and that the first session receives a `table:updated` broadcast reflecting it.

- [ ] **Step 5: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add electron/server/operator.gateway.ts
git commit -m "feat: wire table:join/table:leave socket handlers"
```

---

## Client (`/Users/mohitsoni/Desktop/Workspace/dinedesk-cap`)

### Task 8: `ServerTable` model — operators list

**Files:**
- Modify: `lib/models/server_models.dart:27-83`
- Test: `test/models/server_table_test.dart` (create the `test/models/` directory if it doesn't exist)

- [ ] **Step 1: Write the failing test**

```dart
// test/models/server_table_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/models/server_models.dart';

void main() {
  test('ServerTable.fromMap parses the operators array into id/name lists', () {
    final table = ServerTable.fromMap({
      'id': 't1',
      'name': 'T1',
      'capacity': 4,
      'status': 'occupied',
      'floor_id': 'f1',
      'order_total': 0,
      'operators': [
        {'operator_id': 'op1', 'operator_name': 'Priya'},
        {'operator_id': 'op2', 'operator_name': 'Rahul'},
      ],
    });

    expect(table.operatorIds, ['op1', 'op2']);
    expect(table.operatorNames, ['Priya', 'Rahul']);
  });

  test('ServerTable.fromMap defaults to empty lists when operators is absent', () {
    final table = ServerTable.fromMap({
      'id': 't1',
      'name': 'T1',
      'capacity': 4,
      'status': 'free',
      'floor_id': 'f1',
      'order_total': 0,
    });

    expect(table.operatorIds, <String>[]);
    expect(table.operatorNames, <String>[]);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap && flutter test test/models/server_table_test.dart`
Expected: FAIL — `operatorIds`/`operatorNames` getters don't exist on `ServerTable`

- [ ] **Step 3: Update `ServerTable`**

In `lib/models/server_models.dart`, replace the singular `operatorId`/`waiterName` fields (they're currently dead — the backend never populated them) with lists:

```dart
class ServerTable {
  final String id;
  final String name;
  final int capacity;
  final String status;
  final String floorId;
  final double orderTotal;
  final String? activeOrderId;
  final String? reservationCustomer;
  final String? zone;
  final int activeBillCount;
  final int orderItemCount;
  final int oldestKotMinutes;
  final int kotCount;
  final List<String> operatorIds;
  final List<String> operatorNames;

  const ServerTable({
    required this.id,
    required this.name,
    required this.capacity,
    required this.status,
    required this.floorId,
    required this.orderTotal,
    this.activeOrderId,
    this.reservationCustomer,
    this.zone,
    this.activeBillCount = 0,
    this.orderItemCount = 0,
    this.oldestKotMinutes = 0,
    this.kotCount = 0,
    this.operatorIds = const [],
    this.operatorNames = const [],
  });

  factory ServerTable.fromMap(Map<String, dynamic> m) {
    final operators = (m['operators'] is List)
        ? (m['operators'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : const <Map<String, dynamic>>[];
    return ServerTable(
      id: _toStr(m['id']),
      name: _toStr(m['name'], _toStr(m['id'])),
      capacity: _toInt(m['capacity'], 4),
      status: _toStr(m['status'], 'free'),
      floorId: _toStr(m['floor_id']),
      orderTotal: _toDouble(m['order_total']),
      activeOrderId: m['active_order_id']?.toString(),
      reservationCustomer: m['reservation_customer']?.toString(),
      zone: m['zone']?.toString(),
      activeBillCount: _toInt(m['active_bill_count']),
      orderItemCount: _toInt(m['order_item_count']),
      oldestKotMinutes: _toInt(m['oldest_kot_minutes']),
      kotCount: _toInt(m['kot_count']),
      operatorIds:
          operators.map((o) => _toStr(o['operator_id'])).toList(),
      operatorNames:
          operators.map((o) => _toStr(o['operator_name'])).toList(),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap && flutter test test/models/server_table_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: Search for and fix any other reference to the removed fields**

Run: `cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap && grep -rn "\.operatorId\b\|st\.waiterName\b" lib/ --include="*.dart"`

The only consumer (per the design spec investigation) is `_serverTableToLocal` in `lib/services/sync_service.dart`, which Task 10 updates. If this search turns up any other reference, update it there before proceeding — do not leave a dangling reference to the removed fields.

- [ ] **Step 6: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/models/server_models.dart test/models/server_table_test.dart
git commit -m "feat: parse operators list on ServerTable instead of dead single operatorId field"
```

---

### Task 9: `RestaurantTable` model — joined operators

**Files:**
- Modify: `lib/data/providers.dart:14-90` (`RestaurantTable`)
- Test: `test/data/restaurant_table_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/data/restaurant_table_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';

void main() {
  test('RestaurantTable.copyWith replaces joinedOperatorNames', () {
    const table = RestaurantTable(
      id: 'T1',
      serverId: 't1',
      seats: 4,
      floor: 'Ground',
      state: TableState.mine,
      joinedOperatorNames: ['Priya'],
    );

    final updated = table.copyWith(joinedOperatorNames: ['Priya', 'Rahul']);

    expect(updated.joinedOperatorNames, ['Priya', 'Rahul']);
    expect(table.joinedOperatorNames, ['Priya']); // original unchanged
  });

  test('RestaurantTable defaults joinedOperatorNames to an empty list', () {
    const table = RestaurantTable(
      id: 'T1',
      serverId: 't1',
      seats: 4,
      floor: 'Ground',
      state: TableState.free,
    );

    expect(table.joinedOperatorNames, <String>[]);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap && flutter test test/data/restaurant_table_test.dart`
Expected: FAIL — no `joinedOperatorNames` named parameter on `RestaurantTable`

- [ ] **Step 3: Update `RestaurantTable`**

In `lib/data/providers.dart`, replace the singular `waiterName` field with `joinedOperatorNames` (the display list) — the class also needs the raw operator-id list to do "am I on this table" membership checks in Task 10, so add both:

```dart
class RestaurantTable {
  static const _absent = Object();

  final String id;
  final String serverId;
  final int seats;
  final String floor;
  final TableState state;
  final List<String> joinedOperatorIds;
  final List<String> joinedOperatorNames;
  final int? coverCount;
  final double? bill;
  final String? note;
  final String? activeOrderId;
  final int activeBillCount;
  final int orderItemCount;
  final int oldestKotMinutes;
  final int kotCount;
  final DateTime? occupiedSince;
  const RestaurantTable({
    required this.id,
    required this.serverId,
    required this.seats,
    required this.floor,
    required this.state,
    this.joinedOperatorIds = const [],
    this.joinedOperatorNames = const [],
    this.coverCount,
    this.bill,
    this.note,
    this.activeOrderId,
    this.activeBillCount = 0,
    this.orderItemCount = 0,
    this.oldestKotMinutes = 0,
    this.kotCount = 0,
    this.occupiedSince,
  });

  RestaurantTable copyWith({
    String? id,
    String? serverId,
    int? seats,
    String? floor,
    TableState? state,
    List<String>? joinedOperatorIds,
    List<String>? joinedOperatorNames,
    Object? coverCount = _absent,
    Object? bill = _absent,
    Object? note = _absent,
    Object? activeOrderId = _absent,
    int? activeBillCount,
    int? orderItemCount,
    int? oldestKotMinutes,
    int? kotCount,
    Object? occupiedSince = _absent,
  }) {
    return RestaurantTable(
      id: id ?? this.id,
      serverId: serverId ?? this.serverId,
      seats: seats ?? this.seats,
      floor: floor ?? this.floor,
      state: state ?? this.state,
      joinedOperatorIds: joinedOperatorIds ?? this.joinedOperatorIds,
      joinedOperatorNames: joinedOperatorNames ?? this.joinedOperatorNames,
      coverCount:
          coverCount == _absent ? this.coverCount : coverCount as int?,
      bill: bill == _absent ? this.bill : bill as double?,
      note: note == _absent ? this.note : note as String?,
      activeOrderId: activeOrderId == _absent
          ? this.activeOrderId
          : activeOrderId as String?,
      activeBillCount: activeBillCount ?? this.activeBillCount,
      orderItemCount: orderItemCount ?? this.orderItemCount,
      oldestKotMinutes: oldestKotMinutes ?? this.oldestKotMinutes,
      kotCount: kotCount ?? this.kotCount,
      occupiedSince: occupiedSince == _absent
          ? this.occupiedSince
          : occupiedSince as DateTime?,
    );
  }
}
```

(This mirrors the existing `copyWith` field-by-field exactly — check the current file's remaining fields/lines below 90 aren't duplicated; the class ends where the existing `copyWith` closes today. If the real file's `copyWith` has additional fields beyond what's shown in this plan's earlier read of the file — re-verify against the live file before editing, since the file may have grown since this plan was written, and preserve every existing field.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap && flutter test test/data/restaurant_table_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/data/providers.dart test/data/restaurant_table_test.dart
git commit -m "feat: replace RestaurantTable.waiterName with joined-operators lists"
```

---

### Task 10: `_mapTableStatus` — list-membership instead of equality

**Files:**
- Modify: `lib/services/sync_service.dart:637-670` (`_serverTableToLocal`), `:842-860` (`_mapTableStatus`)
- Test: `test/services/sync_service_map_table_status_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/services/sync_service_map_table_status_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/services/sync_service.dart';

void main() {
  group('mapTableStatus (list-membership)', () {
    test('mine when the current operator is anywhere in the operators list', () {
      expect(
        mapTableStatus('occupied', 'op2', ['op1', 'op2']),
        TableState.mine,
      );
    });

    test('other when occupied and current operator is not in the list', () {
      expect(
        mapTableStatus('occupied', 'op3', ['op1', 'op2']),
        TableState.other,
      );
    });

    test('mine when occupied and the operators list is empty (unclaimed)', () {
      expect(
        mapTableStatus('occupied', 'op1', []),
        TableState.mine,
      );
    });

    test('dirty/reserved/free are unaffected by the operators list', () {
      expect(mapTableStatus('cleaning', 'op1', ['op2']), TableState.dirty);
      expect(mapTableStatus('reserved', 'op1', ['op2']), TableState.reserved);
      expect(mapTableStatus('free', 'op1', ['op2']), TableState.free);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap && flutter test test/services/sync_service_map_table_status_test.dart`
Expected: FAIL — `mapTableStatus` doesn't exist as a top-level/exported function (it's currently a private method `_mapTableStatus` on the sync service class)

- [ ] **Step 3: Extract and update the logic**

In `lib/services/sync_service.dart`, change the private instance method:

```dart
  TableState _mapTableStatus(
      String status, String? currentOperatorId, String? tableOperatorId) {
    switch (status.toLowerCase()) {
      case 'dirty':
      case 'cleaning':
        return TableState.dirty;
      case 'reserved':
        return TableState.reserved;
      case 'occupied':

        if (currentOperatorId != null &&
            tableOperatorId != null &&
            tableOperatorId.isNotEmpty &&
            tableOperatorId != currentOperatorId) {
          return TableState.other;
        }
        return TableState.mine;
      default:
        return TableState.free;
    }
  }
```

into a top-level function (so it's directly unit-testable without constructing the whole `SyncService`), and update the call site to use it:

```dart
TableState mapTableStatus(
    String status, String? currentOperatorId, List<String> tableOperatorIds) {
  switch (status.toLowerCase()) {
    case 'dirty':
    case 'cleaning':
      return TableState.dirty;
    case 'reserved':
      return TableState.reserved;
    case 'occupied':
      if (currentOperatorId != null &&
          tableOperatorIds.isNotEmpty &&
          !tableOperatorIds.contains(currentOperatorId)) {
        return TableState.other;
      }
      return TableState.mine;
    default:
      return TableState.free;
  }
}
```

Then, inside the `SyncService` class, update `_serverTableToLocal` to call the top-level function and pass through the new lists:

```dart
  RestaurantTable _serverTableToLocal(ServerTable st) {
    final floorName = _floorMap[st.floorId] ?? st.floorId;
    final currentOperatorId = _ref.read(operatorProvider)?.username;
    final tableState =
        mapTableStatus(st.status, currentOperatorId, st.operatorIds);

    DateTime? occupiedSince;
    if (tableState == TableState.mine) {
      final existing = _ref
          .read(tablesProvider)
          .where((t) => t.serverId == st.id)
          .firstOrNull;
      occupiedSince =
          existing?.occupiedSince ?? _tableTimerCache[st.id] ?? DateTime.now();
      unawaited(_stampTableTimer(st.id));
    } else {
      unawaited(_clearTableTimer(st.id));
      _tableTimerCache.remove(st.id);
    }

    return RestaurantTable(
      id: st.name,
      serverId: st.id,
      seats: st.capacity,
      floor: floorName,
      state: tableState,
      joinedOperatorIds: st.operatorIds,
      joinedOperatorNames: st.operatorNames,
      bill: st.orderTotal > 0 ? st.orderTotal : null,
      note: st.reservationCustomer,
      activeOrderId: st.activeOrderId,
      activeBillCount: st.activeBillCount,
      orderItemCount: st.orderItemCount,
      oldestKotMinutes: st.oldestKotMinutes,
      kotCount: st.kotCount,
      occupiedSince: occupiedSince,
    );
  }
```

Remove the now-unused private `_mapTableStatus` method (replaced by the top-level `mapTableStatus`).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap && flutter test test/services/sync_service_map_table_status_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Run the full test suite and `flutter analyze` to check for regressions**

Run: `cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap && flutter analyze && flutter test`
Expected: No new analyzer errors; all tests pass

- [ ] **Step 6: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/services/sync_service.dart test/services/sync_service_map_table_status_test.dart
git commit -m "refactor: mapTableStatus checks operator-list membership, not single-id equality"
```

---

### Task 11: "Join to help" / "Leave" actions on the order builder header

**Files:**
- Modify: `lib/screens/order_builder_screen.dart:462-486` (header `subLine` logic + the widget that renders it)

- [ ] **Step 1: Locate the header render site**

Run: `cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap && grep -n "subLine" lib/screens/order_builder_screen.dart`

Find where the `subLine` string computed at lines 465-486 is actually rendered as a `Text` widget further down in the same `build` method — this is where the "Join to help" chip needs to sit alongside it. Read that render site's surrounding ~20 lines before editing, to match its existing styling (padding, text style) rather than guessing.

- [ ] **Step 2: Update the subLine text to list every joined steward**

Replace the existing subLine computation:

```dart
    final String subLine;
    if (widget.isRoom) {
      subLine = (room?.guestName != null && room!.guestName!.isNotEmpty)
          ? 'Serving · ${room.guestName}'
          : 'New order';
    } else if (table != null) {
      final guests =
          table.coverCount != null ? ' · ${table.coverCount} guests' : '';
      switch (table.state) {
        case TableState.mine:
          subLine = 'Serving · ${(opName ?? 'You').split(' ').first} (you)$guests';
        case TableState.other:
          subLine =
              'Serving · ${table.waiterName ?? 'another waiter'}$guests';
        case TableState.reserved:
          subLine = table.note ?? 'Reserved';
        default:
          subLine = 'New order';
      }
    } else {
      subLine = 'New order';
    }
```

with:

```dart
    final String subLine;
    if (widget.isRoom) {
      subLine = (room?.guestName != null && room!.guestName!.isNotEmpty)
          ? 'Serving · ${room.guestName}'
          : 'New order';
    } else if (table != null) {
      final guests =
          table.coverCount != null ? ' · ${table.coverCount} guests' : '';
      switch (table.state) {
        case TableState.mine:
          final myFirstName = (opName ?? 'You').split(' ').first;
          final otherNames = table.joinedOperatorNames
              .where((n) => n.split(' ').first != myFirstName)
              .toList();
          final names = [myFirstName, ...otherNames];
          subLine = 'Serving · ${names.join(', ')}$guests';
        case TableState.other:
          final names = table.joinedOperatorNames.isNotEmpty
              ? table.joinedOperatorNames.join(', ')
              : 'another waiter';
          subLine = 'Serving · $names$guests';
        case TableState.reserved:
          subLine = table.note ?? 'Reserved';
        default:
          subLine = 'New order';
      }
    } else {
      subLine = 'New order';
    }
```

- [ ] **Step 3: Add the "Join to help" chip for `TableState.other`**

Find the widget that renders `subLine` as text (from Step 1's search) and, immediately after it, conditionally render a join chip when the table isn't yours yet:

```dart
if (table != null &&
    table.state == TableState.other &&
    !widget.isRoom)
  Padding(
    padding: const EdgeInsets.only(top: 6),
    child: GestureDetector(
      onTap: () async {
        final response = await ref.read(socketServiceProvider).emitAck(
          'table:join',
          {'table_id': table.serverId},
        );
        if (response['kind'] == 'error') {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(SnackBar(
              content: Text(
                  response['message']?.toString() ?? 'Could not join table'),
            ));
          return;
        }
        ref.read(syncServiceProvider).applyTableAck(response);
      },
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.terra.withValues(alpha: 0.12),
          borderRadius: const BorderRadius.all(AppRadii.pill),
        ),
        child: Text('Join to help',
            style: AppTypography.caption
                .copyWith(color: AppColors.terra, fontWeight: FontWeight.w700)),
      ),
    ),
  ),
```

This calls `ref.read(syncServiceProvider).applyTableAck(response)` — a new method needed on `SyncService` to fold a single updated table (the `{ table: {...} }` ack shape from the backend's `table:join`/`table:leave` handlers) back into `tablesProvider`. Add it now, in `lib/services/sync_service.dart`, near the existing `applyOrderAck`:

```dart
  void applyTableAck(Map<String, dynamic> response) {
    final raw = response['table'];
    if (raw is! Map) return;
    final st = ServerTable.fromMap(Map<String, dynamic>.from(raw));
    final updated = _serverTableToLocal(st);
    final tables = [..._ref.read(tablesProvider)];
    final idx = tables.indexWhere((t) => t.serverId == updated.serverId);
    if (idx == -1) return;
    tables[idx] = updated;
    _ref.read(tablesProvider.notifier).state = tables;
  }
```

(This mirrors the existing pattern at `sync_service.dart:55` — `tables.indexWhere((t) => t.serverId == updated.serverId)` — used elsewhere in the same file for single-table updates.)

- [ ] **Step 4: Add a "Leave" action for joined (non-solo) stewards**

In the same header area, add a leave affordance visible only when you're on the table AND at least one other steward is also on it (leaving a table you're the only one on doesn't make sense as a distinct action — you'd just navigate away):

```dart
if (table != null &&
    table.state == TableState.mine &&
    table.joinedOperatorIds.length > 1 &&
    !widget.isRoom)
  Padding(
    padding: const EdgeInsets.only(top: 6),
    child: GestureDetector(
      onTap: () async {
        final response = await ref.read(socketServiceProvider).emitAck(
          'table:leave',
          {'table_id': table.serverId},
        );
        if (response['kind'] == 'error') {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(SnackBar(
              content: Text(
                  response['message']?.toString() ?? 'Could not leave table'),
            ));
          return;
        }
        ref.read(syncServiceProvider).applyTableAck(response);
      },
      child: Text('Leave this table',
          style: AppTypography.caption
              .copyWith(color: context.palette.ink50, decoration: TextDecoration.underline)),
    ),
  ),
```

- [ ] **Step 5: Manual verification (no widget-test harness exists for this screen today)**

Run: `cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap && flutter analyze`
Expected: No new errors.

Then run the app on an emulator/simulator against the updated backend (Tasks 1-7 must be running), open a table as one operator, join it from a second logged-in device/session, and confirm: (a) the header on the second device shows "Join to help" before joining and switches to "Serving · You, Priya" (or similar) after; (b) the first device's header live-updates to include the second steward's name via the `table:updated` broadcast; (c) the "Leave this table" action appears only once 2+ stewards are on the table, and removes the leaving steward from both devices' headers.

- [ ] **Step 6: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/screens/order_builder_screen.dart lib/services/sync_service.dart
git commit -m "feat: add Join to help / Leave this table actions to order builder header"
```

---

## Self-review notes (from writing this plan)

- **Spec coverage:** Section A (data model) → Tasks 1-3, 8-9. Section B (socket contract) → Tasks 6-7. Section C (UI/UX) → Task 11. Section D edge cases: table-freed → Task 1's trigger; shift → Task 4; merge → Task 5; last-steward-leaves → covered by Task 2's `leave()` test (`nulls assigned_waiter_id when the last operator leaves`) plus Task 10's `mapTableStatus` test (`mine when ... operators list is empty`); same-steward-two-devices → Task 2's idempotent-join test; durability → inherent to using a real table, no separate task needed. Section E rollout → the test at the end of each task plus Task 11 Step 5's manual multi-device QA.
- **Known gap carried over from the spec, not resolved by this plan:** whether any backend action (void, discount, close bill) is currently gated to `assigned_waiter_id` specifically rather than `Role.WAITER` + floor access. This plan does not add that check anywhere because it wasn't found during investigation — if a targeted grep for `assigned_waiter_id` in the permissions/discount/bill services turns up such a gate before or during implementation, add a task to switch it to a `table_operators` membership check.
- **`renameTable`/table-split is intentionally untouched** — out of scope per the spec, which only calls out shift and merge.

## Post-implementation correction (found during Task 7 code review)

Task 7's original handler code above (both `TABLE_JOIN` and `TABLE_LEAVE`) included `if (!requireRoleAllowed(session, socket, SocketEvent.TABLE_JOIN/TABLE_LEAVE, ack, [Role.WAITER])) return;`, copied verbatim from the `TABLE_SHIFT`/`TABLE_MERGE` template. This was a bug in the plan itself: `requireRoleAllowed`'s role-list parameter is a **deny-list** (it rejects sessions whose role IS in the list), and every other `[Role.WAITER]` call site in the gateway is a supervisor-only action correctly excluding plain waitstaff. But `table:join`/`table:leave` are self-serve actions meant to be used BY Role.WAITER sessions per this plan's own design decisions — so this check would have rejected the exact users the feature is for. Code review caught this before it shipped; the fix (applied in commit `db502d7`, and reflected in the handler code above) is to drop the `requireRoleAllowed` check entirely for these two events, matching the existing `TABLE_PRESENCE_JOIN`/`TABLE_PRESENCE_LEAVE` handlers' precedent (`requireVerified` + `permissions.isTableAllowed` only, no role gate).

## Post-implementation correction (found during Task 8 code review)

Task 8's original `ServerTable.fromMap` code above parsed `operators` via `(m['operators'] as List?)?.cast<Map<String, dynamic>>()`, which throws a `TypeError` if `operators` is present but not a list, or if any entry in the list isn't a `Map` — inconsistent with this same file's established defensive-parsing convention (`ServerOrder.fromMap`'s `items` field and `BroadcastEnvelope.tablesList`/`roomsList` all use `whereType<Map>().map(Map<String,dynamic>.from)` to silently skip malformed entries instead of throwing). Since `fromMap` runs per-table inside a loop over a socket broadcast, one malformed `operators` entry on a single table could throw and take down the whole real-time table-list refresh. Code review caught this before it shipped; the fix (applied in commit `581300d`, and reflected in the code above) matches the file's existing convention.
