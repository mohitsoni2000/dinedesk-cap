import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'motion/app_scroll_behavior.dart';
import 'motion/motion.dart';
import 'router.dart';
import 'theme/app_theme.dart';
import 'theme/theme_mode_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  final feedback = container.read(feedbackServiceProvider);
  await feedback.init();
  runApp(UncontrolledProviderScope(
    container: container,
    child: const RestroApp(),
  ));
}

class RestroApp extends ConsumerWidget {
  const RestroApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
        title: 'Restro',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ref.watch(themeModeProvider),
        // iOS rubber-band overscroll on every scrollable, every platform.
        scrollBehavior: const AppScrollBehavior(),
        routerConfig: ref.watch(routerProvider),
      );
}
