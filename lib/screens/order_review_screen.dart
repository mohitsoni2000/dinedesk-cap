// Order Review Screen — final pass before submitting to kitchen.
//
// Shows the cart split by kitchen section so the operator can confirm KOT
// distribution. Adds order-level notes + editable customer count. The "Pay"
// button has been removed — billing happens on the admin desktop only.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../services/pin_guard.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/customer_sheet.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_mesh_background.dart';
import '../widgets/order_submitting_overlay.dart';

class OrderReviewScreen extends ConsumerStatefulWidget {
  final String tableId;
  const OrderReviewScreen({super.key, required this.tableId});
  @override
  ConsumerState<OrderReviewScreen> createState() => _OrderReviewScreenState();
}

class _OrderReviewScreenState extends ConsumerState<OrderReviewScreen> {
  final TextEditingController _notes = TextEditingController();
  Map<String, dynamic>? _customer;

  @override
  void initState() {
    super.initState();
    _notes.text = ref.read(orderNotesProvider);
  }

  bool _submitted = false;

  @override
  void dispose() {
    // Reset notes if leaving without submitting (C2 fix).
    if (!_submitted) {
      ref.read(orderNotesProvider.notifier).state = '';
    }
    _notes.dispose();
    super.dispose();
  }

  String _kitchenLabel(String key) => switch (key) {
    'tandoor'   => 'Tandoor',
    'curry'     => 'Curry / Main',
    'south'     => 'South',
    'chinese'   => 'Chinese',
    'beverages' => 'Beverages & Desserts',
    'tikka'     => 'Tikka',
    _           => key[0].toUpperCase() + key.substring(1),
  };

  IconData _kitchenIcon(String key) => switch (key) {
    'tandoor'   => Icons.local_fire_department_outlined,
    'curry'     => Icons.soup_kitchen_outlined,
    'south'     => Icons.ramen_dining_outlined,
    'chinese'   => Icons.takeout_dining_outlined,
    'beverages' => Icons.local_cafe_outlined,
    _           => Icons.restaurant_menu,
  };

  Future<void> _submit() async {
    // PIN guard — verify operator before sending KOT.
    final pinOk = await requirePinIfNeeded(context, ref, 'kot');
    if (!pinOk || !mounted) return;

    HapticFeedback.heavyImpact();
    ref.read(orderNotesProvider.notifier).state = _notes.text;

    final cart = ref.read(cartProvider);
    final notes = _notes.text;

    final completer = Completer<bool>();
    final socketService = ref.read(socketServiceProvider);

    // Build items payload with proper SelectedOptionPayload structure.
    final items = cart.map((l) => <String, dynamic>{
      'item_id': l.item.id,
      'quantity': l.qty,
      'selected_options': l.selectedOptions.map((o) => o.toJson()).toList(),
      'notes': l.itemNote,
    }).toList();

    String? createdOrderId;

    socketService.emit('order:create', <String, dynamic>{
      'table_id': widget.tableId,  // This is now the server UUID
      'items': items,
      'notes': notes,
      'order_type': 'dine_in',
      if (_customer != null && _customer!['id'] != null)
        'customer_id': _customer!['id'],
    }, onAck: (response) {
      if (!mounted) return;
      if (response['kind'] == 'error') {
        if (!completer.isCompleted) completer.complete(false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(response['message']?.toString() ?? 'Order failed')),
        );
        return;
      }
      final order = response['order'] as Map<String, dynamic>?;
      createdOrderId = order?['id']?.toString();
      final kotId = order?['kot_number']?.toString() ??
          order?['order_number']?.toString() ?? generateKotId();
      ref.read(lastKotIdProvider.notifier).state = kotId;

      // C3 fix: emit kot:send immediately after order:create succeeds.
      if (createdOrderId != null) {
        socketService.emit('kot:send', <String, dynamic>{
          'order_id': createdOrderId!,
        }, onAck: (kotResponse) {
          if (kotResponse['kind'] == 'error') {
            debugPrint('[Order] ✗ KOT send failed: ${kotResponse['message']}');
          } else {
            debugPrint('[Order] ✓ KOT sent to kitchen');
          }
        });
      }

      if (!completer.isCompleted) completer.complete(true);
    });

    final ok = await OrderSubmittingOverlay.show(context, completer: completer);
    if (!mounted) return;

