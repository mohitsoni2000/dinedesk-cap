// Discount Sheet — bottom sheet for applying discounts before billing.
//
// Two sections:
//   1. Preset discounts from server (shown as chips)
//   2. Custom discount (% or flat amount) with optional label

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../theme/tokens.dart';
import 'liquid_glass_surface.dart';
import 'liquid_chrome.dart';

class DiscountSheet {
  /// Shows the discount bottom sheet.
  /// Returns a discount map on success, or null if cancelled.
  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required String orderId,
    required double orderTotal,
  }) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => _DiscountSheet(orderId: orderId, orderTotal: orderTotal),
    );
  }
}

enum _DiscountType { percent, flat }

class _DiscountSheet extends ConsumerStatefulWidget {
  final String orderId;
  final double orderTotal;
  const _DiscountSheet({required this.orderId, required this.orderTotal});
  @override
  ConsumerState<_DiscountSheet> createState() => _DiscountSheetState();
}

class _DiscountSheetState extends ConsumerState<_DiscountSheet> {
  // Preset selection
  String? _selectedPresetId;

  // Custom discount
  _DiscountType _customType = _DiscountType.percent;
  final _valueController = TextEditingController();
  final _labelController = TextEditingController();

  bool _submitting = false;

  // Track which tab: 'preset' or 'custom'
  bool _showCustom = false;

  double? get _customValue => double.tryParse(_valueController.text.trim());

  double get _customDiscountAmount {
    final v = _customValue;
    if (v == null || v <= 0) return 0;
    if (_customType == _DiscountType.percent) {
      return (widget.orderTotal * v / 100).clamp(0, widget.orderTotal);
    }
    return v.clamp(0, widget.orderTotal);
  }

  bool get _canApply {
    if (_submitting) return false;
    if (_showCustom) {
      return _customValue != null && _customValue! > 0;
    }
    return _selectedPresetId != null;
  }

