import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../motion/motion.dart';
import '../services/pin_guard.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/customer_sheet.dart';
import '../widgets/quick_action_tile.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_mesh_background.dart';
import '../widgets/order_submitting_overlay.dart';
import '../widgets/liquid_glass_surface.dart';

class OrderReviewScreen extends ConsumerStatefulWidget {
  final String tableId;
  const OrderReviewScreen({super.key, required this.tableId});
  @override
  ConsumerState<OrderReviewScreen> createState() => _OrderReviewScreenState();
}

enum _OrderType { dineIn, takeaway }

/// Step identifier for per-step error messages in order submission.
enum _OrderFlowStep { orderCreate, kotSend, billGenerate, payment }

/// Result of a single order submission step — carries step ID and user message.
final class _OrderFlowStepResult {
  /// Which step failed, or null if the flow succeeded.
  final _OrderFlowStep? failedStep;
  /// Human-readable error message for display.
  final String? errorMessage;

  const _OrderFlowStepResult({this.failedStep, this.errorMessage});
  bool get isSuccess => failedStep == null;
}

class _OrderReviewScreenState extends ConsumerState<OrderReviewScreen> {
  final TextEditingController _notes = TextEditingController();
  Map<String, dynamic>? _customer;
  _OrderType _orderType = _OrderType.dineIn;
  StateController<String>? _notesNotifier;

  @override
  void initState() {
    super.initState();
    _notes.text = ref.read(orderNotesProvider);
    _notesNotifier = ref.read(orderNotesProvider.notifier);
  }

  bool _submitted = false;

  // OR2 fix: track the order ID for which KOT was already sent successfully.
  // On retry after bill:generate failure, skip order:create/update + kot:send.
  String? _kotSentOrderId;

  @override
  void dispose() {
    // Fix #8: Don't clear notes on back navigation — they should persist
    // when user goes back to add more items. Only clear on successful submit.
    if (_submitted) {
      _notesNotifier?.state = '';
    }
    _notes.dispose();
    super.dispose();
  }

  String _kitchenLabel(String key) => switch (key) {
        'tandoor' => 'Tandoor',
        'curry' => 'Curry / Main',
        'south' => 'South',
        'chinese' => 'Chinese',
        'beverages' => 'Beverages & Desserts',
        'tikka' => 'Tikka',
        _ => key[0].toUpperCase() + key.substring(1),
      };

  IconData _kitchenIcon(String key) => switch (key) {
        'tandoor' => Icons.local_fire_department_outlined,
        'curry' => Icons.soup_kitchen_outlined,
        'south' => Icons.ramen_dining_outlined,
        'chinese' => Icons.takeout_dining_outlined,
        'beverages' => Icons.local_cafe_outlined,
        _ => Icons.restaurant_menu,
      };

  List<Map<String, dynamic>> _itemsPayload(List<CartLine> cart) {
    return cart
        .map((l) => <String, dynamic>{
              'item_id': l.item.id,
              if (l.variationId != null) 'variation_id': l.variationId,
              if (l.variationName != null) 'variation_name': l.variationName,
              'quantity': l.qty,
              'selected_options':
                  l.selectedOptions.map((o) => o.toJson()).toList(),
              'notes': l.itemNote,
            })
        .toList();
  }

  String? _activeOrderIdForTable() {
    if (_orderType != _OrderType.dineIn) return null;
    final table = ref
        .read(tablesProvider)
        .where((t) => t.serverId == widget.tableId)
        .firstOrNull;
    if (table?.activeOrderId != null && table!.activeOrderId!.isNotEmpty) {
      return table.activeOrderId;
    }
    final active = ref.read(activeOrdersProvider).where((order) {
      return order['table_id']?.toString() == widget.tableId &&
          order['status']?.toString() != 'paid' &&
          order['status']?.toString() != 'cancelled';
    }).firstOrNull;
    return active?['id']?.toString();
  }

  String? _orderIdFromResponse(
    Map<String, dynamic> response, {
    String? fallback,
  }) {
    final order = response['order'];
    if (order is Map && order['id'] != null) return order['id'].toString();
    return response['order_id']?.toString() ?? fallback;
  }

  void _rememberKotLabel(Map<String, dynamic> response) {
    final order = response['order'];
    final label = order is Map
        ? (order['kot_number']?.toString() ?? order['order_number']?.toString())
        : null;
    ref.read(lastKotIdProvider.notifier).state = label ?? generateKotId();
  }

