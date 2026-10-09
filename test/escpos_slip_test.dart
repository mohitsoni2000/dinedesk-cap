import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';
import 'package:restro/models/entry_ticket.dart';
import 'package:restro/services/escpos_slip.dart';
import 'package:restro/services/ticket_slip_builder.dart';

/// The gate's entry slip as bytes: 58 and 80 mm with the printer's own QR,
/// 58 mm with the phone-drawn (raster) QR, the wrap and size tables, and a
/// batch. The slip is the K1 fixture's first ticket (the desk's own slip
/// words). Goldens are written readable: `<ESC>`, `<GS>`, `<LF>` and `<xx>`
/// for every other byte outside printable ASCII, so a reviewer can see the
/// layout; the mapping is one-to-one, so they pin every byte.
void main() {
  final ack = jsonDecode(
          File('test/fixtures/crew-qsr/ticket_issue_ack.json').readAsStringSync())
      as Map<String, dynamic>;
  final ticket = (ack['tickets'] as List<dynamic>).first as Map<String, dynamic>;
  final slip = TicketSlipContent.tryParse(ticket['slip'])!;
  final qr = slip.qrData!;

  String show(List<int> bytes) {
    final out = StringBuffer();
    for (final b in bytes) {
      if (b == 0x1B) {
        out.write('<ESC>');
      } else if (b == 0x1D) {
        out.write('<GS>');
      } else if (b == 0x0A) {
        out.write('<LF>\n');
      } else if (b < 0x20 || b > 0x7E) {
        out.write('<${b.toRadixString(16).padLeft(2, '0').toUpperCase()}>');
      } else {
        out.writeCharCode(b);
      }
    }
    return out.toString();
  }

  List<int> build(SlipPaper paper, SlipQrMode mode, {required bool cut}) =>
      ticketSlipBytes(slip,
          qrData: qr,
          layout: SlipLayout(paper: paper, qrMode: mode, autoCut: cut));

  /// The desk's native QR sequence for this ticket's code (escpos.ts
  /// `qrBlock`, module size 6, ECC M): model 2, size, ECC, store (pL = 20 +
  /// 3 = 0x17), print, then a line feed.
  const qrBlock = '<GS>(k<04><00>1A2<00>'
      '<GS>(k<03><00>1C<06>'
      '<GS>(k<03><00>1E1'
      '<GS>(k<17><00>1P0CDT:7QKX2MZ4HB6TNW3R'
      '<GS>(k<03><00>1Q0<LF>\n';

  group('slip goldens', () {
    test('58 mm, native QR, no cut (a portable with a tear bar)', () {
      expect(
        show(build(SlipPaper.mm58, SlipQrMode.native, cut: false)),
        '<ESC>@<ESC>a<01><GS>!<11><ESC>E<01>Spice Hub<LF>\n'
        '<GS>!<00><ESC>E<00>12 MG Road, Indiranagar,<LF>\n'
        'Bengaluru<LF>\n'
        'GSTIN 29ABCDE1234F1Z5<LF>\n'
        '--------------------------------<LF>\n'
        '<GS>!"<ESC>E<01>ET-041<LF>\n'
        '<GS>!<00><ESC>E<00><GS>!<11><ESC>E<01>COUPLE PASS<LF>\n'
        '<GS>!<00><ESC>E<00><GS>!<11><ESC>E<01>ADMITS 2 PAX<LF>\n'
        '<GS>!<00><ESC>E<00>COVER Rs800 - use on food &<LF>\n'
        'drinks today<LF>\n'
        'Entry Rs1,200.00 incl. GST<LF>\n'
        'Sale ET/26-27/000037<LF>\n'
        '09 Oct 2026, 08:10 PM<LF>\n'
        'Guest: Ravi Sharma<LF>\n'
        '<LF>\n'
        '$qrBlock'
        '--------------------------------<LF>\n'
        'Valid on 09 Oct 2026 only.<LF>\n'
        'Unused cover is forfeited at day<LF>\n'
        'close.<LF>\n'
        '<ESC>d<04>',
      );
    });

    test('80 mm, native QR, partial cut', () {
      expect(
        show(build(SlipPaper.mm80, SlipQrMode.native, cut: true)),
        '<ESC>@<ESC>a<01><GS>!<11><ESC>E<01>Spice Hub<LF>\n'
        '<GS>!<00><ESC>E<00>12 MG Road, Indiranagar, Bengaluru<LF>\n'
        'GSTIN 29ABCDE1234F1Z5<LF>\n'
        '------------------------------------------------<LF>\n'
        '<GS>!"<ESC>E<01>ET-041<LF>\n'
        '<GS>!<00><ESC>E<00><GS>!<11><ESC>E<01>COUPLE PASS<LF>\n'
        '<GS>!<00><ESC>E<00><GS>!<11><ESC>E<01>ADMITS 2 PAX<LF>\n'
        '<GS>!<00><ESC>E<00>COVER Rs800 - use on food & drinks today<LF>\n'
        'Entry Rs1,200.00 incl. GST<LF>\n'
        'Sale ET/26-27/000037<LF>\n'
        '09 Oct 2026, 08:10 PM<LF>\n'
        'Guest: Ravi Sharma<LF>\n'
        '<LF>\n'
        '$qrBlock'
        '------------------------------------------------<LF>\n'
        'Valid on 09 Oct 2026 only.<LF>\n'
        'Unused cover is forfeited at day close.<LF>\n'
        '<ESC>d<04><GS>VB<00>',
      );
    });

    test('58 mm, raster QR (golden file)', () {
      final golden = File('test/fixtures/escpos/ticket_slip_58_raster.hex')
          .readAsStringSync()
          .replaceAll(RegExp(r'\s'), '');
      final bytes = build(SlipPaper.mm58, SlipQrMode.raster, cut: false);
      expect(bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          golden);
    });

    test('the raster QR is the code itself: header, quiet zone, 6-dot modules',
        () {
      final text = latin1.decode(
          build(SlipPaper.mm58, SlipQrMode.raster, cut: false));
      final native = latin1.decode(
          build(SlipPaper.mm58, SlipQrMode.native, cut: false));
      const header = '\x1Dv0\x00';
      final at = text.indexOf(header);
      // Everything before and after the QR is the native slip's.
      expect(text.substring(0, at), native.substring(0, native.indexOf('\x1D(k')));
      expect(text.substring(text.lastIndexOf('-' * 32)),
          native.substring(native.lastIndexOf('-' * 32)));

      final image = QrImage(QrCode.fromData(
          data: qr, errorCorrectLevel: QrErrorCorrectLevel.M));
      expect(image.moduleCount, 25, reason: 'version 2 for CDT: + 16');
      const side = (25 + 8) * 6; // 4 quiet modules each side, 6 dots each
      const widthBytes = (side + 7) ~/ 8;
      final head = text.codeUnits.sublist(at + 4, at + 8);
      expect(head, <int>[widthBytes, 0, side, 0]);
      expect(widthBytes * side, lessThan(5 * 1024), reason: 'about 5 KB');

      final rows = text.codeUnits.sublist(at + 8, at + 8 + widthBytes * side);
      bool dot(int x, int y) =>
          rows[y * widthBytes + (x >> 3)] & (0x80 >> (x & 7)) != 0;
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < widthBytes * 8; x++) {
          final mx = x ~/ 6 - 4;
          final my = y ~/ 6 - 4;
          final dark = mx >= 0 &&
              my >= 0 &&
              mx < 25 &&
              my < 25 &&
              image.isDark(my, mx);
          if (dot(x, y) != dark) fail('dot ($x, $y) should be ${dark ? 'black' : 'white'}');
        }
      }
      expect(text.codeUnitAt(at + 8 + widthBytes * side), 0x0A);
    });
  });

  group('the QR', () {
    test('native is the desk sequence byte for byte', () {
      expect(
        nativeQrBlock('CDT:7QKX2MZ4HB6TNW3R').codeUnits,
        <int>[
          0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00, //
          0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, 0x06, //
          0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x31, //
          0x1D, 0x28, 0x6B, 0x17, 0x00, 0x31, 0x50, 0x30, //
          ...'CDT:7QKX2MZ4HB6TNW3R'.codeUnits,
          0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30, //
          0x0A,
        ],
      );
    });

    test('a slip without a QR (or with one a printer cannot take) has none',
        () {
      for (final data in <String>['', '   ', 'CDT:₹']) {
        final text = ticketSlipText(slip,
            qrData: data,
            layout: const SlipLayout(
                paper: SlipPaper.mm58,
                qrMode: SlipQrMode.native,
                autoCut: false));
        expect(text, isNot(contains('\x1D(k')), reason: data);
        expect(text, contains('ET-041'),
            reason: 'the ticket number still admits the guest');
      }
    });

    test('a QR too long to encode has no raster block', () {
      expect(rasterQrBlock('X' * 4000), isNull);
    });
  });

  group('wrap and size tables', () {
    test('columns per size and paper', () {
      expect(SlipPaper.mm58.cols, 32);
      expect(SlipPaper.mm80.cols, 48);
      expect(<int>[for (final s in SlipTextSize.values) s.colsOn(SlipPaper.mm58)],
          <int>[32, 16, 16, 10]);
      expect(<int>[for (final s in SlipTextSize.values) s.colsOn(SlipPaper.mm80)],
          <int>[48, 24, 24, 16]);
      expect(<int>[for (final s in SlipTextSize.values) s.n],
          <int>[0x00, 0x10, 0x11, 0x22]);
    });

    final cases = <(String, int, List<String>)>[
      ('Valid on 09 Oct 2026 only.', 32, <String>['Valid on 09 Oct 2026 only.']),
      (
        'Unused cover is forfeited at day close.',
        32,
        <String>['Unused cover is forfeited at day', 'close.']
      ),
      ('  spaced   out  words ', 10, <String>['spaced out', 'words']),
      ('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 10,
          <String>['ABCDEFGHIJ', 'KLMNOPQRST', 'UVWXYZ']),
      ('go ABCDEFGHIJKLMNOP', 10, <String>['go', 'ABCDEFGHIJ', 'KLMNOP']),
      ('exactly ten', 11, <String>['exactly ten']),
      ('', 32, <String>[]),
      ('a b', 0, <String>['a', 'b']),
    ];
    for (final (text, cols, lines) in cases) {
      test('wrap "$text" at $cols', () => expect(wrapForCols(text, cols), lines));
    }

    test('paper and QR mode read back from what was saved', () {
      expect(SlipPaper.fromWire('80'), SlipPaper.mm80);
      expect(SlipPaper.fromWire('58'), SlipPaper.mm58);
      expect(SlipPaper.fromWire(null), SlipPaper.mm58);
      expect(SlipQrMode.fromWire('raster'), SlipQrMode.raster);
      expect(SlipQrMode.fromWire('x'), SlipQrMode.native);
    });

    test('every text goes printer-safe: a Hindi name prints as ?', () {
      const hindi = TicketSlipContent(
        header: <String>['Spice Hub'],
        ticketNo: 'ET-042',
        title: 'COUPLE PASS',
        lines: <String>['Guest: आशा'],
        footer: <String>[],
      );
      final text = ticketSlipText(hindi,
          qrData: qr,
          layout: const SlipLayout(
              paper: SlipPaper.mm58,
              qrMode: SlipQrMode.native,
              autoCut: false));
      expect(text, contains('Guest: ???\n'));
      expect(RegExp(r'[^\x00-\x7F]').hasMatch(text), isFalse);
    });
  });

  test('a batch: every slip re-inits the printer and feeds out on its own', () {
    const layout = SlipLayout(
        paper: SlipPaper.mm80, qrMode: SlipQrMode.native, autoCut: true);
    final second = TicketSlipContent.tryParse(
        ((ack['tickets'] as List<dynamic>)[1] as Map<String, dynamic>)['slip'])!;
    for (final s in <TicketSlipContent>[slip, second]) {
      final text = ticketSlipText(s, qrData: s.qrData!, layout: layout);
      expect(text.startsWith('\x1B@\x1Ba\x01'), isTrue);
      expect(text.endsWith('\x1Bd\x04\x1DVB\x00'), isTrue);
      expect('\x1B@'.allMatches(text).length, 1);
    }
  });
}
