# Real-Time Cap-Desktop Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect Flutter Cap (waiter) app to Electron Desktop POS via Socket.IO on LAN for real-time order management, with Admin Panel feature flags flowing through Desktop to all Caps.

**Architecture:** Desktop runs a Socket.IO server on port 8080 (LAN). Each operator gets a unique QR code containing the Desktop's LAN IP + JWT token. Cap scans QR, connects via Socket.IO, verifies PIN, receives initial data sync, then operates in real-time. Desktop remains the single source of truth (SQLite DB). All Cap writes go through Desktop for validation and broadcast to other connected Caps.

**Tech Stack:** Electron (TypeScript) + Socket.IO server, Flutter (Dart) + socket_io_client, existing SQLite + better-sqlite3, JWT auth, QR code pairing

**Spec:** `docs/superpowers/specs/2026-05-13-realtime-cap-desktop-sync-design.md`

---

## File Structure

### Desktop — New Files (`/Users/mohitsoni/Desktop/Workspace/restro-desktop`)

| File | Responsibility |
|------|---------------|
| `electron/server/operator-server.ts` | Socket.IO server lifecycle (start/stop on port 8080), LAN IP detection |
| `electron/server/session-manager.ts` | JWT token create/validate/revoke, one-operator-one-device enforcement |
| `electron/server/qr-manager.ts` | Generate QR data string per operator, list connected devices |
| `electron/server/operator.gateway.ts` | All Socket.IO event handlers (auth, orders, KOT, bills, etc.) |
| `electron/server/sync-broadcaster.ts` | Room-based broadcast helpers (toAll, toOperator, toTableWatchers) |

### Desktop — Modified Files

| File | Changes |
|------|---------|
| `package.json` | Add `socket.io` server dependency |
| `electron/main.ts` | Start operator server after DB init (~line 405) |
| `electron/ipc/handlers.ts` | Add IPC handlers for QR management (generate, revoke, list devices) |
| `electron/services/socket-sync.service.ts` | Relay `config:push` from admin to sync-broadcaster |

### Cap — New Files (`/Users/mohitsoni/Desktop/Workspace/dinedesk-cap`)

| File | Responsibility |
|------|---------------|
| `lib/services/socket_service.dart` | Socket.IO connection manager (connect, disconnect, emit, reconnect) |
| `lib/services/session_service.dart` | Token/host/port persistence in SharedPreferences |
| `lib/services/sync_service.dart` | Register event listeners, map socket events to Riverpod providers |
| `lib/models/feature_flags.dart` | FeatureFlags data class parsed from Desktop flags |

### Cap — Modified Files

| File | Changes |
|------|---------|
| `pubspec.yaml` | Add socket_io_client, shared_preferences, connectivity_plus |
| `lib/data/providers.dart` | Remove mock fixtures, make providers accept real data, add flagsProvider |
| `lib/main.dart` | No changes needed (ProviderScope already wraps app) |
| `lib/router.dart` | Add reconnect redirect logic for stored sessions |
| `lib/screens/qr_scan_screen.dart` | Parse real QR URI, store host/port/token via session_service |
| `lib/screens/connecting_screen.dart` | Real Socket.IO connect instead of timer simulation |
| `lib/screens/auth_screen.dart` | Real PIN verify via socket event, receive operator data |
| `lib/screens/tables_screen.dart` | Remove mock state mutations, emit socket events instead |
| `lib/screens/order_review_screen.dart` | Send real KOT via socket, handle response |
| `lib/widgets/connection_banner.dart` | Listen to real socket connection state |

---

## Task 1: Install Socket.IO Server in Desktop

**Files:**
- Modify: `/Users/mohitsoni/Desktop/Workspace/restro-desktop/package.json`

- [ ] **Step 1: Install socket.io server package**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
npm install socket.io@^4.8.3
```

Note: The project already has `socket.io-client@^4.8.3`. The server package (`socket.io`) is what we need to ADD.

- [ ] **Step 2: Verify installation**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
node -e "const { Server } = require('socket.io'); console.log('socket.io server OK');"
```

Expected: `socket.io server OK`

- [ ] **Step 3: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add package.json package-lock.json
git commit -m "chore: add socket.io server dependency for Cap real-time sync"
```

---

## Task 2: Create Session Manager

**Files:**
- Create: `/Users/mohitsoni/Desktop/Workspace/restro-desktop/electron/server/session-manager.ts`

- [ ] **Step 1: Create the session manager**

```typescript
// electron/server/session-manager.ts
import jwt from 'jsonwebtoken';
import { v4 as uuid } from 'uuid';
import { AuthService } from '../services/auth.service';

const SERVER_JWT_SECRET = 'dinedesk-operator-server-secret';

export interface OperatorSession {
  operatorId: string;
  operatorName: string;
  tokenId: string;
  socketId: string | null;
  pinVerified: boolean;
  connectedAt: string | null;
  role: string;
  maxDiscountPct: number | null;
  maxDiscountFlat: number | null;
}

export interface TokenPayload {
  operator_id: string;
  operator_name: string;
  token_id: string;
  iat: number;
}

export class SessionManager {
  private sessions = new Map<string, OperatorSession>();
  private tokenIdToOperatorId = new Map<string, string>();
  private authService = new AuthService();

  createToken(operatorId: string, operatorName: string): string {
    const tokenId = uuid();
    const payload: Omit<TokenPayload, 'iat'> = {
      operator_id: operatorId,
      operator_name: operatorName,
      token_id: tokenId,
    };
    const token = jwt.sign(payload, SERVER_JWT_SECRET);

    // Revoke any existing session for this operator
    const existing = this.sessions.get(operatorId);
    if (existing) {
      this.tokenIdToOperatorId.delete(existing.tokenId);
    }

    this.sessions.set(operatorId, {
      operatorId,
      operatorName,
      tokenId,
      socketId: null,
      pinVerified: false,
      connectedAt: null,
      role: 'operator',
      maxDiscountPct: null,
      maxDiscountFlat: null,
    });
    this.tokenIdToOperatorId.set(tokenId, operatorId);

    return token;
  }

  validateToken(token: string): TokenPayload | null {
    try {
      const decoded = jwt.verify(token, SERVER_JWT_SECRET) as TokenPayload;
      const operatorId = this.tokenIdToOperatorId.get(decoded.token_id);
      if (!operatorId) return null;
      const session = this.sessions.get(operatorId);
      if (!session || session.tokenId !== decoded.token_id) return null;
      return decoded;
    } catch {
      return null;
    }
  }

  onSocketConnected(operatorId: string, socketId: string): string | null {
    const session = this.sessions.get(operatorId);
    if (!session) return null;

    // Return old socketId if there was one (for force-disconnect)
    const oldSocketId = session.socketId;
    session.socketId = socketId;
    session.pinVerified = false;
    session.connectedAt = new Date().toISOString();
    return oldSocketId;
  }

  verifyPin(operatorId: string, pin: string): OperatorSession | null {
    const session = this.sessions.get(operatorId);
    if (!session) return null;

    const result = this.authService.pinLogin(pin);
    if (result.kind !== 'success') return null;

    // Verify that the PIN belongs to the operator from the token
    if (result.user.id !== operatorId) return null;

    session.pinVerified = true;
    session.role = result.user.role;
    return session;
  }

  isVerified(operatorId: string): boolean {
    return this.sessions.get(operatorId)?.pinVerified ?? false;
  }

  getSession(operatorId: string): OperatorSession | null {
    return this.sessions.get(operatorId) ?? null;
  }

  getSessionBySocketId(socketId: string): OperatorSession | null {
    for (const session of this.sessions.values()) {
      if (session.socketId === socketId) return session;
    }
    return null;
  }

  revokeToken(operatorId: string): string | null {
    const session = this.sessions.get(operatorId);
    if (!session) return null;
    const socketId = session.socketId;
    this.tokenIdToOperatorId.delete(session.tokenId);
    this.sessions.delete(operatorId);
    return socketId;
  }

  onSocketDisconnected(socketId: string): void {
    for (const session of this.sessions.values()) {
      if (session.socketId === socketId) {
        session.socketId = null;
        session.pinVerified = false;
        session.connectedAt = null;
        break;
      }
    }
  }

  getConnectedDevices(): Array<{
    operatorId: string;
    operatorName: string;
    connected: boolean;
    pinVerified: boolean;
    connectedAt: string | null;
  }> {
    return Array.from(this.sessions.values()).map((s) => ({
      operatorId: s.operatorId,
      operatorName: s.operatorName,
      connected: s.socketId !== null,
      pinVerified: s.pinVerified,
      connectedAt: s.connectedAt,
    }));
  }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add electron/server/session-manager.ts
git commit -m "feat: add session manager for Cap operator authentication"
```

---

## Task 3: Create QR Manager

**Files:**
- Create: `/Users/mohitsoni/Desktop/Workspace/restro-desktop/electron/server/qr-manager.ts`

The project already has `qrcode` package installed.

- [ ] **Step 1: Create QR manager**

```typescript
// electron/server/qr-manager.ts
import { getDb } from '../database';
import { SessionManager } from './session-manager';

interface OperatorForQr {
  id: string;
  name: string;
  pin: string | null;
  is_active: number;
  role: string;
}

export class QrManager {
  constructor(
    private sessionManager: SessionManager,
    private getPort: () => number,
    private getLanIp: () => string
  ) {}

