// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/models/entry_ticket.dart';
import 'package:restro/models/parked_draft.dart';
import 'package:restro/services/bt_printer_service.dart';
import 'package:restro/services/escpos_slip.dart';
import 'package:restro/services/pending_slips_store.dart';
import 'package:restro/services/slip_printer.dart';
import 'package:restro/services/ticket_slip_builder.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_bluetooth_printer.dart';

const BtPrinterInfo _printer =
    BtPrinterInfo(name: 'RPP02N', address: '66:02:BD:06:18:7B');

List<int> _slip(int n) => <int>[0x1B, 0x40, n];

TicketSlip _ticket(String id, String number) => TicketSlip(
      ticketId: id,
      ticketNumber: number,
      qrData: 'CDT:7QKX2MZ4HB6TNW3R',
      content: TicketSlipContent(
        header: const <String>['Spice Hub'],
        ticketNo: number,
        title: 'COUPLE PASS',
        highlight: 'ADMITS 2 PAX',
        lines: const <String>['Guest: Ravi Sharma'],
        footer: const <String>['Valid on 09 Oct 2026 only.'],
        qrData: 'CDT:7QKX2MZ4HB6TNW3R',
      ),
    );

void main() {
  late FakeBluetoothPrinter fake;

  setUp(() {
    fake = FakeBluetoothPrinter();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('BtPrinterService', () {
    test('connects before the run, then one write per slip, in order',
        () async {
      final service = BtPrinterService(fake, interSlipPause: Duration.zero);
      final results =
          await service.printSlips(_printer, <List<int>>[_slip(1), _slip(2)]);
      expect(results.map((r) => r.ok), <bool>[true, true]);
      expect(fake.calls, <String>['connect', 'write', 'write']);
      expect(fake.written, <List<int>>[_slip(1), _slip(2)],
          reason: 'each slip whole, in one write');
    });

    test('reconnects up to twice before a run', () async {
      fake.connects.addAll(<bool>[false, true]);
      final service = BtPrinterService(fake, interSlipPause: Duration.zero);
      final results = await service.printSlips(_printer, <List<int>>[_slip(1)]);
      expect(results.single.ok, isTrue);
      expect(fake.calls, <String>['connect', 'connect', 'write']);
    });

    test('two failed connects: every slip fails, nothing is written',
        () async {
      fake.connects.addAll(<bool>[false, false]);
      final service = BtPrinterService(fake, interSlipPause: Duration.zero);
      final results =
          await service.printSlips(_printer, <List<int>>[_slip(1), _slip(2)]);
      expect(results.map((r) => r.ok), <bool>[false, false]);
      expect(results.first.error, 'not connected');
      expect(fake.calls, <String>['connect', 'connect']);
    });

    test('a printer still linked is only asked, not reconnected', () async {
      final service = BtPrinterService(fake, interSlipPause: Duration.zero);
      await service.printSlips(_printer, <List<int>>[_slip(1)]);
      fake.calls.clear();
      await service.printSlips(_printer, <List<int>>[_slip(2)]);
      expect(fake.calls, <String>['isConnected', 'write']);

      // The link dropped since: the next run connects again.
      fake
        ..linked = false
        ..calls.clear();
      await service.printSlips(_printer, <List<int>>[_slip(3)]);
      expect(fake.calls, <String>['isConnected', 'connect', 'write']);
    });

    test('partial failure: the failed slip is reported, the rest still print',
        () async {
      fake.writeAnswers.addAll(<bool>[true, false, true]);
      final service = BtPrinterService(fake, interSlipPause: Duration.zero);
      final results = await service.printSlips(
          _printer, <List<int>>[_slip(1), _slip(2), _slip(3)]);
      expect(results.map((r) => r.ok), <bool>[true, false, true]);
      expect(results[1].error, 'write failed');
      expect(fake.calls,
          <String>['connect', 'write', 'write', 'connect', 'write'],
          reason: 'a failed write reconnects for the slips after it');
      expect(fake.written, <List<int>>[_slip(1), _slip(3)]);
    });

    test('runs queue on one chain: the second starts when the first ends',
        () async {
      final service = BtPrinterService(fake, interSlipPause: Duration.zero);
      fake.gate = Completer<void>();
      final first =
          service.printSlips(_printer, <List<int>>[_slip(1), _slip(2)]);
      final second = service.printSlips(_printer, <List<int>>[_slip(3)]);
      await pumpEventQueue();
      expect(fake.calls, <String>['connect', 'write'],
          reason: 'the second run waits behind the first');
      fake.gate!.complete();
      final results = await Future.wait(<Future<List<BtSlipResult>>>[first, second]);
      expect(results.map((r) => r.length), <int>[2, 1]);
      expect(fake.written, <List<int>>[_slip(1), _slip(2), _slip(3)]);
    });

    test('pacing: a pause between slips, none before the first or after the last',
        () {
      fakeAsync((async) {
        final service = BtPrinterService(fake,
            interSlipPause: const Duration(milliseconds: 250));
        var done = false;
        unawaited(service
            .printSlips(_printer, <List<int>>[_slip(1), _slip(2), _slip(3)])
            .then((_) => done = true));
        async.flushMicrotasks();
        expect(fake.written, hasLength(1), reason: 'the first goes at once');
        async.elapse(const Duration(milliseconds: 249));
        expect(fake.written, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(fake.written, hasLength(2));
        async.elapse(const Duration(milliseconds: 250));
        expect(fake.written, hasLength(3));
        expect(done, isTrue, reason: 'no pause after the last slip');
      });
    });

    test('the default pause: about 250 ms on Android, 600 ms on an iPhone', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(BtPrinterService(fake).interSlipPause,
          const Duration(milliseconds: 250));
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(BtPrinterService(fake).interSlipPause,
          const Duration(milliseconds: 600));
      debugDefaultTargetPlatformOverride = null;
    });

    test('disconnect waits for the run in progress', () async {
      final service = BtPrinterService(fake, interSlipPause: Duration.zero);
      fake.gate = Completer<void>();
      final run = service.printSlips(_printer, <List<int>>[_slip(1)]);
      final off = service.disconnect();
      await pumpEventQueue();
      expect(fake.calls, isNot(contains('disconnect')));
      fake.gate!.complete();
      await Future.wait(<Future<Object?>>[run, off]);
      expect(fake.calls.last, 'disconnect');
    });
  });

  group('BtPrinterSettings', () {
    test('auto-cut follows the paper until set; JSON round trip', () {
      expect(const BtPrinterSettings().cuts, isFalse, reason: '58 mm tears');
      expect(const BtPrinterSettings(paper: SlipPaper.mm80).cuts, isTrue);
      expect(
          const BtPrinterSettings(paper: SlipPaper.mm80, autoCut: false).cuts,
          isFalse);

      const settings = BtPrinterSettings(
        printer: _printer,
        paper: SlipPaper.mm80,
        autoPrint: false,
        autoCut: false,
        qrMode: SlipQrMode.raster,
      );
      final back = BtPrinterSettings.fromJson(
          jsonDecode(jsonEncode(settings.toJson())));
      expect(back.printer, _printer);
      expect(back.printer!.name, 'RPP02N');
      expect(back.paper, SlipPaper.mm80);
      expect(back.autoPrint, isFalse);
      expect(back.autoCut, isFalse);
      expect(back.qrMode, SlipQrMode.raster);
    });

    test('anything unreadable falls back to no printer and the defaults', () {
      for (final raw in <Object?>[null, 'x', 7, <String, Object?>{'printer': 'x'}]) {
        final s = BtPrinterSettings.fromJson(raw);
        expect(s.printer, isNull);
        expect(s.paper, SlipPaper.mm58);
        expect(s.autoPrint, isTrue);
        expect(s.qrMode, SlipQrMode.native);
      }
    });

    test('the notifier loads what was saved and saves every change', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        BtPrinterSettings.prefsKey: jsonEncode(
            const BtPrinterSettings(printer: _printer, paper: SlipPaper.mm80)
                .toJson()),
      });
      final notifier = BtPrinterSettingsNotifier(const BtPrinterSettingsStore());
      await notifier.loaded;
      expect(notifier.current.printer, _printer);
      expect(notifier.current.paper, SlipPaper.mm80);

      await notifier.update(notifier.current.copyWith(clearPrinter: true));
      final prefs = await SharedPreferences.getInstance();
      expect(
          BtPrinterSettings.fromJson(
                  jsonDecode(prefs.getString(BtPrinterSettings.prefsKey)!))
              .printer,
          isNull);
      notifier.dispose();
    });
  });

  group('BtSlipPrinter (the gate seam)', () {
    const scope = ParkedScope(operatorId: 'op-asha', deskInstanceId: 'desk-1');

    BtSlipPrinter make(BtPrinterSettings settings, SlipJobsNotifier? jobs) =>
        BtSlipPrinter(
          settings: settings,
          service: BtPrinterService(fake, interSlipPause: Duration.zero),
          jobs: jobs,
        );

    test('without a printer it is not ready and prints nothing', () async {
      final printer = make(const BtPrinterSettings(), null);
      expect(printer.isReady, isFalse);
      final result = await printer.printSlips(<TicketSlip>[_ticket('t1', 'ET-041')]);
      expect(result.failed, <String>['t1']);
      await printer.afterSale(<TicketSlip>[_ticket('t1', 'ET-041')]);
      expect(fake.calls, isEmpty);
    });

    test('prints each slip as laid out for this printer, and keeps the record',
        () async {
      final jobs = SlipJobsNotifier(PendingSlipsStore(), scope);
      const settings = BtPrinterSettings(printer: _printer, paper: SlipPaper.mm80);
      final printer = make(settings, jobs);
      expect(printer.isReady, isTrue);
      fake.writeAnswers.addAll(<bool>[true, false]);

      final slips = <TicketSlip>[_ticket('t1', 'ET-041'), _ticket('t2', 'ET-042')];
      final result = await printer.printSlips(slips);
      expect(result.printed, <String>['t1']);
      expect(result.failed, <String>['t2']);
      expect(fake.written.single,
          ticketSlipBytes(slips.first.content!,
              qrData: slips.first.qrData, layout: settings.layout));

      final kept = {for (final j in jobs.state) j.ticketId: j.state};
      expect(kept, <String, SlipJobState>{
        't1': SlipJobState.printed,
        't2': SlipJobState.failed,
      });
      jobs.dispose();
    });

    test('a sale made before the saved settings load still prints', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        BtPrinterSettings.prefsKey:
            jsonEncode(const BtPrinterSettings(printer: _printer).toJson()),
      });
      final saved = BtPrinterSettingsNotifier(const BtPrinterSettingsStore());
      final printer = BtSlipPrinter(
        settings: saved.current,
        service: BtPrinterService(fake, interSlipPause: Duration.zero),
        latest: () async {
          await saved.loaded;
          return saved.current;
        },
      );
      expect(printer.isReady, isFalse, reason: 'still the defaults');
      await printer.afterSale(<TicketSlip>[_ticket('t1', 'ET-041')]);
      expect(fake.written, hasLength(1));
      saved.dispose();
    });

    test('a slip the desk sent no words for prints its number and QR', () {
      final bytes = latin1.decode(slipBytesFor(
          const TicketSlip(
              ticketId: 't9', ticketNumber: 'ET-009', qrData: 'CDT:7QKX2MZ4HB6TNW3R'),
          const BtPrinterSettings().layout));
      expect(bytes, contains('ET-009'));
      expect(bytes, contains('CDT:7QKX2MZ4HB6TNW3R'));
    });

    test('after a sale: auto-print prints; otherwise the slips wait as pending',
        () async {
      final jobs = SlipJobsNotifier(PendingSlipsStore(), scope);
      await make(const BtPrinterSettings(printer: _printer), jobs)
          .afterSale(<TicketSlip>[_ticket('t1', 'ET-041')]);
      expect(fake.written, hasLength(1));
      expect(jobs.state.single.state, SlipJobState.printed);

      await make(const BtPrinterSettings(printer: _printer, autoPrint: false), jobs)
          .afterSale(<TicketSlip>[_ticket('t2', 'ET-042')]);
      expect(fake.written, hasLength(1), reason: 'nothing more printed');
      expect(jobs.state.firstWhere((j) => j.ticketId == 't2').state,
          SlipJobState.pending);
      jobs.dispose();
    });

    test('logs carry counts, never a code, ticket number or guest', () async {
      final lines = <String>[];
      final saved = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => lines.add('$message');
      addTearDown(() => debugPrint = saved);

      final jobs = SlipJobsNotifier(PendingSlipsStore(), scope);
      fake
        ..connects.add(false)
        ..writeAnswers.addAll(<bool>[true, false]);
      await make(const BtPrinterSettings(printer: _printer), jobs).printSlips(
          <TicketSlip>[_ticket('t1', 'ET-041'), _ticket('t2', 'ET-042')]);
      jobs.dispose();

      expect(lines, isNotEmpty);
      for (final line in lines) {
        expect(line, isNot(contains('CDT:')));
        expect(line, isNot(contains('ET-04')));
        expect(line, isNot(contains('Ravi')));
        expect(line, isNot(contains('66:02:BD')));
      }
    });
  });
}
