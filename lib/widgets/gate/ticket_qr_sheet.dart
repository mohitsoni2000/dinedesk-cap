import 'package:flutter/material.dart';

import '../../models/entry_ticket.dart';
import '../../services/slip_printer.dart';
import '../../theme/tokens.dart';
import '../app_surface.dart';
import '../liquid_chrome.dart';
import '../qr_code_view.dart';
import '../sheet_handle.dart';
import 'slip_print_button.dart';

/// Shows one ticket's QR on screen, big enough to scan, with the words its
/// slip carries, and a reprint through the slip printer. For when there is
/// no printer, or a guest lost the slip. Only for users with issue rights
/// (`FeatureFlags.canCopyTickets`): the callers check.
///
/// [reprintOnly]: every print from here copies a slip already handed out
/// (today's list), so each is a reprint, logged on the desk.
Future<void> showTicketQrSheet(
  BuildContext context, {
  required String ticketId,
  required String qrData,
  required String ticketNumber,
  required String typeName,
  TicketSlipContent? slip,
  bool reprintOnly = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (_) => _TicketQrSheet(
      ticketId: ticketId,
      qrData: qrData,
      ticketNumber: ticketNumber,
      typeName: typeName,
      slip: slip,
      reprintOnly: reprintOnly,
    ),
  );
}

class _TicketQrSheet extends StatelessWidget {
  const _TicketQrSheet({
    required this.ticketId,
    required this.qrData,
    required this.ticketNumber,
    required this.typeName,
    required this.slip,
    required this.reprintOnly,
  });

  final String ticketId;
  final String qrData;
  final String ticketNumber;
  final String typeName;
  final TicketSlipContent? slip;
  final bool reprintOnly;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final content = slip;
    return ConstrainedBox(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.92),
      child: AppSurface(
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + context.sheetBottomInset),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHandle(),
              const SizedBox(height: 14),
              Text(content?.title ?? typeName.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: AppTypography.sheetTitle),
              if (content?.highlight != null) ...[
                const SizedBox(height: 4),
                Text(content!.highlight!,
                    textAlign: TextAlign.center,
                    style: AppTypography.title
                        .copyWith(fontWeight: FontWeight.w800)),
              ],
              const SizedBox(height: 16),
              if (qrData.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'This ticket has no QR — the guest gives the ticket '
                    'number at the gate.',
                    textAlign: TextAlign.center,
                    style: palette.caption,
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.white,
                  child: QrCodeView(data: qrData, size: 240),
                ),
              const SizedBox(height: 12),
              Text(
                ticketNumber,
                style: AppTypography.headline.copyWith(
                  fontWeight: FontWeight.w800,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              if (content != null) ...[
                const SizedBox(height: 12),
                for (final line in content.lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(line,
                        textAlign: TextAlign.center,
                        style: AppTypography.bodyMd),
                  ),
                if (content.footer.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final line in content.footer)
                    Text(line,
                        textAlign: TextAlign.center, style: palette.caption),
                ],
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: SlipPrintButton(
                      reprintOnly: reprintOnly,
                      slips: <TicketSlip>[
                        TicketSlip(
                          ticketId: ticketId,
                          ticketNumber: ticketNumber,
                          qrData: qrData,
                          content: slip,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LiquidSecondaryButton(
                      label: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