  generateQrData(operatorId: string): string | null {
    const db = getDb();
    const user = db
      .prepare('SELECT id, name, pin, is_active, role FROM users WHERE id = ?')
      .get(operatorId) as OperatorForQr | undefined;

    if (!user || !user.is_active || !user.pin) return null;

    const token = this.sessionManager.createToken(user.id, user.name);
    const host = this.getLanIp();
    const port = this.getPort();

    return `restroapp://pair?host=${host}&port=${port}&token=${token}`;
  }

  getOperatorsForPairing(): Array<{
    id: string;
    name: string;
    hasPinSet: boolean;
    isActive: boolean;
    role: string;
    connected: boolean;
    pinVerified: boolean;
    connectedAt: string | null;
  }> {
    const db = getDb();
    const users = db
      .prepare("SELECT id, name, pin, is_active, role FROM users WHERE role = 'operator' OR role = 'admin'")
      .all() as OperatorForQr[];

    const devices = this.sessionManager.getConnectedDevices();
    const deviceMap = new Map(devices.map((d) => [d.operatorId, d]));

    return users.map((u) => {
      const device = deviceMap.get(u.id);
      return {
        id: u.id,
        name: u.name,
        hasPinSet: u.pin !== null && u.pin !== '',
        isActive: u.is_active === 1,
        role: u.role,
        connected: device?.connected ?? false,
        pinVerified: device?.pinVerified ?? false,
        connectedAt: device?.connectedAt ?? null,
      };
    });
  }

  revokeOperator(operatorId: string): string | null {
    return this.sessionManager.revokeToken(operatorId);
  }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add electron/server/qr-manager.ts
git commit -m "feat: add QR manager for per-operator pairing codes"
```

---

## Task 4: Create Sync Broadcaster

**Files:**
- Create: `/Users/mohitsoni/Desktop/Workspace/restro-desktop/electron/server/sync-broadcaster.ts`

- [ ] **Step 1: Create broadcaster**

```typescript
// electron/server/sync-broadcaster.ts
import type { Namespace } from 'socket.io';

export class SyncBroadcaster {
  private nsp: Namespace | null = null;

  setNamespace(nsp: Namespace): void {
    this.nsp = nsp;
  }

  toAll(event: string, data: unknown): void {
    this.nsp?.to('all').emit(event, data);
  }

  toOperator(operatorId: string, event: string, data: unknown): void {
    this.nsp?.to(`operator:${operatorId}`).emit(event, data);
  }

  toTableWatchers(tableId: string, event: string, data: unknown): void {
    this.nsp?.to(`table:${tableId}`).emit(event, data);
  }

  /** Notify Angular renderer via IPC that data changed (so Desktop UI also updates) */
  private mainWindow: Electron.BrowserWindow | null = null;

  setMainWindow(win: Electron.BrowserWindow): void {
    this.mainWindow = win;
  }

