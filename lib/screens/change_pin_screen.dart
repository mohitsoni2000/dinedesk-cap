// PIN change flow — current PIN, new PIN, confirm. Uses NumericKeyboard.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../theme/tokens.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/liquid_mesh_background.dart';
import '../widgets/numeric_keyboard.dart';

enum _Step { current, fresh, confirm }

class ChangePinScreen extends StatefulWidget {
  const ChangePinScreen({super.key});
  @override
  State<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends State<ChangePinScreen> {
  _Step _step = _Step.current;
  String _input = '';
  String _newPin = '';
  String? _error;
  bool _done = false;  // prevents double-advance into success modal

  String get _heading => switch (_step) {
    _Step.current => 'Enter current PIN',
    _Step.fresh   => 'Choose new PIN',
    _Step.confirm => 'Confirm new PIN',
  };

  void _advance() {
    if (_done) return;
    if (_input.length < 4) {
      setState(() => _error = 'PIN must be 4–6 digits');
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _error = null;
      switch (_step) {
        case _Step.current:
          // TODO: verify current PIN against server before advancing.
          _step = _Step.fresh;
          _input = '';
          break;
        case _Step.fresh:
          _newPin = _input;
          _input = '';
          _step = _Step.confirm;
          break;
        case _Step.confirm:
          if (_input != _newPin) {
            _input = '';
            _error = 'PINs don\'t match — try again';
            _step = _Step.fresh;
          } else {
            _done = true;
            HapticFeedback.heavyImpact();
            _showSuccessAndExit();
          }
      }
    });
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
                      children: List.generate(6, (i) {
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
                    if (_error != null) ...[
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
                if (v.length > 6) return;
                setState(() { _input = v; _error = null; });
                if (v.length == 6) _advance();
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
