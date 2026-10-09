/// Bluetooth slip printing for the gate (blueprint 12, decision c).
///
/// - [BluetoothPrinter] is the seam: availability, discover, connect,
///   isConnected, write, disconnect. None of them throw; each answers with a
///   plain result. [PrintBluetoothThermalTransport] is the real one
///   (`print_bluetooth_thermal`: Classic SPP to a printer paired in
///   Android's settings, BLE on iPhone); tests use a fake.
/// - [BtPrinterService] is the job chain, LanPrinterService's pattern with
///   one tail: one print run at a time. Before a run it makes sure the
///   saved printer is connected (up to [BtPrinterService.connectAttempts]
///   tries), writes each slip as ONE write (so a QR's command sequence is
///   never split by our code), pauses between slips so a small printer's
///   buffer keeps up, and answers one result per slip. A write that fails
///   reconnects for the slips after it.
/// - [BtPrinterSettings] is this phone's printer, `bt_printer_v1`: which
///   printer, paper width, auto-print after a sale, auto-cut, QR mode.
/// - [BtSlipPrinter] is the gate's [SlipPrinter]: it saves each sale's slips
///   (pending_slips_store.dart) and prints them through the service.
///
/// Logs carry counts and outcomes, never a ticket code or guest data.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/entry_ticket.dart';
import 'escpos_slip.dart';
import 'log.dart';
import 'pending_slips_store.dart';
import 'slip_printer.dart';
import 'ticket_slip_builder.dart';

const String _tag = '[BtPrinter]';

/// A Bluetooth printer as the phone knows it: on Android a paired device and
/// its MAC address, on an iPhone a BLE peripheral and its UUID.
@immutable
class BtPrinterInfo {
  const BtPrinterInfo({required this.name, required this.address});

  final String name;
  final String address;

  Map<String, Object?> toJson() =>
      <String, Object?>{'name': name, 'address': address};

  static BtPrinterInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final address = raw['address'];
    if (address is! String || address.trim().isEmpty) return null;
    final name = raw['name'];
    return BtPrinterInfo(
      name: name is String && name.trim().isNotEmpty ? name : 'Printer',
      address: address,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BtPrinterInfo && other.address == address;

  @override
  int get hashCode => address.hashCode;
}

/// Whether Bluetooth can be used right now.
enum BtAvailability {
  ready,

  /// Bluetooth is switched off.
  off,

  /// The app may not use Bluetooth (Android "Nearby devices", iOS
  /// Bluetooth permission).
  denied,

  /// No Bluetooth on this device, or the printer plugin is not there.
  unsupported,
}

/// The printer seam. Nothing here throws: a printer that is off, out of
/// range or refusing is a `false`, an empty list, or [BtAvailability].
abstract class BluetoothPrinter {
  /// Asks for the Bluetooth permission when it has not been answered yet.
  Future<BtAvailability> availability();

  /// Android: the printers paired in system settings. iPhone: BLE devices
  /// nearby (a few seconds' scan).
  Future<List<BtPrinterInfo>> discover();

  Future<bool> connect(BtPrinterInfo printer);

  Future<bool> get isConnected;

  /// Sends [bytes] in one go; true when the printer took them.
  Future<bool> write(List<int> bytes);

  Future<void> disconnect();
}

/// [BluetoothPrinter] over `print_bluetooth_thermal`. Every call is guarded
/// and timed out: the plugin catches only PlatformException, and a missing
/// plugin (tests, a desktop build) must still answer.
class PrintBluetoothThermalTransport implements BluetoothPrinter {
  const PrintBluetoothThermalTransport({
    this.iosSettle = const Duration(milliseconds: 800),
    this.permissionTimeout = const Duration(minutes: 2),
  });

  /// On an iPhone the first call creates the Bluetooth manager, whose state
  /// is "unknown" for a moment: a first "no" is looked at again after this.
  final Duration iosSettle;

  /// The permission prompt waits for the user; unanswered this long, the
  /// answer is "not allowed".
  final Duration permissionTimeout;

  static const Duration _queryTimeout = Duration(seconds: 10);