  notifyRenderer(channel: string, data: unknown): void {
    this.mainWindow?.webContents.send(channel, data);
  }
}

// Singleton instance — imported by services and gateway
export const broadcaster = new SyncBroadcaster();
```

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add electron/server/sync-broadcaster.ts
git commit -m "feat: add sync broadcaster for room-based Cap notifications"
```

---

## Task 5: Create Operator Server

**Files:**
- Create: `/Users/mohitsoni/Desktop/Workspace/restro-desktop/electron/server/operator-server.ts`

- [ ] **Step 1: Create the server**

```typescript
// electron/server/operator-server.ts
import { createServer } from 'http';
import { Server } from 'socket.io';
import { networkInterfaces } from 'os';
import { SessionManager } from './session-manager';
import { QrManager } from './qr-manager';
import { broadcaster } from './sync-broadcaster';

const DEFAULT_PORT = 8080;

export class OperatorServer {
  private httpServer = createServer();
  private io: Server;
  private port = DEFAULT_PORT;
  private lanIp = '127.0.0.1';

  readonly sessionManager = new SessionManager();
  readonly qrManager: QrManager;

  constructor() {
    this.io = new Server(this.httpServer, {
      cors: { origin: '*' },
      transports: ['websocket', 'polling'],
    });

    this.lanIp = this.detectLanIp();

    this.qrManager = new QrManager(
      this.sessionManager,
      () => this.port,
      () => this.lanIp
    );
  }

  async start(port: number = DEFAULT_PORT): Promise<void> {
    this.port = port;
    return new Promise((resolve, reject) => {
      this.httpServer.listen(this.port, '0.0.0.0', () => {
        console.log(`[OperatorServer] Listening on ${this.lanIp}:${this.port}`);
        const nsp = this.io.of('/operator');
        broadcaster.setNamespace(nsp);
        resolve();
      });
      this.httpServer.on('error', (err: NodeJS.ErrnoException) => {
        if (err.code === 'EADDRINUSE') {
          console.warn(`[OperatorServer] Port ${this.port} in use, trying ${this.port + 1}`);
          this.port += 1;
          this.httpServer.listen(this.port, '0.0.0.0');
        } else {
          reject(err);
        }
      });
    });
  }

  getNamespace() {
    return this.io.of('/operator');
  }

  stop(): void {
    this.io.close();
    this.httpServer.close();
    console.log('[OperatorServer] Stopped');
  }

  getPort(): number {
    return this.port;
  }

  getLanIp(): string {
    return this.lanIp;
  }

  private detectLanIp(): string {
    const nets = networkInterfaces();
    for (const name of Object.keys(nets)) {
      for (const net of nets[name] ?? []) {
        if (net.family === 'IPv4' && !net.internal) {
          return net.address;
        }
      }
    }
    return '127.0.0.1';
  }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add electron/server/operator-server.ts
git commit -m "feat: add operator server with Socket.IO on LAN port 8080"
```

---

## Task 6: Create Operator Gateway (Event Handlers)

**Files:**
- Create: `/Users/mohitsoni/Desktop/Workspace/restro-desktop/electron/server/operator.gateway.ts`

This is the largest file — all Socket.IO event handlers. It reuses existing Desktop services.

- [ ] **Step 1: Create the gateway**

```typescript
// electron/server/operator.gateway.ts
import type { Namespace, Socket } from 'socket.io';
import { SessionManager } from './session-manager';
import { broadcaster } from './sync-broadcaster';
import { OrdersService } from '../services/orders.service';
import { TablesService } from '../services/tables.service';
import { KotService } from '../services/kot.service';
import { BillsService } from '../services/bills.service';
import { getDb } from '../database';

const ordersService = new OrdersService();
const tablesService = new TablesService();
const kotService = new KotService();
const billsService = new BillsService();

export function registerGateway(nsp: Namespace, sessionManager: SessionManager): void {
  nsp.use((socket, next) => {
    const token = socket.handshake.auth?.token as string | undefined;
    if (!token) return next(new Error('No token provided'));

    const payload = sessionManager.validateToken(token);
    if (!payload) return next(new Error('Invalid token'));

    // Attach operator info to socket data
    (socket.data as Record<string, unknown>).operatorId = payload.operator_id;
    (socket.data as Record<string, unknown>).operatorName = payload.operator_name;
    (socket.data as Record<string, unknown>).tokenId = payload.token_id;

    // Check for duplicate login — disconnect old socket
    const oldSocketId = sessionManager.onSocketConnected(payload.operator_id, socket.id);
    if (oldSocketId) {
      const oldSocket = nsp.sockets.get(oldSocketId);
      if (oldSocket) {
        oldSocket.emit('force:disconnect', { reason: 'duplicate_login' });
        oldSocket.disconnect(true);
      }
    }

    next();
  });

  nsp.on('connection', (socket: Socket) => {
    const operatorId = socket.data.operatorId as string;
    const operatorName = socket.data.operatorName as string;

    // Join operator-specific room
    socket.join(`operator:${operatorId}`);

    console.log(`[Gateway] ${operatorName} connected (${socket.id})`);

    // ─── PIN VERIFICATION ───
    socket.on('operator:verify', (data: { pin: string }, ack?: (res: unknown) => void) => {
      const session = sessionManager.verifyPin(operatorId, data.pin);
      if (!session) {
        const res = { error: 'Invalid PIN or PIN does not belong to this operator' };
        if (ack) return ack({ kind: 'rejected', ...res });
        socket.emit('operator:rejected', res);
        return;
      }

      // Join the "all" room for broadcasts
      socket.join('all');

      // Send verified response with initial data
      const initialData = buildInitialSync(operatorId, session.role);
      const res = {
        kind: 'verified',
        operator: {
          id: operatorId,
          name: operatorName,
          role: session.role,
          maxDiscountPct: session.maxDiscountPct,
          maxDiscountFlat: session.maxDiscountFlat,
        },
        ...initialData,
      };
      if (ack) return ack(res);
      socket.emit('operator:verified', res);
    });

    // ─── GUARD: all events below require PIN verification ───
    const requireVerified = (): boolean => {
      if (!sessionManager.isVerified(operatorId)) {
        socket.emit('error:permission', {
          event: 'guard',
          message: 'PIN verification required',
        });
        return false;
      }
      return true;
    };

    // ─── ORDERS ───
    socket.on('order:create', (data: {
      table_id: string;
      items: Array<{
        item_id: string;
        quantity: number;
        selected_options?: string;
        options_price?: number;
        notes?: string;
      }>;
      customer_id?: string;
      notes?: string;
      order_type?: string;
    }, ack?: (res: unknown) => void) => {
      if (!requireVerified()) return;
      try {
        const order = ordersService.createOrder({
          table_id: data.table_id,
          order_type: data.order_type ?? 'dine_in',
          created_by: operatorId,
          customer_id: data.customer_id,
          notes: data.notes,
        });

        // Add items to order
        for (const item of data.items) {
          ordersService.addItem(order.id, {
            item_id: item.item_id,
            quantity: item.quantity,
            selected_options: item.selected_options,
            options_price: item.options_price ?? 0,
            notes: item.notes,
          });
        }

        // Update table status
        if (data.table_id) {
          tablesService.setStatus(data.table_id, 'occupied', order.id);
        }

        const fullOrder = ordersService.getOrder(order.id);
        if (ack) ack({ kind: 'success', order: fullOrder });
        broadcaster.toAll('order:created', fullOrder);
        if (data.table_id) {
          const table = tablesService.getById(data.table_id);
          broadcaster.toAll('table:updated', table);
        }
        broadcaster.notifyRenderer('cap:order:created', fullOrder);
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : 'Order creation failed';
        if (ack) return ack({ kind: 'error', message: msg });
        socket.emit('error:validation', { event: 'order:create', message: msg });
      }
    });

    socket.on('order:update', (data: {
      order_id: string;
      items_add?: Array<{
        item_id: string;
        quantity: number;
        selected_options?: string;
        options_price?: number;
        notes?: string;
      }>;
      items_remove?: string[];
      notes?: string;
    }, ack?: (res: unknown) => void) => {
      if (!requireVerified()) return;
      try {
        if (data.items_add) {
          for (const item of data.items_add) {
            ordersService.addItem(data.order_id, {
              item_id: item.item_id,
              quantity: item.quantity,
              selected_options: item.selected_options,
              options_price: item.options_price ?? 0,
              notes: item.notes,
            });
          }
        }
        if (data.items_remove) {
          for (const itemId of data.items_remove) {
            ordersService.removeItem(itemId, false);
          }
        }
        if (data.notes !== undefined) {
          ordersService.updateNotes(data.order_id, data.notes);
        }
        const fullOrder = ordersService.getOrder(data.order_id);
        if (ack) ack({ kind: 'success', order: fullOrder });
        broadcaster.toAll('order:updated', fullOrder);
        broadcaster.notifyRenderer('cap:order:updated', fullOrder);
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : 'Order update failed';
        if (ack) return ack({ kind: 'error', message: msg });
        socket.emit('error:validation', { event: 'order:update', message: msg });
      }
    });

    socket.on('order:cancel', (data: { order_id: string; reason: string }, ack?: (res: unknown) => void) => {
      if (!requireVerified()) return;
      try {
        ordersService.updateStatus(data.order_id, 'cancelled');
        const order = ordersService.getOrder(data.order_id);
        // Free the table
        if (order?.table_id) {
          tablesService.setStatus(order.table_id, 'free', null);
          const table = tablesService.getById(order.table_id);
          broadcaster.toAll('table:updated', table);
        }
        if (ack) ack({ kind: 'success' });
        broadcaster.toAll('order:cancelled', { order_id: data.order_id });
        broadcaster.notifyRenderer('cap:order:cancelled', { order_id: data.order_id });
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : 'Cancel failed';
        if (ack) return ack({ kind: 'error', message: msg });
        socket.emit('error:validation', { event: 'order:cancel', message: msg });
      }
    });

    // ─── KOT ───
    socket.on('kot:send', (data: { order_id: string }, ack?: (res: unknown) => void) => {
      if (!requireVerified()) return;
      try {
        const kotResult = kotService.sendToKitchen(data.order_id, operatorId);
        if (ack) ack({ kind: 'success', ...kotResult });
        socket.emit('kot:sent', kotResult);
        broadcaster.toAll('kot:new', {
          kot_number: kotResult.kot_number,
          order_id: data.order_id,
          table_name: kotResult.table_name,
        });
        broadcaster.notifyRenderer('cap:kot:sent', kotResult);
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : 'KOT send failed';
        if (ack) return ack({ kind: 'error', message: msg });
        socket.emit('error:validation', { event: 'kot:send', message: msg });
      }
    });

    // ─── BILLS ───
    socket.on('bill:generate', (data: { order_id: string }, ack?: (res: unknown) => void) => {
      if (!requireVerified()) return;
      try {
        const bill = billsService.generateBill(data.order_id, operatorId);
        if (ack) ack({ kind: 'success', bill });
        socket.emit('bill:generated', bill);
        broadcaster.toAll('bill:status', {
          bill_id: bill.id,
          table_id: bill.table_id,
          status: bill.payment_status,
        });
        broadcaster.notifyRenderer('cap:bill:generated', bill);
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : 'Bill generation failed';
        if (ack) return ack({ kind: 'error', message: msg });
        socket.emit('error:validation', { event: 'bill:generate', message: msg });
      }
    });

    socket.on('bill:payment', (data: {
      bill_id: string;
      payments: Array<{ mode: string; amount: number; reference?: string; notes?: string }>;
    }, ack?: (res: unknown) => void) => {
      if (!requireVerified()) return;
      try {
        for (const p of data.payments) {
          billsService.addPayment(data.bill_id, {
            mode: p.mode,
            amount: p.amount,
            reference_number: p.reference,
            notes: p.notes,
            collected_by: operatorId,
          });
        }
        const bill = billsService.getBill(data.bill_id);
        if (ack) ack({ kind: 'success', bill });
        socket.emit('bill:paid', { bill_id: data.bill_id, status: bill?.payment_status });

        // If fully paid, free the table
        if (bill?.payment_status === 'paid' && bill.table_id) {
          const order = ordersService.getOrder(bill.order_id);
          if (order) {
            ordersService.updateStatus(order.id, 'closed');
          }
          tablesService.setStatus(bill.table_id, 'free', null);
          const table = tablesService.getById(bill.table_id);
          broadcaster.toAll('table:updated', table);
        }
        broadcaster.toAll('bill:status', {
          bill_id: data.bill_id,
          table_id: bill?.table_id,
          status: bill?.payment_status,
        });
        broadcaster.notifyRenderer('cap:bill:paid', bill);
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : 'Payment failed';
        if (ack) return ack({ kind: 'error', message: msg });
        socket.emit('error:validation', { event: 'bill:payment', message: msg });
      }
    });

    // ─── DISCOUNTS ───
    socket.on('discount:apply', (data: {
      order_id: string;
      discount_id?: string;
      custom?: { type: string; value: number; label?: string };
    }, ack?: (res: unknown) => void) => {
      if (!requireVerified()) return;
      try {
        const session = sessionManager.getSession(operatorId);
        if (data.custom) {
          // Check operator limits
          if (data.custom.type === 'percentage' && session?.maxDiscountPct !== null) {
            if (data.custom.value > (session?.maxDiscountPct ?? 0)) {
              const msg = `Max discount allowed: ${session?.maxDiscountPct}%`;
              if (ack) return ack({ kind: 'error', message: msg });
              socket.emit('discount:rejected', { error: msg });
              return;
            }
          }
          if (data.custom.type === 'flat' && session?.maxDiscountFlat !== null) {
            if (data.custom.value > (session?.maxDiscountFlat ?? 0)) {
              const msg = `Max discount allowed: ₹${session?.maxDiscountFlat}`;
              if (ack) return ack({ kind: 'error', message: msg });
              socket.emit('discount:rejected', { error: msg });
              return;
            }
          }
          ordersService.applyCustomDiscount(data.order_id, data.custom.type, data.custom.value, data.custom.label);
        } else if (data.discount_id) {
          ordersService.applyDiscount(data.order_id, data.discount_id);
        }
        const order = ordersService.getOrder(data.order_id);
        if (ack) ack({ kind: 'success', order });
        socket.emit('discount:applied', { order_id: data.order_id, order });
        broadcaster.toAll('order:updated', order);
        broadcaster.notifyRenderer('cap:discount:applied', order);
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : 'Discount failed';
        if (ack) return ack({ kind: 'error', message: msg });
        socket.emit('discount:rejected', { error: msg });
      }
    });

    // ─── CUSTOMERS ───
    socket.on('customer:search', (data: { query: string }, ack?: (res: unknown) => void) => {
      if (!requireVerified()) return;
      const db = getDb();
      const q = `%${data.query}%`;
      const customers = db
        .prepare('SELECT * FROM customers WHERE is_active = 1 AND (name LIKE ? OR phone LIKE ?) LIMIT 20')
        .all(q, q);
      if (ack) return ack({ kind: 'success', customers });
      socket.emit('customer:results', { customers });
    });

    socket.on('customer:create', (data: {
      name: string;
      phone?: string;
      email?: string;
      address?: string;
      notes?: string;
    }, ack?: (res: unknown) => void) => {
      if (!requireVerified()) return;
      try {
        const db = getDb();
        const id = require('uuid').v4();
        db.prepare(
          'INSERT INTO customers (id, name, phone, email, address, notes) VALUES (?, ?, ?, ?, ?, ?)'
        ).run(id, data.name, data.phone ?? null, data.email ?? null, data.address ?? null, data.notes ?? null);
        const customer = db.prepare('SELECT * FROM customers WHERE id = ?').get(id);
        if (ack) ack({ kind: 'success', customer });
        socket.emit('customer:created', { customer });
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : 'Customer creation failed';
        if (ack) return ack({ kind: 'error', message: msg });
        socket.emit('error:validation', { event: 'customer:create', message: msg });
      }
    });

    // ─── PRINT ───
    socket.on('print:kot', (data: { order_id: string }, ack?: (res: unknown) => void) => {
      if (!requireVerified()) return;
      // Notify Desktop renderer to trigger print
      broadcaster.notifyRenderer('cap:print:kot', { order_id: data.order_id });
      if (ack) ack({ kind: 'success', status: 'print_requested' });
      socket.emit('print:status', { type: 'kot', status: 'sent_to_printer' });
    });

    socket.on('print:bill', (data: { bill_id: string }, ack?: (res: unknown) => void) => {
      if (!requireVerified()) return;
      broadcaster.notifyRenderer('cap:print:bill', { bill_id: data.bill_id });
      if (ack) ack({ kind: 'success', status: 'print_requested' });
      socket.emit('print:status', { type: 'bill', status: 'sent_to_printer' });
    });

    // ─── DISCONNECT ───
    socket.on('disconnect', (reason: string) => {
      console.log(`[Gateway] ${operatorName} disconnected: ${reason}`);
      sessionManager.onSocketDisconnected(socket.id);
      socket.leave('all');
      socket.leave(`operator:${operatorId}`);
      // Notify other caps and renderer
      broadcaster.toAll('operator:offline', { operator_id: operatorId, name: operatorName });
      broadcaster.notifyRenderer('cap:operator:disconnected', { operator_id: operatorId });
    });
  });
}

// ─── BUILD INITIAL SYNC PAYLOAD ───
function buildInitialSync(operatorId: string, role: string) {
  const db = getDb();

  const tables = tablesService.getAll();
  const floors = db.prepare('SELECT * FROM floors WHERE is_active = 1 ORDER BY display_order').all();
  const categories = db.prepare('SELECT * FROM categories WHERE is_active = 1 ORDER BY sort_order').all();
  const items = db.prepare('SELECT * FROM items WHERE is_active = 1 ORDER BY sort_order').all();
  const itemOptionGroups = db.prepare('SELECT * FROM item_option_groups ORDER BY sort_order').all();
  const itemOptions = db.prepare('SELECT * FROM item_options ORDER BY sort_order').all();
  const packages = db.prepare('SELECT * FROM packages WHERE is_active = 1').all();
  const discounts = db.prepare('SELECT * FROM discounts WHERE is_active = 1').all();
  const coupons = db.prepare("SELECT * FROM coupons WHERE is_active = 1 AND (valid_until IS NULL OR valid_until > datetime('now'))").all();
  const customers = db.prepare('SELECT * FROM customers WHERE is_active = 1 ORDER BY name LIMIT 100').all();
  const reservations = db.prepare("SELECT * FROM reservations WHERE status IN ('confirmed', 'seated') AND date(reserved_at) = date('now')").all();
  const activeOrders = db.prepare("SELECT * FROM orders WHERE status NOT IN ('closed', 'cancelled', 'voided') ORDER BY created_at DESC").all();

  // Feature flags from restaurant_config
  const configRows = db.prepare('SELECT key, value FROM restaurant_config').all() as Array<{ key: string; value: string }>;
  const flags: Record<string, unknown> = {};
  for (const row of configRows) {
    if (row.key.startsWith('flag_') || row.key.startsWith('operator_pin_')) {
      flags[row.key] = row.value;
    }
  }

  // Restaurant info
  const restaurantName = configRows.find((r) => r.key === 'restaurant_name')?.value ?? 'Restaurant';
  const restaurantAddress = configRows.find((r) => r.key === 'address')?.value ?? '';
  const restaurantPhone = configRows.find((r) => r.key === 'phone')?.value ?? '';

  return {
    restaurant_info: { name: restaurantName, address: restaurantAddress, phone: restaurantPhone },
    tables,
    floors,
    menu: { categories, items, item_option_groups: itemOptionGroups, item_options: itemOptions, packages },
    discounts,
    coupons,
    customers,
    reservations,
    active_orders: activeOrders,
    flags,
  };
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add electron/server/operator.gateway.ts
git commit -m "feat: add operator gateway with all Socket.IO event handlers"
```

---

## Task 7: Integrate Server into Electron Main Process

**Files:**
- Modify: `/Users/mohitsoni/Desktop/Workspace/restro-desktop/electron/main.ts`
- Modify: `/Users/mohitsoni/Desktop/Workspace/restro-desktop/electron/ipc/handlers.ts`

- [ ] **Step 1: Add server import and startup to main.ts**

In `electron/main.ts`, after the database initialization block (~line 405 area where `registerIpcHandlers` is called), add the server startup:

```typescript
// Add at top of file with other imports:
import { OperatorServer } from './server/operator-server';
import { registerGateway } from './server/operator.gateway';
import { broadcaster } from './server/sync-broadcaster';
```

After `registerIpcHandlers(...)` call (approximately line 405-410), add:

```typescript
// Start operator server for Cap connections
const operatorServer = new OperatorServer();
operatorServer.start(8080).then(() => {
  const nsp = operatorServer.getNamespace();
  registerGateway(nsp, operatorServer.sessionManager);
  broadcaster.setMainWindow(mainWindow);
  console.log(`[Main] Operator server ready at ${operatorServer.getLanIp()}:${operatorServer.getPort()}`);
}).catch((err) => {
  console.error('[Main] Failed to start operator server:', err);
});

// Expose server to IPC handlers
(global as Record<string, unknown>).__operatorServer = operatorServer;
```

In the `app.on('before-quit')` or window close handler, add:

```typescript
operatorServer.stop();
```

- [ ] **Step 2: Add IPC handlers for QR management**

In `electron/ipc/handlers.ts`, inside the `registerIpcHandlers` function, add:

```typescript
// ─── CAP DEVICE MANAGEMENT ───
ipcMain.handle('cap:getOperatorsForPairing', async () => {
  const server = (global as Record<string, unknown>).__operatorServer as import('../server/operator-server').OperatorServer | undefined;
  if (!server) return [];
  return server.qrManager.getOperatorsForPairing();
});

ipcMain.handle('cap:generateQr', async (_event, operatorId: string) => {
  const server = (global as Record<string, unknown>).__operatorServer as import('../server/operator-server').OperatorServer | undefined;
  if (!server) return null;
  return server.qrManager.generateQrData(operatorId);
});

ipcMain.handle('cap:revokeOperator', async (_event, operatorId: string) => {
  const server = (global as Record<string, unknown>).__operatorServer as import('../server/operator-server').OperatorServer | undefined;
  if (!server) return;
  const socketId = server.qrManager.revokeOperator(operatorId);
  if (socketId) {
    const nsp = server.getNamespace();
    const socket = nsp.sockets.get(socketId);
    if (socket) {
      socket.emit('force:disconnect', { reason: 'token_revoked' });
      socket.disconnect(true);
    }
  }
});

ipcMain.handle('cap:getServerInfo', async () => {
  const server = (global as Record<string, unknown>).__operatorServer as import('../server/operator-server').OperatorServer | undefined;
  if (!server) return null;
  return { ip: server.getLanIp(), port: server.getPort() };
});
```

- [ ] **Step 3: Wire admin flag relay to broadcaster**

In `electron/services/socket-sync.service.ts`, the existing `setOnConfigPush` callback is called when admin pushes config. In `main.ts` where this callback is set, add a broadcast:

```typescript
// In main.ts where socket-sync config:push callback is set:
socketSyncService.setOnConfigPush((config) => {
  // existing handling...
  
  // NEW: relay flags to all connected Caps
  const db = getDb();
  const configRows = db.prepare('SELECT key, value FROM restaurant_config').all() as Array<{ key: string; value: string }>;
  const flags: Record<string, unknown> = {};
  for (const row of configRows) {
    if (row.key.startsWith('flag_') || row.key.startsWith('operator_pin_')) {
      flags[row.key] = row.value;
    }
  }
  broadcaster.toAll('flags:updated', { flags });
});
```

- [ ] **Step 4: Verify Desktop builds**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
npm run build:electron
```

Expected: Build succeeds without errors.

- [ ] **Step 5: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
git add electron/main.ts electron/ipc/handlers.ts electron/services/socket-sync.service.ts
git commit -m "feat: integrate operator server into Electron lifecycle with QR IPC handlers"
```

---

## Task 8: Add Dependencies to Cap Flutter App

**Files:**
- Modify: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/pubspec.yaml`

- [ ] **Step 1: Add new dependencies**

Add under the `dependencies:` section in pubspec.yaml, after `collection: ^1.18.0`:

```yaml
  # Real-time connection to Desktop POS
  socket_io_client: ^3.0.2

