import 'package:flutter/material.dart';

import '../models/token.dart';
import '../theme/tokens.dart';

/// "Preparing" / "Ready" / "Collected"; empty when the desk did not say.
String tokenStatusLabel(TokenStatus status) => switch (status) {
      TokenStatus.preparing => 'Preparing',
      TokenStatus.ready => 'Ready',
      TokenStatus.collected => 'Collected',
      TokenStatus.unknown => '',
    };

Color _statusColor(BuildContext context, TokenStatus status) =>
    switch (status) {
      TokenStatus.preparing => AppColors.warn,
      TokenStatus.ready => AppColors.success,
      TokenStatus.collected => context.palette.ink50,
      TokenStatus.unknown => AppColors.terraDeep,
    };

/// The token as the guest is called by it, big: about 120 logical pixels,
/// tabular figures so `#11` and `#88` take the same width. Unlike the KOT
/// number it is never zero-padded. It scales down to fit a narrow phone.
class TokenNumber extends StatelessWidget {
  const TokenNumber({
    super.key,
    required this.label,
    this.fontSize = 120,
    this.color,
  });

  final String label;
  final double fontSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final shown = tokenDisplay(label);
    return Semantics(
      label: 'Token $shown',
      excludeSemantics: true,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          shown,
          maxLines: 1,
          style: TextStyle(
            fontFamily: AppTypography.inter,
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            height: 1.0,
            letterSpacing: -fontSize / 40,
            color: color ?? context.palette.ink,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// A token as a small pill (history, order detail, lists), tinted by its
/// status: amber while preparing, green when ready, grey once collected.
class TokenBadge extends StatelessWidget {
  const TokenBadge({
    super.key,
    required this.label,
    this.status = TokenStatus.unknown,
    this.showStatus = false,
  });

  final String label;
  final TokenStatus status;

  /// Adds "· Ready" after the token.
  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context, status);
    final statusText = tokenStatusLabel(status);
    final text = showStatus && statusText.isNotEmpty
        ? '${tokenDisplay(label)} · $statusText'
        : tokenDisplay(label);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: const BorderRadius.all(AppRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.confirmation_number_outlined, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: AppTypography.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w800,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Takeaway" / "Standing".
class FulfillmentChip extends StatelessWidget {
  const FulfillmentChip({super.key, required this.type});

  final FulfillmentType type;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return _Chip(
      icon: type == FulfillmentType.takeaway
          ? Icons.takeout_dining_outlined
          : Icons.emoji_people_outlined,
      text: type.label,
      color: palette.ink70,
    );
  }
}

/// "Paid", or "Pay at pickup" for an order fired before payment.
class PaymentTagChip extends StatelessWidget {
  const PaymentTagChip({super.key, required this.paid});

  final bool paid;

  @override
  Widget build(BuildContext context) => _Chip(
        icon: paid ? Icons.check_circle_outline : Icons.schedule_outlined,
        text: paid ? 'Paid' : 'Pay at pickup',
        color: paid ? AppColors.success : AppColors.warn,
      );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: const BorderRadius.all(AppRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(text,
              style: AppTypography.caption
                  .copyWith(color: color, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