    if (ok) {
      _submitted = true;
      ref.read(cartProvider.notifier).clear();
      ref.read(orderNotesProvider.notifier).state = '';
      context.go('/order/${widget.tableId}/success');
    } else {
      // Timeout or error — show feedback so operator can retry.
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(
            content: Text('Order could not be confirmed — please retry'),
          ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);
    final total = cart.fold(0.0, (s, l) => s + l.lineTotal);
    final byKitchen = <String, List<CartLine>>{};
    for (final l in cart) {
      byKitchen.putIfAbsent(l.item.kitchenSection, () => []).add(l);
    }
    final flags = ref.watch(flagsProvider);

    // Resolve display name for the table from the tables provider.
    final tables = ref.watch(tablesProvider);
    final tableDisplay = tables
        .where((t) => t.serverId == widget.tableId)
        .map((t) => t.id)
        .firstOrNull ?? widget.tableId;

    return LiquidMeshBackground(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            LiquidAppBar(
              title: 'Review · $tableDisplay',
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.pop()),
            ),
            Expanded(
              child: cart.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.shopping_basket_outlined,
                          color: AppColors.ink30, size: 48),
                        SizedBox(height: 12),
                        Text('Cart is empty', style: AppTypography.title),
                        SizedBox(height: 4),
                        Text('Go back and add items',
                          style: AppTypography.caption),
                      ],
                    ),
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.lg, AppSpacing.lg,
                      AppSpacing.lg + MediaQuery.of(context).viewInsets.bottom),
                    children: [
                      // Guest count removed — managed on Desktop side.
                      if (flags.customers) ...[
                        const SizedBox(height: 12),

                        // Customer attach row.
                        AppCard(
                          onTap: () async {
                            final result = await CustomerSheet.show(context);
                            if (result != null && mounted) {
                              setState(() => _customer = result);
                            }
                          },
                          child: Row(
                            children: [
                              Icon(
                                _customer != null
                                    ? Icons.person
                                    : Icons.person_add_outlined,
                                color: _customer != null
                                    ? AppColors.terra600
                                    : AppColors.ink70,
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _customer != null
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _customer!['name']?.toString() ??
                                                'Customer',
                                            style: AppTypography.bodyMd.copyWith(
                                                fontWeight: FontWeight.w600),
                                          ),
                                          if (_customer!['phone'] != null &&
                                              _customer!['phone']
                                                  .toString()
                                                  .isNotEmpty)
                                            Text(
                                              _customer!['phone'].toString(),
                                              style: AppTypography.caption,
                                            ),
                                        ],
                                      )
                                    : const Text('Add Customer',
                                        style: AppTypography.bodyMd),
                              ),
                              if (_customer != null)
                                GestureDetector(
                                  onTap: () =>
                                      setState(() => _customer = null),
                                  child: const Icon(Icons.close,
                                      color: AppColors.ink50, size: 18),
                                )
                              else
                                const Icon(Icons.chevron_right,
                                    color: AppColors.ink30, size: 20),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),

                      // Cart lines.
                      AppCard(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            for (int i = 0; i < cart.length; i++) ...[
                              Dismissible(
                                key: ValueKey(cart[i].uid),
                                direction: DismissDirection.endToStart,
                                background: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.symmetric(horizontal: 20),
                                  color: AppColors.danger.withValues(alpha: 0.85),
                                  child: const Icon(Icons.delete_outline,
                                    color: Colors.white),
                                ),
                                onDismissed: (_) {
                                  HapticFeedback.mediumImpact();
                                  // Look up by uid at dismiss-time to avoid stale index (C4 fix).
                                  final uid = cart[i].uid;
                                  final current = ref.read(cartProvider);
                                  final idx = current.indexWhere((l) => l.uid == uid);
                                  if (idx >= 0) ref.read(cartProvider.notifier).removeAt(idx);
                                },
                                child: _CartRow(line: cart[i], index: i),
                              ),
                              if (i < cart.length - 1)
                                const Divider(height: 1, color: AppColors.ink10),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // KOT preview by kitchen section.
                      Text('KOT PREVIEW',
                        style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                      const SizedBox(height: 8),
                      AppCard(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            for (int i = 0; i < byKitchen.entries.length; i++) ...[
                              _KotRow(
                                icon: _kitchenIcon(byKitchen.keys.elementAt(i)),
                                label: _kitchenLabel(byKitchen.keys.elementAt(i)),
                                lines: byKitchen.values.elementAt(i),
                              ),
                              if (i < byKitchen.entries.length - 1)
                                const Divider(height: 1, color: AppColors.ink10),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Order notes.
                      Text('ORDER NOTES',
                        style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                      const SizedBox(height: 8),
                      AppCard(
                        child: TextField(
                          controller: _notes,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: 'Allergies, urgency, etc.',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Total.
                      AppCard(
                        child: Column(
                          children: [
                            Row(children: [
                              const Text('Subtotal', style: AppTypography.bodyMd),
                              const Spacer(),
                              Text(formatRupeesCompact(total),
                                style: AppTypography.bodyMd),
                            ]),
                            const SizedBox(height: 4),
                            const Text('Taxes added on bill (admin desktop)',
                              style: AppTypography.caption,
                              textAlign: TextAlign.right),
                            const Divider(height: 16, color: AppColors.ink10),
                            Row(children: [
                              const Text('Total', style: AppTypography.title),
                              const Spacer(),
                              Text(formatRupeesCompact(total),
                                style: AppTypography.headline),
                            ]),
                          ],
                        ),
                      ),
                    ],
                  ),
            ),
            if (cart.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: LiquidPrimaryButton(
                  label: 'Send to Kitchen',
                  fullWidth: true,
                  leadingIcon: Icons.restaurant_menu,
                  onPressed: _submit,
                ),
              ),
          ],
        ),
      ),
      ),  // LiquidMeshBackground
    );
  }
}

