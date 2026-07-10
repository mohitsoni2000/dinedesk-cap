

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../theme/tokens.dart';
import '../widgets/app_surface.dart';
import '../widgets/liquid_chrome.dart';
import 'sheet_handle.dart';
import 'stepper_button.dart';

class ItemDetailSheet extends ConsumerStatefulWidget {
  final MenuItem item;
  final bool autoFocusNote;
  const ItemDetailSheet(
      {super.key, required this.item, this.autoFocusNote = false});

  @override
  ConsumerState<ItemDetailSheet> createState() => _ItemDetailSheetState();

  static Future<void> show(BuildContext context, MenuItem item,
      {bool autoFocusNote = false}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => ItemDetailSheet(item: item, autoFocusNote: autoFocusNote),
    );
  }
}

class _ItemDetailSheetState extends ConsumerState<ItemDetailSheet> {
  int _qty = 1;
  final Map<String, String> _singleSelections = {};
  final Set<String> _multiSelections = {};

  final Map<String, Set<String>> _addonSelections = {};
  String _note = '';
  String? _selectedVariationId;
  final FocusNode _noteFocusNode = FocusNode();
  final TextEditingController _weightController = TextEditingController();

  bool get _isWeighed => widget.item.isWeighed;
  double? get _weight => double.tryParse(_weightController.text.trim());

  bool get _hasServerOptions => widget.item.optionGroups.isNotEmpty;
  bool get _hasAddonGroups => widget.item.addonGroups.isNotEmpty;

  bool get _variationsEnabled => ref.read(flagsProvider).itemVariations;
  bool get _hasVariations =>
      _variationsEnabled && widget.item.variations.isNotEmpty;

  MenuItemVariation? get _selectedVariation => widget.item.variations
      .where((v) => v.id == _selectedVariationId)
      .firstOrNull;

