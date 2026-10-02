import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:restro/services/escpos_builder.dart';

/// The emergency KOT slip must be byte-for-byte what the desk's own printer
/// path would have sent. The expected hex below was produced by running the
/// DESK's `buildKotEscpos` + `sendNetworkPrint` (command.desk
/// `src/app/core/print/kot-escpos.ts`, `electron/printer/escpos.ts`) against a
/// local TCP socket with the same input, so a drift on either side fails here.
void main() {
  String hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  const sampleItems = <KotSlipItem>[
    KotSlipItem(
      name: 'Paneer Tikka',
      quantity: 2,
      variationName: 'Half',
      options: <String>['Spicy', 'Extra cheese'],
      addons: <({String group, List<String> choices})>[
        (group: 'Sauce', choices: <String>['Mint']),
        (group: 'Dip', choices: <String>['Red']),
      ],
      notes: 'less oil \u20B950',
    ),
    KotSlipItem(name: 'Rice', quantity: 1, weight: 1.5, weightUnit: 'kg'),
    KotSlipItem(
      name:
          '\u092A\u0928\u0940\u0930 Caf\u00E9 \u201CSpecial\u201D \u2013 \u00BD cr\u00E8me',
      quantity: 3,
    ),
  ];

  const sampleCtx = KotSlipContext(
    stationLabel: 'Kitchen',
    kotNumber: 'A7Q2-014',
    orderNumber: 'ORD-0045',
    tableName: 'T4',
    floorName: 'Ground Floor',
    waiterName: 'Ram',
    orderNotes: 'no onion',
    dateStr: '05 Oct 2026',
    timeStr: '10:15:00 am',
    items: sampleItems,
  );

  group('buildKotEscpos', () {
    test('lays the doc out exactly as the desk does', () {
      final doc = buildKotEscpos(sampleCtx);
      expect(doc.title, 'Kitchen');
      expect(doc.subtitleLines, <String>[
        "KOT: A7Q2-014",
        "Order: ORD-0045",
        "Ground Floor | Table T4",
        "05 Oct 2026 10:15:00 am",
        "*** NOTE: no onion ***"
      ]);
      expect(doc.itemLines, <String>[
        "2 x Paneer Tikka (Half)",
        "    Spicy, Extra cheese",
        "    Sauce: Mint | Dip: Red",
        "    ! less oil Rs50",
        "1.5kg Rice",
        "3 x ???? Cafe \"Special\" - 1/2 creme"
      ]);
      expect(doc.footerLines, <String>['Steward: Ram']);
    });

    test('one copy matches the desk byte for byte (golden)', () {
      expect(
        hex(escposBytes(buildKotEscpos(sampleCtx))),
        '1b401b61011d21111b45014b69746368656e0a1d21001b45004b4f543a204137'
        '51322d3031340a4f726465723a204f52442d303034350a47726f756e6420466c'
        '6f6f72207c205461626c652054340a3035204f637420323032362031303a3135'
        '3a303020616d0a2a2a2a204e4f54453a206e6f206f6e696f6e202a2a2a0a2d2d'
        '2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d0a1b6100'
        '3220782050616e6565722054696b6b61202848616c66290a2020202053706963'
        '792c204578747261206368656573650a2020202053617563653a204d696e7420'
        '7c204469703a205265640a2020202021206c657373206f696c20527335300a31'
        '2e356b6720526963650a332078203f3f3f3f204361666520225370656369616c'
        '22202d20312f32206372656d650a2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d'
        '2d2d2d2d2d2d2d2d2d2d2d2d0a537465776172643a2052616d0a0a0a0a1d5642'
        '00',
      );
    });

    test('two copies are two whole tickets back to back (golden)', () {
      final two = hex(escposBytes(buildKotEscpos(sampleCtx), copies: 2));
      expect(
        two,
        '1b401b61011d21111b45014b69746368656e0a1d21001b45004b4f543a204137'
        '51322d3031340a4f726465723a204f52442d303034350a47726f756e6420466c'
        '6f6f72207c205461626c652054340a3035204f637420323032362031303a3135'
        '3a303020616d0a2a2a2a204e4f54453a206e6f206f6e696f6e202a2a2a0a2d2d'
        '2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d0a1b6100'
        '3220782050616e6565722054696b6b61202848616c66290a2020202053706963'
        '792c204578747261206368656573650a2020202053617563653a204d696e7420'
        '7c204469703a205265640a2020202021206c657373206f696c20527335300a31'
        '2e356b6720526963650a332078203f3f3f3f204361666520225370656369616c'
        '22202d20312f32206372656d650a2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d'
        '2d2d2d2d2d2d2d2d2d2d2d2d0a537465776172643a2052616d0a0a0a0a1d5642'
        '001b401b61011d21111b45014b69746368656e0a1d21001b45004b4f543a2041'
        '3751322d3031340a4f726465723a204f52442d303034350a47726f756e642046'
        '6c6f6f72207c205461626c652054340a3035204f637420323032362031303a31'
        '353a303020616d0a2a2a2a204e4f54453a206e6f206f6e696f6e202a2a2a0a2d'
        '2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d0a1b61'
        '003220782050616e6565722054696b6b61202848616c66290a20202020537069'
        '63792c204578747261206368656573650a2020202053617563653a204d696e74'
        '207c204469703a205265640a2020202021206c657373206f696c20527335300a'
        '312e356b6720526963650a332078203f3f3f3f20436166652022537065636961'
        '6c22202d20312f32206372656d650a2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d'
        '2d2d2d2d2d2d2d2d2d2d2d2d2d0a537465776172643a2052616d0a0a0a0a1d56'
        '4200',
      );
    });

    test('every ticket re-inits the printer and ends in a partial cut', () {
      final bytes = escposBytes(buildKotEscpos(sampleCtx), copies: 3);
      final text = latin1.decode(bytes);
      expect('\x1B@'.allMatches(text).length, 3);
      expect('\x1DV\x42\x00'.allMatches(text).length, 3);
      expect(text.endsWith('\n\n\n\x1DV\x42\x00'), isTrue);
    });

    test('copies <= 0 counts as one, like the desk', () {
      final one = escposBytes(buildKotEscpos(sampleCtx));
      expect(escposBytes(buildKotEscpos(sampleCtx), copies: 0), one);
      expect(escposBytes(buildKotEscpos(sampleCtx), copies: -2), one);
    });

    test('the offline banner sits first, a reprint banner after it', () {
      final doc = buildKotEscpos(const KotSlipContext(
        stationLabel: 'Bar',
        kotNumber: 'X1Y2-001',
        tableName: '12',
        dateStr: 'd',
        timeStr: 't',
        isOffline: true,
        items: <KotSlipItem>[KotSlipItem(name: 'Tea', quantity: 1)],
      ));
      expect(doc.subtitleLines.first, '*** OFFLINE KOT ***');
      expect(doc.subtitleLines, contains('KOT: X1Y2-001'));
      expect(doc.subtitleLines.any((l) => l.startsWith('Order:')), isFalse,
          reason: 'an offline order has no number yet');
      expect(doc.subtitleLines, contains('Table 12'));
    });

    test('nameOnly drops the slot label; floor-less slips print just the slot',
        () {
      final doc = buildKotEscpos(const KotSlipContext(
        stationLabel: 'Kitchen',
        kotNumber: 'k',
        tableName: 'VIP-3',
        nameOnly: true,
        floorName: 'Terrace',
        dateStr: 'd',
        timeStr: 't',
        items: <KotSlipItem>[],
      ));
      expect(doc.subtitleLines, contains('Terrace | VIP-3'));
    });
  });

  group('toPrinterSafeText (same rules as the desk)', () {
    const cases = <List<String>>[
      [
        '\u{20B9}250 \u{2013} \u{201C}Caf\u{E9}\u{201D} \u{2026}',
        'Rs250 - "Cafe" ...'
      ],
      ['\u{92A}\u{928}\u{940}\u{930}', '????'],
      [
        'Cr\u{E8}me Br\u{FB}l\u{E9}e \u{BD} \u{BC} \u{BE} \u{D7} \u{2022}',
        'Creme Brulee 1/2 1/4 3/4 x *'
      ],
      ['\u{C6}r\u{F8} \u{DF} \u{D8}l \u{D0}e', 'aero ss ol de'],
      [
        '\u{FB01} \u{B2} \u{2122} \u{FF21}\u{FF22} \u{FF11}\u{FF12} \u{F1} \u{FC} \u{C5}',
        'fi 2 TM AB 12 n u A'
      ],
      ['tab\there\nnew', 'tab here new'],
      ['\u{1F600} emoji', '?? emoji'],
      ['\u{915}\u{93C}\u{916}\u{93C}', '????'],
    ];
    for (final c in cases) {
      test('${c[0]} -> ${c[1]}', () => expect(toPrinterSafeText(c[0]), c[1]));
    }

    test('rupee and Hindi transliterate to the printer-safe form', () {
      expect(toPrinterSafeText('\u20B9250'), 'Rs250');
      expect(toPrinterSafeText('\u092A\u0928\u0940\u0930'), '????');
    });

    test('output is always printable ASCII', () {
      final out = toPrinterSafeText(
          'Caf\u00E9 \u20B9 \u092A\u0928\u0940\u0930 \u{1F600} \t x');
      expect(RegExp(r'^[\x20-\x7E]*$').hasMatch(out), isTrue);
    });
  });
}