  /// Android's RFCOMM connect gives up on its own after about 12s.
  static const Duration _connectTimeout = Duration(seconds: 20);

  /// A raster QR over BLE is a few KB in MTU-sized chunks.
  static const Duration _writeTimeout = Duration(seconds: 45);

  @override
  Future<BtAvailability> availability() async {
    final first = await _availabilityOnce();
    // Only an iPhone's first answer can be early. On Android every ask
    // prompts for the permission again, and a second "Don't allow" is final.
    if (defaultTargetPlatform != TargetPlatform.iOS ||
        first == BtAvailability.ready ||
        first == BtAvailability.unsupported) {
      return first;
    }
    await Future<void>.delayed(iosSettle);
    return _availabilityOnce();
  }

  Future<BtAvailability> _availabilityOnce() async {
    final bool granted;
    try {
      granted = await PrintBluetoothThermal.isPermissionBluetoothGranted
          .timeout(permissionTimeout);
    } on TimeoutException {
      // A prompt nobody answered: not allowed (yet), not "no Bluetooth".
      return BtAvailability.denied;
    } catch (error) {
      logD(_tag, 'availability: ${error.runtimeType}');
      return BtAvailability.unsupported;
    }
    if (!granted) return BtAvailability.denied;
    try {
      final on =
          await PrintBluetoothThermal.bluetoothEnabled.timeout(_queryTimeout);
      return on ? BtAvailability.ready : BtAvailability.off;
    } catch (error) {
      logD(_tag, 'availability: ${error.runtimeType}');
      return BtAvailability.unsupported;
    }
  }

  @override
  Future<List<BtPrinterInfo>> discover() async {
    try {
      final found = await PrintBluetoothThermal.pairedBluetooths
          .timeout(_queryTimeout);
      final printers = <BtPrinterInfo>[];
      for (final device in found) {
        final address = device.macAdress.trim();
        if (address.isEmpty || printers.any((p) => p.address == address)) {
          continue;
        }
        final name = device.name.trim();
        printers.add(BtPrinterInfo(
            name: name.isEmpty || name == 'Unknown' ? 'Unnamed device' : name,
            address: address));
      }
      return printers;
    } catch (error) {
      logD(_tag, 'discover: ${error.runtimeType}');
      return const <BtPrinterInfo>[];
    }
  }

  @override
  Future<bool> connect(BtPrinterInfo printer) async {
    try {
      return await PrintBluetoothThermal.connect(
              macPrinterAddress: printer.address)
          .timeout(_connectTimeout);
    } catch (error) {
      logD(_tag, 'connect: ${error.runtimeType}');
      return false;
    }
  }

