import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../motion/motion.dart';
import '../services/log.dart';
import '../services/session_service.dart';
import '../services/socket_service.dart';
import '../theme/tokens.dart';
import '../widgets/app_surface.dart';
import '../widgets/page_content_clamp.dart';
import '../widgets/pin_pad.dart';

const _tag = '[Recovery]';

class RecoveryLoginScreen extends ConsumerStatefulWidget {
  const RecoveryLoginScreen({super.key});
  @override
  ConsumerState<RecoveryLoginScreen> createState() =>
      _RecoveryLoginScreenState();
}

class _RecoveryLoginScreenState extends ConsumerState<RecoveryLoginScreen>
    with SingleTickerProviderStateMixin {
  final _employeeIdCtrl = TextEditingController();
  final List<String> _pin = [];
  String? _error;
  bool _submitting = false;

  late final AnimationController _shakeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );
  late final Animation<double> _shakeAnim = TweenSequence([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: -12.0), weight: 1),
    TweenSequenceItem(tween: Tween(begin: -12.0, end: 12.0), weight: 2),
    TweenSequenceItem(tween: Tween(begin: 12.0, end: -8.0), weight: 2),
    TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
    TweenSequenceItem(tween: Tween(begin: 8.0, end: 0.0), weight: 1),
  ]).animate(CurvedAnimation(parent: _shakeCtrl, curve: Curves.easeInOut));

  @override
  void dispose() {
    _employeeIdCtrl.dispose();
    _shakeCtrl.dispose();
    super.dispose();
  }

  void _press(String key) {
    if (_submitting) return;
    setState(() {
      _error = null;
      if (_pin.length < 8) _pin.add(key);
    });
  }

  void _delete() {
    if (_submitting) return;
    setState(() {
      _error = null;
      if (_pin.isNotEmpty) _pin.removeLast();
    });
  }

  Future<void> _submit() async {
    final employeeId = _employeeIdCtrl.text.trim();
    if (employeeId.isEmpty) {
      setState(() => _error = 'Enter your employee ID');
      return;
    }
    if (_pin.length < 4) {
      setState(() => _error = 'PIN must be at least 4 digits');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    ref.read(feedbackServiceProvider).fire(const FeedbackMedium());

    final pairing = await SessionService().getSavedPairing();
    final deviceSecret = pairing?.deviceSecret;
    if (pairing == null || deviceSecret == null) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'This device has no saved pairing to recover';
      });
      return;
    }

    final result = await SocketService.recover(
      pairing.host,
      pairing.port,
      employeeId,
      _pin.join(),
      deviceSecret,
    );
    if (!mounted) return;

    switch (result) {
      case RecoverySuccess(:final token, :final deviceSecret):
        logD(_tag, '✓ Recovered — saving fresh credentials');
        ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
        await SessionService()
            .saveRecoveredCredentials(token: token, deviceSecret: deviceSecret);
        if (!mounted) return;
        context.go('/connecting');
      case RecoveryFailed(:final message):
        logD(_tag, '✗ Recovery failed: $message');
        ref.read(feedbackServiceProvider).fire(const FeedbackError());
        setState(() {
          _submitting = false;
          _error = message;
          _pin.clear();
        });
        unawaited(_shakeCtrl.forward(from: 0));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.lg),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight:
                      constraints.maxHeight - AppSpacing.lg - AppSpacing.lg,
                ),
                child: PageContentClamp(
                  maxWidth: 480,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          onPressed: () => context.pop(),
                          icon: Icon(Icons.arrow_back_rounded,
                              color: context.palette.ink70),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Log in without a QR',
                        style: TextStyle(
                          fontFamily: AppTypography.cormorant,
                          fontWeight: FontWeight.w600,
                          fontSize: 32,
                          height: 1.05,
                          color: context.palette.ink,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Employee ID + PIN, on this same phone',
                        style: AppTypography.caption.copyWith(
                          fontSize: 13,
                          color: context.palette.ink50,
                        ),
                      ),
                      const SizedBox(height: 24),
                      AppSurface(
                        borderRadius: const BorderRadius.all(AppRadii.md),
                        padding: const EdgeInsets.all(14),
                        child: TextField(
                          controller: _employeeIdCtrl,
                          enabled: !_submitting,
                          textInputAction: TextInputAction.done,
                          style: AppTypography.bodyMd,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: 'Employee ID',
                            hintStyle: AppTypography.bodyMd
                                .copyWith(color: context.palette.ink30),
                          ),
                          onChanged: (_) {
                            if (_error != null) setState(() => _error = null);
                          },
                        ),
                      ),
                      const SizedBox(height: 20),
                      AnimatedBuilder(
                        animation: _shakeAnim,
                        builder: (_, child) => Transform.translate(
                          offset: Offset(_shakeAnim.value, 0),
                          child: child,
                        ),
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          children: List.generate(8, (i) {
                            final filled = i < _pin.length;
                            final isError = _error != null;
                            final fillColor =
                                isError ? AppColors.danger : AppColors.terra500;
                            final borderColor = isError
                                ? AppColors.danger
                                : context.palette.ink30;
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 120),
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              width: filled ? 16 : 14,
                              height: filled ? 16 : 14,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: filled ? fillColor : Colors.transparent,
                                border:
                                    Border.all(color: borderColor, width: 1.5),
                              ),
                            );
                          }),
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            _error!,
                            style: AppTypography.caption.copyWith(
                              color: AppColors.danger,
                              fontWeight: FontWeight.w600,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        )
                      else if (_submitting)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '⟳ Checking with the desk…',
                            style: AppTypography.caption
                                .copyWith(color: context.palette.ink50),
                          ),
                        ),
                      const SizedBox(height: 20),
                      PinPad(
                        onKeyPress: _press,
                        onForgot: () => showForgotPinDialog(context),
                        onDelete: _delete,
                        enabled: !_submitting,
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _submitting ? null : _submit,
                          child: Text(_submitting ? 'Checking…' : 'Log in'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
