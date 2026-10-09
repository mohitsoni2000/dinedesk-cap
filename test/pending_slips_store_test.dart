import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:restro/models/entry_ticket.dart';
import 'package:restro/models/parked_draft.dart';
import 'package:restro/services/pending_slips_store.dart';
import 'package:restro/services/slip_printer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The slips the phone owes guests: kept per operator and desk, every state
/// saved as it happens, a job left "printing" by a gone app run shown as
/// unknown, printed ones pruned after a day, at most 200 kept.
void main() {
  const asha = ParkedScope(operatorId: 'op-asha', deskInstanceId: 'desk-1');
  const ravi = ParkedScope(operatorId: 'op-ravi', deskInstanceId: 'desk-1');
  const otherDesk =
      ParkedScope(operatorId: 'op-asha', deskInstanceId: 'desk-2');

  var clock = DateTime.utc(2026, 10, 9, 14, 40);
  PendingSlipsStore store() => PendingSlipsStore(now: () => clock);

  TicketSlip slip(String id, {String number = 'ET-041'}) => TicketSlip(
        ticketId: id,
        ticketNumber: number,
        qrData: 'CDT:7QKX2MZ4HB6TNW3R',
        content: TicketSlipContent(
          header: const <String>['Spice Hub', 'GSTIN 29ABCDE1234F1Z5'],
          ticketNo: number,
          title: 'COUPLE PASS',
          highlight: 'ADMITS 2 PAX',
          lines: const <String>['Guest: Ravi Sharma'],
          footer: const <String>['Valid on 09 Oct 2026 only.'],
          qrData: 'CDT:7QKX2MZ4HB6TNW3R',
        ),
      );

  Future<List<Object?>> rawJobs() async {
    final prefs = await SharedPreferences.getInstance();
    final m = jsonDecode(prefs.getString(PendingSlipsStore.prefsKey)!)
        as Map<String, dynamic>;
    return m['jobs'] as List<Object?>;
  }

  setUp(() {
    clock = DateTime.utc(2026, 10, 9, 14, 40);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('a slip comes back whole, with its words and QR', () async {
    final s = store();
    expect(await s.put(asha, <TicketSlip>[slip('t1')], SlipJobState.pending),
        isTrue);
    final job = (await s.list(asha)).single;
    expect(job.ticketId, 't1');
    expect(job.ticketNumber, 'ET-041');
    expect(job.qrData, 'CDT:7QKX2MZ4HB6TNW3R');
    expect(job.state, SlipJobState.pending);
    expect(job.isUnprinted, isTrue);
    final again = job.toSlip();
    expect(again.content!.header, <String>['Spice Hub', 'GSTIN 29ABCDE1234F1Z5']);
    expect(again.content!.highlight, 'ADMITS 2 PAX');
    expect(again.content!.lines, <String>['Guest: Ravi Sharma']);
    expect(again.content!.footer, <String>['Valid on 09 Oct 2026 only.']);
    expect(again.content!.qrData, 'CDT:7QKX2MZ4HB6TNW3R');
  });

  test('each operator on each desk sees only their own', () async {
    final s = store();
    await s.put(asha, <TicketSlip>[slip('t1')], SlipJobState.pending);
    await s.put(ravi, <TicketSlip>[slip('t2')], SlipJobState.pending);
    await s.put(otherDesk, <TicketSlip>[slip('t3')], SlipJobState.pending);
    expect((await s.list(asha)).map((j) => j.ticketId), <String>['t1']);
    expect((await s.list(ravi)).map((j) => j.ticketId), <String>['t2']);
    expect((await s.list(otherDesk)).map((j) => j.ticketId), <String>['t3']);

    await s.remove(asha, <String>['t1', 't2']);
    expect(await s.list(asha), isEmpty);
    expect((await s.list(ravi)).single.ticketId, 't2',
        reason: "another operator's slip is not ours to remove");
  });

  test('printing, then the outcome; a reprint moves the same job', () async {
    final s = store();
    await s.put(asha, <TicketSlip>[slip('t1'), slip('t2')],
        SlipJobState.printing);
    var jobs = await s.list(asha);
    expect(jobs.every((j) => j.isPrintingNow), isTrue);
    expect(jobs.any((j) => j.isUnprinted), isFalse,
        reason: 'on its way to the printer right now');

    clock = clock.add(const Duration(seconds: 5));
    await s.settle(asha, printed: <String>['t1'], failed: <String>['t2']);
    jobs = await s.list(asha);
    expect({for (final j in jobs) j.ticketId: j.state}, <String, SlipJobState>{
      't1': SlipJobState.printed,
      't2': SlipJobState.failed,
    });
    expect(jobs.where((j) => j.isUnprinted).map((j) => j.ticketId),
        <String>['t2']);

    clock = clock.add(const Duration(minutes: 1));
    await s.put(asha, <TicketSlip>[slip('t2')], SlipJobState.printing);
    jobs = await s.list(asha);
    expect(jobs, hasLength(2), reason: 'one job per ticket');
    final t2 = jobs.firstWhere((j) => j.ticketId == 't2');
    expect(t2.state, SlipJobState.printing);
    expect(t2.createdAt, DateTime.utc(2026, 10, 9, 14, 40),
        reason: 'when it was first saved');
  });

  test('a job left "printing" by a gone app run is unknown, and owed',
      () async {
    final s = store();
    await s.put(asha, <TicketSlip>[slip('t1')], SlipJobState.pending);
    final prefs = await SharedPreferences.getInstance();
    final jobs = await rawJobs();
    final raw = Map<String, dynamic>.from(jobs.single! as Map)
      ..['state'] = 'printing'
      ..['session'] = 'an-earlier-run';
    await prefs.setString(PendingSlipsStore.prefsKey,
        jsonEncode(<String, Object?>{'schema': 1, 'jobs': <Object?>[raw]}));

    final job = (await s.list(asha)).single;
    expect(job.isUnknown, isTrue);
    expect(job.isPrintingNow, isFalse);
    expect(job.isUnprinted, isTrue, reason: 'offered again, may duplicate');
  });

  test('printed slips go after a day; unprinted ones stay', () async {
    final s = store();
    await s.put(asha, <TicketSlip>[slip('t1'), slip('t2')],
        SlipJobState.printing);
    await s.settle(asha, printed: <String>['t1'], failed: <String>['t2']);
    clock = clock.add(const Duration(hours: 24, minutes: 1));
    expect((await s.list(asha)).map((j) => j.ticketId), <String>['t2']);
    expect(await rawJobs(), hasLength(1), reason: 'the prune is saved');
  });

  test('at most 200: the oldest printed go first, then the oldest of the rest',
      () async {
    final s = store();
    await s.put(
        asha,
        <TicketSlip>[for (var i = 0; i < 150; i++) slip('p$i')],
        SlipJobState.printing);
    await s.settle(asha,
        printed: <String>[for (var i = 0; i < 150; i++) 'p$i'],
        failed: const <String>[]);
    clock = clock.add(const Duration(minutes: 1));
    await s.put(asha, <TicketSlip>[for (var i = 0; i < 50; i++) slip('u$i')],
        SlipJobState.pending);
    expect(await s.list(asha), hasLength(200));

    clock = clock.add(const Duration(minutes: 1));
    await s.put(asha, <TicketSlip>[slip('new1'), slip('new2')],
        SlipJobState.pending);
    var jobs = await s.list(asha);
    expect(jobs, hasLength(200));
    expect(jobs.where((j) => j.state == SlipJobState.printed), hasLength(148),
        reason: 'two printed ones made room');
    expect(jobs.where((j) => j.isUnprinted), hasLength(52));
    expect(jobs.any((j) => j.ticketId == 'p0' || j.ticketId == 'p1'), isFalse,
        reason: 'the oldest printed went first');

    // With nothing printed left to drop, the oldest unprinted go.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await s.put(asha, <TicketSlip>[for (var i = 0; i < 200; i++) slip('a$i')],
        SlipJobState.pending);
    clock = clock.add(const Duration(minutes: 1));
    await s.put(asha, <TicketSlip>[slip('b0')], SlipJobState.pending);
    jobs = await s.list(asha);
    expect(jobs, hasLength(200));
    expect(jobs.last.ticketId, 'b0');
    expect(jobs.first.ticketId, 'a1', reason: 'a0, the oldest, made room');
  });

  test('another version\'s slips are left alone, and nothing is saved over them',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PendingSlipsStore.prefsKey: jsonEncode(<String, Object?>{
        'schema': 2,
        'jobs': <Object?>[],
      }),
    });
    final s = store();
    expect(await s.list(asha), isEmpty);
    expect(await s.put(asha, <TicketSlip>[slip('t1')], SlipJobState.pending),
        isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(
        (jsonDecode(prefs.getString(PendingSlipsStore.prefsKey)!)
            as Map<String, dynamic>)['schema'],
        2);
  });

  test('an entry this app cannot read is carried through as it was',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PendingSlipsStore.prefsKey: jsonEncode(<String, Object?>{
        'schema': 1,
        'jobs': <Object?>[
          <String, Object?>{'ticket_id': 'x', 'state': 'teleported'},
          'garbage',
        ],
      }),
    });
    final s = store();
    await s.put(asha, <TicketSlip>[slip('t1')], SlipJobState.pending);
    final jobs = await rawJobs();
    expect(jobs, hasLength(3));
    expect(jobs[0], <String, Object?>{'ticket_id': 'x', 'state': 'teleported'});
    expect(jobs[1], 'garbage');
  });

  test('saves racing each other all land (one lock for the key)', () async {
    final a = store();
    final b = store();
    await Future.wait(<Future<bool>>[
      for (var i = 0; i < 10; i++)
        (i.isEven ? a : b)
            .put(asha, <TicketSlip>[slip('r$i')], SlipJobState.pending),
    ]);
    expect(await a.list(asha), hasLength(10));
  });

  test('the notifier follows the store and never throws', () async {
    final jobs = SlipJobsNotifier(store(), asha);
    await jobs.record(<TicketSlip>[slip('t1')], SlipJobState.printing);
    expect(jobs.state.single.isPrintingNow, isTrue);
    await jobs.settle(printed: const <String>[], failed: <String>['t1']);
    expect(jobs.state.single.state, SlipJobState.failed);
    await jobs.remove(<String>['t1']);
    expect(jobs.state, isEmpty);
    jobs.dispose();

    final nobody = SlipJobsNotifier(store(), null);
    await nobody.record(<TicketSlip>[slip('t1')], SlipJobState.pending);
    expect(nobody.state, isEmpty, reason: 'no operator: nothing is kept');
    nobody.dispose();
  });
}
