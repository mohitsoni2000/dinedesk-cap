import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/money.dart';
import '../data/providers.dart';
import '../data/currency.dart';
import '../motion/motion.dart';
import '../services/kot_queue_service.dart';
import '../services/pin_guard.dart';
import '../services/platform_surfaces.dart';
import '../theme/tokens.dart';
import '../utils/request_id.dart';
import '../widgets/app_card.dart';
import '../widgets/quick_action_tile.dart';
import '../widgets/dynamic_toast.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/order_submitting_overlay.dart';
import '../widgets/stepper_button.dart';

class OrderReviewScreen extends ConsumerStatefulWidget {
  final String tableId;

  final bool isRoom;

  final bool autoSend;
  const OrderReviewScreen(
      {super.key,
      required this.tableId,
      this.isRoom = false,
      this.autoSend = false});
  @override
  ConsumerState<OrderReviewScreen> createState() => _OrderReviewScreenState();
}

enum _OrderType { dineIn, takeaway }

enum _OrderFlowStep { orderCreate, kotSend, billGenerate, payment }

final class _OrderFlowStepResult {
  final _OrderFlowStep? failedStep;

  final String? errorMessage;

  const _OrderFlowStepResult({this.failedStep, this.errorMessage});
  bool get isSuccess => failedStep == null;
}

class _OrderReviewScreenState extends ConsumerState<OrderReviewScreen> {
  String get _builderRoute => widget.isRoom
      ? '/order/room/${widget.tableId}'
      : '/order/${widget.tableId}';
  String get _successRoute => widget.isRoom
      ? '/order/room/${widget.tableId}/success'
      : '/order/${widget.tableId}/success';
  final TextEditingController _notes = TextEditingController();
  Map<String, dynamic>? _customer;
  _OrderType _orderType = _OrderType.dineIn;
  StateController<String>? _notesNotifier;

  final Map<String, String> _quickSettleRequestIds = <String, String>{};

  String _quickSettleRequestIdFor(String billId) =>
      _quickSettleRequestIds.putIfAbsent(billId, newRequestId);

