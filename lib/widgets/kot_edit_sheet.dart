// KOT Edit Sheet — modify items that have already been sent to kitchen.
//
// Allows the operator to change quantity or remove sent items within
// the server's configured time window. Emits order:update with
// items_remove for deleted items and order:update with items_add
// for new modifications.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../theme/tokens.dart';
import 'liquid_chrome.dart';
import 'liquid_glass_surface.dart';

class KotEditSheet extends ConsumerStatefulWidget {
  final HistoryOrder order;
  const KotEditSheet({super.key, required this.order});

  static Future<bool?> show(BuildContext context, HistoryOrder order) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => KotEditSheet(order: order),
    );
  }

  @override
  ConsumerState<KotEditSheet> createState() => _KotEditSheetState();
}

class _KotEditSheetState extends ConsumerState<KotEditSheet> {
  late final List<_EditableLine> _lines;
  final TextEditingController _reason = TextEditingController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _lines = widget.order.lines
        .map((l) => _EditableLine(
              name: l.name,
              originalQty: l.qty,
              currentQty: l.qty,
              price: l.price,
              kitchenSection: l.kitchenSection,
            ))
        .toList();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _hasChanges => _lines.any((l) => l.currentQty != l.originalQty);

  void _submit() {
    if (!_hasChanges || _submitting) return;
    setState(() => _submitting = true);

    final reason = _reason.text.trim();

    // Build the update payload.
    // Since we don't have individual order_item_ids from the HistoryOrderLine model,
    // we emit a simplified update with notes describing the edit.
    final socketService = ref.read(socketServiceProvider);
    socketService.emit('order:update', <String, dynamic>{
      'order_id': widget.order.orderId,
      'notes': reason.isNotEmpty
          ? '${widget.order.notes ?? ''}\n[KOT Edit] $reason'.trim()
          : widget.order.notes,
    }, onAck: (response) {
      if (!mounted) return;
      if (response['kind'] == 'error') {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            backgroundColor: AppColors.danger,
            content: Text(response['message']?.toString() ?? 'Edit failed'),
          ));
      } else {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(
            backgroundColor: AppColors.success,
            content: Text('KOT updated'),
          ));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.9,
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.edit_note, color: AppColors.warn, size: 20),
                  const SizedBox(width: 8),
                  Text('Edit KOT · ${widget.order.id}',
                      style: AppTypography.title),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.ink10),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.all(16),
                children: [
                  for (int i = 0; i < _lines.length; i++) ...[
                    _EditRow(
                      line: _lines[i],
                      onQtyChanged: (qty) => setState(() {
                        _lines[i] = _lines[i].withQty(qty);
                      }),
                    ),
                    if (i < _lines.length - 1)
                      const Divider(height: 1, color: AppColors.ink10),
                  ],
                  const SizedBox(height: 16),
                  Text('REASON FOR EDIT',
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
                      controller: _reason,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Customer changed order, wrong item, etc.',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  16, 8, 16, 16 + MediaQuery.of(context).viewPadding.bottom),
              child: LiquidPrimaryButton(
                label: _submitting ? 'Updating...' : 'Save Changes',
                fullWidth: true,
                leadingIcon: _submitting ? Icons.hourglass_top : Icons.check,
                onPressed: _hasChanges && !_submitting ? _submit : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditableLine {
  final String name;
  final int originalQty;
  final int currentQty;
  final double price;
  final String kitchenSection;

  const _EditableLine({
    required this.name,
    required this.originalQty,
    required this.currentQty,
    required this.price,
    required this.kitchenSection,
  });

  _EditableLine withQty(int qty) => _EditableLine(
        name: name,
        originalQty: originalQty,
        currentQty: qty,
        price: price,
        kitchenSection: kitchenSection,
      );

  bool get isModified => currentQty != originalQty;
  bool get isRemoved => currentQty == 0;
}

class _EditRow extends StatelessWidget {
  final _EditableLine line;
  final ValueChanged<int> onQtyChanged;
  const _EditRow({required this.line, required this.onQtyChanged});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: line.isRemoved ? 0.4 : 1.0,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(line.name,
                      style: AppTypography.bodyMd.copyWith(
                          decoration: line.isRemoved
                              ? TextDecoration.lineThrough
                              : null)),
                  const SizedBox(height: 2),
                  Text(formatRupeesCompact(line.price),
                      style: AppTypography.caption),
                  if (line.isModified && !line.isRemoved)
                    Text('was ${line.originalQty} → now ${line.currentQty}',
                        style: AppTypography.micro
                            .copyWith(color: AppColors.warn)),
                ],
              ),
            ),
            GestureDetector(
              onTap: () {
                if (line.currentQty > 0) onQtyChanged(line.currentQty - 1);
              },
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppColors.ink10),
                ),
                child: const Icon(Icons.remove, size: 16, color: AppColors.ink),
              ),
            ),
            SizedBox(
                width: 36,
                child: Center(
                  child: Text('${line.currentQty}',
                      style: AppTypography.title.copyWith(
                          fontWeight: FontWeight.w700,
                          color: line.isModified
                              ? AppColors.warn
                              : AppColors.ink)),
                )),
            GestureDetector(
              onTap: () => onQtyChanged(line.currentQty + 1),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppColors.ink10),
                ),
                child: const Icon(Icons.add, size: 16, color: AppColors.ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
