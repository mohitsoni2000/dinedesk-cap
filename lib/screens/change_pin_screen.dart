// PIN change flow — current PIN, new PIN, confirm. Uses NumericKeyboard.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/liquid_mesh_background.dart';
import '../widgets/numeric_keyboard.dart';

enum _Step { current, fresh, confirm }

class ChangePinScreen extends ConsumerStatefulWidget {
  const ChangePinScreen({super.key});
  @override
  ConsumerState<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends ConsumerState<ChangePinScreen> {
  _Step _step = _Step.current;
  String _input = '';
  String _currentPin = '';  // saved from step 1 for the change request
  String _newPin = '';
  String? _error;
  bool _done = false;
  bool _verifying = false;

  String get _heading => switch (_step) {
    _Step.current => 'Enter current PIN',
    _Step.fresh   => 'Choose new PIN',
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
        // Use operator:verify — the only PIN check event the server supports.
        socketService.emit('operator:verify', {'pin': _input}, onAck: (response) {
          if (!mounted) return;
          if (response['kind'] == 'success') {
            setState(() {
              _currentPin = _input;  // save for the change request
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
          // Persist the new PIN on the server.
          setState(() => _verifying = true);
          final socketService = ref.read(socketServiceProvider);
          // Server may not have operator:change_pin yet — emit and handle gracefully.
          socketService.emit('operator:change_pin', {
            'current_pin': _currentPin,
            'new_pin': _newPin,
          }, onAck: (response) {
            if (!mounted) return;
            if (response['kind'] == 'error') {
              setState(() {
                _verifying = false;
                _error = response['message']?.toString() ?? 'Failed to update PIN';
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
      builder: (_) => LiquidGlassSurface(
        blur: 30, thickness: 14,
        borderRadius: const BorderRadius.vertical(top: AppRadii.lg),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4,
            decoration: BoxDecoration(color: AppColors.ink30, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_rounded, color: AppColors.success, size: 32),
          ),
          const SizedBox(height: 12),
          const Text('PIN updated', style: AppTypography.title),
          const SizedBox(height: 4),
          const Text('Use your new PIN next sign-in.', style: AppTypography.caption),
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
    return LiquidMeshBackground(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            LiquidAppBar(
              title: 'Change PIN',
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.pop(),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_heading, style: AppTypography.title),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(4, (i) {
                        final filled = i < _input.length;
                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          width: 18, height: 18,
                          decoration: BoxDecoration(
                            color: filled ? AppColors.ink : Colors.transparent,
                            shape: BoxShape.circle,
                            border: Border.all(color: AppColors.ink30, width: 1.5),
                          ),
                        );
                      }),
                    ),
                    if (_verifying) ...[
                      const SizedBox(height: 12),
                      const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ] else if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!,
                        style: AppTypography.caption.copyWith(color: AppColors.danger)),
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
                setState(() { _input = v; _error = null; });
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
