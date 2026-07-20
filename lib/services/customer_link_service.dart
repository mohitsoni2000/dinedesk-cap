import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../widgets/customer_sheet.dart';
import 'socket_service.dart';
import 'sync_service.dart';

/// Opens [CustomerSheet] and, when linking against an existing order,
/// pushes the result through the same `customer:link_order` socket contract
/// and [SyncService] normalization used everywhere else order state changes.
class CustomerLinkService {
  final SocketService _socket;
  final SyncService _sync;

  CustomerLinkService(this._socket, this._sync);

  /// Picks (or creates) a customer via [CustomerSheet]. If [orderId] is
  /// given, the picked customer is immediately linked to that order on the
  /// server. Returns the picked customer map, or `null` if the sheet was
  /// dismissed or the link request failed.
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
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            backgroundColor: AppColors.danger,
            content: Text(
              response['message']?.toString() ?? 'Could not link customer',
              style: AppTypography.bodyMd.copyWith(color: Colors.white),
            ),
          ));
      }
      return null;
    }

    _sync.applyOrderAck(response, includeHistory: true);
    return customer;
  }
}
