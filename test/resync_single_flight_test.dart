import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/services/socket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// F3: the post-connect resync used to be requested twice at once (the sync
/// service's own state listener and the bootstrap). `_requestResync` is now
/// single-flight, with these sharing rules.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late SocketService socket;
  late List<Map<String, dynamic>> emitted;
  late List<Completer<dynamic>> replies;

  Map<String, dynamic> success() => <String, dynamic>{
        'kind': 'success',
        'sync': <String, dynamic>{},
        'operator': <String, dynamic>{'id': 'op1', 'name': 'Asha'},
      };

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    socket = SocketService();
    emitted = <Map<String, dynamic>>[];
    replies = <Completer<dynamic>>[];
    socket.debugSetState(SocketState.connected);
    socket.rawEmitOverride = (event, data, timeout) {
      if (event != 'operator:resync') {
        return Future<dynamic>.value(<String, dynamic>{'kind': 'success'});
      }
      emitted.add(data);
      final c = Completer<dynamic>();
      replies.add(c);
      return c.future;
    };
    container = ProviderContainer(
      overrides: [socketServiceProvider.overrideWithValue(socket)],
    );
  });

  tearDown(() {
    container.dispose();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 10));

  test('two full requests at once share one emit and one result', () async {
    final sync = container.read(syncServiceProvider);

    final a = sync.requestResync();
    final b = sync.requestResync();
    await settle();
    expect(emitted, hasLength(1));

    replies.single.complete(success());
    expect(await a, isTrue);
    expect(await b, isTrue);
    expect(emitted, hasLength(1), reason: 'the second never hit the wire');
  });

  test('a menu-only request during a full one shares it', () async {
    final sync = container.read(syncServiceProvider);

    final full = sync.requestResync();
    // flags/menu:access:updated both end up here.
    final menuOnly = sync.debugRequestMenuOnlyResync();
    await settle();
    expect(emitted, hasLength(1));
    expect(emitted.single.containsKey('sections'), isFalse,
        reason: 'the one emit is the full one');

    replies.single.complete(success());
    expect(await full, isTrue);
    expect(await menuOnly, isTrue);
    expect(emitted, hasLength(1));
  });

  test('a full request during a menu-only one waits, then runs its own',
      () async {
    final sync = container.read(syncServiceProvider);

    final menuOnly = sync.debugRequestMenuOnlyResync();
    await settle();
    expect(emitted, hasLength(1));
    expect(emitted.single['sections'], ['menu']);

    final full = sync.requestResync();
    await settle();
    expect(emitted, hasLength(1),
        reason: 'a menu-only reply cannot satisfy a full request, but it must '
            'not race it either');

    replies[0].complete(success());
    expect(await menuOnly, isTrue);
    await settle();
    expect(emitted, hasLength(2));
    expect(emitted[1].containsKey('sections'), isFalse);

    replies[1].complete(success());
    expect(await full, isTrue);
  });

  test('several full requests behind a menu-only one still emit only once',
      () async {
    final sync = container.read(syncServiceProvider);
    final menuOnly = sync.debugRequestMenuOnlyResync();
    await settle();
    final f1 = sync.requestResync();
    final f2 = sync.requestResync();
    replies[0].complete(success());
    await menuOnly;
    await settle();
    expect(emitted, hasLength(2));
    replies[1].complete(success());
    expect(await f1, isTrue);
    expect(await f2, isTrue);
    expect(emitted, hasLength(2));
  });

  test('once settled, the next request goes out again', () async {
    final sync = container.read(syncServiceProvider);
    final first = sync.requestResync();
    await settle();
    replies[0].complete(success());
    await first;

    final second = sync.requestResync();
    await settle();
    expect(emitted, hasLength(2));
    replies[1].complete(success());
    expect(await second, isTrue);
  });

  test('a failed resync does not wedge the single-flight slot', () async {
    final sync = container.read(syncServiceProvider);
    final first = sync.requestResync();
    await settle();
    replies[0].complete(<String, dynamic>{
      'kind': 'error',
      'message': 'nope',
    });
    expect(await first, isFalse);
    expect(sync.lastResyncWasTransportFailure, isFalse);

    final second = sync.requestResync();
    await settle();
    expect(emitted, hasLength(2));
    replies[1].complete(success());
    expect(await second, isTrue);
  });

  test(
      'a transport failure is flagged so the bootstrap can retry, not ask '
      'for a PIN', () async {
    final sync = container.read(syncServiceProvider);
    final pending = sync.requestResync();
    await settle();
    replies[0].completeError(TimeoutException('ack timed out'));
    expect(await pending, isFalse);
    expect(sync.lastResyncWasTransportFailure, isTrue);
  });

  test('a success verifies the socket, authenticates, and kicks the outbox',
      () async {
    final sync = container.read(syncServiceProvider);
    final pending = sync.requestResync();
    await settle();
    replies[0].complete(success());
    await pending;

    expect(socket.state, SocketState.verified);
    expect(container.read(isAuthenticatedProvider), isTrue);
    expect(container.read(operatorProvider)?.name, 'Asha');
  });

  test('reauth_required with the prompt unavailable fails without recursing',
      () async {
    final sync = container.read(syncServiceProvider);
    final pending = sync.requestResync();
    await settle();
    replies[0].complete(<String, dynamic>{
      'kind': 'error',
      'code': 'reauth_required',
      'message': 'PIN verification required',
    });
    // No navigator in a unit test => the prompt reports "not entered".
    expect(await pending.timeout(const Duration(seconds: 2)), isFalse);
    expect(emitted, hasLength(1));
  });
}