  # Persist pairing token for reconnect
  shared_preferences: ^2.2.3

  # WiFi connectivity monitoring
  connectivity_plus: ^6.0.5
```

- [ ] **Step 2: Install**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
flutter pub get
```

Expected: Resolves successfully.

- [ ] **Step 3: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add pubspec.yaml pubspec.lock
git commit -m "chore: add socket_io_client, shared_preferences, connectivity_plus"
```

---

## Task 9: Create Cap Feature Flags Model

**Files:**
- Create: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/lib/models/feature_flags.dart`

- [ ] **Step 1: Create the model**

```dart
// lib/models/feature_flags.dart

class FeatureFlags {
  final bool discounts;
  final bool complimentary;
  final bool voidBills;
  final bool splitPayment;
  final bool liquorBilling;
  final bool beveragesBilling;
  final bool serviceCharge;
  final bool reservations;
  final bool customers;
  final bool inventory;
  final bool kotPrinting;
  final bool packages;
  final bool multiFloor;
  final bool operatorPinAuth;
  final String operatorPinMode; // 'per_action' or 'session'
  final int operatorPinSessionMinutes;
  final bool operatorPinKot;
  final bool operatorPinHold;
  final bool operatorPinKotAndBill;
  final bool operatorPinGenerateBill;
  final bool operatorPinPayment;
  final bool operatorPinCancelOrder;
  final bool operatorPinKotEdit;
  final bool operatorPinQuickSettle;

  const FeatureFlags({
    this.discounts = true,
    this.complimentary = false,
    this.voidBills = true,
    this.splitPayment = true,
    this.liquorBilling = false,
    this.beveragesBilling = false,
    this.serviceCharge = true,
    this.reservations = false,
    this.customers = false,
    this.inventory = false,
    this.kotPrinting = true,
    this.packages = false,
    this.multiFloor = false,
    this.operatorPinAuth = true,
    this.operatorPinMode = 'per_action',
    this.operatorPinSessionMinutes = 5,
    this.operatorPinKot = false,
    this.operatorPinHold = false,
    this.operatorPinKotAndBill = false,
    this.operatorPinGenerateBill = false,
    this.operatorPinPayment = false,
    this.operatorPinCancelOrder = false,
    this.operatorPinKotEdit = false,
    this.operatorPinQuickSettle = false,
  });

  factory FeatureFlags.fromMap(Map<String, dynamic> map) {
    bool flag(String key, [bool fallback = false]) {
      final v = map[key];
      if (v == null) return fallback;
      if (v is bool) return v;
      if (v is int) return v == 1;
      if (v is String) return v == '1' || v == 'true';
      return fallback;
    }

    return FeatureFlags(
      discounts: flag('flag_discounts', true),
      complimentary: flag('flag_complimentary'),
      voidBills: flag('flag_void_bills', true),
      splitPayment: flag('flag_split_payment', true),
      liquorBilling: flag('flag_liquor_billing'),
      beveragesBilling: flag('flag_beverages_billing'),
      serviceCharge: flag('flag_service_charge', true),
      reservations: flag('flag_reservations'),
      customers: flag('flag_customers'),
      inventory: flag('flag_inventory'),
      kotPrinting: flag('flag_kot_printing', true),
      packages: flag('flag_packages'),
      multiFloor: flag('flag_multi_floor'),
      operatorPinAuth: flag('flag_operator_pin_auth', true),
      operatorPinMode: (map['operator_pin_mode'] as String?) ?? 'per_action',
      operatorPinSessionMinutes: int.tryParse('${map['operator_pin_session_minutes']}') ?? 5,
      operatorPinKot: flag('operator_pin_kot'),
      operatorPinHold: flag('operator_pin_hold'),
      operatorPinKotAndBill: flag('operator_pin_kot_and_bill'),
      operatorPinGenerateBill: flag('operator_pin_generate_bill'),
      operatorPinPayment: flag('operator_pin_payment'),
      operatorPinCancelOrder: flag('operator_pin_cancel_order'),
      operatorPinKotEdit: flag('operator_pin_kot_edit'),
      operatorPinQuickSettle: flag('operator_pin_quick_settle'),
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/models/feature_flags.dart
git commit -m "feat: add FeatureFlags model for Desktop flag sync"
```

---

## Task 10: Create Cap Session Service

**Files:**
- Create: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/lib/services/session_service.dart`

- [ ] **Step 1: Create session service**

```dart
// lib/services/session_service.dart
import 'package:shared_preferences/shared_preferences.dart';

class PairingInfo {
  final String host;
  final int port;
  final String token;