  @override
  void initState() {
    super.initState();
    _notes.text = ref.read(orderNotesProvider);
    _notesNotifier = ref.read(orderNotesProvider.notifier);
    if (widget.autoSend) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runAutoSend());
    } else {
      _scheduleTotalsPreview(ref.read(cartProvider));
    }
  }

  bool _autoSendKicked = false;

  bool _autoSendFailed = false;

  Future<void> _runAutoSend() async {
    if (_autoSendKicked || !mounted) return;
    _autoSendKicked = true;
    if (ref.read(cartProvider).isEmpty) {
      if (mounted) setState(() => _autoSendFailed = true);
      return;
    }
    await _submit();

    if (mounted) setState(() => _autoSendFailed = true);
  }

  bool _submitted = false;

  String? _kotSentOrderId;

  String? _pendingOrderRequestId;

  String? _pendingKotRequestId;

  bool _running = false;

  Map<String, dynamic>? _serverTotals;
  Timer? _totalsDebounce;

  Future<void> _editCustomer() async {
    final current = _customer;
    if (current == null) return;
    final updated = await ref
        .read(customerLinkServiceProvider)
        .editCustomer(context, current);
    if (updated != null && mounted) {
      setState(() => _customer = updated);
    }
  }

  @override
  void dispose() {
    if (_submitted) {
      _notesNotifier?.state = '';
    }
    _notes.dispose();
    _totalsDebounce?.cancel();
    super.dispose();
  }

  void _scheduleTotalsPreview(List<CartLine> cart) {
    _totalsDebounce?.cancel();
    if (cart.isEmpty) {
      if (_serverTotals != null) {
        setState(() => _serverTotals = null);
      }
      return;
    }
    _totalsDebounce = Timer(const Duration(milliseconds: 200), () {
      _fetchTotalsPreview(cart);
    });
  }

  Future<void> _fetchTotalsPreview(List<CartLine> cart) async {
    final socketService = ref.read(socketServiceProvider);
    final items = cart
        .map((l) => <String, dynamic>{
              'item_id': l.item.id,
              'item_type': l.item.kitchenSection,
              'total_price': l.lineTotal,
            })
        .toList();
    final response = await socketService.emitAck(
      'order:preview-totals',
      <String, dynamic>{'items': items},
    );
    if (!mounted || response['kind'] == 'error') return;
    final totals = response['totals'];
    if (totals is Map) {
      setState(() {
        _serverTotals = Map<String, dynamic>.from(totals);
      });
    }
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
              'quantity': l.qty,
              'selected_options':
                  l.selectedOptions.map((o) => o.toJson()).toList(),
              if (l.selectedAddons.isNotEmpty)
                'selected_addons':
                    l.selectedAddons.map((g) => g.toJson()).toList(),
              if (l.weight != null) 'weight': l.weight,
              'notes': l.itemNote,
            })
        .toList();
  }

  String? _activeOrderIdForTable() {
    if (widget.isRoom) {
      final room = ref
          .read(roomsProvider)
          .where((r) => r.serverId == widget.tableId)
          .firstOrNull;
      if (room?.activeOrderId != null && room!.activeOrderId!.isNotEmpty) {
        return room.activeOrderId;
      }
      final active = ref.read(activeOrdersProvider).where((order) {
        return order.roomId == widget.tableId &&
            order.status != 'paid' &&
            order.status != 'cancelled';
      }).firstOrNull;
      return active?.id;
    }
    if (_orderType != _OrderType.dineIn) return null;
    final table = ref
        .read(tablesProvider)
        .where((t) => t.serverId == widget.tableId)
        .firstOrNull;
    if (table?.activeOrderId != null && table!.activeOrderId!.isNotEmpty) {
      return table.activeOrderId;
    }
    final active = ref.read(activeOrdersProvider).where((order) {
      return order.tableId == widget.tableId &&
          order.status != 'paid' &&
          order.status != 'cancelled';
    }).firstOrNull;
    return active?.id;
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

    ref.read(lastKotIdProvider.notifier).state = label;
  }

  Future<Map<String, dynamic>> _createOrUpdateOrder({
    required List<Map<String, dynamic>> items,
    required String notes,
  }) {
    final socketService = ref.read(socketServiceProvider);
    final existingOrderId = _activeOrderIdForTable();
    final requestId = _pendingOrderRequestId ??= newRequestId();
    if (existingOrderId != null && items.isNotEmpty) {
      return socketService.emitAck('order:update', <String, dynamic>{
        'order_id': existingOrderId,
        'items_add': items,
        'notes': notes,
        'client_request_id': requestId,
      });
    }
    return socketService.emitAck('order:create', <String, dynamic>{
      if (widget.isRoom)
        'room_id': widget.tableId
      else if (_orderType == _OrderType.dineIn)
        'table_id': widget.tableId,
      'items': items,
      'notes': notes,
      'order_type': widget.isRoom
          ? 'room'
          : (_orderType == _OrderType.dineIn ? 'dine_in' : 'takeaway'),
      if (_customer != null && _customer!['id'] != null)
        'customer_id': _customer!['id'],
      'client_request_id': requestId,
    });
  }

  Future<_OrderFlowStepResult> _runOrderFlow({
    required bool generateBill,
    required bool collectPayment,
    String quickSettleMode = 'cash',
    bool printKot = true,
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
      ref
          .read(syncServiceProvider)
          .applyOrderAck(orderResponse, includeHistory: true);

      orderId = _orderIdFromResponse(orderResponse, fallback: fallbackOrderId);
      if (orderId == null || orderId.isEmpty) {
        return _OrderFlowStepResult(
          failedStep: _OrderFlowStep.orderCreate,
          errorMessage: 'Order saved but ID not returned — please retry',
        );
      }

      ref.read(cartProvider.notifier).setSyncStatusAll(SyncStatus.pending);
      final kotRequestId = _pendingKotRequestId ??= newRequestId();
      KotSendResult kotResponse;
      try {
        kotResponse = await ref.read(kotQueueProvider).sendKot(
              socketService,
              <String, dynamic>{'order_id': orderId},
              clientRequestId: kotRequestId,
            );
      } catch (_) {
        ref.read(cartProvider.notifier).setSyncStatusFailed();
        return const _OrderFlowStepResult(
          failedStep: _OrderFlowStep.kotSend,
          errorMessage: 'Failed to send KOT to kitchen — please retry',
        );
      }
      if (kotResponse.isQueued) {
        _kotSentOrderId = orderId;
        _pendingOrderRequestId = null;
        _pendingKotRequestId = null;
        return const _OrderFlowStepResult(
          failedStep: _OrderFlowStep.kotSend,
          errorMessage:
              'Desk unreachable — KOT queued on this phone and will fire '
              'automatically the moment we reconnect.',
        );
      }
      if (kotResponse.isRejected) {
        ref.read(cartProvider.notifier).setSyncStatusFailed();
        return _OrderFlowStepResult(
          failedStep: _OrderFlowStep.kotSend,
          errorMessage: kotResponse.message?.isNotEmpty == true
              ? 'Kitchen refused this KOT: ${kotResponse.message}'
              : 'Failed to send KOT to kitchen — please retry',
        );
      }
      _kotSentOrderId = orderId;
      _pendingOrderRequestId = null;
      _pendingKotRequestId = null;
      ref.read(cartProvider.notifier).setSyncStatusAll(SyncStatus.synced);
      ref
          .read(syncServiceProvider)
          .applyOrderAck(kotResponse.ack, includeHistory: true);

      _rememberKotLabel(kotResponse.ack);

      String liveName = widget.tableId;
      for (final t in ref.read(tablesProvider)) {
        if (t.serverId == widget.tableId) {
          liveName = t.id;
          break;
        }
      }
      ref.read(liveActivityProvider).start(
            orderId: orderId,
            tableName: liveName,
            subtitle:
                '${ref.read(cartProvider).length} items · sent to kitchen',
          );

      if (printKot) {
        socketService.emit(
          'print:kot',
          <String, dynamic>{'order_id': orderId},
          onAck: (response) {
            if (!mounted || response['kind'] != 'error') return;
            DynamicToast.show(context,
                message: response['message']?.toString() ??
                    'KOT print failed — check the kitchen printer',
                kind: ToastKind.error);
          },
        );
      }
    }

    if (!generateBill) return const _OrderFlowStepResult();

    final billResponse = await socketService.emitAck(
      'bill:generate',
      <String, dynamic>{'order_id': orderId},
      timeout: const Duration(seconds: 15),
    );
    if (billResponse['kind'] == 'error') {
      return _OrderFlowStepResult(
        failedStep: _OrderFlowStep.billGenerate,
        errorMessage: 'Failed to generate bill — please retry',
      );
    }
    ref.read(syncServiceProvider).applyOrderAck(billResponse,
        includeHistory: true, markTableBilled: true);
    if (!collectPayment) return const _OrderFlowStepResult();

    final bills = (billResponse['bills'] is List)
        ? (billResponse['bills'] as List)
            .whereType<Map>()
            .map((b) => Map<String, dynamic>.from(b))
            .toList()
        : <Map<String, dynamic>>[];
    if (bills.isEmpty) {
      return _OrderFlowStepResult(
        failedStep: _OrderFlowStep.billGenerate,
        errorMessage: 'Bill generated but ID not returned — please retry',
      );
    }

    for (final bill in bills) {
      final billId = bill['id']?.toString();
      if (billId == null || billId.isEmpty) {
        return _OrderFlowStepResult(
          failedStep: _OrderFlowStep.billGenerate,
          errorMessage: 'Bill generated but ID not returned — please retry',
        );
      }
      final billTotal = Money.fromWire(bill['total_amount']);
      if (billTotal == null) {
        return _OrderFlowStepResult(
          failedStep: _OrderFlowStep.payment,
          errorMessage:
              'Bill total missing — please settle from the bill screen',
        );
      }
      final paymentResponse = await socketService.emitAck(
        'bill:payment',
        <String, dynamic>{
          'bill_id': billId,
          'payments': [
            {'payment_mode': quickSettleMode, 'amount': billTotal.toWire()}
          ],
          'client_request_id': _quickSettleRequestIdFor(billId),
        },
        timeout: const Duration(seconds: 15),
      );
      if (paymentResponse['kind'] == 'error') {
        return _OrderFlowStepResult(
          failedStep: _OrderFlowStep.payment,
          errorMessage: 'Payment failed — please retry from the bill screen',
        );
      }
      ref
          .read(syncServiceProvider)
          .applyOrderAck(paymentResponse, includeHistory: true);
    }

    for (final bill in bills) {
      socketService
          .emit('print:bill', <String, dynamic>{'bill_id': bill['id']});
    }
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
    bool printKot = true,
    bool returnToBuilder = false,
  }) async {
    if (_running) return;
    _running = true;

    try {
      ref.read(feedbackServiceProvider).fire(const FeedbackHeavy());
      ref.read(orderNotesProvider.notifier).state = _notes.text;

      final completer = Completer<bool>();
      final runningFlow = _runOrderFlow(
        generateBill: generateBill,
        collectPayment: collectPayment,
        quickSettleMode: quickSettleMode,
        printKot: printKot,
      );
      unawaited(runningFlow.then((result) {
        if (!completer.isCompleted) completer.complete(result.isSuccess);
      }));

      final ok =
          await OrderSubmittingOverlay.show(context, completer: completer);
      if (!mounted) return;
      if (ok) {
        _submitted = true;
        _kotSentOrderId = null;
        _pendingOrderRequestId = null;
        _pendingKotRequestId = null;
        ref.read(cartProvider.notifier).clear();
        ref.read(orderNotesProvider.notifier).state = '';
        if (returnToBuilder) {
          final kotLabel = ref.read(lastKotIdProvider);
          DynamicToast.show(context,
              message: 'KOT $kotLabel sent to kitchen — not printed',
              kind: ToastKind.success);
          context.go(_builderRoute);
          return;
        }
        context.go(_successRoute);
        return;
      }

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
      } catch (_) {}

      if (mounted) {
        DynamicToast.show(context, message: msg, kind: ToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _submitOnlyKot() async {
    final pinOk = await requirePinIfNeeded(context, ref, 'kot');
    if (!pinOk || !mounted) return;
    await _submitWithFlow(
      generateBill: false,
      collectPayment: false,
      printKot: false,
      returnToBuilder: true,
    );
  }

  Future<void> _holdOrder() async {
    final pinOk = await requirePinIfNeeded(context, ref, 'hold');
    if (!pinOk || !mounted) return;
    if (_running) return;
    _running = true;

    try {
      ref.read(feedbackServiceProvider).fire(const FeedbackHeavy());
      ref.read(orderNotesProvider.notifier).state = _notes.text;

      final cart = ref.read(cartProvider);
      final orderResponse = await _createOrUpdateOrder(
        items: _itemsPayload(cart),
        notes: _notes.text,
      );
      if (orderResponse['kind'] == 'error') {
        if (mounted) {
          DynamicToast.show(context,
              message: 'Could not save order — please retry',
              kind: ToastKind.error);
        }
        return;
      }
      ref
          .read(syncServiceProvider)
          .applyOrderAck(orderResponse, includeHistory: true);

      final orderId = _orderIdFromResponse(
        orderResponse,
        fallback: _activeOrderIdForTable(),
      );
      if (orderId == null || orderId.isEmpty) {
        if (mounted) {
          DynamicToast.show(context,
              message: 'Order saved but ID not returned — please retry',
              kind: ToastKind.error);
        }
        return;
      }

      final holdResponse = await ref
          .read(socketServiceProvider)
          .emitAck('order:hold', <String, dynamic>{'order_id': orderId});
      if (holdResponse['kind'] == 'error') {
        if (mounted) {
          DynamicToast.show(context,
              message: holdResponse['message']?.toString() ??
                  'Could not hold order — please retry',
              kind: ToastKind.error);
        }
        return;
      }
      ref
          .read(syncServiceProvider)
          .applyOrderAck(holdResponse, includeHistory: true);

      if (!mounted) return;
      _submitted = true;
      ref.read(cartProvider.notifier).clear();
      ref.read(orderNotesProvider.notifier).state = '';
      DynamicToast.show(context,
          message: 'Order held — table reserved', kind: ToastKind.success);
      context.go('/tables');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _submitKotAndBill() async {
    final pinOk = await requirePinIfNeeded(context, ref, 'kot_and_bill');
    if (!pinOk || !mounted) return;
    await _submitWithFlow(generateBill: true, collectPayment: false);
  }

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
        backgroundColor: ctx.palette.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(AppRadii.lg)),
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
                leading: Icon(entry.value.$1, color: ctx.palette.ink70),
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
        backgroundColor: ctx.palette.surface,
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
            child:
                const Text('Save', style: TextStyle(color: AppColors.terra500)),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }

  void _showCartLineMenu(BuildContext context, CartLine line, int index) {
    ref.read(feedbackServiceProvider).fire(const FeedbackMedium());
    showModalBottomSheet(
      context: context,
      backgroundColor: context.palette.surface,
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
              '×${line.qty}  ·  ${formatRupeesCompact(line.lineTotal)}',
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
                      ref
                          .read(cartProvider.notifier)
                          .setQtyAt(index, line.qty + 1);
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
                        ref
                            .read(cartProvider.notifier)
                            .setQtyAt(index, line.qty - 1);
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
                      ref
                          .read(feedbackServiceProvider)
                          .fire(const FeedbackError());
                      ref.read(cartProvider.notifier).removeAt(index);
                    },
                  ),
                ),
              ],
            ),
            SizedBox(height: context.sheetBottomInset),
          ],
        ),
      ),
    );
  }

  void _undoDelete(CartLine line) {
    ref.read(cartProvider.notifier).addCustom(
          item: line.item,
          qty: line.qty,
          mods: line.mods,
          selectedOptions: line.selectedOptions,
          selectedAddons: line.selectedAddons,
          modsExtra: line.modsExtra,
          itemNote: line.itemNote,
          variationId: line.variationId,
          variationName: line.variationName,
          weight: line.weight,
        );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.autoSend && !_autoSendFailed) {
      return ColoredBox(
        color: context.palette.paper,
        child: const Scaffold(backgroundColor: Colors.transparent),
      );
    }
    final cart = ref.watch(cartProvider);
    ref.listen<List<CartLine>>(cartProvider, (previous, next) {
      _scheduleTotalsPreview(next);
    });
    final total = cart.map((l) => l.lineTotal).sumMoney();
    final serverTotal = (_serverTotals?['totalAmount'] as num?)?.toDouble();
    final byKitchen = <String, List<CartLine>>{};
    for (final l in cart) {
      byKitchen.putIfAbsent(l.item.kitchenSection, () => []).add(l);
    }
    final flags = ref.watch(flagsProvider);

    final tables = ref.watch(tablesProvider);
    final rooms = ref.watch(roomsProvider);
    final tableDisplay = widget.isRoom
        ? (rooms
                .where((r) => r.serverId == widget.tableId)
                .map((r) => r.id)
                .firstOrNull ??
            widget.tableId)
        : (tables
                .where((t) => t.serverId == widget.tableId)
                .map((t) => t.id)
                .firstOrNull ??
            widget.tableId);

    final activeOrders = ref.watch(activeOrdersProvider);
    final hasExistingOrder = widget.isRoom
        ? rooms.any(
              (r) =>
                  r.serverId == widget.tableId &&
                  r.activeOrderId != null &&
                  r.activeOrderId!.isNotEmpty,
            ) ||
            activeOrders.any(
              (o) =>
                  o.roomId == widget.tableId &&
                  o.status != 'paid' &&
                  o.status != 'cancelled',
            )
        : tables.any(
              (t) =>
                  t.serverId == widget.tableId &&
                  t.activeOrderId != null &&
                  t.activeOrderId!.isNotEmpty,
            ) ||
            activeOrders.any(
              (o) =>
                  o.tableId == widget.tableId &&
                  o.status != 'paid' &&
                  o.status != 'cancelled',
            );

    final activeBillCount = widget.isRoom
        ? (rooms
                .where((r) => r.serverId == widget.tableId)
                .map((r) => r.activeBillCount)
                .firstOrNull ??
            0)
        : (tables
                .where((t) => t.serverId == widget.tableId)
                .map((t) => t.activeBillCount)
                .firstOrNull ??
            0);
    final billAlreadyGenerated = activeBillCount > 0;

    final Widget actionControls = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        children: [
          if (!widget.isRoom) ...[
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
                            ? context.palette.ink
                            : context.palette.surface,
                        borderRadius: const BorderRadius.horizontal(
                          left: AppRadii.sm,
                        ),
                        border: Border.all(color: context.palette.hairline),
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
                                : context.palette.ink70,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Dine-in',
                            style: AppTypography.caption.copyWith(
                              color: _orderType == _OrderType.dineIn
                                  ? Colors.white
                                  : context.palette.ink,
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
                            ? context.palette.ink
                            : context.palette.surface,
                        borderRadius: const BorderRadius.horizontal(
                          right: AppRadii.sm,
                        ),
                        border: Border.all(color: context.palette.hairline),
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
                                : context.palette.ink70,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Takeaway',
                            style: AppTypography.caption.copyWith(
                              color: _orderType == _OrderType.takeaway
                                  ? Colors.white
                                  : context.palette.ink,
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
          ],
          LiquidPrimaryButton(
            label: 'Send to Kitchen',
            fullWidth: true,
            leadingIcon: Icons.restaurant_menu,
            onPressed: _submit,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: LiquidSecondaryButton(
                  label: 'Hold',
                  leadingIcon: Icons.pause_circle_outline,
                  onPressed: _holdOrder,
                ),
              ),
              if (flags.directKot) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: LiquidSecondaryButton(
                    label: 'Only KOT',
                    leadingIcon: Icons.print_disabled_outlined,
                    onPressed: _submitOnlyKot,
                  ),
                ),
              ],
            ],
          ),
          if (flags.generateBill) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: LiquidSecondaryButton(
                    label: 'KOT + Bill',
                    leadingIcon: Icons.receipt_long,
                    onPressed: billAlreadyGenerated ? null : _submitKotAndBill,
                  ),
                ),
                if (flags.collectPayment) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: LiquidSecondaryButton(
                      label: 'Quick Settle',
                      leadingIcon: Icons.payments_outlined,
                      onPressed: billAlreadyGenerated ? null : _quickSettle,
                    ),
                  ),
                ],
              ],
            ),
          ],
          if (billAlreadyGenerated) ...[
            const SizedBox(height: 8),
            Text(
              'Bill already generated — go back to collect payment',
              style: AppTypography.caption.copyWith(
                color: context.palette.ink50,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );

    return ColoredBox(
      color: context.palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: LayoutBuilder(builder: (context, box) {
            final bool wide = box.isTwoPane && cart.isNotEmpty;
            final Widget mainColumn = Column(
              children: [
                Hero(
                  tag: HeroTags.cartBar,
                  child: Material(
                    color: Colors.transparent,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: Row(
                        children: [
                          Pressable(
                            onTap: cart.isEmpty ? null : () => context.pop(),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: context.palette.surface,
                                borderRadius:
                                    const BorderRadius.all(AppRadii.sm),
                                border:
                                    Border.all(color: context.palette.hairline),
                              ),
                              alignment: Alignment.center,
                              child: Icon(Icons.arrow_back,
                                  size: 18,
                                  color: cart.isEmpty
                                      ? context.palette.ink30
                                      : context.palette.ink70),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              widget.isRoom
                                  ? 'Review · Room $tableDisplay'
                                  : 'Review · $tableDisplay',
                              style: AppTypography.sheetTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
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
                            AppSpacing.lg + context.sheetBottomInset,
                          ),
                          children: [
                            if (flags.customers) ...[
                              const SizedBox(height: 12),
                              AppCard(
                                onTap: () async {
                                  final result = await ref
                                      .read(customerLinkServiceProvider)
                                      .pickAndLinkCustomer(context);
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
                                          : context.palette.ink70,
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
                                                if (_customer!['phone'] !=
                                                        null &&
                                                    _customer!['phone']
                                                        .toString()
                                                        .isNotEmpty)
                                                  Text(
                                                    _customer!['phone']
                                                        .toString(),
                                                    style:
                                                        AppTypography.caption,
                                                  ),
                                              ],
                                            )
                                          : const Text(
                                              'Add Customer',
                                              style: AppTypography.bodyMd,
                                            ),
                                    ),
                                    if (_customer != null) ...[
                                      if (flags.customerEdit)
                                        GestureDetector(
                                          onTap: _editCustomer,
                                          child: Padding(
                                            padding: const EdgeInsets.only(
                                                right: 12),
                                            child: Icon(
                                              Icons.edit_outlined,
                                              color: context.palette.ink50,
                                              size: 18,
                                            ),
                                          ),
                                        ),
                                      GestureDetector(
                                        onTap: () =>
                                            setState(() => _customer = null),
                                        child: Icon(
                                          Icons.close,
                                          color: context.palette.ink50,
                                          size: 18,
                                        ),
                                      ),
                                    ] else
                                      Icon(
                                        Icons.chevron_right,
                                        color: context.palette.ink30,
                                        size: 20,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
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

                                        DynamicToast.show(
                                          context,
                                          message:
                                              '${deleted.item.name} removed',
                                          duration: const Duration(seconds: 4),
                                          actionLabel: 'Undo',
                                          onAction: () => _undoDelete(deleted),
                                        );
                                      },
                                      child: GestureDetector(
                                        onLongPress: () => _showCartLineMenu(
                                          context,
                                          cart[i],
                                          i,
                                        ),
                                        child:
                                            _CartRow(line: cart[i], index: i),
                                      ),
                                    ),
                                    if (i < cart.length - 1)
                                      Divider(
                                        height: 1,
                                        color: context.palette.ink10,
                                      ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
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
                                      Divider(
                                        height: 1,
                                        color: context.palette.ink10,
                                      ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
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
                            Builder(
                              builder: (_) {
                                var foodTotal = Money.zero;
                                var liquorTotal = Money.zero;
                                var bevTotal = Money.zero;
                                for (final l in cart) {
                                  final type =
                                      l.item.kitchenSection.toLowerCase();
                                  final lineAmt = l.lineTotal;
                                  if (type == 'beverages') {
                                    bevTotal += lineAmt;
                                  } else if (type == 'liquor' ||
                                      type == 'bar') {
                                    liquorTotal += lineAmt;
                                  } else {
                                    foodTotal += lineAmt;
                                  }
                                }
                                final showLiquor = liquorTotal.isPositive &&
                                    flags.liquorBilling;
                                final showBev = bevTotal.isPositive &&
                                    flags.beveragesBilling;

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
                                                formatRupeesCompact(
                                                    liquorTotal),
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
                                      Text(
                                        serverTotal != null
                                            ? 'Includes GST & service charge'
                                            : 'Calculating final total…',
                                        style: AppTypography.caption,
                                        textAlign: TextAlign.right,
                                      ),
                                      const Padding(
                                        padding:
                                            EdgeInsets.symmetric(vertical: 10),
                                        child: _DashedDivider(),
                                      ),
                                      Row(
                                        children: [
                                          Text(
                                            'Total',
                                            style: AppTypography.title.copyWith(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 15.5),
                                          ),
                                          const Spacer(),
                                          Hero(
                                            tag: HeroTags.orderTotal,
                                            child: Material(
                                              color: Colors.transparent,
                                              child: KineticRupeeCounter(
                                                amount: serverTotal ??
                                                    total.asRupeesForDisplay,
                                                fontSize: 24,
                                                color: context.palette.ink,
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
                if (cart.isNotEmpty && !wide) actionControls,
              ],
            );

            if (!wide) return mainColumn;

            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: mainColumn),
                Container(width: 1, color: context.palette.hairline),
                SizedBox(
                  width: 356,
                  child: SingleChildScrollView(child: actionControls),
                ),
              ],
            );
          }),
        ),
      ),
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
                      color: context.palette.ink70,
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
          if (line.item.isWeighed) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: context.palette.ink05,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${line.weight ?? 0} ${line.item.measureUnit ?? ''}',
                style:
                    AppTypography.bodyMd.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ] else ...[
            StepperButton(
              icon: Icons.remove,
              glass: true,
              repeatOnHold: true,
              haptics: false,
              onTap: () {
                ref
                    .read(feedbackServiceProvider)
                    .fire(const FeedbackSelection());
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
            StepperButton(
              icon: Icons.add,
              glass: true,
              repeatOnHold: true,
              haptics: false,
              onTap: () {
                ref
                    .read(feedbackServiceProvider)
                    .fire(const FeedbackSelection());
                ref.read(cartProvider.notifier).setQtyAt(index, line.qty + 1);
              },
            ),
          ],
          const SizedBox(width: 12),
          SizedBox(
            width: 70,
            child: Text(
              formatRupeesCompact(line.lineTotal),
              style: AppTypography.title,
              textAlign: TextAlign.right,
            ),
          ),
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
              color: context.palette.ink05,
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

class _EmptyCartGuard extends ConsumerWidget {
  final VoidCallback onBackToMenu;
  const _EmptyCartGuard({
    required this.onBackToMenu,
  });

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
            Icon(
              Icons.shopping_basket_outlined,
              color: context.palette.ink30,
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
                      (o) =>
                          o.lines.isNotEmpty &&
                          o.status != OrderStatus.cancelled,
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
                          .where((m) => line.itemId.isNotEmpty
                              ? m.id == line.itemId
                              : m.name == line.name)
                          .firstOrNull;
                      if (menuItem != null) {
                        final modsExtra = line.price - menuItem.price;
                        ref.read(cartProvider.notifier).addCustom(
                              item: menuItem,
                              qty: line.qty,
                              mods: line.mods,
                              modsExtra: modsExtra,
                              itemNote: '',
                              variationId: line.variationId,
                              variationName: line.variationName,
                            );
                        added++;
                      } else {
                        skipped.add(line.name);
                      }
                    }
                    ref
                        .read(feedbackServiceProvider)
                        .fire(const FeedbackMedium());
                    final summary = skipped.isEmpty
                        ? '$added item${added == 1 ? '' : 's'} added from ${lastOrder.id}'
                        : '$added item${added == 1 ? '' : 's'} added, '
                            '${skipped.length} item${skipped.length == 1 ? '' : 's'} '
                            'skipped: '
                            '${skipped.take(3).join(', ')}'
                            '${skipped.length > 3 ? ' (+${skipped.length - 3} more)' : ''}';
                    DynamicToast.show(context,
                        message: summary,
                        kind: ToastKind.success,
                        duration: const Duration(seconds: 4));
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

class _DashedDivider extends StatelessWidget {
  const _DashedDivider();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 1,
      child: LayoutBuilder(builder: (_, constraints) {
        const dashWidth = 5.0;
        const gap = 4.0;
        final count = (constraints.maxWidth / (dashWidth + gap)).floor();
        return Row(
          children: List.generate(
            count,
            (_) => Container(
              width: dashWidth,
              height: 1,
              margin: const EdgeInsets.only(right: gap),
              color: context.palette.hairline,
            ),
          ),
        );
      }),
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
