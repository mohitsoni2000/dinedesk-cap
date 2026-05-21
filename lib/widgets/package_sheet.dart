// Package Sheet — browse and add combo packages to the cart.
//
// Packages are synced from the Desktop server in the initial sync
// and stored in rawMenuDataProvider under the 'packages' key.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../theme/tokens.dart';
import 'liquid_chrome.dart';
import 'liquid_glass_surface.dart';

class PackageSheet extends ConsumerWidget {
  const PackageSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => const PackageSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rawMenu = ref.watch(rawMenuDataProvider);
    final packagesRaw = rawMenu['packages'];
    final packages = <Map<String, dynamic>>[];
    if (packagesRaw is List) {
      for (final p in packagesRaw) {
        if (p is Map) packages.add(Map<String, dynamic>.from(p));
      }
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      maxChildSize: 0.9,
      minChildSize: 0.4,
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.inventory_2_outlined,
                      color: AppColors.violet, size: 20),
                  const SizedBox(width: 8),
                  const Text('Packages', style: AppTypography.title),
                  const Spacer(),
                  Text('${packages.length} available',
                      style: AppTypography.caption),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.ink10),
            Expanded(
              child: packages.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.inventory_2_outlined,
                              color: AppColors.ink30, size: 48),
                          SizedBox(height: 12),
                          Text('No packages', style: AppTypography.title),
                          SizedBox(height: 4),
                          Text('Combo packages are created on the Desktop',
                              style: AppTypography.caption),
                        ],
                      ),
                    )
                  : ListView.separated(
                      controller: scroll,
                      padding: const EdgeInsets.all(16),
                      itemCount: packages.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => _PackageCard(
                        pkg: packages[i],
                        onAdd: () {
                          _addPackageToCart(ref, packages[i]);
                          Navigator.of(context).pop();
                          ScaffoldMessenger.of(context)
                            ..clearSnackBars()
                            ..showSnackBar(SnackBar(
                              content:
                                  Text('${packages[i]['name']} added to cart'),
                            ));
                        },
                      ),
                    ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  16, 8, 16, 16 + MediaQuery.of(context).viewPadding.bottom),
              child: LiquidSecondaryButton(
                label: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _addPackageToCart(WidgetRef ref, Map<String, dynamic> pkg) {
    final menu = ref.read(menuProvider);
    final pkgItems = pkg['items'];
    if (pkgItems is! List) return;

    for (final item in pkgItems) {
      if (item is! Map) continue;
      final itemId = item['item_id']?.toString();
      final qty = (item['quantity'] is int) ? item['quantity'] as int : 1;
      if (itemId == null) continue;

      // Find matching menu item.
      MenuItem? menuItem;
      for (final m in menu) {
        if (m.id == itemId) {
          menuItem = m;
          break;
        }
      }
      if (menuItem == null) continue;

      ref.read(cartProvider.notifier).addCustom(
            item: menuItem,
            qty: qty,
            mods: const [],
            modsExtra: 0,
            itemNote: 'Package: ${pkg['name']}',
          );
    }
  }
}

class _PackageCard extends StatelessWidget {
  final Map<String, dynamic> pkg;
  final VoidCallback onAdd;
  const _PackageCard({required this.pkg, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final name = pkg['name']?.toString() ?? 'Package';
    final price =
        (pkg['price'] is num) ? (pkg['price'] as num).toDouble() : 0.0;
    final desc = pkg['description']?.toString();
    final items = pkg['items'];
    final itemCount = (items is List) ? items.length : 0;
    final isActive = pkg['is_active'] == 1 || pkg['is_active'] == true;

    return Opacity(
      opacity: isActive ? 1.0 : 0.45,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.paper,
          borderRadius: const BorderRadius.all(AppRadii.md),
          border: Border.all(color: AppColors.violet.withValues(alpha: 0.2)),
          boxShadow: AppShadows.card,
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.violet.withValues(alpha: 0.1),
                borderRadius: const BorderRadius.all(AppRadii.sm),
              ),
              child: const Icon(Icons.inventory_2,
                  color: AppColors.violet, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: AppTypography.bodyMd
                          .copyWith(fontWeight: FontWeight.w600)),
                  if (desc != null && desc.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(desc,
                        style: AppTypography.caption,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                  const SizedBox(height: 2),
                  Text('$itemCount items · ${formatRupeesCompact(price)}',
                      style: AppTypography.caption
                          .copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            if (isActive)
              GestureDetector(
                onTap: onAdd,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.violet,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(Icons.add, color: Colors.white, size: 20),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