  @override
  void initState() {
    super.initState();
    if (_hasVariations) {
      _selectedVariationId = widget.item.variations.first.id;
    }
    for (final group in widget.item.optionGroups) {
      if ((group.isRequired || group.minSelect > 0) &&
          group.options.isNotEmpty) {
        _singleSelections[group.id] = group.options.first.id;
      }
    }
    if (widget.autoFocusNote) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _noteFocusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _noteFocusNode.dispose();
    _weightController.dispose();
    super.dispose();
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

  double get _addonExtra => _selectedAddonGroups.fold(
        0,
        (total, group) => total + group.extraPrice,
      );

  List<SelectedAddonGroup> get _selectedAddonGroups {
    final result = <SelectedAddonGroup>[];
    for (final group in widget.item.addonGroups) {
      final chosenIds = _addonSelections[group.id] ?? const <String>{};
      if (chosenIds.isEmpty) continue;
      final choices = group.choices
          .where((c) => chosenIds.contains(c.id))
          .map((c) => SelectedAddonChoice(
                choiceId: c.id,
                name: c.name,
                price: c.price,
              ))
          .toList();
      if (choices.isEmpty) continue;
      result.add(SelectedAddonGroup(
        groupId: group.id,
        groupName: group.name,
        choices: choices,
      ));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final basePrice = _selectedVariation?.price ?? widget.item.price;
    final unit = basePrice + _serverOptionExtra + _addonExtra;
    final total = _isWeighed ? unit * (_weight ?? 0) : unit * _qty;
    final canAdd = !_isWeighed || (_weight != null && _weight! > 0);

    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => AppSurface(
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            const SizedBox(height: 8),
            const SheetHandle(),
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
                  Text(
                    _selectedVariation != null
                        ? formatRupeesCompact(_selectedVariation!.price)
                        : formatRupeesCompact(widget.item.price),
                    style: AppTypography.title,
                  ),
                  const SizedBox(height: 24),

                  if (_hasVariations) ...[
                    Text('SIZE / VARIANT',
                        style:
                            AppTypography.micro.copyWith(letterSpacing: 1.4)),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final variation in widget.item.variations)
                          GestureDetector(
                            onTap: () {
                              HapticFeedback.selectionClick();
                              setState(
                                  () => _selectedVariationId = variation.id);
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: _selectedVariationId == variation.id
                                    ? AppColors.terraSoft
                                    : context.palette.surface,
                                borderRadius:
                                    const BorderRadius.all(AppRadii.sm),
                                border: Border.all(
                                  color: _selectedVariationId == variation.id
                                      ? AppColors.terra
                                      : AppColors.hairline,
                                  width: _selectedVariationId == variation.id
                                      ? 1.5
                                      : 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    variation.name,
                                    style: AppTypography.bodyMd.copyWith(
                                      fontWeight:
                                          _selectedVariationId == variation.id
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                      color: _selectedVariationId ==
                                              variation.id
                                          ? AppColors.terraDeep
                                          : context.palette.ink,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    formatRupeesCompact(variation.price),
                                    style: AppTypography.caption.copyWith(
                                      color: AppColors.terraDeep,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Divider(height: 1, color: context.palette.ink10),
                    const SizedBox(height: 20),
                  ],

                  if (_isWeighed) ...[
                    Text(
                      'WEIGHT (${widget.item.measureUnit})',
                      style: AppTypography.micro.copyWith(letterSpacing: 1.2),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: context.palette.surface,
                        borderRadius: const BorderRadius.all(AppRadii.sm),
                        border: Border.all(
                            color: AppColors.hairline, width: 1.5),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        controller: _weightController,
                        cursorColor: AppColors.terra,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: 'e.g. 0.5',
                          suffixText: widget.item.measureUnit,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ] else ...[

                    Row(
                      children: [
                        Text('QUANTITY',
                            style: AppTypography.micro
                                .copyWith(letterSpacing: 1.2)),
                        const Spacer(),
                        StepperButton(
                            icon: Icons.remove,
                            onTap: () {
                              if (_qty > 1) setState(() => _qty--);
                            }),
                        const SizedBox(width: 16),
                        SizedBox(
                            width: 32,
                            child: Center(
                              child: Text('$_qty',
                                  style: AppTypography.headline),
                            )),
                        const SizedBox(width: 16),
                        StepperButton(
                            icon: Icons.add,
                            onTap: () => setState(() => _qty++)),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  Divider(height: 1, color: context.palette.ink10),
                  const SizedBox(height: 20),

                  if (_hasAddonGroups) ...[
                    for (final group in widget.item.addonGroups) ...[
                      Text(
                        group.name.toUpperCase(),
                        style: AppTypography.micro.copyWith(letterSpacing: 1.4),
                      ),
                      const SizedBox(height: 12),
                      Column(
                        children: [
                          for (final choice in group.choices)
                            _OptionTile(
                              label: choice.name,
                              priceModifier: choice.price,
                              selected: (_addonSelections[group.id] ?? const {})
                                  .contains(choice.id),
                              multiSelect: group.selectionType == 'M',
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() {
                                  final current = _addonSelections.putIfAbsent(
                                      group.id, () => <String>{});
                                  if (group.selectionType == 'M') {
                                    if (current.contains(choice.id)) {
                                      current.remove(choice.id);
                                    } else if (current.length <
                                        group.maxSelect) {
                                      current.add(choice.id);
                                    }
                                  } else {
                                    current
                                      ..clear()
                                      ..add(choice.id);
                                  }
                                });
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                  ],

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

                  Text('SPECIAL NOTE',
                      style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: context.palette.surface,
                      borderRadius: const BorderRadius.all(AppRadii.sm),
                      border:
                          Border.all(color: AppColors.hairline, width: 1.5),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: TextField(
                      focusNode: _noteFocusNode,
                      cursorColor: AppColors.terra,
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
                      label: _isWeighed && !canAdd
                          ? 'Enter Weight'
                          : 'Add to Order',
                      fullWidth: true,
                      leadingIcon: Icons.add,
                      onPressed: !canAdd
                          ? null
                          : () {
                              HapticFeedback.mediumImpact();
                              final modLabels = <String>[];
                              final selectedOpts = <SelectedOption>[];

                              for (final option in _selectedServerOptions) {
                                modLabels.add(option.optionName);
                                selectedOpts.add(option);
                              }
                              final selectedAddonGroups = _selectedAddonGroups;
                              for (final group in selectedAddonGroups) {
                                for (final choice in group.choices) {
                                  modLabels.add(choice.name);
                                }
                              }

                              final variationPriceDiff =
                                  (_selectedVariation?.price ??
                                          widget.item.price) -
                                      widget.item.price;
                              final allMods = [
                                if (_selectedVariation != null)
                                  _selectedVariation!.name,
                                ...modLabels,
                              ];
                              ref.read(cartProvider.notifier).addCustom(
                                    item: widget.item,
                                    qty: _qty,
                                    mods: allMods,
                                    selectedOptions: selectedOpts,
                                    selectedAddons: selectedAddonGroups,
                                    modsExtra:
                                        _serverOptionExtra + variationPriceDiff,
                                    itemNote: _note,
                                    variationId: _selectedVariationId,
                                    variationName: _selectedVariation?.name,
                                    weight: _isWeighed ? _weight : null,
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
            color: selected ? AppColors.terraSoft : context.palette.surface,
            borderRadius: const BorderRadius.all(AppRadii.sm),
            border: Border.all(
              color: selected ? AppColors.terra : AppColors.hairline,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: selected ? AppColors.terra : Colors.transparent,
                  shape: multiSelect ? BoxShape.rectangle : BoxShape.circle,
                  borderRadius: multiSelect ? BorderRadius.circular(4) : null,
                  border: Border.all(
                    color: selected ? AppColors.terra : context.palette.ink30,
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
                      color: selected
                          ? AppColors.terraDeep
                          : context.palette.ink,
                    )),
              ),
              if (showPrice)
                Text(priceLabel,
                    style: AppTypography.caption.copyWith(
                      color: priceModifier > 0
                          ? AppColors.terraDeep
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
