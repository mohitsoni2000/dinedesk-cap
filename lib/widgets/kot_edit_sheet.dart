

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../services/pin_guard.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'dynamic_toast.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

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
              orderItemId: l.orderItemId,
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

  Future<void> _submit() async {
    if (!_hasChanges || _submitting) return;
    final pinOk = await requirePinIfNeeded(context, ref, 'kot_edit');
    if (!pinOk || !mounted) return;
    setState(() => _submitting = true);

    final reason = _reason.text.trim();

    final changes = <Map<String, dynamic>>[];
    for (final l in _lines) {
      if (!l.isModified || l.orderItemId.isEmpty) continue;
      if (l.isRemoved) {
        changes.add({'type': 'remove', 'order_item_id': l.orderItemId});
      } else {
        changes.add({
          'type': 'update_quantity',
          'order_item_id': l.orderItemId,
          'new_quantity': l.currentQty,
        });
      }
    }

    final socketService = ref.read(socketServiceProvider);
    socketService.emit('kot:edit', <String, dynamic>{
      'order_id': widget.order.orderId,
      'changes': changes,
      'reason': reason.isNotEmpty ? reason : 'Modified from waiter app',
    }, onAck: (response) {
      if (!mounted) return;
      if (response['kind'] == 'error') {
        setState(() => _submitting = false);
        DynamicToast.show(context,
            message: response['message']?.toString() ?? 'Edit failed',
            kind: ToastKind.error);
      } else {
        Navigator.of(context).pop(true);
        DynamicToast.show(context,
            message: 'KOT updated', kind: ToastKind.success);
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
                  const Icon(Icons.edit_note, color: AppColors.warn, size: 20),
                  const SizedBox(width: 8),
                  Text('Edit KOT · ${widget.order.id}',
                      style: AppTypography.sheetTitle),
                ],
              ),
            ),
            Divider(height: 1, color: context.palette.hairline),
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
                      Divider(height: 1, color: context.palette.hairline),
                  ],
                  const SizedBox(height: 16),
                  Text('REASON FOR EDIT',
                      style: AppTypography.micro.copyWith(letterSpacing: 1.4)),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: context.palette.surface,
                      borderRadius: const BorderRadius.all(AppRadii.sm),
                      border: Border.all(
                          color: context.palette.hairline, width: 1.5),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: TextField(
                      controller: _reason,
                      cursorColor: AppColors.terra,
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
                  16, 8, 16, 16 + context.sheetBottomInset),
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
  final String orderItemId;
  final String name;
  final int originalQty;
  final int currentQty;
  final double price;
  final String kitchenSection;

  const _EditableLine({
    required this.orderItemId,
    required this.name,
    required this.originalQty,
    required this.currentQty,
    required this.price,
    required this.kitchenSection,
  });

  _EditableLine withQty(int qty) => _EditableLine(
        orderItemId: orderItemId,
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
            AppSurface(
              borderRadius: BorderRadius.circular(18),
              padding: EdgeInsets.zero,
              shadow: const [],
              onTap: () {
                if (line.currentQty > 0) onQtyChanged(line.currentQty - 1);
              },
              child: SizedBox(
                width: 36,
                height: 36,
                child: Center(
                    child: Icon(Icons.remove,
                        size: 16, color: context.palette.ink)),
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
                              : context.palette.ink)),
                )),
            AppSurface(
              borderRadius: BorderRadius.circular(18),
              padding: EdgeInsets.zero,
              shadow: const [],
              onTap: () => onQtyChanged(line.currentQty + 1),
              child: SizedBox(
                width: 36,
                height: 36,
                child: Center(
                    child:
                        Icon(Icons.add, size: 16, color: context.palette.ink)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
