// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/money.dart';
import 'package:restro/data/parked_providers.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/models/entry_ticket.dart';
import 'package:restro/models/parked_draft.dart';
import 'package:restro/services/parked_cart_resolver.dart';
import 'package:restro/services/parked_drafts_store.dart';
import 'package:restro/theme/app_theme.dart';
import 'package:restro/widgets/liquid_chrome.dart';
import 'package:restro/widgets/parked_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/parked_fixtures.dart';

/// Storage that holds what it was given but refuses every write.
class _RefusingStore extends InMemorySharedPreferencesStore {
  _RefusingStore(super.data) : super.withData();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

/// The parked sheet as a cashier or usher uses it: this operator's drafts for
/// one kind, Resume and Discard on each, and a resolved draft handed back.
void main() {
  const key = 'parked_drafts_v1';

  // Ids the fixtures give: pk-<operator>-<kind>-<seq>.
  const p1 = 'pk-op-asha-counterCart-1';
  const p2 = 'pk-op-asha-counterCart-2';
  const ravis = 'pk-op-ravi-counterCart-1';

  ValueKey<String> resume(String id) => ValueKey<String>('parked-resume-$id');
  ValueKey<String> discard(String id) => ValueKey<String>('parked-discard-$id');

  List<ParkedDraft> drafts() {
    final t = DateTime.now();
    return <ParkedDraft>[
      draftOf(
        CounterCartDraft.fromCart(<CartLine>[
          dosaLine(qty: 2),
          CartLine(item: coffee(), qty: 1),
        ]),
        createdAt: t.subtract(const Duration(minutes: 5)),
        seq: 1,
      ),
      draftOf(
        cartDraft(),
        createdAt: t.subtract(const Duration(hours: 2, minutes: 10)),
        seq: 2,
      ),
      draftOf(cartDraft(),
          scope: ravi,
          createdAt: t.subtract(const Duration(minutes: 1)),
          seq: 1),
      draftOf(ticketDraft(),
          createdAt: t.subtract(const Duration(minutes: 3)), seq: 1),
    ];
  }

  late ProviderContainer container;
  ParkedResume? result;
  var closed = false;

  Future<void> openSheet(
    WidgetTester tester, {
    Size size = const Size(1024, 1366),
    List<ParkedDraft>? parked,
    ParkedKind kind = ParkedKind.counterCart,
    List<MenuItem>? menu,
    List<TicketType>? types,
    Future<bool> Function(ParkedDraft draft)? beforeResume,
  }) async {
    // The default is wide enough for the test font, which draws every glyph a
    // full em wide; the layout test below asks for a real phone instead.
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues(<String, Object>{
      key: envelopeJson(
          <Object?>[for (final d in parked ?? drafts()) d.toJson()]),
    });
    container = ProviderContainer(overrides: [
      parkedScopeProvider.overrideWithValue(asha),
    ]);
    addTearDown(container.dispose);
    container.read(menuProvider.notifier).state =
        menu ?? <MenuItem>[menuItem(), coffee()];
    container.read(ticketTypesProvider.notifier).state = types ??
        <TicketType>[
          ticketType(),
          ticketType(id: 'tt-stag', name: 'Stag Entry', rupees: 600, pax: 1),
        ];
    result = null;
    closed = false;

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(showParkedSheet(
                context,
                kind: kind,
                beforeResume: beforeResume,
              ).then((r) {
                result = r;
                closed = true;
              })),
              child: const Text('open sheet'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
  }

  int parkedCarts() =>
      container.read(parkedCountProvider(ParkedKind.counterCart));

  Future<List<String>> storedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final env = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
    return <String>[
      for (final e in env['drafts'] as List<Object?>)
        (e as Map<String, dynamic>)['id'] as String,
    ];
  }

  Finder inDialog(String text) =>
      find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

  group('the list', () {
    testWidgets(
        'shows this operator\'s drafts for the kind: label, items, '
        'total and how long ago', (tester) async {
      await openSheet(tester);

      expect(find.text('Parked carts'), findsOneWidget);
      expect(find.text('P1'), findsOneWidget);
      expect(find.text('P2'), findsOneWidget);
      expect(find.text('2× Masala Dosa, 1× Cold Coffee'), findsOneWidget);
      expect(find.text('1× Masala Dosa'), findsOneWidget);
      expect(find.text('₹320'), findsOneWidget);
      expect(find.text('₹100'), findsOneWidget);
      expect(find.text('parked 5 min ago'), findsOneWidget);
      expect(find.text('parked 2 h ago'), findsOneWidget);

      expect(find.byKey(resume(p1)), findsOneWidget);
      expect(find.byKey(resume(p2)), findsOneWidget);
      expect(find.byKey(discard(p1)), findsOneWidget);
      expect(find.byKey(resume(ravis)), findsNothing,
          reason: 'another operator\'s cart is not shown');
      expect(find.textContaining('Couple Entry'), findsNothing,
          reason: 'a ticket sale is not a cart');
    });

    testWidgets('says so when nothing is parked', (tester) async {
      await openSheet(tester, parked: const <ParkedDraft>[]);
      expect(find.text('Nothing is parked'), findsOneWidget);
      expect(find.byType(LiquidPrimaryButton), findsNothing);
    });

    testWidgets('the Gate lists ticket sales, with the guest\'s name',
        (tester) async {
      final t = DateTime.now().subtract(const Duration(minutes: 7));
      await openSheet(
        tester,
        kind: ParkedKind.ticketIssue,
        parked: <ParkedDraft>[
          draftOf(
            ticketDraft(
              lines: <ParkedTicketLine>[
                ParkedTicketLine.of(ticketType(), 2),
                ParkedTicketLine.of(
                    ticketType(id: 'tt-stag', name: 'Stag Entry', rupees: 600),
                    1),
              ],
              guestName: 'Meera',
            ),
            createdAt: t,
          ),
          ...drafts(),
        ],
      );

      expect(find.text('Parked ticket sales'), findsOneWidget);
      expect(find.text('2× Couple Entry, 1× Stag Entry'), findsOneWidget);
      expect(find.text('₹2,600'), findsOneWidget);
      expect(find.text('Meera'), findsOneWidget);
      expect(find.text('parked 7 min ago'), findsOneWidget);
      expect(find.textContaining('Masala Dosa'), findsNothing);
    });
  });

  testWidgets('lays out on a small phone, long lists and all', (tester) async {
    final t = DateTime.now().subtract(const Duration(minutes: 5));
    await openSheet(
      tester,
      size: const Size(360, 800),
      parked: <ParkedDraft>[
        for (var i = 1; i <= 4; i++)
          draftOf(
            CounterCartDraft.fromCart(<CartLine>[
              for (var n = 1; n <= 5; n++)
                CartLine(
                    item: menuItem(id: 'i$n', name: 'Item number $n'), qty: n),
            ]),
            createdAt: t,
            seq: i,
          ),
      ],
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Parked carts'), findsOneWidget);
    expect(find.byType(LiquidPrimaryButton), findsWidgets);

    await tester.tap(find.byKey(discard('pk-op-asha-counterCart-1')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Discard P1?'), findsOneWidget);
  });

  group('Resume', () {
    testWidgets('hands the resolved draft back and takes it off the phone',
        (tester) async {
      await openSheet(tester);

      await tester.tap(find.byKey(resume(p1)));
      await tester.pumpAndSettle();

      expect(closed, isTrue);
      final resumed = result!;
      expect(resumed.draft.label, 'P1');
      expect(resumed.cart!.lines.map((l) => (l.item.id, l.qty)),
          <(String, int)>[('dosa', 2), ('coffee', 1)]);
      expect(resumed.tickets, isNull);
      expect(resumed.resolved.needsAttention, isFalse);

      expect(parkedCarts(), 1, reason: 'P2 is left');
      expect(await storedIds(), <String>[p2, ravis, 'pk-op-asha-ticketIssue-1'],
          reason: 'P1 is gone; nobody else\'s drafts were touched');
    });

    testWidgets('a ticket sale resumes against the ticket types',
        (tester) async {
      final t = DateTime.now().subtract(const Duration(minutes: 7));
      await openSheet(
        tester,
        kind: ParkedKind.ticketIssue,
        parked: <ParkedDraft>[
          draftOf(
            ticketDraft(guestName: 'Meera', guestPhone: '9876500000'),
            createdAt: t,
          ),
        ],
      );
      await tester.tap(find.byKey(resume('pk-op-asha-ticketIssue-1')));
      await tester.pumpAndSettle();

      final tickets = result!.tickets!;
      expect(tickets.lines.single.type.id, 'tt-couple');
      expect(tickets.lines.single.qty, 2);
      expect(tickets.guestName, 'Meera');
      expect(tickets.guestPhone, '9876500000');
      expect(result!.cart, isNull);
    });

    testWidgets(
        'a changed menu is shown as Needs attention first; Back keeps '
        'the draft, Resume with changes goes on', (tester) async {
      // The dosa is gone and the coffee went from ₹120 to ₹130.
      await openSheet(tester, menu: <MenuItem>[coffee(regular: 130)]);

      await tester.tap(find.byKey(resume(p1)));
      await tester.pumpAndSettle();

      expect(find.text('Needs attention'), findsOneWidget);
      expect(find.text('No longer available'), findsOneWidget);
      expect(
          find.text('Masala Dosa ×2 — no longer on the menu'), findsOneWidget);
      expect(find.text('Price changed'), findsOneWidget);
      expect(find.text('Cold Coffee — ₹120 → ₹130 each'), findsOneWidget);
      expect(closed, isFalse, reason: 'nothing is resumed until they agree');

      await tester.tap(find.widgetWithText(TextButton, 'Back'));
      await tester.pumpAndSettle();
      expect(find.text('Needs attention'), findsNothing);
      expect(find.byKey(resume(p1)), findsOneWidget, reason: 'still parked');
      expect(parkedCarts(), 2);
      expect(closed, isFalse);

      await tester.tap(find.byKey(resume(p1)));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Resume with changes'));
      await tester.pumpAndSettle();

      expect(closed, isTrue);
      final resumed = result!;
      expect(resumed.resolved.dropped.single.itemName, 'Masala Dosa');
      expect(resumed.resolved.repriced.single.now, const Money.rupees(130));
      expect(resumed.cart!.lines.single.unitPrice, const Money.rupees(130));
      expect(parkedCarts(), 1);
    });

    testWidgets(
        'when nothing is left it says so, offers no Resume and keeps '
        'the draft', (tester) async {
      await openSheet(tester, menu: <MenuItem>[coffee()]);

      await tester.tap(find.byKey(resume(p2)));
      await tester.pumpAndSettle();

      expect(find.text('Needs attention'), findsOneWidget);
      expect(find.text('Nothing here can be resumed.'), findsOneWidget);
      expect(
          find.widgetWithText(TextButton, 'Resume with changes'), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Back'));
      await tester.pumpAndSettle();
      expect(find.byKey(resume(p2)), findsOneWidget);
      expect(parkedCarts(), 2);
    });

    testWidgets(
        'the host can stop a resume, for example with a cart already '
        'in progress', (tester) async {
      final asked = <String>[];
      var answer = false;
      await openSheet(tester, beforeResume: (draft) async {
        asked.add(draft.label);
        return answer;
      });

      await tester.tap(find.byKey(resume(p1)));
      await tester.pumpAndSettle();
      expect(asked, <String>['P1']);
      expect(closed, isFalse);
      expect(parkedCarts(), 2, reason: 'a "no" costs nothing');
      expect(find.byKey(resume(p1)), findsOneWidget);

      answer = true;
      await tester.tap(find.byKey(resume(p1)));
      await tester.pumpAndSettle();
      expect(asked, <String>['P1', 'P1']);
      expect(closed, isTrue);
      expect(result!.draft.label, 'P1');
      expect(parkedCarts(), 1);
    });

    testWidgets(
        'the host is asked after Needs attention, so a cancelled '
        'resume has done nothing', (tester) async {
      var asked = 0;
      await openSheet(tester, menu: <MenuItem>[coffee(regular: 130)],
          beforeResume: (_) async {
        asked++;
        return true;
      });
      await tester.tap(find.byKey(resume(p1)));
      await tester.pumpAndSettle();
      expect(asked, 0);

      await tester.tap(find.widgetWithText(TextButton, 'Back'));
      await tester.pumpAndSettle();
      expect(asked, 0);

      await tester.tap(find.byKey(resume(p1)));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Resume with changes'));
      await tester.pumpAndSettle();
      expect(asked, 1);
      expect(closed, isTrue);
    });

    testWidgets('a second tap while the host is still deciding does nothing',
        (tester) async {
      final decision = Completer<bool>();
      var asked = 0;
      await openSheet(tester, beforeResume: (_) {
        asked++;
        return decision.future;
      });

      await tester.tap(find.byKey(resume(p1)));
      await tester.pump();
      await tester.tap(find.byKey(resume(p1)), warnIfMissed: false);
      await tester.tap(find.byKey(resume(p2)), warnIfMissed: false);
      await tester.pump();
      expect(asked, 1);

      decision.complete(true);
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result!.draft.label, 'P1');
      expect(parkedCarts(), 1);
    });

    testWidgets('a host that throws leaves the draft where it was',
        (tester) async {
      await openSheet(tester, beforeResume: (_) async {
        throw StateError('could not park the cart in progress');
      });
      await tester.tap(find.byKey(resume(p1)));
      await tester.pumpAndSettle(const Duration(seconds: 5));

      expect(closed, isFalse);
      expect(parkedCarts(), 2);
      expect(find.byKey(resume(p1)), findsOneWidget);
    });

    testWidgets(
        'the cap error from a host that parked the cart in progress '
        'reaches the cashier as it is', (tester) async {
      await openSheet(tester, beforeResume: (_) async {
        throw ParkedCapReached(ParkedKind.counterCart, 20);
      });
      await tester.tap(find.byKey(resume(p1)));
      await tester.pumpAndSettle();

      expect(
          find.text('You already have 20 parked carts. '
              'Resume or discard one first.'),
          findsOneWidget);
      expect(closed, isFalse);
      expect(parkedCarts(), 2);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('with no menu yet, Resume is off and the sheet says why',
        (tester) async {
      await openSheet(tester, menu: const <MenuItem>[]);

      expect(
          find.text('The menu has not loaded yet — reconnect to the desk '
              'to resume.'),
          findsOneWidget);
      expect(
          tester.widget<LiquidPrimaryButton>(find.byKey(resume(p1))).onPressed,
          isNull);
      expect(
          tester
              .widget<LiquidSecondaryButton>(find.byKey(discard(p1)))
              .onPressed,
          isNotNull,
          reason: 'discarding needs no menu');
    });

    testWidgets('the Gate needs ticket types to resume', (tester) async {
      await openSheet(
        tester,
        kind: ParkedKind.ticketIssue,
        types: const <TicketType>[],
      );
      expect(
          find.text('The ticket types have not loaded yet — reconnect to '
              'the desk to resume.'),
          findsOneWidget);
      expect(
          tester
              .widget<LiquidPrimaryButton>(
                  find.byKey(resume('pk-op-asha-ticketIssue-1')))
              .onPressed,
          isNull);
    });
  });

  group('Discard', () {
    testWidgets('asks first: Keep leaves it, Discard removes it',
        (tester) async {
      await openSheet(tester);

      await tester.tap(find.byKey(discard(p1)));
      await tester.pumpAndSettle();
      expect(find.text('Discard P1?'), findsOneWidget);
      expect(parkedCarts(), 2, reason: 'nothing happens until they confirm');

      await tester.tap(find.widgetWithText(TextButton, 'Keep'));
      await tester.pumpAndSettle();
      expect(find.text('Discard P1?'), findsNothing);
      expect(find.byKey(resume(p1)), findsOneWidget);
      expect(parkedCarts(), 2);
      expect(await storedIds(), contains(p1));

      await tester.tap(find.byKey(discard(p1)));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pumpAndSettle();

      expect(find.byKey(resume(p1)), findsNothing);
      expect(find.byKey(resume(p2)), findsOneWidget,
          reason: 'only the one that was confirmed');
      expect(find.text('P1'), findsNothing);
      expect(parkedCarts(), 1);
      expect(await storedIds(), isNot(contains(p1)));
      expect(await storedIds(), contains(ravis),
          reason: 'someone else\'s cart is not ours to discard');
      expect(closed, isFalse, reason: 'the sheet stays for the next one');
    });

    testWidgets('names the draft it is about to throw away', (tester) async {
      await openSheet(tester);
      await tester.tap(find.byKey(discard(p2)));
      await tester.pumpAndSettle();
      expect(find.text('Discard P2?'), findsOneWidget);
      expect(inDialog('This cannot be undone.'), findsOneWidget);
    });

    testWidgets('a refused write keeps the draft and says so', (tester) async {
      await openSheet(tester);
      final onDisk = (await SharedPreferences.getInstance()).getString(key)!;
      SharedPreferencesStorePlatform.instance =
          _RefusingStore(<String, Object>{'flutter.$key': onDisk});

      await tester.tap(find.byKey(discard(p1)));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pumpAndSettle();

      expect(
          find.text("Couldn't update the parked drafts on this phone. "
              'Try again.'),
          findsOneWidget);
      expect(find.byKey(resume(p1)), findsOneWidget,
          reason: 'still parked, and still shown');
      expect(parkedCarts(), 2);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('discarding the last one leaves the empty note',
        (tester) async {
      await openSheet(tester, parked: <ParkedDraft>[drafts().first]);
      await tester.tap(find.byKey(discard(p1)));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing is parked'), findsOneWidget);
    });
  });

  group('Needs attention summary', () {
    Future<void> show(WidgetTester tester, ResolvedDraft resolved) =>
        tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: NeedsAttentionSummary(resolved: resolved)),
        ));

    testWidgets('lists what went and what moved', (tester) async {
      final resolved = resolveCounterCart(
        CounterCartDraft.fromCart(<CartLine>[coffeeLine(), dosaLine()]),
        <MenuItem>[coffee(withIceCream: false), menuItem(rupees: 120)],
      );
      await show(tester, resolved);

      expect(find.text('No longer available'), findsOneWidget);
      expect(find.text('Cold Coffee — Ice cream is no longer offered'),
          findsOneWidget);
      expect(find.text('Price changed'), findsOneWidget);
      expect(find.text('Masala Dosa — ₹100 → ₹120 each'), findsOneWidget);
    });

    testWidgets('leaves out a section with nothing in it', (tester) async {
      final resolved = resolveCounterCart(
        CounterCartDraft.fromCart(<CartLine>[dosaLine()]),
        <MenuItem>[menuItem(rupees: 120)],
      );
      await show(tester, resolved);
      expect(find.text('Price changed'), findsOneWidget);
      expect(find.text('No longer available'), findsNothing);
    });
  });

  group('formatParkedAge', () {
    test('reads like a counter would say it', () {
      String age(Duration d) => formatParkedAge(d);
      expect(age(Duration.zero), 'just now');
      expect(age(const Duration(seconds: 59)), 'just now');
      expect(age(const Duration(minutes: 1)), '1 min ago');
      expect(age(const Duration(minutes: 59, seconds: 59)), '59 min ago');
      expect(age(const Duration(hours: 1)), '1 h ago');
      expect(age(const Duration(hours: 23, minutes: 59)), '23 h ago');
      expect(age(const Duration(hours: 24)), '1 d ago');
      expect(age(const Duration(days: 3, hours: 5)), '3 d ago');
    });

    test('a clock that moved back is just now, not a negative age', () {
      expect(formatParkedAge(const Duration(minutes: -4)), 'just now');
    });
  });
}