  @override
  Future<bool> get isConnected async {
    try {
      return await PrintBluetoothThermal.connectionStatus
          .timeout(_queryTimeout);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> write(List<int> bytes) async {
    try {
      // A plain list, never a Uint8List (what latin1.encode makes): the codec
      // sends typed data as a byte[], which the plugin's Android side does
      // not read as `List<Int>`, so it would answer false and print nothing.
      return await PrintBluetoothThermal.writeBytes(List<int>.of(bytes))
          .timeout(_writeTimeout);
    } catch (error) {
      logD(_tag, 'write: ${error.runtimeType}');
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await PrintBluetoothThermal.disconnect.timeout(_queryTimeout);
    } catch (_) {}
  }
}

/// How one slip went.
@immutable
class BtSlipResult {
  const BtSlipResult.printed()
      : ok = true,
        error = null;
  const BtSlipResult.failed(String this.error) : ok = false;

  final bool ok;

  /// A short reason when [ok] is false, for the log.
  final String? error;

  @override
  String toString() => ok ? 'printed' : 'failed($error)';
}

/// The pause between two slips: Android's Classic link drains faster than
/// an iPhone's BLE one.
Duration defaultInterSlipPause() =>
    defaultTargetPlatform == TargetPlatform.iOS
        ? const Duration(milliseconds: 600)
        : const Duration(milliseconds: 250);

/// One print run at a time to the one printer this phone uses.
class BtPrinterService {
  BtPrinterService(
    this._printer, {
    Duration? interSlipPause,
    this.connectAttempts = 2,
    this.firstWriteRetryAfter = const Duration(milliseconds: 700),
  }) : interSlipPause = interSlipPause ?? defaultInterSlipPause();

  final BluetoothPrinter _printer;
  final Duration interSlipPause;

  /// Connect tries before a run (and after a write that failed).
  final int connectAttempts;

  /// An iPhone's BLE printer says "connected" before its write
  /// characteristic is found, so the first write after a fresh connect can
  /// be refused. It is tried once more after this pause. That never doubles
  /// a slip: iOS refuses such a write before sending a byte, and Android's
  /// plugin drops its socket on a failed write, so its retry sends nothing.
  final Duration firstWriteRetryAfter;

  /// The tail of the job chain: each run starts when the one before ended.
  Future<void> _tail = Future<void>.value();

  /// The printer the last successful connect was to.
  BtPrinterInfo? _linked;

  Future<T> _enqueue<T>(Future<T> Function() job) {
    final run = _tail.then((_) => job());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Prints [slips] on [target], in order, one write per slip. Never throws;
  /// one result per slip.
  Future<List<BtSlipResult>> printSlips(
          BtPrinterInfo target, List<List<int>> slips) =>
      _enqueue(() => _run(target, slips));

  /// Connects to [target] now (after it was picked), queued like a print.
  Future<bool> connect(BtPrinterInfo target) async =>
      await _enqueue(() => _ensureConnected(target)) != _Link.none;

  /// Lets the printer go, after any run in progress.
  Future<void> disconnect() => _enqueue(() async {
        _linked = null;
        await _printer.disconnect();
      });

  Future<List<BtSlipResult>> _run(
      BtPrinterInfo target, List<List<int>> slips) async {
    final results = <BtSlipResult>[];
    if (slips.isEmpty) return results;
    var link = await _ensureConnected(target);
    for (var i = 0; i < slips.length; i++) {
      if (link == _Link.none) {
        results.add(const BtSlipResult.failed('not connected'));
        continue;
      }
      if (i > 0) await Future<void>.delayed(interSlipPause);
      var ok = await _printer.write(slips[i]);
      if (!ok && link == _Link.fresh) {
        logD(_tag, 'first write after connect refused: trying once more');
        await Future<void>.delayed(firstWriteRetryAfter);
        ok = await _printer.write(slips[i]);
      }
      // Only the first write after a connect gets the second try.
      link = _Link.reused;
      if (ok) {
        results.add(const BtSlipResult.printed());
        continue;
      }
      results.add(const BtSlipResult.failed('write failed'));
      _linked = null;
      // The link may have dropped mid-run: reconnect for the slips after it.
      if (i < slips.length - 1) link = await _ensureConnected(target);
    }
    final printed = results.where((r) => r.ok).length;
    logD(_tag, 'printed $printed of ${slips.length}');
    return results;
  }

  Future<_Link> _ensureConnected(BtPrinterInfo target) async {
    if (_linked == target && await _printer.isConnected) return _Link.reused;
    for (var attempt = 1; attempt <= connectAttempts; attempt++) {
      if (await _printer.connect(target)) {
        _linked = target;
        return _Link.fresh;
      }
      logD(_tag, 'connect attempt $attempt failed');
    }
    _linked = null;
    return _Link.none;
  }
}

/// The printer link a write goes over: none, one already up, or one just
/// made (whose first write an iPhone's printer may not take yet).
enum _Link { none, reused, fresh }

/// This phone's slip printer, saved as `bt_printer_v1`.
@immutable
class BtPrinterSettings {
  const BtPrinterSettings({
    this.printer,
    this.paper = SlipPaper.mm58,
    this.autoPrint = true,
    this.autoCut,
    this.qrMode = SlipQrMode.native,
  });

  static const String prefsKey = 'bt_printer_v1';

  /// Null until a printer is chosen: then nothing prints and the gate
  /// shows the QR on screen.
  final BtPrinterInfo? printer;
  final SlipPaper paper;

  /// Print a sale's slips as soon as the desk confirms it.
  final bool autoPrint;

  /// Null: by paper (80 mm cuts, a 58 mm portable has a tear bar).
  final bool? autoCut;
  final SlipQrMode qrMode;

  bool get cuts => autoCut ?? paper == SlipPaper.mm80;

  SlipLayout get layout =>
      SlipLayout(paper: paper, qrMode: qrMode, autoCut: cuts);

  BtPrinterSettings copyWith({
    BtPrinterInfo? printer,
    bool clearPrinter = false,
    SlipPaper? paper,
    bool? autoPrint,
    bool? autoCut,
    SlipQrMode? qrMode,
  }) =>
      BtPrinterSettings(
        printer: clearPrinter ? null : printer ?? this.printer,
        paper: paper ?? this.paper,
        autoPrint: autoPrint ?? this.autoPrint,
        autoCut: autoCut ?? this.autoCut,
        qrMode: qrMode ?? this.qrMode,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'schema': 1,
        if (printer != null) 'printer': printer!.toJson(),
        'paper': paper.wire,
        'auto_print': autoPrint,
        if (autoCut != null) 'auto_cut': autoCut,
        'qr_mode': qrMode.wire,
      };

  static BtPrinterSettings fromJson(Object? raw) {
    if (raw is! Map) return const BtPrinterSettings();
    final autoPrint = raw['auto_print'];
    final autoCut = raw['auto_cut'];
    return BtPrinterSettings(
      printer: BtPrinterInfo.fromJson(raw['printer']),
      paper: SlipPaper.fromWire(raw['paper']),
      autoPrint: autoPrint is bool ? autoPrint : true,
      autoCut: autoCut is bool ? autoCut : null,
      qrMode: SlipQrMode.fromWire(raw['qr_mode']),
    );
  }
}

/// Reads and writes [BtPrinterSettings.prefsKey].
class BtPrinterSettingsStore {
  const BtPrinterSettingsStore();

  Future<BtPrinterSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString(BtPrinterSettings.prefsKey);
      if (text == null) return const BtPrinterSettings();
      return BtPrinterSettings.fromJson(jsonDecode(text));
    } catch (error) {
      logE(_tag, 'could not read the printer settings', error.runtimeType);
      return const BtPrinterSettings();
    }
  }

  Future<bool> save(BtPrinterSettings settings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(
          BtPrinterSettings.prefsKey, jsonEncode(settings.toJson()));
    } catch (error) {
      logE(_tag, 'could not save the printer settings', error.runtimeType);
      return false;
    }
  }
}

class BtPrinterSettingsNotifier extends StateNotifier<BtPrinterSettings> {
  BtPrinterSettingsNotifier(this._store) : super(const BtPrinterSettings()) {
    loaded = _load();
  }