class _CartRow extends ConsumerWidget {
  final CartLine line;
  final int index;
  const _CartRow({required this.line, required this.index});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _VegMark(isVeg: line.item.isVeg),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.item.name, style: AppTypography.bodyMd),
                if (line.mods.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(line.mods.join(' · '),
                    style: AppTypography.caption.copyWith(color: AppColors.ink70)),
                ],
                if (line.itemNote.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text('"${line.itemNote}"',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.terra600,
                      fontStyle: FontStyle.italic)),
                ],
                const SizedBox(height: 2),
                Text(formatRupeesCompact(line.item.price + line.modsExtra),
                  style: AppTypography.caption),
              ],
            ),
          ),
          _Step(icon: Icons.remove, onTap: () {
            HapticFeedback.selectionClick();
            ref.read(cartProvider.notifier).setQtyAt(index, line.qty - 1);
          }),
          SizedBox(width: 32, child: Center(
            child: Text('${line.qty}',
              style: AppTypography.title.copyWith(fontWeight: FontWeight.w600)),
          )),
          _Step(icon: Icons.add, onTap: () {
            HapticFeedback.selectionClick();
            ref.read(cartProvider.notifier).setQtyAt(index, line.qty + 1);
          }),
          const SizedBox(width: 12),
          SizedBox(
            width: 70,
            child: Text(
              formatRupeesCompact(line.lineTotal),
              style: AppTypography.title, textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _Step({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    behavior: HitTestBehavior.opaque,
    child: SizedBox(
      width: 44, height: 44,
      child: Center(
        child: Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.ink10),
          ),
          child: Icon(icon, size: 14, color: AppColors.ink),
        ),
      ),
    ),
  );
}

class _KotRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final List<CartLine> lines;
  const _KotRow({
    required this.icon, required this.label, required this.lines});
  @override
  Widget build(BuildContext context) {
    final qty = lines.fold<int>(0, (s, l) => s + l.qty);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: AppColors.terra500.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: AppColors.terra600),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTypography.bodyMd.copyWith(
                  fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('${lines.length} ${lines.length == 1 ? "item" : "items"} · '
                    '$qty units',
                  style: AppTypography.caption),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.ink05,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('1 KOT',
              style: AppTypography.micro.copyWith(letterSpacing: 0.6)),
          ),
        ],
      ),
    );
  }
}

class _VegMark extends StatelessWidget {
  final bool isVeg;
  const _VegMark({required this.isVeg});
  @override
  Widget build(BuildContext context) {
    final color = isVeg ? AppColors.success : AppColors.danger;
    return Container(
      width: 12, height: 12,
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Center(
        child: Container(
          width: 5, height: 5,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
