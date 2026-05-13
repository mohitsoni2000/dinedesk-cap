// Order Builder — menu + cart for a specific table.
//
// Tap row → ItemDetailSheet for qty + grouped modifiers + note.
// Save & exit keeps the cart in memory until the session ends.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_mesh_background.dart';
import '../widgets/app_card.dart';
import '../widgets/item_detail_sheet.dart';

class OrderBuilderScreen extends ConsumerStatefulWidget {
  final String tableId;
  const OrderBuilderScreen({super.key, required this.tableId});
  @override
  ConsumerState<OrderBuilderScreen> createState() => _OrderBuilderScreenState();
}

class _OrderBuilderScreenState extends ConsumerState<OrderBuilderScreen> {
  String _query = '';
  bool _searchOpen = false;
  String? _activeSection;

  Future<bool> _confirmDiscard() async {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.paper,
        title: const Text('Discard draft?', style: AppTypography.title),
        content: Text(
          '${cart.length} items will be removed. Use "Save & exit" to keep them for later.',
          style: AppTypography.bodyMd),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard',
              style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final menu = ref.watch(menuProvider);
    final cart = ref.watch(cartProvider);
    final cartTotal = cart.fold(0.0, (s, l) => s + l.lineTotal);
    final guests = ref.watch(orderCustomerCountProvider);

    final sections = <String, List<MenuItem>>{};
    for (final m in menu) {
      if (_query.isNotEmpty &&
          !m.name.toLowerCase().contains(_query.toLowerCase())) {
        continue;
      }
      if (_activeSection != null && m.section != _activeSection) continue;
      sections.putIfAbsent(m.section, () => []).add(m);
    }

    final allSections = menu.map((m) => m.section).toSet().toList();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final ok = await _confirmDiscard();
        if (!context.mounted) return;
        if (ok) {
          ref.read(cartProvider.notifier).clear();
          context.pop();
        }
      },
      child: LiquidMeshBackground(
        child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              LiquidAppBar(
                title: 'Table ${widget.tableId}',
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () async {
                    final ok = await _confirmDiscard();
                    if (!context.mounted) return;
                    if (ok) {
                      ref.read(cartProvider.notifier).clear();
                      context.pop();
                    }
                  },
                ),
                actions: [
                  Hero(
                    tag: 'table-${widget.tableId}',
                    flightShuttleBuilder: (_, __, ___, ____, _____) =>
                        const SizedBox.shrink(),
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.tableMineBg,
                          borderRadius: const BorderRadius.all(AppRadii.xs),
                          border: Border.all(
                            color: AppColors.terra400.withValues(alpha: 0.4)),
                        ),
                        child: Text(widget.tableId,
                          style: AppTypography.caption.copyWith(
                            fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: const BoxDecoration(
                      color: AppColors.ink05,
                      borderRadius: BorderRadius.all(AppRadii.xs),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.people_outline, size: 14, color: AppColors.ink70),
                      const SizedBox(width: 4),
                      Text('$guests',
                        style: AppTypography.caption.copyWith(fontWeight: FontWeight.w600)),
                    ]),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    icon: Icon(_searchOpen ? Icons.close : Icons.search,
                      color: AppColors.ink70),
                    onPressed: () => setState(() {
                      _searchOpen = !_searchOpen;
                      if (!_searchOpen) _query = '';
                    }),
                  ),
                  IconButton(
                    icon: const Icon(Icons.bookmark_border, color: AppColors.ink70),
                    tooltip: 'Save & exit',
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Draft saved — resume from Tables'),
                        backgroundColor: AppColors.ink,
                      ));
                      context.pop();
                    },
                  ),
                ],
              ),
              if (_searchOpen)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.55),
                      borderRadius: const BorderRadius.all(AppRadii.sm),
                      border: Border.all(color: AppColors.ink10),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Search menu…',
                        icon: Icon(Icons.search, color: AppColors.ink50, size: 18),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                ),
              // Section chips.
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  children: [
                    _SectionChip(
                      label: 'All',
                      selected: _activeSection == null,
                      onTap: () => setState(() => _activeSection = null),
                    ),
                    const SizedBox(width: 8),
                    for (final s in allSections) ...[
                      _SectionChip(
                        label: s,
                        selected: _activeSection == s,
                        onTap: () => setState(() => _activeSection = s),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: sections.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.restaurant_menu,
                              color: AppColors.ink30, size: 48),
                            SizedBox(height: 12),
                            Text('No items match',
                              style: AppTypography.title),
                            SizedBox(height: 4),
                            Text('Try a different search',
                              style: AppTypography.caption),
                          ],
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      children: [
                        for (final entry in sections.entries) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(entry.key.toUpperCase(),
                              style: AppTypography.micro.copyWith(letterSpacing: 1.2),
                            ),
                          ),
                          AppCard(
                            padding: EdgeInsets.zero,
                            child: Column(
                              children: [
                                for (int i = 0; i < entry.value.length; i++) ...[
                                  _ItemRow(
                                    item: entry.value[i],
                                    onAdd: () {
                                      HapticFeedback.selectionClick();
                                      ref.read(cartProvider.notifier)
                                        .add(entry.value[i]);
                                    },
                                    onTap: () => ItemDetailSheet.show(
                                        context, entry.value[i]),
                                  ),
                                  if (i < entry.value.length - 1)
                                    const Divider(height: 1, color: AppColors.ink10),
                                ],
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 80),
                      ],
                    ),
              ),
              if (cart.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: GestureDetector(
                    onTap: () => context.push('/order/${widget.tableId}/review'),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [AppColors.terra400, AppColors.terra600],
                        ),
                        borderRadius: BorderRadius.all(AppRadii.md),
                        boxShadow: AppShadows.terraGlow,
                      ),
                      child: Row(
                        children: [
                          Text('Review · ${cart.length} ${cart.length == 1 ? "item" : "items"}',
                            style: AppTypography.bodyMd.copyWith(
                              color: Colors.white, fontWeight: FontWeight.w600),
                          ),
                          const Spacer(),
                          Text(formatRupeesCompact(cartTotal),
                            style: AppTypography.title.copyWith(color: Colors.white),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.arrow_forward, color: Colors.white),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      ),  // LiquidMeshBackground
    );
  }
}

