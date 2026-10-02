import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/services/socket_service.dart';
import 'package:restro/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// Contract item 8: once the desk turns on connection-state recovery for a
/// capable client, every broadcast reaches socket_io_client as
/// `[payload, offset]`. Every handler in the sync service expects the payload
/// Map; if the unwrap ever regressed, the whole live-update layer would go
/// silent without a single error. This pins it for *every* event the app
/// listens to.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late SocketService socket;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    socket = SocketService();
    container = ProviderContainer(
      overrides: [socketServiceProvider.overrideWithValue(socket)],
    );
    // A real io.Socket that never connects: listeners attach to it, and
    // emitEvent() below delivers exactly what the Manager would.
    socket.debugAttachSocket(io.io(
      'http://127.0.0.1:1/operator',
      io.OptionBuilder().disableAutoConnect().build(),
    ));
  });

  tearDown(() {
    container.dispose();
  });

  /// What socket_io_client's `emitEvent` does for `[event, payload, offset]`.
  void deliver(String event, List<dynamic> args) =>
      socket.socket!.emitEvent(<dynamic>[event, ...args]);

  test('every event the sync service listens to is in broadcastEvents', () {
    final source = File('lib/services/sync_service.dart').readAsStringSync();
    final listened = RegExp(r"_socket\.on\('([^']+)'")
        .allMatches(source)
        .map((m) => m.group(1)!)
        .toSet();
    expect(listened, isNotEmpty);
    expect(listened, SyncService.broadcastEvents.toSet(),
        reason: 'a listener missing from broadcastEvents is never removed by '
            'unregisterListeners, and one missing here is untested below');
  });

  test('registerListeners registers all of them', () {
    container.read(syncServiceProvider).registerListeners();
    expect(socket.registeredEvents.toSet(),
        containsAll(SyncService.broadcastEvents));
  });

  test(
      'every broadcast, wrapped as [payload, offset], reaches a handler as a '
      'Map', () {
    // Spies only — not the real handlers, some of which (force:disconnect)
    // tear the socket down by design.
    for (final event in SyncService.broadcastEvents) {
      final payload = <String, dynamic>{'probe': event, 'order_id': 'o1'};
      Object? seen;
      socket.on(event, (data) => seen = data);

      deliver(event, <dynamic>[payload, 'AbCdEf12345']);

      expect(seen, isA<Map<dynamic, dynamic>>(),
          reason: '$event arrived as ${seen.runtimeType}');
      expect((seen! as Map<dynamic, dynamic>)['probe'], event);
    }
  });

  test('an event with no payload (just the offset) arrives as an empty Map',
      () {
    for (final event in SyncService.broadcastEvents) {
      Object? seen;
      socket.on(event, (data) => seen = data);
      deliver(event, <dynamic>['AbCdEf12345']);
      expect(seen, isA<Map<dynamic, dynamic>>(), reason: event);
      expect((seen! as Map<dynamic, dynamic>), isEmpty);
    }
  });

  test('the real handlers still apply an offset-wrapped payload', () async {
    container.read(syncServiceProvider).registerListeners();

    deliver('table:updated', <dynamic>[
      <String, dynamic>{
        'id': 't1',
        'name': 'T1',
        'status': 'free',
        'is_active': 1,
        'seats': 4,
      },
      'AbCdEf12345',
    ]);
    deliver('flags:updated', <dynamic>[
      <String, dynamic>{
        'flags': <String, dynamic>{'flag_rooms': true},
      },
      'AbCdEf12345',
    ]);
    // tables are applied on a 16ms flush.
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(container.read(tablesProvider).map((t) => t.serverId), ['t1']);
    expect(container.read(flagsProvider).rooms, isTrue);
  });

  test('without recovery the plain single-payload shape still works', () {
    container.read(syncServiceProvider).registerListeners();
    Object? seen;
    socket.on('order:updated', (data) => seen = data);
    deliver('order:updated', <dynamic>[
      <String, dynamic>{'order_id': 'o1'},
    ]);
    expect(seen, isA<Map<dynamic, dynamic>>());
  });
}