  Future<Map<String, dynamic>> _createOrUpdateOrder({
    required List<Map<String, dynamic>> items,
    required String notes,
  }) {
    final socketService = ref.read(socketServiceProvider);
    final existingOrderId = _activeOrderIdForTable();
    if (existingOrderId != null && items.isNotEmpty) {
      return socketService.emitAck('order:update', <String, dynamic>{
        'order_id': existingOrderId,
        'items_add': items,
        'notes': notes,
      });
    }
    return socketService.emitAck('order:create', <String, dynamic>{
      if (_orderType == _OrderType.dineIn) 'table_id': widget.tableId,
      'items': items,
      'notes': notes,
      'order_type': _orderType == _OrderType.dineIn ? 'dine_in' : 'takeaway',
      if (_customer != null && _customer!['id'] != null)
        'customer_id': _customer!['id'],
    });
  }

  /// Runs the order submission flow, returning which step failed and why.
  Future<_OrderFlowStepResult> _runOrderFlow({
    required bool generateBill,
    required bool collectPayment,
    String quickSettleMode = 'cash',
  }) async {
    final cart = ref.read(cartProvider);
    final socketService = ref.read(socketServiceProvider);
    String? orderId;

    if (_kotSentOrderId != null) {
      orderId = _kotSentOrderId;
    } else {
      final items = _itemsPayload(cart);
      final fallbackOrderId = _activeOrderIdForTable();

      final orderResponse = await _createOrUpdateOrder(
        items: items,
        notes: _notes.text,
      );
      if (orderResponse['kind'] == 'error') {
        return _OrderFlowStepResult(
          failedStep: _OrderFlowStep.orderCreate,
          errorMessage: 'Could not save order — please retry',
        );
      }
      ref.read(syncServiceProvider).applyOrderAck(orderResponse, includeHistory: true);
      _rememberKotLabel(orderResponse);

      orderId = _orderIdFromResponse(orderResponse, fallback: fallbackOrderId);
      if (orderId == null || orderId.isEmpty) {
        return _OrderFlowStepResult(
          failedStep: _OrderFlowStep.orderCreate,
          errorMessage: 'Order saved but ID not returned — please retry',
        );
      }

      // Optimistic UI: mark all cart lines as pending before the KOT emit.
      ref.read(cartProvider.notifier).setSyncStatusAll(SyncStatus.pending);
      Map<String, dynamic> kotResponse;
      try {
        kotResponse = await socketService
            .emitAck('kot:send', <String, dynamic>{'order_id': orderId})
            .timeout(const Duration(seconds: 8));
      } on TimeoutException {
        ref.read(cartProvider.notifier).setSyncStatusFailed();
        return const _OrderFlowStepResult(
          failedStep: _OrderFlowStep.kotSend,
          errorMessage: 'KOT timed out — please retry',
        );
      } catch (_) {
        ref.read(cartProvider.notifier).setSyncStatusFailed();
        return const _OrderFlowStepResult(
          failedStep: _OrderFlowStep.kotSend,
          errorMessage: 'Failed to send KOT to kitchen — please retry',
        );
      }
      if (kotResponse['kind'] == 'error') {
        ref.read(cartProvider.notifier).setSyncStatusFailed();
        return _OrderFlowStepResult(
          failedStep: _OrderFlowStep.kotSend,
          errorMessage: 'Failed to send KOT to kitchen — please retry',
        );
      }
      ref.read(cartProvider.notifier).setSyncStatusAll(SyncStatus.synced);
      ref.read(syncServiceProvider).applyOrderAck(kotResponse, includeHistory: true);
      _kotSentOrderId = orderId;
    }

    if (!generateBill) return const _OrderFlowStepResult();

    final billResponse = await socketService.emitAck(
      'bill:generate', <String, dynamic>{'order_id': orderId},
    );
    if (billResponse['kind'] == 'error') {
      return _OrderFlowStepResult(
        failedStep: _OrderFlowStep.billGenerate,
        errorMessage: 'Failed to generate bill — please retry',
      );
    }
    ref.read(syncServiceProvider).applyOrderAck(
          billResponse, includeHistory: true, markTableBilled: true);
    if (!collectPayment) return const _OrderFlowStepResult();

    final bills = billResponse['bills'];
    final bill = (bills is List && bills.isNotEmpty && bills.first is Map)
        ? Map<String, dynamic>.from(bills.first as Map) : null;
    final billId = bill?['id']?.toString();
    if (billId == null || billId.isEmpty) {
      return _OrderFlowStepResult(
        failedStep: _OrderFlowStep.billGenerate,
        errorMessage: 'Bill generated but ID not returned — please retry',
      );
    }

    final total = cart.fold(0.0, (double s, CartLine l) => s + l.lineTotal);
    final billTotal = (bill?['total_amount'] as num?)?.toDouble() ?? total;
    final paymentResponse = await socketService.emitAck(
      'bill:payment', <String, dynamic>{
        'bill_id': billId,
        'payments': [{'payment_mode': quickSettleMode, 'amount': billTotal}],
      },
    );
    if (paymentResponse['kind'] == 'error') {
      return _OrderFlowStepResult(
        failedStep: _OrderFlowStep.payment,
        errorMessage: 'Payment failed — please retry from the bill screen',
      );
    }
    ref.read(syncServiceProvider).applyOrderAck(paymentResponse, includeHistory: true);
    return const _OrderFlowStepResult();
  }

