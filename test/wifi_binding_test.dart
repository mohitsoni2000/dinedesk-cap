import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/link_monitor.dart';
import 'package:restro/services/wifi_binding.dart';

/// The Dart half of the Wi-Fi binding. The channel names are a contract with
/// the Kotlin side: `crew/network` (bindWifi/unbind) and `crew/network/events`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('crew/network');
  const events = EventChannel('crew/network/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockStreamHandler(events, null);
  });

  test('the no-op binding (iOS, tests) reports unbound and no events',
      () async {
    const binding = NoopWifiBinding();
    expect(await binding.bindWifi(), isFalse);
    await binding.unbind();
    expect(await binding.events.isEmpty, isTrue);
  });

  test('bindWifi returns the native bool; unbind is forwarded', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call.method);
      return call.method == 'bindWifi' ? true : null;
    });
    final binding = AndroidWifiBinding();
    expect(await binding.bindWifi(), isTrue);
    await binding.unbind();
    expect(calls, ['bindWifi', 'unbind']);
  });

  test('a missing native half is treated as unbound, never thrown', () async {
    // No handler registered => MissingPluginException.
    final binding = AndroidWifiBinding();
    expect(await binding.bindWifi(), isFalse);
    await binding.unbind();
  });

  test('a platform error is treated as unbound', () async {
    messenger.setMockMethodCallHandler(
        method, (call) async => throw PlatformException(code: 'boom'));
    final binding = AndroidWifiBinding();
    expect(await binding.bindWifi(), isFalse);
    await binding.unbind();
  });

  test('network events arrive as NetworkEvents; junk is dropped', () async {
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (arguments, sink) {
        sink.success(<String, dynamic>{'type': 'available', 'networkId': '42'});
        sink.success(<String, dynamic>{'type': 'bogus'});
        sink.success(<String, dynamic>{'type': 'lost'});
        sink.endOfStream();
      }),
    );
    final received = await AndroidWifiBinding().events.toList();
    expect(received.map((e) => e.type),
        [NetworkEventType.available, NetworkEventType.lost]);
    expect(received.first.networkId, '42');
  });

  test('a missing event channel just yields a quiet stream', () async {
    final received = await AndroidWifiBinding()
        .events
        .toList()
        .timeout(const Duration(seconds: 2), onTimeout: () => <NetworkEvent>[]);
    expect(received, isEmpty);
  });
}
