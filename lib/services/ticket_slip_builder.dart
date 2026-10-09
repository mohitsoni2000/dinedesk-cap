/// An entry ticket's slip as ESC/POS bytes for this phone's Bluetooth
/// printer. The desk writes the words (`TicketSlipContent`, one shared
/// builder for desk and Crew slips); the phone only lays them out, for its
/// own paper width and QR mode (blueprint 12, decision d):
///
/// ```
///   centred
///   Spice Hub                      venue, 2x2 bold
///   12 MG Road, Indiranagar        address / GSTIN, normal
///   --------------------------------
///   ET-041                         ticket number, 3x3 bold
///   COUPLE PASS                    title, 2x2 bold
///   ADMITS 2 PAX                   highlight, 2x2 bold
///   COVER Rs800 - use on food ...  lines, normal
///   [QR]                           native GS ( k, or raster GS v 0
///   --------------------------------
///   Valid on 09 Oct 2026 only.     footer, normal
///   feed 4, cut when auto-cut is on
/// ```
///
/// Every text goes through [toPrinterSafeText] first (printers speak code
/// page 437/850), so a Devanagari name prints as `?`, and is wrapped at the
/// columns its size leaves ([wrapForCols]). Each slip starts with `ESC @`,
/// so a batch is just slips back to back.
library;

import 'dart:convert';

import '../models/entry_ticket.dart';
import 'escpos_builder.dart' show toPrinterSafeText;
import 'escpos_commands.dart';
import 'escpos_slip.dart';

/// How the printer is told to draw the QR.
enum SlipQrMode {
  /// `GS ( k`: the printer draws it. Small and sharp; most printers.
  native('native'),

  /// `GS v 0`: the phone draws it, for a printer that prints garbage for
  /// the native command.
  raster('raster');

  const SlipQrMode(this.wire);
  final String wire;

  static SlipQrMode fromWire(Object? raw) =>
      raw?.toString() == raster.wire ? raster : native;
}

/// The printer-side choices a slip is laid out for.
class SlipLayout {
  const SlipLayout({
    required this.paper,
    required this.qrMode,
    required this.autoCut,
  });

  final SlipPaper paper;
  final SlipQrMode qrMode;

  /// End with a partial cut. 58 mm portables have a tear bar instead.
  final bool autoCut;
}

final RegExp _printableAscii = RegExp(r'^[\x20-\x7E]+$');

/// The slip for [slip] as bytes (latin1), laid out for [layout]. [qrData]
/// is what the QR encodes (`CDT:…`); without one, or with one a printer
/// cannot take, the slip has no QR and the ticket number stands in.
List<int> ticketSlipBytes(
  TicketSlipContent slip, {
  required String qrData,
  required SlipLayout layout,
}) =>
    latin1.encode(ticketSlipText(slip, qrData: qrData, layout: layout));

/// [ticketSlipBytes] as the latin1 string, one character per byte.
String ticketSlipText(
  TicketSlipContent slip, {
  required String qrData,
  required SlipLayout layout,
}) {
  final paper = layout.paper;
  final rule = '${'-' * paper.cols}\n';
  final out = StringBuffer(escInit)..write(escAlignCenter);

  if (slip.header.isNotEmpty) {
    out.write(_block(slip.header.first, SlipTextSize.x2, paper, bold: true));
    for (final line in slip.header.skip(1)) {
      out.write(_block(line, SlipTextSize.normal, paper));
    }
  }
  out
    ..write(rule)
    ..write(_block(slip.ticketNo, SlipTextSize.x3, paper, bold: true))
    ..write(_block(slip.title, SlipTextSize.x2, paper, bold: true))
    ..write(_block(slip.highlight ?? '', SlipTextSize.x2, paper, bold: true));
  for (final line in slip.lines) {
    out.write(_block(line, SlipTextSize.normal, paper));
  }

  final qr = qrData.trim();
  if (_printableAscii.hasMatch(qr)) {
    final block = layout.qrMode == SlipQrMode.raster
        ? rasterQrBlock(qr)
        : nativeQrBlock(qr);
    if (block != null) out..write('\n')..write(block);
  }

  if (slip.footer.isNotEmpty) {
    out.write(rule);
    for (final line in slip.footer) {
      out.write(_block(line, SlipTextSize.normal, paper));
    }
  }
  out.write(escFeedLines(4));
  if (layout.autoCut) out.write(escCutPartial);
  return out.toString();
}

/// [text] made printer-safe and wrapped for [size] on [paper]; sized or
/// bold text sets its style first and returns to normal after. Empty text
/// prints nothing at all.
String _block(
  String text,
  SlipTextSize size,
  SlipPaper paper, {
  bool bold = false,
}) {
  final lines = wrapForCols(toPrinterSafeText(text), size.colsOn(paper));
  if (lines.isEmpty) return '';
  final styled = bold || size != SlipTextSize.normal;
  final out = StringBuffer();
  if (styled) {
    out.write(size.command);
    if (bold) out.write(escBoldOn);
  }
  for (final line in lines) {
    out.write('$line\n');
  }
  if (styled) {
    out.write(escSizeNormal);
    if (bold) out.write(escBoldOff);
  }
  return out.toString();
}
