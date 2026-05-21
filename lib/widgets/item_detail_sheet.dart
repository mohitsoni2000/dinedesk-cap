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
  final Map<String, String> _singleSelections = {};
  final Set<String> _multiSelections = {};
  String _note = '';

  bool get _hasServerOptions => widget.item.optionGroups.isNotEmpty;

  @override
  void initState() {
    super.initState();
    for (final group in widget.item.optionGroups) {
      if ((group.isRequired || group.minSelect > 0) &&
          group.options.isNotEmpty) {
        _singleSelections[group.id] = group.options.first.id;
      }
    }
  }

  double get _serverOptionExtra => _selectedServerOptions.fold(
        0,
        (total, option) => total + option.priceModifier,
      );

  List<SelectedOption> get _selectedServerOptions {
    final selected = <SelectedOption>[];
    for (final group in widget.item.optionGroups) {
      for (final option in group.options) {
        final isSelected = _singleSelections[group.id] == option.id ||
            _multiSelections.contains(option.id);
        if (!isSelected) continue;
        selected.add(SelectedOption(
          groupName: group.name,
          optionName: option.name,
          priceModifier: option.priceModifier,
        ));
      }
    }
    return selected;
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.item.price + _serverOptionExtra;
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
              width: 40,
              height: 4,
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
                        child: Text(widget.item.name,
                            style: AppTypography.displayMd),
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
                          style:
                              AppTypography.micro.copyWith(letterSpacing: 1.2)),
                      const Spacer(),
                      _StepBtn(
                          icon: Icons.remove,
                          onTap: () {
                            if (_qty > 1) setState(() => _qty--);
                          }),
                      const SizedBox(width: 16),
                      SizedBox(
                          width: 32,
                          child: Center(
                            child: Text('$_qty', style: AppTypography.headline),
                          )),
                      const SizedBox(width: 16),
                      _StepBtn(
                          icon: Icons.add, onTap: () => setState(() => _qty++)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Divider(height: 1, color: AppColors.ink10),
                  const SizedBox(height: 20),

                  if (_hasServerOptions) ...[
                    for (final group in widget.item.optionGroups) ...[
                      Text(
                        group.name.toUpperCase(),
                        style: AppTypography.micro.copyWith(letterSpacing: 1.4),
                      ),
                      const SizedBox(height: 12),
                      Column(
                        children: [
                          for (final option in group.options)
                            _OptionTile(
                              label: option.name,
                              priceModifier: option.priceModifier,
                              selected:
                                  _singleSelections[group.id] == option.id ||
                                      _multiSelections.contains(option.id),
                              multiSelect: group.maxSelect > 1,
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() {
                                  if (group.maxSelect > 1) {
                                    if (_multiSelections.contains(option.id)) {
                                      _multiSelections.remove(option.id);
                                    } else {
                                      final selectedInGroup = group.options
                                          .where((o) =>
                                              _multiSelections.contains(o.id))
                                          .length;
                                      if (selectedInGroup < group.maxSelect) {
                                        _multiSelections.add(option.id);
                                      }
                                    }
                                  } else {
                                    _singleSelections[group.id] = option.id;
                                  }
                                });
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                  ],

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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
              padding: EdgeInsets.fromLTRB(
                  16, 8, 16, 16 + MediaQuery.of(context).viewPadding.bottom),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('TOTAL', style: AppTypography.micro),
                      const SizedBox(height: 2),
                      Text(formatRupeesCompact(total),
                          style: AppTypography.headline),
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
                        final modLabels = <String>[];
                        final selectedOpts = <SelectedOption>[];

                        for (final option in _selectedServerOptions) {
                          modLabels.add(option.optionName);
                          selectedOpts.add(option);
                        }

                        ref.read(cartProvider.notifier).addCustom(
                              item: widget.item,
                              qty: _qty,
                              mods: modLabels,
                              selectedOptions: selectedOpts,
                              modsExtra: _serverOptionExtra,
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
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
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

class _OptionTile extends StatelessWidget {
  final String label;
  final double priceModifier;
  final bool selected;
  final bool multiSelect;
  final VoidCallback onTap;
  const _OptionTile({
    required this.label,
    required this.priceModifier,
    required this.selected,
    required this.multiSelect,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final showPrice = priceModifier != 0;
    final priceLabel = priceModifier > 0
        ? '+${formatRupeesCompact(priceModifier)}'
        : priceModifier < 0
            ? '−${formatRupeesCompact(priceModifier.abs())}'
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
                  : AppColors.ink10,
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: selected ? AppColors.terra500 : Colors.transparent,
                  shape: multiSelect ? BoxShape.rectangle : BoxShape.circle,
                  borderRadius: multiSelect ? BorderRadius.circular(4) : null,
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
                child: Text(label,
                    style: AppTypography.bodyMd.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    )),
              ),
              if (showPrice)
                Text(priceLabel,
                    style: AppTypography.caption.copyWith(
                      color: priceModifier > 0
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
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Center(
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
