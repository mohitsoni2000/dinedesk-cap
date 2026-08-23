import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../motion/motion.dart';
import '../services/session_service.dart';
import '../services/socket_service.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'sheet_handle.dart';

class ManualEntrySheet {
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (_) => const _ManualEntrySheetBody(),
    );
  }
}

class _ManualEntrySheetBody extends ConsumerStatefulWidget {
  const _ManualEntrySheetBody();

  @override
  ConsumerState<_ManualEntrySheetBody> createState() =>
      _ManualEntrySheetBodyState();
}

class _ManualEntrySheetBodyState extends ConsumerState<_ManualEntrySheetBody> {
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '8080');
  final _codeCtrl = TextEditingController();
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim());
    final code = _codeCtrl.text.trim();
    if (host.isEmpty || port == null || code.length != 6) {
      setState(() =>
          _error = 'Enter the host, port and 6-character code from the desk');
      return;
    }

    setState(() {
      _checking = true;
      _error = null;
    });
    final result = await SocketService.probe(host, port, code);
    if (!mounted) return;

    switch (result) {
      case ProbeResult.ok:
        ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
        await SessionService()
            .savePairing(PairingInfo(host: host, port: port, token: code));
        if (!mounted) return;
        Navigator.of(context).pop();
        context.go('/connecting');
      case ProbeResult.authRejected:
        setState(() {
          _checking = false;
          _error = 'Code expired — ask the admin for a fresh one';
        });
      case ProbeResult.unreachable:
        setState(() {
          _checking = false;
          _error = "Can't reach the server — same Wi-Fi?";
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: context.sheetBottomInset,
      ),
      child: AppSurface(
        tint: AppColors.night,
        border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
        shadow: AppShadows.elevatedFor(context),
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(child: SheetHandle()),
            const SizedBox(height: 16),
            const Text(
              'Enter code instead',
              style: TextStyle(
                fontFamily: AppTypography.cormorant,
                fontWeight: FontWeight.w600,
                fontSize: 26,
                height: 1.1,
                color: Colors.white,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Ask the admin desktop for the host, port and pairing code',
              style: AppTypography.caption
                  .copyWith(color: Colors.white.withValues(alpha: 0.55)),
            ),
            const SizedBox(height: 20),
            _ManualField(
                controller: _hostCtrl, label: 'HOST', hint: '192.168.1.24'),
            const SizedBox(height: 12),
            _ManualField(
              controller: _portCtrl,
              label: 'PORT',
              hint: '8080',
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            _ManualField(
              controller: _codeCtrl,
              label: '6-CHARACTER CODE',
              hint: 'A1B2C3',
              maxLength: 6,
              textCapitalization: TextCapitalization.characters,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: AppTypography.caption.copyWith(color: AppColors.danger),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: Pressable(
                onTap: _checking ? null : _connect,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: AppColors.terra,
                    borderRadius: const BorderRadius.all(AppRadii.md),
                    boxShadow: AppShadows.terraGlow,
                  ),
                  alignment: Alignment.center,
                  child: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Connect',
                          style: TextStyle(
                            fontFamily: AppTypography.inter,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ManualField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputType? keyboardType;
  final int? maxLength;
  final TextCapitalization textCapitalization;
  const _ManualField({
    required this.controller,
    required this.label,
    required this.hint,
    this.keyboardType,
    this.maxLength,
    this.textCapitalization = TextCapitalization.none,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: AppTypography.micro
                .copyWith(color: Colors.white.withValues(alpha: 0.45))),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: const BorderRadius.all(AppRadii.sm),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: TextField(
            controller: controller,
            keyboardType: keyboardType,
            maxLength: maxLength,
            textCapitalization: textCapitalization,
            style: const TextStyle(color: Colors.white, fontSize: 15),
            decoration: InputDecoration(
              border: InputBorder.none,
              counterText: '',
              hintText: hint,
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
            ),
          ),
        ),
      ],
    );
  }
}
