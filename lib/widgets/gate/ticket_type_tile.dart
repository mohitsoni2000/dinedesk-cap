import 'package:flutter/material.dart';

import '../../data/currency.dart';
import '../../models/entry_ticket.dart';
import '../../theme/tokens.dart';
import '../app_card.dart';
import '../stepper_button.dart';

/// `#RRGGBB` as a colour; null when it is not one.
Color? ticketTypeColor(String? hex) {
  final match = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(hex?.trim() ?? '');
  if (match == null) return null;
  return Color(0xFF000000 | int.parse(match.group(1)!, radix: 16));
}

/// One ticket type on the issue screen: its name, what one costs (GST in),
/// how many it admits, its cover, and how many are in this sale. A tap adds
/// one.
class TicketTypeTile extends StatelessWidget {
  const TicketTypeTile({
    super.key,
    required this.type,
    required this.qty,
    required this.onAdd,
    required this.onRemove,
    this.enabled = true,
  });

  final TicketType type;
  final int qty;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = ticketTypeColor(type.color) ?? AppColors.terra;
    final picked = qty > 0;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: AppCard(
        onTap: enabled ? onAdd : null,
        padding: const EdgeInsets.all(14),
        border: Border.all(
          color: picked ? accent : palette.hairline,
          width: picked ? 1.5 : 1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  type.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style:
                      AppTypography.bodyMd.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Text(formatRupeesCompact(type.unitTotal),
                style: AppTypography.headline),
            const SizedBox(height: 2),
            Text(
              [
                'Admits ${type.pax}',
                if (type.hasCover) 'Cover ${formatRupeesCompact(type.coverAmount)}',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: palette.caption,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (picked && enabled)
                  StepperButton(
                    key: ValueKey<String>('ticket-remove-${type.id}'),
                    icon: Icons.remove,
                    onTap: onRemove,
                  )
                else
                  const SizedBox(width: AppTouchTargets.control),
                Expanded(
                  child: Text(
                    '$qty',
                    key: ValueKey<String>('ticket-qty-${type.id}'),
                    textAlign: TextAlign.center,
                    style: AppTypography.title.copyWith(
                      fontWeight: FontWeight.w800,
                      color: picked ? palette.ink : palette.ink30,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
                if (enabled)
                  StepperButton(
                    key: ValueKey<String>('ticket-add-${type.id}'),
                    icon: Icons.add,
                    onTap: onAdd,
                  )
                else
                  const SizedBox(width: AppTouchTargets.control),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
