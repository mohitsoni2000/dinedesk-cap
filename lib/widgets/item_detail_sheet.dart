// Item Detail Sheet — qty + grouped modifiers + special note.
//
// Modifiers split into two groups (Indian POS pattern):
//   • Spice level   — single-select (Mild / Medium / Spicy / Extra Spicy)
//   • Add-ons       — multi-select with price impact (Extra Cheese +₹60, etc.)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/liquid_chrome.dart';

class ItemDetailSheet extends ConsumerStatefulWidget {
  final MenuItem item;
  const ItemDetailSheet({super.key, required this.item});

  @override
  ConsumerState<ItemDetailSheet> createState() => _ItemDetailSheetState();

  static Future<void> show(BuildContext context, MenuItem item) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => ItemDetailSheet(item: item),
    );
  }
}

class _ItemDetailSheetState extends ConsumerState<ItemDetailSheet> {
  int _qty = 1;
  String? _spiceId;
  final Set<String> _addOnIds = {};
  String _note = '';

  /// Whether this item's kitchen section supports spice levels.
  bool get _showSpice =>
      widget.item.kitchenSection != 'beverages';

  @override
  void initState() {
    super.initState();
    _spiceId = _showSpice ? 'sp_med' : null;
  }

  double get _addOnExtra {
    double total = 0;
    for (final id in _addOnIds) {
      final m = addOns.firstWhere((x) => x.id == id);
      total += m.extraPrice;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.item.price + _addOnExtra;
    final total = unit * _qty;

    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => LiquidGlassSurface(
        blur: 30,
        thickness: 14,
        borderRadius: const BorderRadius.vertical(top: AppRadii.lg),
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: AppColors.ink30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                children: [
                  Text(widget.item.section.toUpperCase(),
                    style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _VegBadge(isVeg: widget.item.isVeg),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(widget.item.name, style: AppTypography.displayMd),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(formatRupeesCompact(widget.item.price),
                    style: AppTypography.title),
                  const SizedBox(height: 24),

                  // Qty.
                  Row(
                    children: [
                      Text('QUANTITY',
                        style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
                      const Spacer(),
                      _StepBtn(icon: Icons.remove, onTap: () {
                        if (_qty > 1) setState(() => _qty--);
                      }),
                      const SizedBox(width: 16),
                      SizedBox(width: 32, child: Center(
                        child: Text('$_qty', style: AppTypography.headline),
                      )),
                      const SizedBox(width: 16),
                      _StepBtn(icon: Icons.add, onTap: () => setState(() => _qty++)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Divider(height: 1, color: AppColors.ink10),
                  const SizedBox(height: 20),

                  // Spice level — single-select (hidden for beverages/desserts).
                  if (_showSpice) ...[
                    Text('SPICE LEVEL',
                      style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        for (int i = 0; i < spiceLevels.length; i++) ...[
                          Expanded(
                            child: _SegmentChip(
                              label: spiceLevels[i].label,
                              selected: _spiceId == spiceLevels[i].id,
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _spiceId = spiceLevels[i].id);
                              },
                            ),
                          ),
                          if (i < spiceLevels.length - 1) const SizedBox(width: 6),
                        ],
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],

                  // Add-ons — multi-select with price.
                  Text('ADD-ONS',
                    style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                  const SizedBox(height: 12),
                  Column(
                    children: [
                      for (final m in addOns)
                        _AddOnTile(
                          modifier: m,
                          selected: _addOnIds.contains(m.id),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() {
                              if (_addOnIds.contains(m.id)) {
                                _addOnIds.remove(m.id);
                              } else {
                                _addOnIds.add(m.id);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Note.
                  Text('SPECIAL NOTE',
                    style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.5),
                      borderRadius: const BorderRadius.all(AppRadii.sm),
                      border: Border.all(color: AppColors.ink10),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: TextField(
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Allergies, prep notes…',
                      ),
                      onChanged: (v) => _note = v,
                      maxLines: 2,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),

            // Footer CTA.
            Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16,
                16 + MediaQuery.of(context).viewPadding.bottom),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('TOTAL', style: AppTypography.micro),
                      const SizedBox(height: 2),
                      Text(formatRupeesCompact(total), style: AppTypography.headline),
                    ],
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: LiquidPrimaryButton(
                      label: 'Add to Order',
                      fullWidth: true,
                      leadingIcon: Icons.add,
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        final modLabels = <String>[
                          if (_spiceId != null)
                            spiceLevels.firstWhere((x) => x.id == _spiceId).label,
                          for (final id in _addOnIds)
                            addOns.firstWhere((x) => x.id == id).label,
                        ];
                        ref.read(cartProvider.notifier).addCustom(
                          item: widget.item,
                          qty: _qty,
                          mods: modLabels,
                          modsExtra: _addOnExtra,
                          itemNote: _note,
                        );
                        Navigator.of(context).pop();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _StepBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () { HapticFeedback.selectionClick(); onTap(); },
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 44, height: 44,
        child: Center(
          child: Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.ink10),
            ),
            child: Icon(icon, size: 18, color: AppColors.ink),
          ),
        ),
      ),
    );
  }
}

class _SegmentChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SegmentChip({
    required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : Colors.white.withValues(alpha: 0.6),
          borderRadius: const BorderRadius.all(AppRadii.sm),
          border: Border.all(color: selected ? AppColors.ink : AppColors.ink10),
        ),
        alignment: Alignment.center,
        child: Text(label,
          style: AppTypography.caption.copyWith(
            color: selected ? Colors.white : AppColors.ink,
            fontWeight: FontWeight.w600,
          )),
      ),
    );
  }
}

class _AddOnTile extends StatelessWidget {
  final Modifier modifier;
  final bool selected;
  final VoidCallback onTap;
  const _AddOnTile({
    required this.modifier, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final showPrice = modifier.extraPrice != 0;
    final priceLabel = modifier.extraPrice > 0
        ? '+${formatRupeesCompact(modifier.extraPrice)}'
        : modifier.extraPrice < 0
            ? '−${formatRupeesCompact(modifier.extraPrice.abs())}'
            : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.terra500.withValues(alpha: 0.10)
                : Colors.white.withValues(alpha: 0.6),
            borderRadius: const BorderRadius.all(AppRadii.sm),
            border: Border.all(
              color: selected
                  ? AppColors.terra500.withValues(alpha: 0.5)
                  : AppColors.ink10),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 18, height: 18,
                decoration: BoxDecoration(
                  color: selected ? AppColors.terra500 : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: selected ? AppColors.terra500 : AppColors.ink30,
                    width: 1.5,
                  ),
                ),
                child: selected
                    ? const Icon(Icons.check, size: 12, color: Colors.white)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(modifier.label,
                  style: AppTypography.bodyMd.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  )),
              ),
              if (showPrice)
                Text(priceLabel,
                  style: AppTypography.caption.copyWith(
                    color: modifier.extraPrice > 0
                        ? AppColors.terra600
                        : AppColors.success,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

class _VegBadge extends StatelessWidget {
  final bool isVeg;
  const _VegBadge({required this.isVeg});
  @override
  Widget build(BuildContext context) {
    final color = isVeg ? AppColors.success : AppColors.danger;
    return Container(
      width: 18, height: 18,
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Center(
        child: Container(
          width: 8, height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
