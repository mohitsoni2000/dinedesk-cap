import 'package:flutter/material.dart';
import '../data/money.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'dynamic_toast.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

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
      builder: (_, scroll) => AppSurface(
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            const SizedBox(height: 8),
            const SheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.inventory_2_outlined,
                      color: AppColors.violet, size: 20),
                  const SizedBox(width: 8),
                  const Text('Packages', style: AppTypography.sheetTitle),
                  const Spacer(),
                  Text('${packages.length} available',
                      style: AppTypography.caption),
                ],
              ),
            ),
            Divider(height: 1, color: context.palette.hairline),
            Expanded(
              child: packages.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.inventory_2_outlined,
                              color: context.palette.ink30, size: 48),
                          const SizedBox(height: 12),
                          const Text('No packages', style: AppTypography.title),
                          const SizedBox(height: 4),
                          const Text(
                              'Combo packages are created on the Desktop',
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
                          DynamicToast.show(context,
                              message: '${packages[i]['name']} added to cart',
                              kind: ToastKind.success);
                        },
                      ),
                    ),
            ),
            Padding(
              padding:
                  EdgeInsets.fromLTRB(16, 8, 16, 16 + context.sheetBottomInset),
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
            modsExtra: Money.zero,
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
    final price = Money.fromWire(pkg['price']) ?? Money.zero;
    final desc = pkg['description']?.toString();
    final items = pkg['items'];
    final itemCount = (items is List) ? items.length : 0;
    final isActive = pkg['is_active'] == 1 || pkg['is_active'] == true;

    return Opacity(
      opacity: isActive ? 1.0 : 0.45,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.palette.surface,
          borderRadius: const BorderRadius.all(AppRadii.md),
          border: Border.all(color: AppColors.violet.withValues(alpha: 0.2)),
          boxShadow: AppShadows.cardFor(context),
        ),
        child: Row(
          children: [
            Container(
              width: AppControlSizes.iconTile,
              height: AppControlSizes.iconTile,
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
