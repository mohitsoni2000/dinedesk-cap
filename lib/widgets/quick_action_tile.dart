import 'package:flutter/material.dart';
import '../motion/motion.dart';
import '../theme/tokens.dart';

class QuickActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const QuickActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: const BoxDecoration(
          color: AppColors.ink05,
          borderRadius: BorderRadius.all(AppRadii.sm),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: AppColors.ink70),
            const SizedBox(height: 6),
            Text(label, style: AppTypography.micro),
          ],
        ),
      ),
    );
  }
}
