

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';
import '../widgets/app_surface.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/numeric_keyboard.dart';
import '../widgets/sheet_handle.dart';

enum _Step { current, fresh, confirm }

class ChangePinScreen extends ConsumerStatefulWidget {
  const ChangePinScreen({super.key});
  @override
  ConsumerState<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends ConsumerState<ChangePinScreen> {
  _Step _step = _Step.current;
  String _input = '';
  String _currentPin = '';
  String _newPin = '';
  String? _error;
  bool _done = false;
  bool _verifying = false;

  String get _heading => switch (_step) {
        _Step.current => 'Enter current PIN',
        _Step.fresh => 'Choose new PIN',
        _Step.confirm => 'Confirm new PIN',
      };

  void _advance() {
    if (_done || _verifying) return;
    if (_input.length < 4) {
      setState(() => _error = 'PIN must be 4 digits');
      return;
    }
    HapticFeedback.mediumImpact();
    switch (_step) {
      case _Step.current:
        final socketService = ref.read(socketServiceProvider);
        setState(() => _verifying = true);

        socketService.emit('operator:verify', {'pin': _input},
            onAck: (response) {
          if (!mounted) return;
          if (response['kind'] == 'success') {
            setState(() {
              _currentPin = _input;
              _step = _Step.fresh;
              _input = '';
              _verifying = false;
            });
          } else {
            setState(() {
              _error = 'Incorrect PIN';
              _input = '';
              _verifying = false;
            });
          }
        });
        break;
      case _Step.fresh:
        setState(() {
          _newPin = _input;
          _input = '';
          _step = _Step.confirm;
          _error = null;
        });
        break;
      case _Step.confirm:
        if (_input != _newPin) {
          setState(() {
            _input = '';
            _error = 'PINs don\'t match — try again';
            _step = _Step.fresh;
          });
        } else {

          setState(() => _verifying = true);
          final socketService = ref.read(socketServiceProvider);

          socketService.emit('operator:change_pin', {
            'current_pin': _currentPin,
            'new_pin': _newPin,
          }, onAck: (response) {
            if (!mounted) return;
            if (response['kind'] == 'error') {
              setState(() {
                _verifying = false;
                _error =
                    response['message']?.toString() ?? 'Failed to update PIN';
                _step = _Step.fresh;
                _input = '';
              });
            } else {
              setState(() {
                _done = true;
                _verifying = false;
                _error = null;
              });
              HapticFeedback.heavyImpact();
              _showSuccessAndExit();
            }
          });
        }
        break;
    }
  }

  void _showSuccessAndExit() {
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => AppSurface(
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SheetHandle(),
          const SizedBox(height: 16),
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_rounded,
                color: AppColors.success, size: 32),
          ),
          const SizedBox(height: 12),
          const Text('PIN updated', style: AppTypography.sheetTitle),
          const SizedBox(height: 4),
          Text('Use your new PIN next sign-in.',
              style: context.palette.caption),
          const SizedBox(height: 16),
          LiquidPrimaryButton(
            label: 'Done',
            fullWidth: true,
            onPressed: () {
              Navigator.of(context).pop();
              context.pop();
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              _ChangePinHeader(onBack: () => context.pop()),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_heading, style: AppTypography.sheetTitle),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(4, (i) {
                          final filled = i < _input.length;
                          return Container(
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: filled
                                  ? AppColors.terra
                                  : Colors.transparent,
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: filled
                                      ? AppColors.terra
                                      : context.palette.ink30,
                                  width: 1.5),
                            ),
                          );
                        }),
                      ),
                      if (_verifying) ...[
                        const SizedBox(height: 12),
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ] else if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!,
                            style: AppTypography.caption
                                .copyWith(color: AppColors.danger)),
                      ],
                    ],
                  ),
                ),
              ),
              NumericKeyboard(
                value: _input,
                onChanged: (v) {
                  if (_verifying) return;
                  if (v.length > 4) return;
                  setState(() {
                    _input = v;
                    _error = null;
                  });
                  if (v.length == 4) _advance();
                },
                onSubmit: _advance,
                submitLabel: 'Continue',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChangePinHeader extends StatelessWidget {
  final VoidCallback onBack;
  const _ChangePinHeader({required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
      child: Row(
        children: [
          Pressable(
            onTap: onBack,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: context.palette.surface,
                borderRadius: const BorderRadius.all(AppRadii.sm),
                border: Border.all(color: context.palette.hairline),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_back,
                  size: 18, color: context.palette.ink70),
            ),
          ),
          const SizedBox(width: 10),
          const Text('Change PIN', style: AppTypography.sheetTitle),
        ],
      ),
    );
  }
}
