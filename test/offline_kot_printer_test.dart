import 'package:flutter_test/flutter_test.dart';
import 'package:restro/models/kot_print_config.dart';
import 'package:restro/services/escpos_builder.dart';
import 'package:restro/services/lan_printer_service.dart';
import 'package:restro/services/offline_kot_printer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records every job instead of opening a socket. [failHosts] fail.
class _FakePrinter implements LanPrinter {
  final Set<String> failHosts;
  final List<({KotPrintDestination dest, EscposDoc doc})> jobs =
      <({KotPrintDestination dest, EscposDoc doc})>[];
  _FakePrinter({this.failHosts = const <String>{}});

  @override
  Future<LanPrintResult> printDoc(
      KotPrintDestination dest, EscposDoc doc) async {
    jobs.add((dest: dest, doc: doc));
    return failHosts.contains(dest.host)
        ? LanPrintResult.failure('${dest.host} refused')
        : const LanPrintResult.success();
  }
}

KotPrintDestination dest(String host, {int copies = 1}) =>
    KotPrintDestination(host: host, port: 9100, copies: copies);

OfflineKotLine line(String itemId, String name,
        {String? category, int qty = 1}) =>
    OfflineKotLine(
      itemId: itemId,
      categoryId: category,
      slip: KotSlipItem(name: name, quantity: qty),
    );

OfflineKotRequest request(
  List<OfflineKotLine> lines, {
  String orderType = 'dine_in',
  String? floorId = 'f1',
}) =>
    OfflineKotRequest(
      lines: lines,
      orderType: orderType,
      floorId: floorId,
      floorName: 'Ground',
      tableName: 'T4',
      operatorName: 'Ram',
      offlineRef: 'A7Q2-014',
      at: DateTime.utc(2026, 10, 5, 4, 45), // 10:15 IST
    );