  final BtPrinterSettingsStore _store;

  /// Completes once the saved settings are in [state].
  late final Future<void> loaded;
  bool _changed = false;

  /// The settings now (once [loaded], what is saved or changed since).
  BtPrinterSettings get current => state;

  Future<void> _load() async {
    final saved = await _store.load();
    // A change made while loading wins over what was on disk.
    if (mounted && !_changed) state = saved;
  }

  /// Applies [next] now and saves it.
  Future<void> update(BtPrinterSettings next) async {
    _changed = true;
    state = next;
    await _store.save(next);
  }
}

/// The real transport; tests override it with a fake.
final bluetoothPrinterProvider = Provider<BluetoothPrinter>(
    (_) => const PrintBluetoothThermalTransport());

final btPrinterServiceProvider = Provider<BtPrinterService>(
    (ref) => BtPrinterService(ref.watch(bluetoothPrinterProvider)));

final btPrinterSettingsProvider =
    StateNotifierProvider<BtPrinterSettingsNotifier, BtPrinterSettings>(
        (_) => BtPrinterSettingsNotifier(const BtPrinterSettingsStore()));

/// The gate's printer when Bluetooth printing is in (main.dart overrides
/// [slipPrinterProvider] with it). Screens see the settings as they are now;
/// a print waits until the saved ones are loaded, so a sale made the moment
/// the app opens still prints.
final btSlipPrinterProvider = Provider<SlipPrinter>((ref) {
  final saved = ref.watch(btPrinterSettingsProvider.notifier);
  return BtSlipPrinter(
    settings: ref.watch(btPrinterSettingsProvider),
    service: ref.watch(btPrinterServiceProvider),
    jobs: ref.watch(slipJobsProvider.notifier),
    latest: () async {
      await saved.loaded;
      return saved.current;
    },
  );
});

/// [slip] as bytes for [layout]. A slip the desk sent no words for prints
/// its ticket number and QR.
List<int> slipBytesFor(TicketSlip slip, SlipLayout layout) => ticketSlipBytes(
      slip.content ??
          TicketSlipContent(
            header: const <String>[],
            ticketNo: slip.ticketNumber,
            title: '',
            lines: const <String>[],
            footer: const <String>[],
          ),
      qrData: slip.qrData,
      layout: layout,
    );

/// A test page: the paper, QR and cut settings in use, and a QR that is not
/// a ticket (the gate's scanner ignores it without asking the desk).
List<int> testSlipBytes(BtPrinterSettings settings) => ticketSlipBytes(
      TicketSlipContent(
        header: const <String>['Command.Crew'],
        ticketNo: 'TEST',
        title: 'Printer check',
        highlight: 'IT WORKS',
        lines: <String>[
          'Paper ${settings.paper.wire} mm',
          'QR ${settings.qrMode == SlipQrMode.raster ? 'as image' : 'native'}',
          'Cut ${settings.cuts ? 'on' : 'off'}',
        ],
        footer: const <String>[
          'If this QR scans with a phone camera, entry slips will too.',
        ],
      ),
      qrData: 'TEST PRINT',
      layout: settings.layout,
    );

/// The gate's [SlipPrinter] over Bluetooth. Every slip it is asked to print
/// is saved first (so nothing is lost to a dead printer or a killed app),
/// then printed, then marked printed or failed.
class BtSlipPrinter implements SlipPrinter {
  BtSlipPrinter({
    required this.settings,
    required this.service,
    this.jobs,
    Future<BtPrinterSettings> Function()? latest,
  }) : _latest = latest;

