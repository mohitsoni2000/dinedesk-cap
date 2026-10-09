import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/entry_ticket.dart';
import 'package:restro/models/feature_flags.dart';
import 'package:restro/models/qsr_config.dart';
import 'package:restro/models/token.dart';
import 'package:restro/services/offline_snapshot.dart';
import 'package:restro/services/socket_service.dart';
import 'package:restro/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// The four sync keys a QSR / entry-ticket desk adds (`qsr_config`,
/// `entry_ticket_types`, `entry_ticket_config`, `payment_modes`), their live
/// broadcasts, and how token orders show up. Absent keys follow the
/// `session_policy` rule: a FULL sync without them is an older desk (reset to
/// plain restaurant), a partial reply says nothing about them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const dir = 'test/fixtures/crew-qsr';
  Map<String, dynamic> fixture(String name) =>
      jsonDecode(File('$dir/$name').readAsStringSync()) as Map<String, dynamic>;

  late Directory tmp;
  late OfflineSnapshotStore store;
  late SocketService socket;
  late ProviderContainer container;

  ProviderContainer newContainer() => ProviderContainer(overrides: [
        socketServiceProvider.overrideWithValue(socket),
        offlineSnapshotStoreProvider.overrideWithValue(store),
      ]);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = await Directory.systemTemp.createTemp('sync_qsr_test');
    store = OfflineSnapshotStore(directory: tmp);
    socket = SocketService();
    socket.debugAttachSocket(io.io(
      'http://127.0.0.1:1/operator',
      io.OptionBuilder().disableAutoConnect().build(),
    ));
    container = newContainer();
  });

  tearDown(() async {
    container.dispose();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  SyncService sync() => container.read(syncServiceProvider);

  /// What socket_io_client delivers for a broadcast (offset-wrapped).
  void deliver(String event, Map<String, dynamic> payload) =>
      socket.socket!.emitEvent(<dynamic>[event, payload, 'AbCdEf12345']);

  /// A full sync (it has `tables`) carrying [extra].
  Map<String, dynamic> full([Map<String, dynamic> extra = const {}]) =>
      <String, dynamic>{'tables': <Object>[], ...extra};

  group('applyInitialSync', () {
    test('a full sync applies all four keys', () async {
      await sync().applyInitialSync(full(fixture('sync_qsr_keys.json')));

      final qsr = container.read(qsrConfigProvider);
      expect(qsr.isQsr, isTrue);
      expect(qsr.tokenStrategy, TokenStrategy.prefixed);
      expect(container.read(ticketTypesProvider).map((t) => t.id),
          <String>['ett_couple', 'ett_stag']);
      expect(container.read(ticketConfigProvider).coverPaymentMode,
          'cover_ticket');
      expect(container.read(payModesProvider).map((m) => m.code),
          <String>['cash', 'upi', 'card', 'custom_phonepe']);
    });

    test('a full sync from an older desk resets to plain restaurant', () async {
      await sync().applyInitialSync(full(fixture('sync_qsr_keys.json')));
      await sync().applyInitialSync(full());

      expect(container.read(qsrConfigProvider).isQsr, isFalse);
      expect(container.read(ticketTypesProvider), isEmpty);
      expect(container.read(ticketConfigProvider).coverPaymentMode, isNull);
      expect(container.read(payModesProvider), isEmpty);
    });

    test('a partial reply (no tables) leaves them alone', () async {
      await sync().applyInitialSync(full(fixture('sync_qsr_keys.json')));
      await sync().applyInitialSync(<String, dynamic>{'menu_version': 'mv-2'});

      expect(container.read(qsrConfigProvider).isQsr, isTrue);
      expect(container.read(ticketTypesProvider), hasLength(2));
      expect(container.read(ticketConfigProvider).coverPaymentMode,
          'cover_ticket');
      expect(container.read(payModesProvider), hasLength(4));
    });

    test('a partial reply that does carry a key applies it', () async {
      await sync().applyInitialSync(full(fixture('sync_qsr_keys.json')));
      await sync().applyInitialSync(<String, dynamic>{
        'qsr_config': <String, dynamic>{'operating_mode': 'restaurant'},
      });
      expect(container.read(qsrConfigProvider).isQsr, isFalse);
      expect(container.read(ticketTypesProvider), hasLength(2));
    });

    test('present-but-null is the desk saying "none"', () async {
      await sync().applyInitialSync(full(fixture('sync_qsr_keys.json')));
      await sync().applyInitialSync(<String, dynamic>{
        'qsr_config': null,
        'entry_ticket_types': null,
        'entry_ticket_config': null,
        'payment_modes': null,
      });
      expect(container.read(qsrConfigProvider).isQsr, isFalse);
      expect(container.read(ticketTypesProvider), isEmpty);
      expect(container.read(ticketConfigProvider).coverPaymentMode, isNull);
      expect(container.read(payModesProvider), isEmpty);
    });

    test('the cover mode never shows up as a pay mode', () async {
      final keys = fixture('sync_qsr_keys.json');
      await sync().applyInitialSync(full(<String, dynamic>{
        ...keys,
        'payment_modes': <Object?>[
          ...(keys['payment_modes'] as List<dynamic>),
          <String, dynamic>{'code': 'cover_ticket', 'name': 'Cover Ticket'},
        ],
      }));
      expect(container.read(payModesProvider).map((m) => m.code),
          isNot(contains('cover_ticket')));
    });
  });

  group('broadcasts', () {
    setUp(() => sync().registerListeners());

    test('qsr_config:updated switches the mode live', () async {
      await sync().applyInitialSync(full());
      expect(container.read(qsrConfigProvider).isQsr, isFalse);

      deliver('qsr_config:updated', <String, dynamic>{
        'qsr_config': fixture('sync_qsr_keys.json')['qsr_config'],
      });
      expect(container.read(qsrConfigProvider).isQsr, isTrue);

      deliver('qsr_config:updated', <String, dynamic>{
        'qsr_config': <String, dynamic>{'operating_mode': 'restaurant'},
      });
      expect(container.read(qsrConfigProvider).isQsr, isFalse);
    });

    test('a qsr_config:updated without the key changes nothing', () async {
      await sync().applyInitialSync(full(fixture('sync_qsr_keys.json')));
      deliver('qsr_config:updated', <String, dynamic>{});
      expect(container.read(qsrConfigProvider).isQsr, isTrue);
    });

    test('ticket_types:updated replaces the types and the cover mode',
        () async {
      await sync().applyInitialSync(full(fixture('sync_qsr_keys.json')));
      deliver('ticket_types:updated', <String, dynamic>{
        'entry_ticket_types': <Object>[
          <String, dynamic>{
            'id': 'ett_vip',
            'name': 'VIP Table Pass',
            'price': 5000,
            'unit_total': 5000,
            'pax': 4,
          },
        ],
        'entry_ticket_config': <String, dynamic>{
          'cover_payment_mode': null,
          'qr_prefix': 'CDT:',
        },
      });
      expect(container.read(ticketTypesProvider).single.id, 'ett_vip');
      expect(container.read(ticketTypesProvider).single.unitTotal,
          const Money.rupees(5000));
      expect(container.read(ticketConfigProvider).coverPaymentMode, isNull);
    });

    test('payment_modes:updated replaces the pay modes', () async {
      await sync().applyInitialSync(full(fixture('sync_qsr_keys.json')));
      deliver('payment_modes:updated', <String, dynamic>{
        'payment_modes': <Object>[
          <String, dynamic>{
            'code': 'custom_swiggy',
            'name': 'Swiggy Dineout',
            'print_name': 'Swiggy',
            'kind': 'revenue',
            'is_cash': 0,
            'reference_mode': 'optional',
            'require_reason': 0,
            'sort_order': 3,
          },
        ],
      });
      expect(container.read(payModesProvider).map((m) => m.code),
          <String>['custom_swiggy']);
    });

    test('order:ready calls a token order by its token', () async {
      container.read(flagsProvider.notifier).state =
          const FeatureFlags(readyToServe: true);
      deliver('order:ready', fixture('order_ready_token.json'));

      final ready = container.read(readyOrdersProvider).single;
      expect(ready.orderId, 'ord_9c21');
      expect(ready.tokenLabel, 'T-07');
      expect(ready.tableName, 'Token T-07');
      expect(ready.kotNumber, 'KOT-0129');
    });

    test('order:ready still needs ready-to-serve', () async {
      deliver('order:ready', fixture('order_ready_token.json'));
      expect(container.read(readyOrdersProvider), isEmpty);
    });

    test('kot:sent for a token order puts "Token T-07" in history', () async {
      deliver('kot:sent', <String, dynamic>{
        'order': fixture('order_with_token.json'),
        'kot': <String, dynamic>{'kot_type': 'new', 'token_label': 'T-07'},
      });
      final entry = container.read(historyProvider).single;
      expect(entry.tableId, 'Token T-07');
      expect(entry.tokenLabel, 'T-07');
      expect(container.read(activeOrdersProvider).single.token!.label, 'T-07');
    });
  });

  group('token orders in history', () {
    test('carry the token label, status and fulfillment', () async {
      await sync().applyInitialSync(full(<String, dynamic>{
        'active_orders': <Object>[fixture('order_with_token.json')],
      }));
      final entry = container.read(historyProvider).single;
      expect(entry.orderId, 'ord_9c21');
      expect(entry.tableId, 'Token T-07',
          reason: 'the badge where a table name would go');
      expect(entry.tokenLabel, 'T-07');
      expect(entry.tokenStatus, TokenStatus.preparing);
      expect(entry.fulfillmentType, FulfillmentType.takeaway);
      expect(entry.copyWith(status: OrderStatus.paid).tokenLabel, 'T-07',
          reason: 'a status change keeps the token');
    });

    test('a table order is unchanged', () async {
      await sync().applyInitialSync(full(<String, dynamic>{
        'tables': <Object>[
          <String, dynamic>{'id': 't1', 'name': 'T1', 'status': 'occupied'},
        ],
        'active_orders': <Object>[
          <String, dynamic>{
            'id': 'o1',
            'table_id': 't1',
            'order_type': 'dine_in',
            'total': 250,
            'items': <Object>[
              <String, dynamic>{
                'id': 'oi1',
                'item_name': 'Dal',
                'quantity': 1,
                'unit_price': 250,
                'total_price': 250,
              },
            ],
          },
        ],
      }));
      final entry = container.read(historyProvider).single;
      expect(entry.tableId, 'T1');
      expect(entry.tokenLabel, isNull);
      expect(entry.fulfillmentType, isNull);
    });
  });

  group('offline snapshot', () {
    test('keeps qsr_config, so a cold start offline opens the Counter',
        () async {
      final live = sync()..deskInstanceIdOverride = 'desk-1';
      await live.applyInitialSync(full(fixture('sync_qsr_keys.json')));
      await live.saveSnapshot();

      final saved = (await store.load(deskInstanceId: 'desk-1'))!;
      expect(saved.qsrConfig!['operating_mode'], 'qsr');

      final cold = newContainer();
      addTearDown(cold.dispose);
      expect(
          await cold
              .read(syncServiceProvider)
              .hydrateFromSnapshot(deskInstanceId: 'desk-1'),
          isTrue);
      expect(cold.read(qsrConfigProvider).isQsr, isTrue);
      expect(
          cold.read(qsrConfigProvider).tokenStrategy, TokenStrategy.prefixed);
    });

    test('qsr_config:updated is saved too', () async {
      final live = sync()..deskInstanceIdOverride = 'desk-1';
      live.registerListeners();
      await live.applyInitialSync(full());
      deliver('qsr_config:updated', <String, dynamic>{
        'qsr_config': <String, dynamic>{'operating_mode': 'qsr'},
      });
      await live.saveSnapshot();
      expect((await store.load())!.qsrConfig!['operating_mode'], 'qsr');
    });

    test('a snapshot from before QSR hydrates restaurant mode', () async {
      await store.save(OfflineSnapshot(
        savedAt: DateTime.utc(2026, 10, 9),
        deskInstanceId: 'desk-1',
      ));
      container.read(qsrConfigProvider.notifier).state =
          QsrConfig.tryParse(<String, dynamic>{'operating_mode': 'qsr'})!;
      expect(
          await sync().hydrateFromSnapshot(deskInstanceId: 'desk-1'), isTrue);
      expect(container.read(qsrConfigProvider).isQsr, isFalse);
    });
  });

  test('the entry-ticket providers start empty', () {
    expect(container.read(qsrConfigProvider).isQsr, isFalse);
    expect(container.read(ticketTypesProvider), isEmpty);
    expect(container.read(ticketConfigProvider), same(TicketConfig.none));
    expect(container.read(payModesProvider), isEmpty);
    expect(container.read(lastTokenProvider), isNull);
  });
}
