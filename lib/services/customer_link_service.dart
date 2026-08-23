import 'package:flutter/material.dart';

import '../widgets/customer_sheet.dart';
import '../widgets/dynamic_toast.dart';
import 'socket_service.dart';
import 'sync_service.dart';

class CustomerLinkService {
  final SocketService _socket;
  final SyncService _sync;

  CustomerLinkService(this._socket, this._sync);

  Future<Map<String, dynamic>?> pickAndLinkCustomer(
    BuildContext context, {
    String? orderId,
  }) async {
    final customer = await CustomerSheet.show(context);
    if (customer == null) return null;
    if (orderId == null) return customer;

    final customerId = customer['id']?.toString();
    if (customerId == null || customerId.isEmpty) return customer;

    final response = await _socket.emitAck('customer:link_order', {
      'order_id': orderId,
      'customer_id': customerId,
    });

    if (response['kind'] == 'error') {
      if (context.mounted) {
        DynamicToast.show(context,
            message:
                response['message']?.toString() ?? 'Could not link customer',
            kind: ToastKind.error);
      }
      return null;
    }

    _sync.applyOrderAck(response, includeHistory: true);
    return customer;
  }

  Future<Map<String, dynamic>?> editCustomer(
    BuildContext context,
    Map<String, dynamic> customer,
  ) {
    return CustomerSheet.showEdit(context, customer);
  }
}
