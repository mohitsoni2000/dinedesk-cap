import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restro/services/network_keepalive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  var startResult = true;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    startResult = true;
    NetworkKeepAlive.debugIsAndroid = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('crew/network'),
            (c) async {
      calls.add(c);
      return switch (c.method) {
        'startKeepAlive' => startResult,
        'isIgnoringBatteryOptimizations' => false,
        _ => true,
      };
    });
  });

  tearDown(() {
    NetworkKeepAlive.debugIsAndroid = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('crew/network'), null);
  });

  test('toggle defaults ON and persists', () async {
    expect(await NetworkKeepAlive.isEnabled(), isTrue);
    await NetworkKeepAlive.setEnabled(false);
    expect(await NetworkKeepAlive.isEnabled(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(NetworkKeepAlive.prefKey), isFalse);
  });

  test('start invokes the service and reports running', () async {
    expect(await NetworkKeepAlive.start(restaurant: 'Spice'), isTrue);
    expect(NetworkKeepAlive.isRunning, isTrue);
    expect(calls.single.method, 'startKeepAlive');
    expect((calls.single.arguments as Map)['restaurant'], 'Spice');
  });

  test('start is skipped when the toggle is off', () async {
    SharedPreferences.setMockInitialValues({NetworkKeepAlive.prefKey: false});
    expect(await NetworkKeepAlive.start(), isFalse);
    expect(calls, isEmpty);
  });

  test('a refused start leaves isRunning false', () async {
    startResult = false;
    expect(await NetworkKeepAlive.start(), isFalse);
    expect(NetworkKeepAlive.isRunning, isFalse);
  });

  test('stop always reaches the host', () async {
    await NetworkKeepAlive.stop();
    expect(calls.single.method, 'stopKeepAlive');
    expect(NetworkKeepAlive.isRunning, isFalse);
  });

  test('turning the toggle off stops, on starts', () async {
    await NetworkKeepAlive.setEnabled(false);
    expect(calls.map((c) => c.method), ['stopKeepAlive']);
    calls.clear();
    await NetworkKeepAlive.setEnabled(true, restaurant: 'X');
    expect(calls.map((c) => c.method), ['startKeepAlive']);
  });

  test('low-latency lock forwards the flag', () async {
    await NetworkKeepAlive.setLowLatencyLock(true);
    expect(calls.single.method, 'setLowLatencyLock');
    expect(calls.single.arguments, true);
  });

  test('battery prompt is one-time', () async {
    expect(await NetworkKeepAlive.shouldPromptBatteryOptimization(), isTrue);
    await NetworkKeepAlive.markBatteryPrompted();
    expect(await NetworkKeepAlive.shouldPromptBatteryOptimization(), isFalse);
  });

  test('everything is a no-op off Android', () async {
    NetworkKeepAlive.debugIsAndroid = false;
    expect(await NetworkKeepAlive.start(), isFalse);
    await NetworkKeepAlive.stop();
    await NetworkKeepAlive.setLowLatencyLock(true);
    expect(await NetworkKeepAlive.shouldPromptBatteryOptimization(), isFalse);
    expect(calls, isEmpty);
  });

  test('missing plugin is swallowed', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('crew/network'), null);
    expect(await NetworkKeepAlive.start(), isFalse);
    await NetworkKeepAlive.setLowLatencyLock(false);
  });
}