void main() {
  // Kitchen (item + category routed), Bar (category routed, dine_in only),
  // Terrace (floor scoped), Fallback, Expo (master).
  final config = KotPrintConfig(
    version: 'v1',
    groups: <KotPrintGroup>[
      KotPrintGroup(id: 'kitchen', name: 'Kitchen', destinations: [
        dest('10.0.0.11'),
      ]),
      KotPrintGroup(
        id: 'bar',
        name: 'Bar',
        orderTypes: const <String>['dine_in'],
        destinations: [dest('10.0.0.12', copies: 2)],
      ),
      KotPrintGroup(
        id: 'terrace',
        name: 'Terrace Grill',
        floorIds: const <String>['f-terrace'],
        destinations: [dest('10.0.0.13')],
      ),
      KotPrintGroup(
        id: 'fallback',
        name: 'Fallback',
        isFallback: true,
        destinations: [dest('10.0.0.14')],
      ),
      KotPrintGroup(
        id: 'expo',
        name: 'Expo',
        isMaster: true,
        destinations: [dest('10.0.0.15')],
      ),
    ],
    itemGroups: const <String, List<String>>{
      'tikka': <String>['kitchen'],
      'grill': <String>['terrace'],
    },
    categoryGroups: const <String, List<String>>{
      'c-drinks': <String>['bar'],
      'c-mains': <String>['kitchen'],
    },
    floors: const <String, KotFloorLabel>{
      'f1': KotFloorLabel(printName: 'GF'),
      'f-terrace': KotFloorLabel(printName: 'Terrace', nameOnly: true),
    },
  );

  Map<String, List<String>> names(OfflineKotPlan plan) =>
      <String, List<String>>{
        for (final e in plan.byGroup.entries)
          e.key: e.value.map((l) => l.slip.name).toList(),
      };

  group('routing parity with planKotDispatch (print-group branch)', () {
    test('an item routes by its own group first', () {
      final plan = OfflineKotPrinter.plan(
        [line('tikka', 'Tikka', category: 'c-drinks')],
        config,
        orderType: 'dine_in',
        floorId: 'f1',
      );
      expect(names(plan)['kitchen'], ['Tikka']);
      expect(plan.byGroup.containsKey('bar'), isFalse,
          reason: 'the item group wins; the category is only a fallback route');
    });

    test('else by its category groups', () {
      final plan = OfflineKotPrinter.plan(
        [line('mojito', 'Mojito', category: 'c-drinks')],
        config,
        orderType: 'dine_in',
        floorId: 'f1',
      );
      expect(names(plan)['bar'], ['Mojito']);
    });

    test('unrouted items go to the fallback group', () {
      final plan = OfflineKotPrinter.plan(
        [line('mystery', 'Mystery', category: 'c-unknown')],
        config,
        orderType: 'dine_in',
        floorId: 'f1',
      );
      expect(names(plan)['fallback'], ['Mystery']);
      expect(plan.legacy, isEmpty);
    });

    test('master groups receive everything, once', () {
      final plan = OfflineKotPrinter.plan(
        [
          line('tikka', 'Tikka'),
          line('mojito', 'Mojito', category: 'c-drinks'),
          line('mystery', 'Mystery'),
        ],
        config,
        orderType: 'dine_in',
        floorId: 'f1',
      );
      expect(names(plan)['expo'], ['Tikka', 'Mojito', 'Mystery']);
      expect(names(plan)['kitchen'], ['Tikka']);
      expect(names(plan)['fallback'], ['Mystery']);
    });

    test('a group that does not take this order type is skipped', () {
      final plan = OfflineKotPrinter.plan(
        [line('mojito', 'Mojito', category: 'c-drinks')],
        config,
        orderType: 'takeaway',
        floorId: null,
      );
      expect(plan.byGroup.containsKey('bar'), isFalse);
      expect(names(plan)['fallback'], ['Mojito'],
          reason: 'bar is dine_in only, so the item is unrouted');
    });

    test('a floor-scoped group needs the matching floor', () {
      final wrongFloor = OfflineKotPrinter.plan(
        [line('grill', 'Grill')],
        config,
        orderType: 'dine_in',
        floorId: 'f1',
      );
      expect(wrongFloor.byGroup.containsKey('terrace'), isFalse);
      expect(names(wrongFloor)['fallback'], ['Grill']);

      final right = OfflineKotPrinter.plan(
        [line('grill', 'Grill')],
        config,
        orderType: 'dine_in',
        floorId: 'f-terrace',
      );
      expect(names(right)['terrace'], ['Grill']);

      final unknownFloor = OfflineKotPrinter.plan(
        [line('grill', 'Grill')],
        config,
        orderType: 'dine_in',
        floorId: null,
      );
      expect(unknownFloor.byGroup.containsKey('terrace'), isFalse,
          reason: 'a floor-scoped group needs a KNOWN floor for seated orders');
    });

    test('takeaway has no floor and still reaches floor-scoped groups', () {
      final plan = OfflineKotPrinter.plan(
        [line('grill', 'Grill')],
        config,
        orderType: 'takeaway',
        floorId: null,
      );
      expect(names(plan)['terrace'], ['Grill']);
    });

    test('no fallback group: unrouted items are the legacy (desk) problem', () {
      final noFallback = KotPrintConfig(
        version: 'v',
        groups: <KotPrintGroup>[
          KotPrintGroup(id: 'kitchen', name: 'Kitchen', destinations: [
            dest('10.0.0.11'),
          ]),
        ],
        itemGroups: const <String, List<String>>{
          'tikka': <String>['kitchen'],
        },
      );
      final plan = OfflineKotPrinter.plan(
        [line('tikka', 'Tikka'), line('mystery', 'Mystery')],
        noFallback,
        orderType: 'dine_in',
      );
      expect(names(plan), {
        'kitchen': ['Tikka']
      });
      expect(plan.legacy.map((l) => l.slip.name), ['Mystery']);
    });

    test('ids that are not in the config are ignored', () {
      final stale = KotPrintConfig(
        version: 'v',
        groups: <KotPrintGroup>[
          KotPrintGroup(
              id: 'fallback',
              name: 'F',
              isFallback: true,
              destinations: [dest('10.0.0.14')]),
        ],
        itemGroups: const <String, List<String>>{
          'tikka': <String>['deleted-group'],
        },
      );
      final plan = OfflineKotPrinter.plan([line('tikka', 'Tikka')], stale,
          orderType: 'dine_in');
      expect(names(plan), {
        'fallback': ['Tikka']
      });
    });
  });

  group('printing', () {
    test('everything printed: ids reported, slips carry the offline ref',
        () async {
      final fake = _FakePrinter();
      final printer = OfflineKotPrinter(printer: fake);
      final outcome = await printer.print(
        config,
        request([
          line('tikka', 'Tikka', qty: 2),
          line('mojito', 'Mojito', category: 'c-drinks'),
        ]),
      );

      expect(outcome.printedGroupIds.toSet(), {'kitchen', 'bar', 'expo'});
      expect(outcome.failedGroupIds, isEmpty);
      expect(outcome.allPrinted, isTrue);

      final kitchen =
          fake.jobs.firstWhere((j) => j.dest.host == '10.0.0.11').doc;
      expect(kitchen.title, 'KITCHEN');
      expect(kitchen.subtitleLines.first, '*** OFFLINE KOT ***');
      expect(kitchen.subtitleLines, contains('KOT: A7Q2-014'));
      expect(kitchen.subtitleLines, contains('GF | Table T4'),
          reason: 'the floor prints its configured print_name');
      expect(kitchen.subtitleLines, contains('05 Oct 2026 10:15:00 am'),
          reason: 'IST, not UTC');
      expect(kitchen.itemLines, ['2 x Tikka']);
      expect(kitchen.footerLines, ['Steward: Ram']);

      final expo = fake.jobs.firstWhere((j) => j.dest.host == '10.0.0.15').doc;
      expect(expo.itemLines, ['2 x Tikka', '1 x Mojito']);
    });

    test('a floor with name_only prints the bare table name', () async {
      final fake = _FakePrinter();
      await OfflineKotPrinter(printer: fake).print(
        config,
        request([line('grill', 'Grill')], floorId: 'f-terrace'),
      );
      final doc = fake.jobs.firstWhere((j) => j.dest.host == '10.0.0.13').doc;
      expect(doc.subtitleLines, contains('Terrace | T4'));
    });

    test('destination copies are handed to the printer', () async {
      final fake = _FakePrinter();
      await OfflineKotPrinter(printer: fake).print(
        config,
        request([line('mojito', 'Mojito', category: 'c-drinks')]),
      );
      expect(
          fake.jobs.firstWhere((j) => j.dest.host == '10.0.0.12').dest.copies,
          2);
    });

    test('a failing printer reports its group as failed, the rest as printed',
        () async {
      final fake = _FakePrinter(failHosts: {'10.0.0.12'});
      final outcome = await OfflineKotPrinter(printer: fake).print(
        config,
        request([
          line('tikka', 'Tikka'),
          line('mojito', 'Mojito', category: 'c-drinks'),
        ]),
      );
      expect(outcome.failedGroupIds, ['bar']);
      expect(outcome.printedGroupIds.toSet(), {'kitchen', 'expo'});
      expect(outcome.errors['bar'], contains('refused'));
      expect(outcome.anyPrinted, isTrue);
      expect(outcome.allPrinted, isFalse);
    });

    test('a group with several destinations fails if ANY of them fails',
        () async {
      final twoPrinters = KotPrintConfig(
        version: 'v',
        groups: <KotPrintGroup>[
          KotPrintGroup(
              id: 'kitchen',
              name: 'Kitchen',
              isFallback: true,
              destinations: [dest('10.0.0.11'), dest('10.0.0.21')]),
        ],
      );
      final fake = _FakePrinter(failHosts: {'10.0.0.21'});
      final outcome = await OfflineKotPrinter(printer: fake)
          .print(twoPrinters, request([line('x', 'X')]));
      expect(fake.jobs.length, 2, reason: 'both destinations were tried');
      expect(outcome.failedGroupIds, ['kitchen']);
      expect(outcome.printedGroupIds, isEmpty);
    });

    test('nothing printed: no printed_offline marker at all', () async {
      final fake = _FakePrinter(
          failHosts: {'10.0.0.11', '10.0.0.12', '10.0.0.14', '10.0.0.15'});
      final outcome = await OfflineKotPrinter(printer: fake)
          .print(config, request([line('tikka', 'Tikka')]));
      expect(outcome.anyPrinted, isFalse);
      expect(outcome.toPayloadFields(DateTime.utc(2026)), isEmpty,
          reason: 'the desk must print a KOT nobody printed');
    });

    test('a group the desk listed without a network printer counts as failed',
        () async {
      final winOnly = KotPrintConfig(
        version: 'v',
        groups: <KotPrintGroup>[
          const KotPrintGroup(id: 'windows-only', name: 'Pass'),
          KotPrintGroup(
              id: 'fallback',
              name: 'Fallback',
              isFallback: true,
              destinations: [dest('10.0.0.14')]),
        ],
        itemGroups: const <String, List<String>>{
          'tikka': <String>['windows-only'],
        },
      );
      final outcome = await OfflineKotPrinter(printer: _FakePrinter())
          .print(winOnly, request([line('tikka', 'Tikka'), line('x', 'X')]));
      expect(outcome.failedGroupIds, ['windows-only']);
      expect(outcome.printedGroupIds, ['fallback']);
    });

    test('unroutable items are reported as the legacy failure', () async {
      final noFallback = KotPrintConfig(
        version: 'v',
        groups: <KotPrintGroup>[
          KotPrintGroup(id: 'kitchen', name: 'Kitchen', destinations: [
            dest('10.0.0.11'),
          ]),
        ],
        itemGroups: const <String, List<String>>{
          'tikka': <String>['kitchen'],
        },
      );
      final outcome = await OfflineKotPrinter(printer: _FakePrinter())
          .print(noFallback, request([line('tikka', 'Tikka'), line('m', 'M')]));
      expect(outcome.printedGroupIds, ['kitchen']);
      expect(outcome.failedGroupIds, [legacyFailedGroupId]);
    });

    test('payload fields follow the contract (item 10)', () async {
      final outcome = await OfflineKotPrinter(printer: _FakePrinter())
          .print(config, request([line('tikka', 'Tikka')]));
      final fields = outcome.toPayloadFields(DateTime.utc(2026, 10, 5, 4, 45));
      expect(fields['printed_offline'], isTrue);
      expect(fields['offline_ref'], 'A7Q2-014');
      expect(fields['printed_at'], '2026-10-05T04:45:00.000Z');
      expect(fields['failed_group_ids'], isEmpty);
    });

    test('a printer that throws is a failure, not an exception', () async {
      final outcome = await OfflineKotPrinter(printer: _ThrowingPrinter())
          .print(config, request([line('tikka', 'Tikka')]));
      expect(outcome.anyPrinted, isFalse);
      expect(outcome.failedGroupIds, isNotEmpty);
    });

    test('no items prints nothing', () async {
      final fake = _FakePrinter();
      final outcome =
          await OfflineKotPrinter(printer: fake).print(config, request([]));
      expect(fake.jobs, isEmpty);
      expect(outcome.anyPrinted, isFalse);
    });
  });

  group('offline_ref', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('is CODE-NNN, with a persistent 4-char code and a rising counter',
        () async {
      final gen = OfflineRefGenerator();
      final a = await gen.next();
      final b = await gen.next();
      expect(a, matches(RegExp(r'^[A-Z2-9]{4}-001$')));
      expect(b, matches(RegExp(r'^[A-Z2-9]{4}-002$')));
      expect(a.substring(0, 4), b.substring(0, 4));

      // A new generator (an app restart) carries on, same code, next number.
      final c = await OfflineRefGenerator().next();
      expect(c.substring(0, 4), a.substring(0, 4));
      expect(c.endsWith('-003'), isTrue);
      expect(c.length, lessThanOrEqualTo(40));
    });

    test('concurrent callers never get the same ref', () async {
      final gen = OfflineRefGenerator();
      final refs = await Future.wait(<Future<String>>[
        for (var i = 0; i < 10; i++) gen.next(),
      ]);
      expect(refs.toSet().length, 10);
    });

    test('the code is derived from the persistent id', () {
      expect(OfflineRefGenerator.deviceCode('abc'),
          OfflineRefGenerator.deviceCode('abc'));
      expect(OfflineRefGenerator.deviceCode('abc'),
          isNot(OfflineRefGenerator.deviceCode('abd')));
      expect(OfflineRefGenerator.format('A7Q2', 14), 'A7Q2-014');
      expect(OfflineRefGenerator.format('A7Q2', 1234), 'A7Q2-1234');
    });
  });

  group('KotPrintConfig parsing', () {
    test('parses the desk shape and survives a toJson round trip', () {
      final raw = <String, dynamic>{
        'version': 'abc',
        'groups': [
          {
            'id': 7,
            'name': 'Kitchen',
            'is_master': false,
            'is_fallback': 1,
            'order_types': ['dine_in'],
            'floor_ids': <String>[],
            'destinations': [
              {
                'host': '10.0.0.5',
                'port': 9100,
                'copies': 0,
                'printable_width_mm': 72,
                'chars_per_line': 42
              },
              {'host': '', 'port': 9100},
            ],
          },
        ],
        'item_groups': {
          'i1': ['7']
        },
        'category_groups': {
          'c1': ['7']
        },
        'floors': {
          'f1': {'print_name': 'GF', 'name_only': true}
        },
        'beverages_enabled': true,
      };
      final cfg = KotPrintConfig.tryParse(raw)!;
      expect(cfg.groups.single.id, '7');
      expect(cfg.groups.single.isFallback, isTrue);
      expect(cfg.groups.single.destinations.length, 1,
          reason: 'an empty host is no destination');
      expect(cfg.groups.single.destinations.single.copies, 1,
          reason: 'copies <= 0 counts as 1');
      expect(cfg.floors['f1']!.nameOnly, isTrue);
      expect(cfg.beveragesEnabled, isTrue);
      final again = KotPrintConfig.tryParse(cfg.toJson())!;
      expect(again.version, 'abc');
      expect(again.itemGroups['i1'], ['7']);
    });

    test('null / garbage is "no direct printing", not an error', () {
      expect(KotPrintConfig.tryParse(null), isNull);
      expect(KotPrintConfig.tryParse('x'), isNull);
      expect(KotPrintConfig.tryParse(<String, dynamic>{'groups': <Object>[]}),
          isNull);
    });
  });
}

class _ThrowingPrinter implements LanPrinter {
  @override
  Future<LanPrintResult> printDoc(KotPrintDestination dest, EscposDoc doc) =>
      throw StateError('boom');
}
