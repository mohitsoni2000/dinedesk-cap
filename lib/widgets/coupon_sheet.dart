

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

class CouponSheet extends ConsumerStatefulWidget {
  final String orderId;
  const CouponSheet({super.key, required this.orderId});

  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required String orderId,
  }) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => CouponSheet(orderId: orderId),
    );
  }

  @override
  ConsumerState<CouponSheet> createState() => _CouponSheetState();
}

class _CouponSheetState extends ConsumerState<CouponSheet> {
  final TextEditingController _code = TextEditingController();
  bool _applying = false;
  String? _error;
  String? _success;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _apply() {
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter a coupon code');
      return;
    }
    setState(() {
      _applying = true;
      _error = null;
    });

    final socketService = ref.read(socketServiceProvider);
    socketService.emit('discount:apply', <String, dynamic>{
      'order_id': widget.orderId,
      'coupon_code': code,
    }, onAck: (response) {
      if (!mounted) return;
      if (response['kind'] == 'error') {
        setState(() {
          _applying = false;
          _error = response['message']?.toString() ?? 'Invalid coupon';
        });
      } else {
        setState(() {
          _applying = false;
          _success = 'Coupon applied!';
        });
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) Navigator.of(context).pop(response);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.45,
      maxChildSize: 0.7,
      minChildSize: 0.3,
      expand: false,
      builder: (_, scroll) => AppSurface(
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            const SizedBox(height: 8),
            const SheetHandle(),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.local_offer_outlined,
                      color: AppColors.terra, size: 20),
                  SizedBox(width: 8),
                  Text('Apply Coupon', style: AppTypography.sheetTitle),
                ],
              ),
            ),
            Divider(height: 1, color: context.palette.hairline),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: context.palette.surface,
                      borderRadius: const BorderRadius.all(AppRadii.sm),
                      border:
                          Border.all(color: context.palette.hairline, width: 1.5),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    child: TextField(
                      controller: _code,
                      cursorColor: AppColors.terra,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Enter coupon code',
                        icon: Icon(Icons.confirmation_number_outlined,
                            color: context.palette.ink50),
                      ),
                      onChanged: (_) {
                        if (_error != null) setState(() => _error = null);
                      },
                      onSubmitted: (_) => _apply(),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!,
                        style: AppTypography.caption
                            .copyWith(color: AppColors.danger)),
                  ],
                  if (_success != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.check_circle,
                            color: AppColors.success, size: 16),
                        const SizedBox(width: 6),
                        Text(_success!,
                            style: AppTypography.bodyMd.copyWith(
                                color: AppColors.success,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  16, 8, 16, 16 + context.sheetBottomInset),
              child: LiquidPrimaryButton(
                label: _applying ? 'Applying...' : 'Apply Coupon',
                fullWidth: true,
                leadingIcon: _applying ? Icons.hourglass_top : Icons.check,
                onPressed: _applying ? null : _apply,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