  const PairingInfo({required this.host, required this.port, required this.token});
}

class SessionService {
  static const _keyHost = 'pairing_host';
  static const _keyPort = 'pairing_port';
  static const _keyToken = 'pairing_token';

  Future<void> savePairing(PairingInfo info) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyHost, info.host);
    await prefs.setInt(_keyPort, info.port);
    await prefs.setString(_keyToken, info.token);
  }

  Future<PairingInfo?> getSavedPairing() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(_keyHost);
    final port = prefs.getInt(_keyPort);
    final token = prefs.getString(_keyToken);
    if (host == null || port == null || token == null) return null;
    return PairingInfo(host: host, port: port, token: token);
  }

  Future<void> clearPairing() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyHost);
    await prefs.remove(_keyPort);
    await prefs.remove(_keyToken);
  }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/services/session_service.dart
git commit -m "feat: add session service for pairing token persistence"
```

---

## Task 11: Create Cap Socket Service

**Files:**
- Create: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/lib/services/socket_service.dart`

- [ ] **Step 1: Create socket service**

```dart
// lib/services/socket_service.dart
import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as io;

enum SocketState { disconnected, connecting, connected, verified }

class SocketService {
  io.Socket? _socket;
  final _stateController = StreamController<SocketState>.broadcast();
  SocketState _state = SocketState.disconnected;

  Stream<SocketState> get stateStream => _stateController.stream;
  SocketState get state => _state;
  io.Socket? get socket => _socket;

  void connect(String host, int port, String token) {
    disconnect();
    _setState(SocketState.connecting);

    _socket = io.io(
      'http://$host:$port/operator',
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .enableReconnection()
          .setReconnectionDelay(2000)
          .setReconnectionAttempts(double.maxFinite.toInt())
          .build(),
    );

    _socket!.onConnect((_) {
      _setState(SocketState.connected);
    });

    _socket!.onDisconnect((_) {
      _setState(SocketState.disconnected);
    });

    _socket!.onConnectError((err) {
      _setState(SocketState.disconnected);
    });

    _socket!.on('force:disconnect', (data) {
      _setState(SocketState.disconnected);
      disconnect();
    });

    _socket!.connect();
  }

  void verifyPin(String pin, {required Function(Map<String, dynamic>) onVerified, required Function(String) onRejected}) {
    _socket?.emitWithAck('operator:verify', {'pin': pin}).then((res) {
      final response = Map<String, dynamic>.from(res as Map);
      if (response['kind'] == 'verified') {
        _setState(SocketState.verified);
        onVerified(response);
      } else {
        onRejected(response['error']?.toString() ?? 'Invalid PIN');
      }
    }).catchError((err) {
      onRejected('Connection error');
    });
  }

  void emit(String event, Map<String, dynamic> data, {Function(Map<String, dynamic>)? onAck}) {
    if (onAck != null) {
      _socket?.emitWithAck(event, data).then((res) {
        onAck(Map<String, dynamic>.from(res as Map));
      });
    } else {
      _socket?.emit(event, data);
    }
  }

  void on(String event, Function(dynamic) handler) {
    _socket?.on(event, handler);
  }

  void off(String event) {
    _socket?.off(event);
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _setState(SocketState.disconnected);
  }

  void _setState(SocketState s) {
    _state = s;
    _stateController.add(s);
  }

  void dispose() {
    disconnect();
    _stateController.close();
  }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/services/socket_service.dart
git commit -m "feat: add socket service for Desktop Socket.IO connection"
```

