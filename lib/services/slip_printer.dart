/// The seam entry-ticket slips are printed through. The gate only ever talks
/// to a [SlipPrinter]; the Bluetooth printer (bt_printer_service.dart,
/// blueprint decision c) is the implementation main.dart puts behind
/// [slipPrinterProvider]. [NoSlipPrinter] is the default (and what tests
/// get): no printer, and the screens show the QR on screen instead.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/entry_ticket.dart';

/// One slip to print: one ticket, its QR, and the words the desk wrote for
/// it (one shared builder for desk and Crew slips).
class TicketSlip {
  const TicketSlip({
    required this.ticketId,
    required this.ticketNumber,
    required this.qrData,
    this.content,
  });

  factory TicketSlip.fromTicket(EntryTicket ticket) => TicketSlip(
        ticketId: ticket.id,
        ticketNumber: ticket.ticketNumber,
        qrData: ticket.slip?.qrData ?? ticket.qrCode,
        content: ticket.slip,
      );

  final String ticketId;
  final String ticketNumber;

  /// What the printed QR encodes (`CDT:…`); empty when the desk sent none.
  final String qrData;

  /// Null when the desk sent no slip text: print the number and QR only.
  final TicketSlipContent? content;
}

/// What one print run came to, by ticket id.
class SlipPrintResult {
  const SlipPrintResult({required this.printed, required this.failed});

  final List<String> printed;
  final List<String> failed;

  bool get allPrinted => failed.isEmpty;
}

abstract class SlipPrinter {
  /// A printer is set up, so Print may be offered.
  bool get isReady;

  /// Prints one slip per ticket, in order. Never throws: a slip that did not
  /// print is listed in [SlipPrintResult.failed].
  Future<SlipPrintResult> printSlips(List<TicketSlip> slips);

  /// The desk just confirmed a sale of these tickets: print them now if this
  /// printer prints after every sale, or keep them for later. Never throws.
  Future<void> afterSale(List<TicketSlip> slips);
}

/// No printer on this phone: nothing prints, every slip is reported failed.
class NoSlipPrinter implements SlipPrinter {
  const NoSlipPrinter();

  @override
  bool get isReady => false;

  @override
  Future<SlipPrintResult> printSlips(List<TicketSlip> slips) async =>
      SlipPrintResult(
        printed: const <String>[],
        failed: <String>[for (final slip in slips) slip.ticketId],
      );

  @override
  Future<void> afterSale(List<TicketSlip> slips) async {}
}

final Provider<SlipPrinter> slipPrinterProvider =
    Provider<SlipPrinter>((_) => const NoSlipPrinter());