  /// The settings as the screens see them now ([isReady]).
  final BtPrinterSettings settings;
  final BtPrinterService service;

  /// Null without a signed-in operator on a paired desk: prints anyway,
  /// keeps no record.
  final SlipJobsNotifier? jobs;

  /// The saved settings once loaded, for a print; [settings] without it.
  final Future<BtPrinterSettings> Function()? _latest;

  Future<BtPrinterSettings> _current() async {
    final latest = _latest;
    if (latest == null) return settings;
    try {
      return await latest();
    } catch (_) {
      return settings;
    }
  }

  @override
  bool get isReady => settings.printer != null;

  @override
  Future<SlipPrintResult> printSlips(List<TicketSlip> slips) async {
    final ids = <String>[for (final slip in slips) slip.ticketId];
    final current = await _current();
    final target = current.printer;
    if (target == null || slips.isEmpty) {
      return SlipPrintResult(printed: const <String>[], failed: ids);
    }
    await jobs?.record(slips, SlipJobState.printing);
    List<BtSlipResult> results;
    try {
      final layout = current.layout;
      results = await service.printSlips(target, <List<int>>[
        for (final slip in slips) slipBytesFor(slip, layout),
      ]);
    } catch (error) {
      logE(_tag, 'print run failed', error.runtimeType);
      results = const <BtSlipResult>[];
    }
    final printed = <String>[];
    final failed = <String>[];
    for (var i = 0; i < slips.length; i++) {
      final ok = i < results.length && results[i].ok;
      (ok ? printed : failed).add(ids[i]);
    }
    await jobs?.settle(printed: printed, failed: failed);
    return SlipPrintResult(printed: printed, failed: failed);
  }

  /// After a sale: print its slips now when auto-print is on, else keep them
  /// as pending for the slip queue. Nothing without a printer.
  @override
  Future<void> afterSale(List<TicketSlip> slips) async {
    if (slips.isEmpty) return;
    final current = await _current();
    if (current.printer == null) return;
    if (current.autoPrint) {
      await printSlips(slips);
    } else {
      await jobs?.record(slips, SlipJobState.pending);
    }
  }
}