---

## Task 12: Create Cap Sync Service & Update Providers

**Files:**
- Create: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/lib/services/sync_service.dart`
- Modify: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/lib/data/providers.dart`

- [ ] **Step 1: Add new providers to providers.dart**

Keep all existing model classes (RestaurantTable, MenuItem, CartLine, etc.) unchanged. Replace the mock fixtures and provider declarations at the bottom of the file.

Replace the fixture-based providers (starting around line 354) with real data providers:

```dart
// ─── REAL DATA PROVIDERS (replace mock fixtures) ───

// Tables: initially empty, populated by sync:initial
final tablesProvider = StateProvider<List<RestaurantTable>>((_) => []);

// Menu: initially empty, populated by sync:initial
final menuProvider = StateProvider<List<MenuItem>>((_) => []);

// Raw menu data from Desktop (categories, items, options, packages)
final rawMenuDataProvider = StateProvider<Map<String, dynamic>>((_) => {});

// Feature flags
final flagsProvider = StateProvider<FeatureFlags>((_) => const FeatureFlags());

// History/orders from Desktop
final historyProvider = StateProvider<List<HistoryOrder>>((_) => []);

// Active orders (all operators)
final activeOrdersProvider = StateProvider<List<Map<String, dynamic>>>((_) => []);

// Selected table for builder
final selectedTableIdProvider = StateProvider<String?>((_) => null);

// Customer count for current order
final orderCustomerCountProvider = StateProvider<int>((_) => 2);

// Order notes
final orderNotesProvider = StateProvider<String>((_) => '');

// Cart (local — preserved across reconnects)
final cartProvider = StateNotifierProvider<CartNotifier, List<CartLine>>(
  (_) => CartNotifier(),
);
// CartNotifier class stays EXACTLY as-is (lines 365-444)

// Operator: populated after PIN verify
final operatorProvider = StateProvider<Operator?>((_) => null);

// Operator stats: populated from Desktop
final operatorStatsProvider = StateProvider<OperatorStats>(
  (_) => const OperatorStats(ordersToday: 0, tablesServed: 0, itemsSold: 0),
);

// Restaurant info: populated after socket connect
final restaurantProvider = StateProvider<RestaurantInfo?>((_) => null);

// Connection status: driven by socket service
final connectionProvider = StateProvider<ConnectionStatus>(
  (_) => const ConnectionStatus(online: false, label: 'Not connected'),
);

// Active operators on shift
final activeOperatorsProvider = StateProvider<List<ActiveOperator>>((_) => []);

// Auth state
final isAuthenticatedProvider = StateProvider<bool>((_) => false);

// Last KOT number
final lastKotIdProvider = StateProvider<String>((_) => '');
```

Note: Add `import '../models/feature_flags.dart';` at the top of providers.dart.

Also change `final menuProvider = Provider<List<MenuItem>>` to `StateProvider` so it can be updated by sync events.

- [ ] **Step 2: Create sync service**

```dart
// lib/services/sync_service.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/providers.dart';
import '../models/feature_flags.dart';
import 'socket_service.dart';

class SyncService {
  final SocketService socketService;

  SyncService(this.socketService);

  void registerListeners(WidgetRef ref) {
    final socket = socketService.socket;
    if (socket == null) return;

    // ─── INITIAL SYNC (after PIN verified) ───
    // This data comes back in the operator:verified ack response,
    // so we handle it in the auth screen. But real-time events go here:

    // ─── TABLES ───
    socket.on('table:updated', (data) {
      final tableData = Map<String, dynamic>.from(data as Map);
      final tables = ref.read(tablesProvider);
      final tableId = tableData['id'] as String;
      ref.read(tablesProvider.notifier).state = [
        for (final t in tables)
          if (t.id == tableId)
            _parseTable(tableData)
          else
            t,
      ];
    });

    // ─── ORDERS ───
    socket.on('order:created', (data) {
      final orderData = Map<String, dynamic>.from(data as Map);
      final orders = List<Map<String, dynamic>>.from(ref.read(activeOrdersProvider));
      orders.add(orderData);
      ref.read(activeOrdersProvider.notifier).state = orders;
    });

    socket.on('order:updated', (data) {
      final orderData = Map<String, dynamic>.from(data as Map);
      final orderId = orderData['id'] as String;
      final orders = List<Map<String, dynamic>>.from(ref.read(activeOrdersProvider));
      ref.read(activeOrdersProvider.notifier).state = [
        for (final o in orders)
          if (o['id'] == orderId) orderData else o,
      ];
    });

    socket.on('order:cancelled', (data) {
      final d = Map<String, dynamic>.from(data as Map);
      final orderId = d['order_id'] as String;
      final orders = List<Map<String, dynamic>>.from(ref.read(activeOrdersProvider));
      orders.removeWhere((o) => o['id'] == orderId);
      ref.read(activeOrdersProvider.notifier).state = orders;
    });

    // ─── KOT ───
    socket.on('kot:new', (data) {
      // Notification — could show a toast or update badge
    });

    // ─── BILLS ───
    socket.on('bill:status', (data) {
      // Update table status will come via table:updated
    });

    // ─── FLAGS (real-time from admin) ───
    socket.on('flags:updated', (data) {
      final d = Map<String, dynamic>.from(data as Map);
      final flags = d['flags'] as Map<String, dynamic>?;
      if (flags != null) {
        ref.read(flagsProvider.notifier).state = FeatureFlags.fromMap(flags);
      }
    });

    // ─── MENU ───
    socket.on('menu:updated', (data) {
      final d = Map<String, dynamic>.from(data as Map);
      ref.read(rawMenuDataProvider.notifier).state = d;
      ref.read(menuProvider.notifier).state = _parseMenuItems(d);
    });

    // ─── FORCE DISCONNECT ───
    socket.on('force:disconnect', (data) {
      ref.read(isAuthenticatedProvider.notifier).state = false;
      ref.read(connectionProvider.notifier).state =
          const ConnectionStatus(online: false, label: 'Disconnected by admin');
    });
  }

  /// Populate all providers from sync:initial data
  void applyInitialSync(WidgetRef ref, Map<String, dynamic> data) {
    // Tables
    final tablesRaw = data['tables'] as List<dynamic>? ?? [];
    ref.read(tablesProvider.notifier).state = tablesRaw
        .map((t) => _parseTable(Map<String, dynamic>.from(t as Map)))
        .toList();

    // Menu
    final menuRaw = data['menu'] as Map<String, dynamic>? ?? {};
    ref.read(rawMenuDataProvider.notifier).state = menuRaw;
    ref.read(menuProvider.notifier).state = _parseMenuItems(menuRaw);

    // Flags
    final flagsRaw = data['flags'] as Map<String, dynamic>? ?? {};
    ref.read(flagsProvider.notifier).state = FeatureFlags.fromMap(flagsRaw);

    // Active orders
    final ordersRaw = data['active_orders'] as List<dynamic>? ?? [];
    ref.read(activeOrdersProvider.notifier).state =
        ordersRaw.map((o) => Map<String, dynamic>.from(o as Map)).toList();

    // Restaurant info
    final ri = data['restaurant_info'] as Map<String, dynamic>?;
    if (ri != null) {
      ref.read(restaurantProvider.notifier).state = RestaurantInfo(
        name: ri['name'] as String? ?? 'Restaurant',
        address: ri['address'] as String? ?? '',
        adminDeviceLabel: 'Desktop POS',
        adminIp: '',
      );
    }

    // Operator
    final op = data['operator'] as Map<String, dynamic>?;
    if (op != null) {
      ref.read(operatorProvider.notifier).state = Operator(
        name: op['name'] as String? ?? '',
        role: op['role'] as String? ?? 'operator',
        shift: '',
        username: op['id'] as String? ?? '',
      );
    }
  }

  void unregisterListeners() {
    socketService.off('table:updated');
    socketService.off('order:created');
    socketService.off('order:updated');
    socketService.off('order:cancelled');
    socketService.off('kot:new');
    socketService.off('bill:status');
    socketService.off('flags:updated');
    socketService.off('menu:updated');
    socketService.off('force:disconnect');
  }
}

// ─── Parsers ───

RestaurantTable _parseTable(Map<String, dynamic> t) {
  final statusStr = t['status'] as String? ?? 'free';
  TableState state;
  switch (statusStr) {
    case 'occupied':
      state = TableState.other;
      break;
    case 'reserved':
      state = TableState.reserved;
      break;
    case 'cleaning':
      state = TableState.dirty;
      break;
    default:
      state = TableState.free;
  }

  return RestaurantTable(
    id: t['id'] as String? ?? t['name'] as String? ?? '',
    seats: t['capacity'] as int? ?? 4,
    floor: t['floor_id'] as String? ?? 'GROUND',
    state: state,
    waiterName: null,
    coverCount: null,
    bill: (t['order_total'] as num?)?.toDouble(),
    note: t['reservation_customer'] as String?,
  );
}

List<MenuItem> _parseMenuItems(Map<String, dynamic> menuData) {
  final items = menuData['items'] as List<dynamic>? ?? [];
  final categories = menuData['categories'] as List<dynamic>? ?? [];

  final catMap = <String, Map<String, dynamic>>{};
  for (final c in categories) {
    final cat = Map<String, dynamic>.from(c as Map);
    catMap[cat['id'] as String] = cat;
  }

  return items.map((raw) {
    final item = Map<String, dynamic>.from(raw as Map);
    final cat = catMap[item['category_id'] as String?];
    return MenuItem(
      id: item['id'] as String? ?? '',
      name: item['name'] as String? ?? '',
      section: cat?['name'] as String? ?? 'Other',
      kitchenSection: cat?['type'] as String? ?? 'food',
      price: (item['base_price'] as num? ?? 0).toDouble(),
      isVeg: (item['is_veg'] as int? ?? 0) == 1,
      available: (item['is_active'] as int? ?? 1) == 1,
    );
  }).toList();
}
```

