import 'dart:async';

import 'package:restro/services/bt_printer_service.dart';

/// A printer that answers as told and remembers what it was asked.
class FakeBluetoothPrinter implements BluetoothPrinter {
  BtAvailability answer = BtAvailability.ready;
  List<BtPrinterInfo> nearby = const <BtPrinterInfo>[];

  /// Answers for the next connects, in order; true once they run out.
  final List<bool> connects = <bool>[];

  /// Answers for the next writes, in order; true once they run out.
  final List<bool> writeAnswers = <bool>[];

  /// When set, every write waits for it.
  Completer<void>? gate;

  bool linked = false;
  final List<String> calls = <String>[];
  final List<List<int>> written = <List<int>>[];

  @override
  Future<BtAvailability> availability() async => answer;

  @override
  Future<List<BtPrinterInfo>> discover() async => nearby;

  @override
  Future<bool> connect(BtPrinterInfo printer) async {
    calls.add('connect');
    linked = connects.isEmpty || connects.removeAt(0);
    return linked;
  }

  @override
  Future<bool> get isConnected async {
    calls.add('isConnected');
    return linked;
  }

  @override
  Future<bool> write(List<int> bytes) async {
    calls.add('write');
    await gate?.future;
    final ok = writeAnswers.isEmpty || writeAnswers.removeAt(0);
    if (ok) {
      written.add(bytes);
    } else {
      linked = false;
    }
    return ok;
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    linked = false;
  }
}