class _SectionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SectionChip({
    required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () { HapticFeedback.selectionClick(); onTap(); },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : Colors.white.withValues(alpha: 0.6),
          borderRadius: const BorderRadius.all(AppRadii.pill),
          border: Border.all(
            color: selected ? AppColors.ink : AppColors.ink10),
        ),
        child: Center(
          child: Text(label,
            style: AppTypography.caption.copyWith(
              color: selected ? Colors.white : AppColors.ink,
              fontWeight: FontWeight.w600,
            )),
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  final MenuItem item;
  final VoidCallback onAdd;
  final VoidCallback onTap;
  const _ItemRow({required this.item, required this.onAdd, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final unavailable = !item.available;
    return InkWell(
      onTap: unavailable ? null : onTap,
      child: Opacity(
        opacity: unavailable ? 0.45 : 1,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              // Veg/non-veg indicator (FSSAI dot).
              _VegMark(isVeg: item.isVeg),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(item.name, style: AppTypography.bodyMd),
                        ),
                        if (unavailable) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.warn.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('86',
                              style: AppTypography.micro.copyWith(
                                color: AppColors.warn,
                                letterSpacing: 0.6,
                              )),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(formatRupeesCompact(item.price),
                      style: AppTypography.caption),
                  ],
                ),
              ),
              if (!unavailable)
                GestureDetector(
                  onTap: onAdd,
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: 48, height: 48,
                    child: Center(
                      child: Container(
                        width: 32, height: 32,
                        decoration: BoxDecoration(
                          color: AppColors.ink,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(Icons.add, color: Colors.white, size: 18),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// FSSAI veg/non-veg marker — green square dot for veg, red for non-veg.
class _VegMark extends StatelessWidget {
  final bool isVeg;
  const _VegMark({required this.isVeg});
  @override
  Widget build(BuildContext context) {
    final color = isVeg ? AppColors.success : AppColors.danger;
    return Container(
      width: 14, height: 14,
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Center(
        child: Container(
          width: 6, height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