  Future<void> _submit() async {
    final pinOk = await requirePinIfNeeded(context, ref, 'kot');
    if (!pinOk || !mounted) return;
    await _submitWithFlow(generateBill: false, collectPayment: false);
  }

  Future<void> _submitWithFlow({
    required bool generateBill,
    required bool collectPayment,
    String quickSettleMode = 'cash',
  }) async {
    ref.read(feedbackServiceProvider).fire(const FeedbackHeavy());
    ref.read(orderNotesProvider.notifier).state = _notes.text;

    final completer = Completer<bool>();
    final runningFlow = _runOrderFlow(
      generateBill: generateBill,
      collectPayment: collectPayment,
      quickSettleMode: quickSettleMode,
    );
    unawaited(runningFlow.then((result) {
      if (!completer.isCompleted) completer.complete(result.isSuccess);
    }));

    final ok = await OrderSubmittingOverlay.show(context, completer: completer);
    if (!mounted) return;
    if (ok) {
      _submitted = true;
      _kotSentOrderId = null; // OR2: reset so next order starts fresh
      ref.read(cartProvider.notifier).clear();
      ref.read(orderNotesProvider.notifier).state = '';
      context.go('/order/${widget.tableId}/success');
      return;
    }

    // Flow failed — capture messenger before await to avoid async gap warning.
    final messenger = ScaffoldMessenger.of(context);
    String msg = 'Order could not be confirmed — please retry';
    try {
      final result = await runningFlow;
      if (result.errorMessage != null) {
        final stepLabel = switch (result.failedStep) {
          _OrderFlowStep.orderCreate => 'Order creation',
          _OrderFlowStep.kotSend => 'KOT to kitchen',
          _OrderFlowStep.billGenerate => 'Bill generation',
          _OrderFlowStep.payment => 'Payment',
          null => null,
        };
        msg = stepLabel != null
            ? '$stepLabel failed: ${result.errorMessage}'
            : result.errorMessage!;
      }
    } catch (_) {
      // ignore — use default message
    }

    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// KOT + Bill: create order → send KOT → generate bill in one action.
  Future<void> _submitKotAndBill() async {
    final pinOk = await requirePinIfNeeded(context, ref, 'kot_and_bill');
    if (!pinOk || !mounted) return;
    await _submitWithFlow(generateBill: true, collectPayment: false);
  }

  /// Quick Settle: create → KOT → bill → pay, all in one.
  /// Shows a payment mode picker before committing.
  Future<void> _quickSettle() async {
    final pinOk = await requirePinIfNeeded(context, ref, 'quick_settle');
    if (!pinOk || !mounted) return;

    final mode = await _pickQuickSettleMode();
    if (mode == null || !mounted) return;

    await _submitWithFlow(
        generateBill: true, collectPayment: true, quickSettleMode: mode);
  }

  Future<String?> _pickQuickSettleMode() {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.paper,
        shape:
            const RoundedRectangleBorder(borderRadius: BorderRadius.all(AppRadii.lg)),
        title: const Text('Payment Mode', style: AppTypography.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in const {
              'cash': (Icons.payments_outlined, 'Cash'),
              'upi': (Icons.phone_android_outlined, 'UPI'),
              'card': (Icons.credit_card_outlined, 'Card'),
            }.entries)
              ListTile(
                leading: Icon(entry.value.$1, color: AppColors.ink70),
                title: Text(entry.value.$2, style: AppTypography.bodyMd),
                onTap: () => Navigator.of(ctx).pop(entry.key),
                shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(AppRadii.sm)),
              ),
          ],
        ),
      ),
    );
  }

  void _editCartLineNote(BuildContext context, CartLine line, int index) {
    final controller = TextEditingController(text: line.itemNote);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.paper,
        title: const Text('Item Note', style: AppTypography.title),
        content: TextField(
          controller: controller,
          maxLines: 2,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Allergies, prep notes…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final newNote = controller.text.trim();
              ref.read(cartProvider.notifier).setNoteAt(index, newNote);
              Navigator.of(ctx).pop();
            },
            child: const Text('Save', style: TextStyle(color: AppColors.terra500)),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }

  void _showCartLineMenu(BuildContext context, CartLine line, int index) {
    ref.read(feedbackServiceProvider).fire(const FeedbackMedium());
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: AppRadii.lg),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.item.name, style: AppTypography.headline),
            Text(
              '×${line.qty}  ·  ₹${line.lineTotal.toStringAsFixed(0)}',
              style: AppTypography.caption,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: QuickActionTile(
                    icon: Icons.add,
                    label: '+1',
                    onTap: () {
                      Navigator.of(context).pop();
                      ref.read(cartProvider.notifier).setQtyAt(index, line.qty + 1);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: QuickActionTile(
                    icon: Icons.remove,
                    label: '−1',
                    onTap: () {
                      Navigator.of(context).pop();
                      if (line.qty > 1) {
                        ref.read(cartProvider.notifier).setQtyAt(index, line.qty - 1);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: QuickActionTile(
                    icon: Icons.edit_note,
                    label: 'Edit Note',
                    onTap: () {
                      Navigator.of(context).pop();
                      _editCartLineNote(context, line, index);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: QuickActionTile(
                    icon: Icons.delete_outline,
                    label: 'Remove',
                    onTap: () {
                      Navigator.of(context).pop();
                      ref.read(feedbackServiceProvider).fire(const FeedbackError());
                      ref.read(cartProvider.notifier).removeAt(index);
                    },
                  ),
                ),
              ],
            ),
            SizedBox(height: MediaQuery.of(context).viewPadding.bottom),
          ],
        ),
      ),
    );
  }

  /// Undo a recently deleted cart line.
  void _undoDelete(CartLine line) {
    ref.read(cartProvider.notifier).addCustom(
          item: line.item,
          qty: line.qty,
          mods: line.mods,
          selectedOptions: line.selectedOptions,
          modsExtra: line.modsExtra,
          itemNote: line.itemNote,
        );
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
            .firstOrNull ??
        widget.tableId;

    // T1 fix: lock order_type toggle once a draft dine-in order exists for
    // this table — switching types after items are sent would create a
    // duplicate order on a different order_id.
    final activeOrders = ref.watch(activeOrdersProvider);
    final hasExistingOrder = tables.any(
          (t) =>
              t.serverId == widget.tableId &&
              t.activeOrderId != null &&
              t.activeOrderId!.isNotEmpty,
        ) ||
        activeOrders.any(
          (o) =>
              o['table_id']?.toString() == widget.tableId &&
              o['status']?.toString() != 'paid' &&
              o['status']?.toString() != 'cancelled',
        );

    // D1 fix: if another operator already generated a bill (activeBillCount > 0
    // from socket broadcast), disable "KOT + Bill" and "Quick Settle" to
    // prevent duplicate bill generation.
    final activeBillCount = tables
        .where((t) => t.serverId == widget.tableId)
        .map((t) => t.activeBillCount)
        .firstOrNull ?? 0;
    final billAlreadyGenerated = activeBillCount > 0;

    return LiquidMeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              Hero(
                tag: HeroTags.cartBar,
                child: Material(
                  color: Colors.transparent,
                  child: LiquidAppBar(
                    title: 'Review · $tableDisplay',
                    leading: IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: cart.isEmpty
                          ? null // Task #10 fix: disable back with empty cart
                          : () => context.pop(),
                    ),
                  ),
                ),
              ),
              // Retry banner — shown when any cart line failed to sync.
              Consumer(
                builder: (context, ref, _) {
                  final hasFailure = ref.watch(
                    cartProvider.select(
                      (c) => c.any((l) => l.syncStatus == SyncStatus.failed),
                    ),
                  );
                  if (!hasFailure) return const SizedBox.shrink();
                  return GestureDetector(
                    onTap: () {
                      ref.read(cartProvider.notifier).retryFailed();
                      _submit();
                    },
                    child: Container(
                      width: double.infinity,
                      color: AppColors.warn,
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 16,
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Sync failed — tap to retry',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              Expanded(
                child: cart.isEmpty
                    ? _EmptyCartGuard(
                        onBackToMenu: () => context.pop(),
                      )
                    : ListView(
                        padding: EdgeInsets.fromLTRB(
                          AppSpacing.lg,
                          AppSpacing.lg,
                          AppSpacing.lg,
                          AppSpacing.lg +
                              MediaQuery.of(context).viewInsets.bottom,
                        ),
                        children: [
                          // Guest count removed — managed on Desktop side.
                          if (flags.customers) ...[
                            const SizedBox(height: 12),

                            // Customer attach row.
                            AppCard(
                              onTap: () async {
                                final result = await CustomerSheet.show(
                                  context,
                                );
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
                                                _customer!['name']
                                                        ?.toString() ??
                                                    'Customer',
                                                style: AppTypography.bodyMd
                                                    .copyWith(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              if (_customer!['phone'] != null &&
                                                  _customer!['phone']
                                                      .toString()
                                                      .isNotEmpty)
                                                Text(
                                                  _customer!['phone']
                                                      .toString(),
                                                  style: AppTypography.caption,
                                                ),
                                            ],
                                          )
                                        : const Text(
                                            'Add Customer',
                                            style: AppTypography.bodyMd,
                                          ),
                                  ),
                                  if (_customer != null)
                                    GestureDetector(
                                      onTap: () =>
                                          setState(() => _customer = null),
                                      child: const Icon(
                                        Icons.close,
                                        color: AppColors.ink50,
                                        size: 18,
                                      ),
                                    )
                                  else
                                    const Icon(
                                      Icons.chevron_right,
                                      color: AppColors.ink30,
                                      size: 20,
                                    ),
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
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 20,
                                      ),
                                      color: AppColors.danger.withValues(
                                        alpha: 0.85,
                                      ),
                                      child: const Icon(
                                        Icons.delete_outline,
                                        color: Colors.white,
                                      ),
                                    ),
                                    onDismissed: (_) {
                                      ref
                                          .read(feedbackServiceProvider)
                                          .fire(const FeedbackMedium());
                                      final deleted = cart[i];
                                      final uid = deleted.uid;
                                      final current = ref.read(cartProvider);
                                      final idx = current.indexWhere(
                                        (l) => l.uid == uid,
                                      );
                                      if (idx >= 0) {
                                        ref
                                            .read(cartProvider.notifier)
                                            .removeAt(idx);
                                      }
                                      // Undo snackbar — 4 second window.
                                      ScaffoldMessenger.of(context)
                                        ..clearSnackBars()
                                        ..showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              '${deleted.item.name} removed',
                                            ),
                                            duration: const Duration(
                                              seconds: 4,
                                            ),
                                            action: SnackBarAction(
                                              label: 'UNDO',
                                              textColor: AppColors.terra400,
                                              onPressed: () =>
                                                  _undoDelete(deleted),
                                            ),
                                          ),
                                        );
                                    },
                                    child: GestureDetector(
                                      onLongPress: () => _showCartLineMenu(
                                        context,
                                        cart[i],
                                        i,
                                      ),
                                      child: _CartRow(line: cart[i], index: i),
                                    ),
                                  ),
                                  if (i < cart.length - 1)
                                    const Divider(
                                      height: 1,
                                      color: AppColors.ink10,
                                    ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),

                          // KOT preview by kitchen section.
                          Text(
                            'KOT PREVIEW',
                            style: AppTypography.micro.copyWith(
                              letterSpacing: 1.4,
                            ),
                          ),
                          const SizedBox(height: 8),
                          AppCard(
                            padding: EdgeInsets.zero,
                            child: Column(
                              children: [
                                for (int i = 0;
                                    i < byKitchen.entries.length;
                                    i++) ...[
                                  _KotRow(
                                    icon: _kitchenIcon(
                                      byKitchen.keys.elementAt(i),
                                    ),
                                    label: _kitchenLabel(
                                      byKitchen.keys.elementAt(i),
                                    ),
                                    lines: byKitchen.values.elementAt(i),
                                  ),
                                  if (i < byKitchen.entries.length - 1)
                                    const Divider(
                                      height: 1,
                                      color: AppColors.ink10,
                                    ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Order notes.
                          Text(
                            'ORDER NOTES',
                            style: AppTypography.micro.copyWith(
                              letterSpacing: 1.4,
                            ),
                          ),
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

                          // Billing breakdown by type.
                          Builder(
                            builder: (_) {
                              double foodTotal = 0;
                              double liquorTotal = 0;
                              double bevTotal = 0;
                              for (final l in cart) {
                                final type =
                                    l.item.kitchenSection.toLowerCase();
                                final lineAmt = l.lineTotal;
                                if (type == 'beverages') {
                                  bevTotal += lineAmt;
                                } else if (type == 'liquor' || type == 'bar') {
                                  liquorTotal += lineAmt;
                                } else {
                                  foodTotal += lineAmt;
                                }
                              }
                              final showLiquor =
                                  liquorTotal > 0 && flags.liquorBilling;
                              final showBev =
                                  bevTotal > 0 && flags.beveragesBilling;

                              return AppCard(
                                child: Column(
                                  children: [
                                    if (showLiquor || showBev) ...[
                                      Row(
                                        children: [
                                          const Text(
                                            'Food',
                                            style: AppTypography.bodyMd,
                                          ),
                                          const Spacer(),
                                          Text(
                                            formatRupeesCompact(foodTotal),
                                            style: AppTypography.bodyMd,
                                          ),
                                        ],
                                      ),
                                      if (showLiquor) ...[
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            const Text(
                                              'Liquor',
                                              style: AppTypography.bodyMd,
                                            ),
                                            const Spacer(),
                                            Text(
                                              formatRupeesCompact(liquorTotal),
                                              style: AppTypography.bodyMd,
                                            ),
                                          ],
                                        ),
                                      ],
                                      if (showBev) ...[
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            const Text(
                                              'Beverages',
                                              style: AppTypography.bodyMd,
                                            ),
                                            const Spacer(),
                                            Text(
                                              formatRupeesCompact(bevTotal),
                                              style: AppTypography.bodyMd,
                                            ),
                                          ],
                                        ),
                                      ],
                                    ] else ...[
                                      Row(
                                        children: [
                                          const Text(
                                            'Subtotal',
                                            style: AppTypography.bodyMd,
                                          ),
                                          const Spacer(),
                                          Text(
                                            formatRupeesCompact(total),
                                            style: AppTypography.bodyMd,
                                          ),
                                        ],
                                      ),
                                    ],
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Taxes added on bill (admin desktop)',
                                      style: AppTypography.caption,
                                      textAlign: TextAlign.right,
                                    ),
                                    const Divider(
                                      height: 16,
                                      color: AppColors.ink10,
                                    ),
                                    Row(
                                      children: [
                                        const Text(
                                          'Total',
                                          style: AppTypography.title,
                                        ),
                                        const Spacer(),
                                        Hero(
                                          tag: HeroTags.orderTotal,
                                          child: Material(
                                            color: Colors.transparent,
                                            child: KineticRupeeCounter(
                                              amount: total,
                                              fontSize: 24,
                                              color: AppColors.ink,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
              ),
              if (cart.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    children: [
                      // Dine-in / Takeaway toggle.
                      // Locked once a draft order exists — changing type after
                      // items are sent would create a duplicate order.
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: hasExistingOrder
                                  ? null
                                  : () => setState(
                                        () => _orderType = _OrderType.dineIn,
                                      ),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: _orderType == _OrderType.dineIn
                                      ? AppColors.ink
                                      : Colors.white.withValues(alpha: 0.5),
                                  borderRadius: const BorderRadius.horizontal(
                                    left: AppRadii.sm,
                                  ),
                                  border: Border.all(color: AppColors.ink10),
                                ),
                                alignment: Alignment.center,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.restaurant,
                                      size: 16,
                                      color: _orderType == _OrderType.dineIn
                                          ? Colors.white
                                          : AppColors.ink70,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Dine-in',
                                      style: AppTypography.caption.copyWith(
                                        color: _orderType == _OrderType.dineIn
                                            ? Colors.white
                                            : AppColors.ink,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: hasExistingOrder
                                  ? null
                                  : () => setState(
                                        () => _orderType = _OrderType.takeaway,
                                      ),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: _orderType == _OrderType.takeaway
                                      ? AppColors.ink
                                      : Colors.white.withValues(alpha: 0.5),
                                  borderRadius: const BorderRadius.horizontal(
                                    right: AppRadii.sm,
                                  ),
                                  border: Border.all(color: AppColors.ink10),
                                ),
                                alignment: Alignment.center,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.takeout_dining,
                                      size: 16,
                                      color: _orderType == _OrderType.takeaway
                                          ? Colors.white
                                          : AppColors.ink70,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Takeaway',
                                      style: AppTypography.caption.copyWith(
                                        color: _orderType == _OrderType.takeaway
                                            ? Colors.white
                                            : AppColors.ink,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Fix #4: Make "Send to Kitchen" visually dominant.
                      // Full-width with glow, separated from secondary actions.
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.all(AppRadii.md),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.terra400.withValues(alpha: 0.35),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: LiquidPrimaryButton(
                          label: 'Send to Kitchen',
                          fullWidth: true,
                          leadingIcon: Icons.restaurant_menu,
                          onPressed: _submit,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Secondary actions row.
                      Row(
                        children: [
                          Expanded(
                            child: LiquidSecondaryButton(
                              label: 'KOT + Bill',
                              leadingIcon: Icons.receipt_long,
                              // D1: disable if bill already generated from
                              // another device — prevent duplicate billing.
                              onPressed: billAlreadyGenerated
                                  ? null
                                  : _submitKotAndBill,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: LiquidSecondaryButton(
                              label: 'Quick Settle',
                              leadingIcon: Icons.payments_outlined,
                              onPressed: billAlreadyGenerated
                                  ? null
                                  : _quickSettle,
                            ),
                          ),
                        ],
                      ),
                      if (billAlreadyGenerated) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Bill already generated — go back to collect payment',
                          style: AppTypography.caption.copyWith(
                            color: AppColors.ink50,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ), // LiquidMeshBackground
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
                  Text(
                    line.mods.join(' · '),
                    style: AppTypography.caption.copyWith(
                      color: AppColors.ink70,
                    ),
                  ),
                ],
                if (line.itemNote.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    '"${line.itemNote}"',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.terra600,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  formatRupeesCompact(line.item.price + line.modsExtra),
                  style: AppTypography.caption,
                ),
              ],
            ),
          ),
          _Step(
            icon: Icons.remove,
            onTap: () {
              ref.read(feedbackServiceProvider).fire(const FeedbackSelection());
              ref.read(cartProvider.notifier).setQtyAt(index, line.qty - 1);
            },
          ),
          SizedBox(
            width: 32,
            child: Center(
              child: Text(
                '${line.qty}',
                style: AppTypography.title.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          _Step(
            icon: Icons.add,
            onTap: () {
              ref.read(feedbackServiceProvider).fire(const FeedbackSelection());
              ref.read(cartProvider.notifier).setQtyAt(index, line.qty + 1);
            },
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 70,
            child: Text(
              formatRupeesCompact(line.lineTotal),
              style: AppTypography.title,
              textAlign: TextAlign.right,
            ),
          ),
          // Sync status badge — spinner while pending, warning icon if failed.
          if (line.syncStatus == SyncStatus.pending) ...[
            const SizedBox(width: 8),
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ] else if (line.syncStatus == SyncStatus.failed) ...[
            const SizedBox(width: 8),
            const Icon(
              Icons.warning_amber_rounded,
              size: 16,
              color: AppColors.warn,
            ),
          ],
        ],
      ),
    );
  }
}

/// Qty stepper with hold-to-repeat: tap = single step, long-press = rapid fire.
/// 500ms threshold before repeat starts, 150ms interval.
class _Step extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _Step({required this.icon, required this.onTap});
  @override
  State<_Step> createState() => _StepState();
}

class _StepState extends State<_Step> {
  Timer? _timer;

  void _startRepeat() {
    widget.onTap();
    _timer = Timer(const Duration(milliseconds: 500), () {
      _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
        widget.onTap();
      });
    });
  }

  void _stopRepeat() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopRepeat();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: widget.onTap,
        onLongPressStart: (_) => _startRepeat(),
        onLongPressEnd: (_) => _stopRepeat(),
        onLongPressCancel: _stopRepeat,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: LiquidGlassSurface(
              borderRadius: BorderRadius.circular(14),
              blur: 14,
              thickness: 6,
              child: SizedBox(
                width: 28,
                height: 28,
                child: Center(
                    child: Icon(widget.icon, size: 14, color: AppColors.ink)),
              ),
            ),
          ),
        ),
      );
}

class _KotRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final List<CartLine> lines;
  const _KotRow({required this.icon, required this.label, required this.lines});
  @override
  Widget build(BuildContext context) {
    final qty = lines.fold<int>(0, (s, l) => s + l.qty);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
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
                Text(
                  label,
                  style: AppTypography.bodyMd.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${lines.length} ${lines.length == 1 ? "item" : "items"} · '
                  '$qty units',
                  style: AppTypography.caption,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.ink05,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '1 KOT',
              style: AppTypography.micro.copyWith(letterSpacing: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// Task #10 fix: guard wrapping the empty-cart state with a PopScope so the
/// user cannot accidentally back out of the review screen with nothing ordered.
/// Both the Android back button and iOS swipe gesture are intercepted.
class _EmptyCartGuard extends ConsumerWidget {
  final VoidCallback onBackToMenu;
  const _EmptyCartGuard({required this.onBackToMenu});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _showEmptyCartDialog(context);
      },
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.shopping_basket_outlined,
              color: AppColors.ink30,
              size: 48,
            ),
            const SizedBox(height: 12),
            const Text(
              'Cart is empty',
              style: AppTypography.title,
            ),
            const SizedBox(height: 4),
            const Text(
              'Go back and add items',
              style: AppTypography.caption,
            ),
            const SizedBox(height: 20),
            LiquidPrimaryButton(
              label: 'Add Items',
              fullWidth: true,
              leadingIcon: Icons.add,
              onPressed: () => context.pop(),
            ),
            const SizedBox(height: 12),
            Builder(
              builder: (_) {
                final history = ref.watch(historyProvider);
                final lastOrder = history
                    .where(
                      (o) => o.lines.isNotEmpty && o.status != OrderStatus.cancelled,
                    )
                    .firstOrNull;
                if (lastOrder == null) {
                  return const SizedBox.shrink();
                }
                return LiquidSecondaryButton(
                  label: 'Repeat Last Order (${lastOrder.id})',
                  leadingIcon: Icons.replay,
                  onPressed: () {
                    final menu = ref.read(menuProvider);
                    int added = 0;
                    final skipped = <String>[];
                    for (final line in lastOrder.lines) {
                      final menuItem = menu
                          .where((m) =>
                              line.itemId.isNotEmpty
                                  ? m.id == line.itemId
                                  : m.name == line.name)
                          .firstOrNull;
                      if (menuItem != null) {
                        ref.read(cartProvider.notifier).addCustom(
                              item: menuItem,
                              qty: line.qty,
                              mods: line.mods,
                              modsExtra: 0,
                              itemNote: '',
                            );
                        added++;
                      } else {
                        skipped.add(line.name);
                      }
                    }
                    ref.read(feedbackServiceProvider).fire(const FeedbackMedium());
                    final summary = skipped.isEmpty
                        ? '$added item${added == 1 ? '' : 's'} added from ${lastOrder.id}'
                        : '$added item${added == 1 ? '' : 's'} added, '
                            '${skipped.length} item${skipped.length == 1 ? '' : 's'} '
                            'skipped: '
                            '${skipped.take(3).join(', ')}'
                            '${skipped.length > 3 ? ' (+${skipped.length - 3} more)' : ''}';
                    ScaffoldMessenger.of(context)
                      ..clearSnackBars()
                      ..showSnackBar(
                        SnackBar(
                          content: Text(summary),
                          duration: const Duration(seconds: 4),
                        ),
                      );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEmptyCartDialog(BuildContext context) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nothing to review'),
        content: const Text(
          'Your cart is empty. Go back and add items to place an order.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Go to Menu'),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true) onBackToMenu();
    });
  }
}

class _VegMark extends StatelessWidget {
  final bool isVeg;
  const _VegMark({required this.isVeg});
  @override
  Widget build(BuildContext context) {
    final color = isVeg ? AppColors.success : AppColors.danger;
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Center(
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