- [ ] **Step 3: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/services/sync_service.dart lib/data/providers.dart lib/models/feature_flags.dart
git commit -m "feat: add sync service and replace mock providers with real data"
```

---

## Task 13: Update Cap QR Scan Screen

**Files:**
- Modify: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/lib/screens/qr_scan_screen.dart`

- [ ] **Step 1: Update QR scan to parse real URI and store pairing info**

Replace the `_onDetect` method (around line 41-60) logic. Currently it just navigates to `/connecting` after a 300ms delay. Update it to:

```dart
// Add at top of file:
import '../services/session_service.dart';

// In _onDetect method, replace the navigation logic:
void _onDetect(BarcodeCapture capture) {
  if (_processing) return;
  final raw = capture.barcodes.firstOrNull?.rawValue;
  if (raw == null) return;

  if (!raw.startsWith('restroapp://pair?')) {
    _showError('Invalid QR — expected a DineDesk pairing code');
    return;
  }

  setState(() => _processing = true);

  // Parse the URI
  final uri = Uri.parse(raw);
  final host = uri.queryParameters['host'];
  final portStr = uri.queryParameters['port'];
  final token = uri.queryParameters['token'];

  if (host == null || portStr == null || token == null) {
    _showError('Invalid QR — missing connection details');
    setState(() => _processing = false);
    return;
  }

  final port = int.tryParse(portStr);
  if (port == null) {
    _showError('Invalid QR — bad port number');
    setState(() => _processing = false);
    return;
  }

  // Store pairing info
  SessionService().savePairing(PairingInfo(host: host, port: port, token: token)).then((_) {
    if (mounted) context.go('/connecting');
  });
}
```

Also update the demo bypass `_demoScan()` to store test pairing info:

```dart
void _demoScan() {
  SessionService()
      .savePairing(const PairingInfo(host: '192.168.1.5', port: 8080, token: 'demo'))
      .then((_) {
    if (mounted) context.go('/connecting');
  });
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/screens/qr_scan_screen.dart
git commit -m "feat: QR scan parses real pairing URI and stores connection info"
```

---

## Task 14: Update Cap Connecting Screen

**Files:**
- Modify: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/lib/screens/connecting_screen.dart`

- [ ] **Step 1: Replace simulated connection with real Socket.IO connect**

Replace the `_tick()` timer logic (lines 46-58) with real connection:

```dart
// Add imports at top:
import '../services/session_service.dart';
import '../services/socket_service.dart';

// Add to _ConnectingScreenState:
final _socketService = SocketService();
late final StreamSubscription<SocketState> _sub;

@override
void initState() {
  super.initState();
  _sub = _socketService.stateStream.listen((state) {
    if (!mounted) return;
    if (state == SocketState.connected) {
      setState(() {
        _stage = 2; // "Almost there…"
      });
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) context.go('/auth');
      });
    } else if (state == SocketState.disconnected && _stage > 0) {
      // Connection failed
      setState(() {
        _stage = 0;
        _error = 'Could not connect to Desktop. Check WiFi.';
      });
    }
  });
  _startConnection();
}

Future<void> _startConnection() async {
  setState(() { _stage = 0; _error = null; });

  // Stage 1: Finding restaurant
  await Future.delayed(const Duration(milliseconds: 500));
  if (!mounted) return;
  setState(() => _stage = 1);

  // Load pairing info
  final pairing = await SessionService().getSavedPairing();
  if (pairing == null) {
    if (mounted) context.go('/scan');
    return;
  }

  // Stage 2: Connecting
  _socketService.connect(pairing.host, pairing.port, pairing.token);
}

@override
void dispose() {
  _sub.cancel();
  // Don't disconnect socket here — auth screen needs it
  super.dispose();
}
```

Note: The socket service instance needs to be shared between connecting and auth screens. Create a Riverpod provider for it:

In `lib/data/providers.dart`, add:

```dart
// Global socket & sync service providers
final socketServiceProvider = Provider<SocketService>((_) => SocketService());
final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService(ref.read(socketServiceProvider));
});
```

Then in connecting_screen, use `ref.read(socketServiceProvider)` instead of creating a new instance.

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/screens/connecting_screen.dart lib/data/providers.dart
git commit -m "feat: connecting screen uses real Socket.IO connection"
```

---

## Task 15: Update Cap Auth Screen

**Files:**
- Modify: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/lib/screens/auth_screen.dart`

- [ ] **Step 1: Replace mock PIN auth with real socket verification**

Replace the `_maybeSubmit()` method (lines 51-69) with real PIN verification:

```dart
// Add imports:
import '../services/socket_service.dart';
import '../services/sync_service.dart';

// Replace _maybeSubmit:
void _maybeSubmit() {
  if (_pin.length < 4) return;
  setState(() { _submitting = true; _error = null; });

  final socketService = ref.read(socketServiceProvider);
  final syncService = ref.read(syncServiceProvider);
  final pin = _pin.join();

  socketService.verifyPin(
    pin,
    onVerified: (response) {
      if (!mounted) return;

      // Apply initial sync data to all providers
      syncService.applyInitialSync(ref, response);

      // Register real-time listeners
      syncService.registerListeners(ref);

      // Update connection status
      ref.read(connectionProvider.notifier).state = ConnectionStatus(
        online: true,
        label: 'Connected · ${response['restaurant_info']?['name'] ?? 'Restaurant'}',
      );

      ref.read(isAuthenticatedProvider.notifier).state = true;
      context.go('/tables');
    },
    onRejected: (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = error;
        _pin.clear();
      });
    },
  );
}
```

Remove the username field requirement — the QR token already identifies the operator. Just keep the PIN entry.

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/screens/auth_screen.dart
git commit -m "feat: auth screen verifies PIN via socket with real data sync"
```

---

## Task 16: Update Cap Connection Banner

**Files:**
- Modify: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/lib/widgets/connection_banner.dart`

- [ ] **Step 1: Listen to real socket state instead of just provider**

Add a `ref.listen` on the socket service state. In `_ConnectionBannerState`, update the build method to also listen to socket state changes:

```dart
// Add import:
import '../services/socket_service.dart';
import '../data/providers.dart';

// In build method, add after existing ref.listen:
ref.listen<ConnectionStatus>(connectionProvider, (prev, next) {
  if (prev != null && prev.online && !next.online) {
    _startTimer();
  } else if (prev != null && !prev.online && next.online) {
    _stopTimer();
  }
});