  Future<void> _apply() async {
    if (!_canApply) return;
    setState(() => _submitting = true);
    HapticFeedback.heavyImpact();

    final socketService = ref.read(socketServiceProvider);
    final Map<String, dynamic> payload;

    if (_showCustom) {
      payload = {
        'order_id': widget.orderId,
        'custom': {
          'type': _customType == _DiscountType.percent ? 'percent' : 'flat',
          'value': _customValue,
          if (_labelController.text.trim().isNotEmpty)
            'label': _labelController.text.trim(),
        },
      };
    } else {
      payload = {
        'order_id': widget.orderId,
        'discount_id': _selectedPresetId,
      };
    }

    socketService.emit('discount:apply', payload, onAck: (response) {
      if (!mounted) return;
      if (response['error'] != null) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            backgroundColor: AppColors.danger,
            content: Text(
              response['error'].toString(),
              style: AppTypography.bodyMd.copyWith(color: Colors.white),
            ),
          ));
      } else {
        Navigator.of(context).pop(response);
      }
    });

    // Timeout fallback
    Future.delayed(const Duration(seconds: 10), () {
      if (mounted && _submitting) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(
            content: Text('Discount request timed out — please retry'),
          ));
      }
    });
  }

  @override
  void dispose() {
    _valueController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presets = ref.watch(discountsProvider);
    final hasPresets = presets.isNotEmpty;

    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.88,
      builder: (_, scrollCtrl) => LiquidGlassSurface(
        blur: 30,
        thickness: 14,
        borderRadius: const BorderRadius.vertical(top: AppRadii.lg),
        padding: EdgeInsets.fromLTRB(
          20, 12, 20, 28 + MediaQuery.of(context).viewPadding.bottom),
        child: ListView(
          controller: scrollCtrl,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: AppColors.ink30,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Header
            Row(
              children: [
                const Icon(Icons.discount_outlined,
                  color: AppColors.terra500, size: 22),
                const SizedBox(width: 10),
                const Text('Apply Discount', style: AppTypography.title),
                const Spacer(),
                Text('Order: ${formatRupeesCompact(widget.orderTotal)}',
                  style: AppTypography.caption),
              ],
            ),
            const SizedBox(height: 20),

            // Tab toggle (if presets exist)
            if (hasPresets) ...[
              Row(
                children: [
                  Expanded(
                    child: _TabChip(
                      label: 'Presets',
                      icon: Icons.local_offer_outlined,
                      selected: !_showCustom,
                      onTap: () => setState(() => _showCustom = false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _TabChip(
                      label: 'Custom',
                      icon: Icons.edit_outlined,
                      selected: _showCustom,
                      onTap: () => setState(() {
                        _showCustom = true;
                        _selectedPresetId = null;
                      }),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],

            // Preset discounts section
            if (!_showCustom && hasPresets) ...[
              Text('AVAILABLE DISCOUNTS',
                style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in presets)
                    _PresetChip(
                      name: preset['name']?.toString() ?? 'Discount',
                      value: _formatPresetValue(preset),
                      selected: _selectedPresetId == preset['id']?.toString(),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() {
                          _selectedPresetId = preset['id']?.toString();
                        });
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],

            // Custom discount section
            if (_showCustom || !hasPresets) ...[
              Text('DISCOUNT TYPE',
                style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _TabChip(
                      label: 'Percentage (%)',
                      icon: Icons.percent,
                      selected: _customType == _DiscountType.percent,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _customType = _DiscountType.percent);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _TabChip(
                      label: 'Flat (\u20B9)',
                      icon: Icons.currency_rupee,
                      selected: _customType == _DiscountType.flat,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _customType = _DiscountType.flat);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Value input
              Text('VALUE',
                style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: AppColors.paper,
                  borderRadius: const BorderRadius.all(AppRadii.sm),
                  border: Border.all(color: AppColors.ink10),
                ),
                child: TextField(
                  controller: _valueController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                  style: AppTypography.headline,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: _customType == _DiscountType.percent
                        ? 'e.g. 10'
                        : 'e.g. 100',
                    hintStyle: AppTypography.caption,
                    isDense: true,
                    prefixText: _customType == _DiscountType.flat
                        ? '\u20B9 '
                        : null,
                    prefixStyle: AppTypography.headline,
                    suffixText: _customType == _DiscountType.percent
                        ? '%'
                        : null,
                    suffixStyle: AppTypography.headline.copyWith(
                      color: AppColors.ink50),
                  ),
                ),
              ),

              // Show computed discount amount for percentage
              if (_customType == _DiscountType.percent &&
                  _customValue != null &&
                  _customValue! > 0) ...[
                const SizedBox(height: 8),
                Text(
                  'Discount: ${formatRupeesCompact(_customDiscountAmount)}',
                  style: AppTypography.caption.copyWith(
                    color: AppColors.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],

              // Warn if percentage > 100
              if (_customType == _DiscountType.percent &&
                  _customValue != null &&
                  _customValue! > 100) ...[
                const SizedBox(height: 4),
                Text(
                  'Percentage cannot exceed 100%',
                  style: AppTypography.caption.copyWith(
                    color: AppColors.danger),
                ),
              ],

              // Warn if flat > total
              if (_customType == _DiscountType.flat &&
                  _customValue != null &&
                  _customValue! > widget.orderTotal) ...[
                const SizedBox(height: 4),
                Text(
                  'Amount exceeds order total',
                  style: AppTypography.caption.copyWith(
                    color: AppColors.danger),
                ),
              ],

              const SizedBox(height: 12),

              // Optional label
              Text('LABEL (OPTIONAL)',
                style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: AppColors.paper,
                  borderRadius: const BorderRadius.all(AppRadii.sm),
                  border: Border.all(color: AppColors.ink10),
                ),
                child: TextField(
                  controller: _labelController,
                  style: AppTypography.bodyMd,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'e.g. Birthday special, VIP guest',
                    hintStyle: AppTypography.caption,
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            const SizedBox(height: 8),

            // CTA buttons
            Row(
              children: [
                Expanded(
                  child: LiquidSecondaryButton(
                    label: 'Cancel',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LiquidPrimaryButton(
                    label: _submitting ? 'Applying...' : 'Apply Discount',
                    fullWidth: true,
                    leadingIcon: _submitting
                        ? Icons.hourglass_top
                        : Icons.check_circle_outline,
                    onPressed: _canApply ? _apply : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatPresetValue(Map<String, dynamic> preset) {
    final type = preset['type']?.toString();
    final value = (preset['value'] as num?)?.toDouble() ?? 0;
    if (type == 'percent') return '${value.toStringAsFixed(0)}%';
    return formatRupeesCompact(value);
  }
}

class _TabChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _TabChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : Colors.white.withValues(alpha: 0.6),
          borderRadius: const BorderRadius.all(AppRadii.sm),
          border: Border.all(
            color: selected ? AppColors.ink : AppColors.ink10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16,
              color: selected ? Colors.white : AppColors.ink70),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                style: AppTypography.bodyMd.copyWith(
                  color: selected ? Colors.white : AppColors.ink,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String name;
  final String value;
  final bool selected;
  final VoidCallback onTap;
  const _PresetChip({
    required this.name,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.terra500.withValues(alpha: 0.14)
              : Colors.white.withValues(alpha: 0.6),
          borderRadius: const BorderRadius.all(AppRadii.sm),
          border: Border.all(
            color: selected ? AppColors.terra500 : AppColors.ink10,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name,
              style: AppTypography.bodyMd.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? AppColors.terra600 : AppColors.ink,
              )),
            const SizedBox(height: 2),
            Text(value,
              style: AppTypography.caption.copyWith(
                color: selected ? AppColors.terra500 : AppColors.ink70,
              )),
          ],
        ),
      ),
    );
  }
}
