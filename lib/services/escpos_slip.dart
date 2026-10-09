/// The building blocks of a gate slip on a thermal roll: the two paper
/// widths, the text sizes and how many columns each leaves, word wrap, and
/// the QR, either native (`GS ( k`) or as a raster image for printers that
/// print garbage for the native command.
///
/// Pure Dart (no IO, no Flutter): ticket_slip_builder.dart lays a slip out
/// with these, and the goldens in test/escpos_slip_test.dart pin the bytes.
library;

import 'package:qr/qr.dart';

import 'escpos_commands.dart';

/// The roll in the slip printer. Columns are at the normal font (12 dots a
/// character): 58 mm paper prints 384 dots, 32 columns (the desk's
/// `slipColumns`, and crew-print-config's cap for 58 mm); 80 mm prints 576
/// dots, 48 columns.
enum SlipPaper {
  mm58('58', cols: 32, dots: 384),
  mm80('80', cols: 48, dots: 576);

  const SlipPaper(this.wire, {required this.cols, required this.dots});

  /// How it is saved: `58` / `80`.
  final String wire;
  final int cols;
  final int dots;

  /// 58 mm unless [raw] says 80: the portable printers gates carry.
  static SlipPaper fromWire(Object? raw) =>
      raw?.toString() == mm80.wire ? mm80 : mm58;
}

/// The `GS ! n` sizes a slip uses, and how wide each character is.
enum SlipTextSize {
  /// `GS ! 00`.
  normal(0x00, 1),

  /// `GS ! 10`: twice as wide, normal height.
  wide(0x10, 2),

  /// `GS ! 11`: twice as wide and tall.
  x2(0x11, 2),

  /// `GS ! 22`: three times.
  x3(0x22, 3);

  const SlipTextSize(this.n, this.widthFactor);

  /// The `GS ! n` argument.
  final int n;
  final int widthFactor;

  String get command => '\x1D!${String.fromCharCode(n)}';

  /// Columns on [paper] at this size: 58 mm 32/16/16/10, 80 mm 48/24/24/16.
  int colsOn(SlipPaper paper) => paper.cols ~/ widthFactor;
}

final RegExp _space = RegExp(r'\s+');

/// Greedy word wrap at [cols] columns, breaking at spaces and hard-breaking
/// a word longer than a line (the printer would wrap on its own, but in the
/// middle of a word). The desk's `wrapSlipText`, line for line. Runs on
/// printer-safe ASCII, one column per character.
List<String> wrapForCols(String text, int cols) {
  final width = cols < 1 ? 1 : cols;
  final out = <String>[];
  var line = '';
  for (final word in text.split(_space).where((w) => w.isNotEmpty)) {
    var rest = word;
    while (rest.length > width) {
      if (line.isNotEmpty) {
        out.add(line);
        line = '';
      }
      out.add(rest.substring(0, width));
      rest = rest.substring(width);
    }
    if (line.isEmpty) {
      line = rest;
    } else if (line.length + 1 + rest.length <= width) {
      line = '$line $rest';
    } else {
      out.add(line);
      line = rest;
    }
  }
  if (line.isNotEmpty) out.add(line);
  return out;
}

/// The native QR's module size: 6 dots, as the desk's slips print it
/// (`SLIP_QR_MODULE_SIZE`). A version 2 code is then about 19 mm wide.
const int slipQrModuleDots = 6;

/// A native QR (model 2, module size 6, ECC M) for [data], then a line feed
/// so the printer prints it: the desk's `qrBlock` sequence, byte for byte.
String nativeQrBlock(String data) =>
    '$escQrModel2${escQrModuleSize(slipQrModuleDots)}$escQrEccM'
    '${escQrStore(data)}$escQrPrint\n';

/// The same QR drawn by the phone (`GS v 0`), for a printer that prints
/// garbage for `GS ( k`: ECC M, a four-module quiet zone, [moduleDots] dots
/// a module, each row padded to whole bytes (about 5 KB for a ticket's
/// code). Null when [data] cannot be encoded.
String? rasterQrBlock(String data, {int moduleDots = slipQrModuleDots}) {
  final QrImage image;
  try {
    image = QrImage(QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    ));
  } catch (_) {
    return null;
  }
  const quiet = 4;
  final side = (image.moduleCount + 2 * quiet) * moduleDots;
  final widthBytes = (side + 7) ~/ 8;
  final out = StringBuffer(escRasterHeader(widthBytes, side));
  final row = List<int>.filled(widthBytes, 0);
  for (var y = 0; y < side; y++) {
    final moduleRow = y ~/ moduleDots - quiet;
    row.fillRange(0, widthBytes, 0);
    for (var x = 0; x < side; x++) {
      final moduleCol = x ~/ moduleDots - quiet;
      if (moduleRow < 0 ||
          moduleCol < 0 ||
          moduleRow >= image.moduleCount ||
          moduleCol >= image.moduleCount) {
        continue;
      }
      if (image.isDark(moduleRow, moduleCol)) {
        row[x >> 3] |= 0x80 >> (x & 7);
      }
    }
    out.write(String.fromCharCodes(row));
  }
  // The image is printed as it arrives; the feed ends its line.
  out.write('\n');
  return out.toString();
}
