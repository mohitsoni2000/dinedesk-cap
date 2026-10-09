// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/parked_draft.dart';
import 'package:restro/services/parked_drafts_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/parked_fixtures.dart';

/// A SharedPreferences backend whose writes all fail.
class _RefusingStore extends InMemorySharedPreferencesStore {
  _RefusingStore() : super.empty();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

/// A SharedPreferences backend with a slow disk, which counts how many writes
/// are in flight at once.
class _SlowDiskStore extends InMemorySharedPreferencesStore {
  _SlowDiskStore() : super.empty();

  int inFlight = 0;
  int mostInFlight = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    inFlight++;
    if (inFlight > mostInFlight) mostInFlight = inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final saved = await super.setValue(valueType, key, value);
    inFlight--;
    return saved;
  }
}

/// The cashier's parked carts and the gate's parked ticket sales live on the
/// phone only, in one SharedPreferences key. These tests pin what is kept,
/// what is shown to whom, and above all what is never thrown away.
void main() {
  const key = 'parked_drafts_v1';

  // 2026-10-09 15:30 in IST.
  final start = DateTime.utc(2026, 10, 9, 10, 0);
  late DateTime now;
  late ParkedDraftsStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    now = start;
    store = ParkedDraftsStore(now: () => now);
  });

  Future<String?> rawText() async =>
      (await SharedPreferences.getInstance()).getString(key);

  Future<Map<String, dynamic>> envelope() async =>
      jsonDecode((await rawText())!) as Map<String, dynamic>;

  Future<List<Object?>> entries() async =>
      (await envelope())['drafts'] as List<Object?>;

  Future<void> writeEntries(List<Object?> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, envelopeJson(entries));
  }

  Future<List<String>> ids(ParkedScope scope, {ParkedKind? kind}) async => [
        for (final d in await store.list(scope, kind: kind)) d.id,
      ];

  Map<String, dynamic> validEntry({
    String id = 'seeded',
    ParkedScope scope = asha,
    DateTime? createdAt,
    int seq = 1,
  }) =>
      draftOf(cartDraft(),
              scope: scope, createdAt: createdAt ?? now, seq: seq, id: id)
          .toJson();

  group('storage and schema', () {
    test('everything lives under one key as {schema: 1, drafts: [...]}',
        () async {
      await store.park(asha, cartDraft());
      await store.park(asha, ticketDraft());

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), <String>{key});
      final env = await envelope();
      expect(env.keys.toSet(), <String>{'schema', 'drafts'});
      expect(env['schema'], 1);
      expect(env['drafts'], hasLength(2));
    });

    test('each draft is stamped with the operator, the desk, its kind and when',
        () async {
      final cart = await store.park(asha, cartDraft());
      final tickets = await store.park(ravi, ticketDraft());

      final stored = await entries();
      final first = stored[0] as Map<String, dynamic>;
      expect(first['id'], cart.id);
      expect(first['kind'], 'counterCart');
      expect(first['operator_id'], 'op-asha');
      expect(first['desk_instance_id'], 'desk-1');
      expect(first['created_at'], '2026-10-09T10:00:00.000Z');
      final second = stored[1] as Map<String, dynamic>;
      expect(second['id'], tickets.id);
      expect(second['kind'], 'ticketIssue');
      expect(second['operator_id'], 'op-ravi');
    });

    test(
        'a ticket draft is stored as {lines: [{ticket_type_id, qty}], guest_*}',
        () async {
      await store.park(
        asha,
        ticketDraft(
          lines: <ParkedTicketLine>[
            ParkedTicketLine.of(ticketType(), 2),
            ParkedTicketLine.of(
                ticketType(id: 'tt-stag', name: 'Stag Entry', rupees: 600), 1),
          ],
          guestName: 'Meera',
          guestPhone: '9876500000',
        ),
      );
      final payload = ((await entries()).single
          as Map<String, dynamic>)['payload'] as Map<String, dynamic>;
      expect(payload['guest_name'], 'Meera');
      expect(payload['guest_phone'], '9876500000');
      final lines =
          (payload['lines'] as List<Object?>).cast<Map<String, dynamic>>();
      expect(lines.map((l) => l['ticket_type_id']), <String>[
        'tt-couple',
        'tt-stag',
      ]);
      expect(lines.map((l) => l['qty']), <int>[2, 1]);
    });

    test('money is kept as the rupee numbers the desk speaks', () async {
      await store.park(asha, cartDraft(<CartLine>[coffeeLine()]));
      final payload = ((await entries()).single
          as Map<String, dynamic>)['payload'] as Map<String, dynamic>;
      final line =
          (payload['lines'] as List<Object?>).single as Map<String, dynamic>;
      expect(line['item_price'], 120);
      expect(line['mods_extra'], 70);
      final addons = (line['selected_addons'] as List<Object?>).single
          as Map<String, dynamic>;
      expect(
          ((addons['choices'] as List<Object?>).single
              as Map<String, dynamic>)['price'],
          40);
    });

    for (final (name, raw) in <(String, String)>[
      ('another schema version', envelopeJson(<Object?>[], schema: 2)),
      ('a schema that is not a number', envelopeJson(<Object?>[], schema: '1')),
      ('no schema', jsonEncode(<String, Object?>{'drafts': <Object?>[]})),
      (
        'not a list of drafts',
        jsonEncode(<String, Object?>{'schema': 1, 'drafts': 'x'})
      ),
      ('not JSON', 'definitely not json'),
      ('not an object', '[1, 2, 3]'),
    ]) {
      test(
          'an envelope with $name is skipped and left as it was; the next '
          'park moves it aside and starts afresh', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{key: raw});

        expect(await store.list(asha), isEmpty);
        expect(await store.take(asha, 'anything'), isNull);
        expect(await store.discard(asha, 'anything'), isFalse);
        expect(await rawText(), raw,
            reason: 'reads never rewrite or delete what they cannot read');

        final parked = await store.park(asha, cartDraft());
        expect(parked.label, 'P1', reason: 'never blocked for good');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('$key.unreadable'), raw,
            reason: 'kept on the phone, byte for byte');
        expect((await store.list(asha)).single.id, parked.id);
      });
    }

    test('a value of the wrong type under the key is kept aside too', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        key: <String>['not', 'a', 'string']
      });
      expect(await store.list(asha), isEmpty);
      await store.park(asha, cartDraft());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('$key.unreadable'),
          <String>['not', 'a', 'string']);
      expect(await store.list(asha), hasLength(1));
    });

    test('a second unreadable envelope never overwrites the first one kept',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        key: 'second',
        '$key.unreadable': 'first',
      });
      await store.park(asha, cartDraft());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('$key.unreadable'), 'first');
      expect(prefs.getString('$key.unreadable.2'), 'second');
    });

    test('parking nothing is refused and writes nothing', () async {
      await expectLater(
        store.park(asha, const CounterCartDraft(lines: <ParkedCartLine>[])),
        throwsA(isA<ParkedDraftsException>()),
      );
      expect(await rawText(), isNull);
    });

    test('a refused write is an error, and leaves no phantom draft behind',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SharedPreferencesStorePlatform.instance = _RefusingStore();

      await expectLater(
        store.park(asha, cartDraft()),
        throwsA(isA<ParkedDraftsException>()
            .having((e) => e.message, 'message', contains("Couldn't save"))),
      );
      expect(await store.list(asha), isEmpty,
          reason: 'the phone must not show a cart it failed to keep');
    });
  });

  group('operator and desk', () {
    test('only the operator and desk that parked a draft see it', () async {
      final mine = await store.park(asha, cartDraft());

      expect(await ids(asha), <String>[mine.id]);
      expect(await ids(ravi), isEmpty, reason: 'another operator, same desk');
      expect(await ids(ashaElsewhere), isEmpty,
          reason: 'same operator, another desk');
    });

    test('a draft round-trips with its stamp and its contents', () async {
      final parked = await store.park(
        asha,
        CounterCartDraft.fromCart(<CartLine>[coffeeLine()], notes: 'to go'),
      );
      final back = (await store.list(asha)).single;
      expect(back.id, parked.id);
      expect(back.scope, asha);
      expect(back.kind, ParkedKind.counterCart);
      expect(back.createdAt, parked.createdAt);
      expect(back.payload.toJson(), parked.payload.toJson());
    });

    test('other operators\' drafts stay on disk untouched', () async {
      final theirs = await store.park(ravi, cartDraft());
      final theirEntry = (await entries()).single;

      final mine = await store.park(asha, cartDraft());
      await store.take(asha, mine.id);
      final another = await store.park(asha, ticketDraft());
      await store.discard(asha, another.id);

      expect(await store.discard(asha, theirs.id), isFalse,
          reason: 'not asha\'s to discard');
      expect(await store.take(asha, theirs.id), isNull,
          reason: 'not asha\'s to resume');
      expect(await entries(), <Object?>[theirEntry]);
      expect(await ids(ravi), <String>[theirs.id]);
    });

    test('not even one that happens to share an id with mine', () async {
      final theirs = <String, dynamic>{
        ...validEntry(id: 'same-id', scope: ravi),
      };
      final mine = <String, dynamic>{
        ...validEntry(id: 'same-id', scope: asha),
      };
      await writeEntries(<Object?>[theirs, mine]);

      expect(await store.discard(asha, 'same-id'), isTrue);

      expect(await entries(), <Object?>[theirs],
          reason: 'only asha\'s entry went');
      expect(await ids(ravi), <String>['same-id']);
    });

    test('list can ask for one kind', () async {
      final cart = await store.park(asha, cartDraft());
      final tickets = await store.park(asha, ticketDraft());
      expect(await ids(asha, kind: ParkedKind.counterCart), <String>[cart.id]);
      expect(
          await ids(asha, kind: ParkedKind.ticketIssue), <String>[tickets.id]);
      expect(await ids(asha), <String>[cart.id, tickets.id]);
    });
  });

  group('the cap: 20 per kind per operator', () {
    Future<List<String>> parkTwenty(ParkedScope scope,
        [ParkedPayload? payload]) async {
      final parked = <String>[];
      for (var i = 0; i < 20; i++) {
        parked.add((await store.park(scope, payload ?? cartDraft())).id);
        now = now.add(const Duration(minutes: 1));
      }
      return parked;
    }

    test('the 21st is refused with a clear error and nothing is evicted',
        () async {
      final first20 = await parkTwenty(asha);

      await expectLater(
        store.park(asha, cartDraft()),
        throwsA(isA<ParkedCapReached>()
            .having((e) => e.kind, 'kind', ParkedKind.counterCart)
            .having((e) => e.limit, 'limit', 20)
            .having(
                (e) => e.message,
                'message',
                'You already have 20 parked carts. '
                    'Resume or discard one first.')),
      );

      expect(await ids(asha), first20,
          reason: 'all twenty, oldest included, still there');
      expect(await entries(), hasLength(20));
    });

    test('a ticket sale reads naturally in the error', () async {
      await parkTwenty(asha, ticketDraft());
      await expectLater(
        store.park(asha, ticketDraft()),
        throwsA(isA<ParkedCapReached>().having(
            (e) => e.message, 'message', contains('20 parked ticket sales'))),
      );
    });

    test('the cap is per kind', () async {
      await parkTwenty(asha);
      final tickets = await store.park(asha, ticketDraft());
      expect(await ids(asha, kind: ParkedKind.ticketIssue), <String>[
        tickets.id,
      ]);
    });

    test('the cap is per operator and per desk', () async {
      await parkTwenty(asha);
      await store.park(ravi, cartDraft());
      await store.park(ashaElsewhere, cartDraft());
      expect(await store.list(ravi), hasLength(1));
      expect(await store.list(ashaElsewhere), hasLength(1));
      expect(await store.list(asha), hasLength(20));
    });

    test('discarding or resuming one frees a slot', () async {
      final all = await parkTwenty(asha);

      await store.discard(asha, all[3]);
      await store.park(asha, cartDraft());
      expect(await store.list(asha), hasLength(20));

      await expectLater(
          store.park(asha, cartDraft()), throwsA(isA<ParkedCapReached>()));
      await store.take(asha, all[0]);
      await store.park(asha, cartDraft());
      expect(await store.list(asha), hasLength(20));
    });

    test('drafts past their seven days do not count towards the cap', () async {
      final old = <Object?>[
        for (var i = 1; i <= 20; i++)
          validEntry(
              id: 'old-$i',
              seq: i,
              createdAt: now.subtract(const Duration(days: 8))),
      ];
      await writeEntries(old);

      final fresh = await store.park(asha, cartDraft());

      expect(await ids(asha), <String>[fresh.id]);
    });
  });

  group('retention: seven days', () {
    test('older than seven days is pruned, from the disk, not just the view',
        () async {
      final old = await store.park(asha, cartDraft());
      now = now.add(const Duration(days: 3));
      final middle = await store.park(asha, cartDraft());

      now = now.add(const Duration(days: 4));
      expect(await ids(asha), <String>[old.id, middle.id],
          reason: 'exactly seven days old is still kept');

      now = now.add(const Duration(minutes: 1));
      expect(await ids(asha), <String>[middle.id]);
      expect(await entries(), hasLength(1));
    });

    test('pruning applies to every operator\'s drafts, whoever is looking',
        () async {
      await store.park(ravi, cartDraft());
      now = now.add(const Duration(days: 8));
      final mine = await store.park(asha, cartDraft());

      expect(await ids(asha), <String>[mine.id]);
      expect(await entries(), hasLength(1), reason: 'ravi\'s expired one went');
    });

    test('a draft of an unknown kind or an unreadable one is never pruned',
        () async {
      final ancient = now.subtract(const Duration(days: 90));
      final unknown = <String, Object?>{
        ...validEntry(createdAt: ancient),
        'kind': 'banquetHold',
      };
      final corrupt = <String, Object?>{
        ...validEntry(createdAt: ancient),
        'payload': 'broken',
      };
      await writeEntries(<Object?>[unknown, corrupt]);

      expect(await store.list(asha), isEmpty);
      await store.park(asha, cartDraft());

      final kept = await entries();
      expect(kept, containsAll(<Object?>[unknown, corrupt]));
    });

    test('a clock set back does not expire anything', () async {
      final parked = await store.park(asha, cartDraft());
      now = now.subtract(const Duration(days: 30));
      expect(await ids(asha), <String>[parked.id]);
    });
  });

  group('what it cannot read is skipped and never deleted', () {
    final unreadable = <String, Object?>{'id': 'half-written'};

    test('corrupt entries are skipped, and survive every kind of write',
        () async {
      final good = validEntry(id: 'good');
      final corrupt = <Object?>[
        'a stray string',
        42,
        null,
        unreadable,
        <String, Object?>{...validEntry(id: 'bad-time'), 'created_at': 'soon'},
        <String, Object?>{...validEntry(id: 'bad-payload'), 'payload': 'x'},
        <String, Object?>{...validEntry(id: 'bad-seq'), 'seq': 0},
        <String, Object?>{
          ...validEntry(id: 'bad-line'),
          'payload': <String, Object?>{
            'lines': <Object?>[
              <String, Object?>{'quantity': 1}
            ]
          },
        },
        <String, Object?>{
          ...validEntry(id: 'no-lines'),
          'payload': <String, Object?>{'lines': <Object?>[]},
        },
      ];
      await writeEntries(
          <Object?>[...corrupt.take(4), good, ...corrupt.skip(4)]);

      expect(await ids(asha), <String>['good']);

      final parked = await store.park(asha, cartDraft());
      expect(await ids(asha), <String>['good', parked.id]);
      await store.discard(asha, parked.id);
      await store.take(asha, 'good');

      expect(await entries(), corrupt,
          reason: 'every unreadable entry is still there, in its place');
    });

    test('an entry of an unknown kind is skipped, not counted, not removed',
        () async {
      final unknown = <String, Object?>{
        ...validEntry(id: 'future'),
        'kind': 'banquetHold',
        'payload': <String, Object?>{'whatever': true},
      };
      await writeEntries(<Object?>[unknown]);

      expect(await store.list(asha), isEmpty);
      final cart = await store.park(asha, cartDraft());
      expect(await store.discard(asha, 'future'), isFalse,
          reason: 'it is not a draft this app knows how to discard');
      await store.discard(asha, cart.id);

      expect(await entries(), <Object?>[unknown]);
    });

    test('an unknown kind does not take up a slot of the cap or a label',
        () async {
      await writeEntries(<Object?>[
        <String, Object?>{...validEntry(id: 'future'), 'kind': 'banquetHold'},
      ]);
      final parked = await store.park(asha, cartDraft());
      expect(parked.label, 'P1');
    });

    test('what it skips is logged, without saying what was in it', () async {
      final lines = <String>[];
      final restore = debugPrint;
      debugPrint =
          (String? message, {int? wrapWidth}) => lines.add(message ?? '');
      addTearDown(() => debugPrint = restore);

      await writeEntries(<Object?>[
        <String, Object?>{...validEntry(id: 'future'), 'kind': 'banquetHold'},
        unreadable,
        'junk',
      ]);
      await store.list(asha);

      final text = lines.join('\n');
      expect(text, contains('[Parked]'));
      expect(text, contains('1 of an unknown kind'));
      expect(text, contains('2 unreadable'));
      expect(text, contains('left on disk'));

      lines.clear();
      await store.list(asha);
      await store.list(asha);
      expect(lines.where((l) => l.contains('unreadable')), isEmpty,
          reason: 'said once, not on every read');

      lines.clear();
      SharedPreferences.setMockInitialValues(
          <String, Object>{key: envelopeJson(<Object?>[], schema: 7)});
      await store.list(asha);
      await store.list(asha);
      expect(lines.where((l) => l.contains('schema 7')), hasLength(1),
          reason: 'a new state is said, once');
    });
  });

  group('survives re-instantiation', () {
    test('a new store sees what the old one parked', () async {
      final cart = await store.park(asha, cartDraft(<CartLine>[coffeeLine()]));
      final tickets = await store.park(
        asha,
        ticketDraft(guestName: 'Meera', guestPhone: '9876500000'),
      );

      final again = ParkedDraftsStore(now: () => now);
      final back = await again.list(asha);

      expect(back.map((d) => d.id), <String>[cart.id, tickets.id]);
      expect(back[0].payload.toJson(), cart.payload.toJson());
      expect(back[1].payload.toJson(), tickets.payload.toJson());
      expect(back.map((d) => d.label), <String>['P1', 'P1']);
    });

    test('labels carry on where the old store left off', () async {
      await store.park(asha, cartDraft());
      await store.park(asha, cartDraft());
      final again = ParkedDraftsStore(now: () => now);
      expect((await again.park(asha, cartDraft())).label, 'P3');
    });
  });

  group('labels: P1, P2, P3, restarting each IST day', () {
    test('run P1, P2, P3 for an operator', () async {
      final labels = <String>[
        for (var i = 0; i < 3; i++) (await store.park(asha, cartDraft())).label,
      ];
      expect(labels, <String>['P1', 'P2', 'P3']);
    });

    test('count carts and ticket sales on their own', () async {
      await store.park(asha, cartDraft());
      await store.park(asha, cartDraft());
      expect((await store.park(asha, ticketDraft())).label, 'P1');
    });

    test('count per operator and per desk', () async {
      await store.park(asha, cartDraft());
      expect((await store.park(ravi, cartDraft())).label, 'P1');
      expect((await store.park(ashaElsewhere, cartDraft())).label, 'P1');
    });

    test('restart at P1 when the IST day turns over, and only then', () async {
      // 23:59:59 IST on the 9th.
      now = DateTime.utc(2026, 10, 9, 18, 29, 59);
      final late1 = await store.park(asha, cartDraft());
      final late2 = await store.park(asha, cartDraft());

      // 00:00:00 IST on the 10th.
      now = DateTime.utc(2026, 10, 9, 18, 30);
      final next1 = await store.park(asha, cartDraft());
      final next2 = await store.park(asha, cartDraft());

      expect(<String>[late1.label, late2.label, next1.label, next2.label],
          <String>['P1', 'P2', 'P1', 'P2']);
      expect(await ids(asha), hasLength(4),
          reason: 'yesterday\'s drafts are still parked');
    });

    test('UTC midnight is not the day boundary: IST is', () async {
      // 05:00 IST on the 10th, a little before UTC midnight.
      now = DateTime.utc(2026, 10, 9, 23, 30);
      await store.park(asha, cartDraft());
      // 05:35 IST on the 10th: UTC has turned over, IST has not.
      now = DateTime.utc(2026, 10, 10, 0, 5);
      expect((await store.park(asha, cartDraft())).label, 'P2');
    });

    test('a label is not handed out again while its draft is still parked',
        () async {
      final p1 = await store.park(asha, cartDraft());
      await store.park(asha, cartDraft());
      await store.take(asha, p1.id);
      expect((await store.park(asha, cartDraft())).label, 'P3');
    });
  });

  group('resume and discard', () {
    test('take returns the draft and removes it; a second take finds nothing',
        () async {
      final parked = await store.park(asha, cartDraft());

      final first = await store.take(asha, parked.id);
      final second = await store.take(asha, parked.id);

      expect(first?.id, parked.id);
      expect(first?.payload.toJson(), parked.payload.toJson());
      expect(second, isNull, reason: 'two counters cannot both resume it');
      expect(await store.list(asha), isEmpty);
    });

    test('discard says whether there was anything to discard', () async {
      final parked = await store.park(asha, cartDraft());
      expect(await store.discard(asha, parked.id), isTrue);
      expect(await store.discard(asha, parked.id), isFalse);
      expect(await entries(), isEmpty);
    });
  });

  group('concurrency', () {
    test('parking in parallel never loses a draft or repeats a label',
        () async {
      final parked = await Future.wait(<Future<ParkedDraft>>[
        for (var i = 0; i < 12; i++) store.park(asha, cartDraft()),
      ]);

      expect(parked.map((d) => d.id).toSet(), hasLength(12));
      expect(parked.map((d) => d.seq).toSet(),
          <int>{for (var i = 1; i <= 12; i++) i});
      expect(await store.list(asha), hasLength(12));
    });

    test('writes to the disk never overlap, so a slow disk cannot reorder them',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final disk = _SlowDiskStore();
      SharedPreferencesStorePlatform.instance = disk;

      final seed = await store.park(asha, cartDraft());
      await Future.wait(<Future<Object?>>[
        for (var i = 0; i < 6; i++) store.park(asha, cartDraft()),
        store.take(asha, seed.id),
        store.park(ravi, ticketDraft()),
        store.discard(asha, 'nothing-by-this-name'),
        store.list(asha),
      ]);

      expect(disk.mostInFlight, 1);
      expect(await store.list(asha), hasLength(6));
      expect(await store.list(ravi), hasLength(1));
    });

    test('parks, resumes and discards racing each other leave a clean list',
        () async {
      final seed = await store.park(asha, cartDraft());
      final other = await store.park(asha, cartDraft());

      final results = await Future.wait(<Future<Object?>>[
        store.park(asha, cartDraft()),
        store.take(asha, seed.id),
        store.take(asha, seed.id),
        store.discard(asha, other.id),
        store.park(asha, cartDraft()),
      ]);

      expect(results.whereType<ParkedDraft>().where((d) => d.id == seed.id),
          hasLength(1),
          reason: 'exactly one of the two takes wins');
      expect(await store.list(asha), hasLength(2));
    });
  });

  group('logs carry counts and kinds, never contents', () {
    test('no item, note, guest or id ever reaches the log', () async {
      final lines = <String>[];
      final restore = debugPrint;
      debugPrint =
          (String? message, {int? wrapWidth}) => lines.add(message ?? '');
      addTearDown(() => debugPrint = restore);

      final cart = await store.park(
        asha,
        CounterCartDraft.fromCart(
          <CartLine>[
            CartLine(
              item: menuItem(name: 'Secret Dosa'),
              qty: 1,
              itemNote: 'Hush Note',
            ),
          ],
          notes: 'Order Whisper',
        ),
      );
      final tickets = await store.park(
        asha,
        ticketDraft(guestName: 'Asha Verma', guestPhone: '9876543210'),
      );
      await writeEntries(<Object?>[
        ...await entries(),
        'junk',
        <String, Object?>{...validEntry(id: 'future'), 'kind': 'banquetHold'},
      ]);
      await store.list(asha);
      await store.take(asha, tickets.id);
      await store.discard(asha, cart.id);
      final late = await store.park(asha, cartDraft());
      now = now.add(const Duration(days: 9));
      await store.list(asha);

      expect(lines, isNotEmpty, reason: 'it does say what it is doing');
      final text = lines.join('\n');
      for (final secret in <String>[
        'Secret Dosa',
        'Hush Note',
        'Order Whisper',
        'Asha Verma',
        '9876543210',
        'Couple Entry',
        'op-asha',
        'desk-1',
        cart.id,
        tickets.id,
        late.id,
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(text, contains('parked counterCart'));
      expect(text, contains('parked ticketIssue'));
      expect(text, contains('resumed ticketIssue'));
      expect(text, contains('discarded counterCart'));
      expect(text, contains('pruned 1 expired'));
    });
  });
}