// Add socket state listener in initState or build:
// The socket service updates connectionProvider, so the existing
// listener already works. Just need to wire socket events to
// update connectionProvider.
```

In `lib/services/socket_service.dart`, update the state handlers to also work with a provider callback. The simplest approach: in the connecting screen or auth screen, listen to socket state and update connectionProvider:

Add to the `SyncService.registerListeners` method:

```dart
// Listen to socket state and update connectionProvider
socketService.stateStream.listen((state) {
  switch (state) {
    case SocketState.verified:
      ref.read(connectionProvider.notifier).state =
          const ConnectionStatus(online: true, label: 'Connected');
      break;
    case SocketState.disconnected:
      ref.read(connectionProvider.notifier).state =
          const ConnectionStatus(online: false, label: 'Reconnecting...');
      break;
    default:
      break;
  }
});
```

The existing connection_banner.dart code already handles the timer and navigation to `/disconnected` — no changes needed to the banner widget itself.

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/services/sync_service.dart lib/widgets/connection_banner.dart
git commit -m "feat: connection banner reflects real socket state"
```

---

## Task 17: Update Cap Router for Reconnect Flow

**Files:**
- Modify: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/lib/router.dart`

- [ ] **Step 1: Add reconnect redirect for stored sessions**

Update the redirect logic to check for stored pairing on splash:

```dart
// In router.dart, update the redirect function:
redirect: (context, state) {
  final loc = state.matchedLocation;
  const authFlow = ['/splash', '/scan', '/connecting', '/auth'];
  final onAuthFlow = authFlow.any((p) => loc.startsWith(p));
  final onDisconnect = loc == '/disconnected' || loc == '/force-disconnected';
  if (!authed && !onAuthFlow && !onDisconnect) return '/auth';
  if (authed && onAuthFlow) return '/tables';
  return null;
},
```

The redirect logic stays the same. The reconnect flow is handled in the splash screen: on cold start, splash checks for stored pairing and auto-navigates to `/connecting` instead of `/scan` if found.

Update splash_screen.dart transition logic:

```dart
// In splash screen, after the 1.8s delay:
Future.delayed(const Duration(milliseconds: 1800), () async {
  if (!mounted) return;
  final pairing = await SessionService().getSavedPairing();
  if (pairing != null) {
    context.go('/connecting'); // Skip QR scan, try reconnect
  } else {
    context.go('/scan');
  }
});
```

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/router.dart lib/screens/splash_screen.dart
git commit -m "feat: splash checks for stored pairing and auto-reconnects"
```

---

## Task 18: Update Cap Tables Screen for Real Events

**Files:**
- Modify: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/lib/screens/tables_screen.dart`

- [ ] **Step 1: Replace mock table state mutations with socket events**

Update `_onTableTap` method (lines 25-69). Instead of directly mutating tablesProvider, emit socket events:

```dart
// Add import:
import '../services/socket_service.dart';

// Replace the table tap handler for free tables:
void _onTableTap(RestaurantTable t) async {
  if (t.state == TableState.free) {
    final count = await CustomerCountSheet.show(context, t);
    if (!mounted || count == null) return;
    ref.read(cartProvider.notifier).clear();
    ref.read(orderNotesProvider.notifier).state = '';
    ref.read(orderCustomerCountProvider.notifier).state = count;
    ref.read(selectedTableIdProvider.notifier).state = t.id;
    // Don't mutate table state locally — Desktop will broadcast table:updated
    // after order:create
    if (mounted) context.push('/order/${t.id}');
  } else if (t.state == TableState.mine || t.state == TableState.other) {
    // Allow viewing/editing orders on occupied tables
    final prevTable = ref.read(selectedTableIdProvider);
    if (prevTable != null && prevTable != t.id) {
      ref.read(cartProvider.notifier).clear();
      ref.read(orderNotesProvider.notifier).state = '';
    }
    ref.read(orderCustomerCountProvider.notifier).state = t.coverCount ?? 2;
    ref.read(selectedTableIdProvider.notifier).state = t.id;
    context.push('/order/${t.id}');
  } else if (t.state == TableState.dirty) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(content: Text('Table needs cleaning.')),
      );
  } else if (t.state == TableState.reserved) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text('Reserved · ${t.note ?? "see admin"}'),
      ));
  }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/screens/tables_screen.dart
git commit -m "feat: tables screen reads real data, no local state mutations"
```

---

## Task 19: Update Cap Order Review Screen for Real KOT

**Files:**
- Modify: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/lib/screens/order_review_screen.dart`

- [ ] **Step 1: Replace mock KOT submission with real socket events**

Find the submit/send-to-kitchen handler in order_review_screen.dart and replace with:

```dart
// Add imports:
import '../services/socket_service.dart';

// Replace the send-to-kitchen logic:
Future<void> _sendToKitchen() async {
  if (_submitting) return;
  setState(() => _submitting = true);

  final socketService = ref.read(socketServiceProvider);
  final cart = ref.read(cartProvider);
  final tableId = widget.tableId;
  final notes = ref.read(orderNotesProvider);
  final customerCount = ref.read(orderCustomerCountProvider);

  // Build items payload
  final items = cart.map((line) => {
    return {
      'item_id': line.item.id,
      'quantity': line.qty,
      'notes': line.itemNote.isNotEmpty ? line.itemNote : null,
      'selected_options': line.mods.isNotEmpty ? line.mods.join(',') : null,
      'options_price': line.modsExtra,
    };
  }).toList();

  // Emit order:create
  socketService.emit('order:create', {
    'table_id': tableId,
    'items': items,
    'notes': notes,
    'order_type': 'dine_in',
  }, onAck: (response) {
    if (!mounted) return;
    if (response['kind'] == 'success') {
      final order = response['order'] as Map<String, dynamic>?;
      final orderId = order?['id'] as String? ?? '';

      // Now send KOT
      socketService.emit('kot:send', {'order_id': orderId}, onAck: (kotRes) {
        if (!mounted) return;
        if (kotRes['kind'] == 'success') {
          final kotNumber = kotRes['kot_number'] as String? ?? '';
          ref.read(lastKotIdProvider.notifier).state = kotNumber;
          ref.read(cartProvider.notifier).clear();
          ref.read(orderNotesProvider.notifier).state = '';
          context.go('/order/$tableId/success');
        } else {
          setState(() => _submitting = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('KOT failed: ${kotRes['message'] ?? 'Unknown error'}'),
          ));
        }
      });
    } else {
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Order failed: ${response['message'] ?? 'Unknown error'}'),
      ));
    }
  });
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/screens/order_review_screen.dart
git commit -m "feat: order review sends real order + KOT via socket"
```

---

## Task 20: Update Disconnected Screen & Cleanup

**Files:**
- Modify: `/Users/mohitsoni/Desktop/Workspace/dinedesk-cap/lib/screens/disconnected_screen.dart`

- [ ] **Step 1: Clear session on disconnect screen actions**

Update the "Scan QR" button to clear stored pairing:

```dart
// Add import:
import '../services/session_service.dart';

// Update "Scan QR" button:
LiquidPrimaryButton(
  label: 'Scan QR',
  fullWidth: true,
  leadingIcon: Icons.qr_code_scanner,
  onPressed: () {
    HapticFeedback.mediumImpact();
    SessionService().clearPairing();
    context.go('/scan');
  },
),
```

The "Try reconnect once more" button already goes to `/connecting`, which will read stored pairing and try reconnect — that's correct.

- [ ] **Step 2: Commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add lib/screens/disconnected_screen.dart
git commit -m "feat: disconnect screen clears pairing on QR re-scan"
```

---

## Task 21: End-to-End Verification

- [ ] **Step 1: Start Desktop app**

```bash
cd /Users/mohitsoni/Desktop/Workspace/restro-desktop
npm run dev
```

Check console for: `[OperatorServer] Listening on <LAN_IP>:8080`

- [ ] **Step 2: Verify QR generation works via IPC**

In Desktop app, open DevTools console and test:

```javascript
window.electronAPI.invoke('cap:getOperatorsForPairing').then(console.log)
window.electronAPI.invoke('cap:generateQr', '<operator-id>').then(console.log)
```

Expected: Returns QR data string `restroapp://pair?host=...&port=8080&token=...`

- [ ] **Step 3: Start Cap Flutter app**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
flutter run
```

- [ ] **Step 4: Test full flow**

1. Desktop: Generate QR for an operator
2. Cap: Scan QR (or use demo bypass with correct IP/port)
3. Cap: Enter operator's PIN
4. Cap: Should see real tables, menu from Desktop DB
5. Cap: Create an order on a table
6. Desktop: Verify order appears in Desktop UI
7. Cap: Send KOT
8. Desktop: Verify KOT number generated

- [ ] **Step 5: Test disconnect/reconnect**

1. Turn off WiFi on Cap device briefly
2. Cap: Should show reconnecting banner with countdown
3. Turn WiFi back on
4. Cap: Should auto-reconnect, cart preserved

- [ ] **Step 6: Final commit**

```bash
cd /Users/mohitsoni/Desktop/Workspace/dinedesk-cap
git add -A
git commit -m "feat: complete real-time Cap-Desktop sync via Socket.IO"
```
