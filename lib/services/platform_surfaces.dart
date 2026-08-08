import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import '../data/currency.dart';
import '../data/money.dart';
import '../data/providers.dart';
import 'log.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// Platform surfaces: home-screen widgets (iOS WidgetKit + Android),
/// Live Activities / Dynamic Island (iOS), and ready-to-serve alerts that
/// mirror to Apple Watch & bridge to Wear OS via system notifications.
/// All best-effort: every call is guarded so a missing native piece can
/// never break the ordering flow.
/// ─────────────────────────────────────────────────────────────────────────

const kAppGroupId = 'group.com.command.crew';

final readyAlertsProvider =
    Provider<ReadyAlertsService>((ref) => ReadyAlertsService());
final liveActivityProvider =
    Provider<LiveActivityService>((ref) => LiveActivityService());
final widgetSyncProvider =
    Provider<WidgetSyncService>((ref) => WidgetSyncService());

/// Ready-to-serve alerts. High-priority local notifications appear on the
/// lock screen, **mirror to Apple Watch automatically** (phone locked) and
/// **bridge to Wear OS automatically** — watch coverage with zero watch app.
class ReadyAlertsService {
  static const _tag = '[ReadyAlerts]';
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _id = 700;

  Future<void> init() async {
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _ready = true;
    } catch (e) {
      logD(_tag, 'init failed (ok in tests): $e');
    }
  }

  Future<void> notifyReady(String tableName, List<String> items) async {
    if (!_ready) return;
    final body = items.isEmpty
        ? 'Order is ready to serve'
        : items.length <= 2
            ? items.join(' · ')
            : '${items.take(2).join(' · ')} +${items.length - 2} more';
    try {
      await _plugin.show(
        _id++,
        '$tableName · ready to serve',
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'ready_orders',
            'Ready to serve',
            channelDescription: 'Kitchen marked an order ready',
            importance: Importance.max,
            priority: Priority.high,
            category: AndroidNotificationCategory.status,
          ),
          iOS: DarwinNotificationDetails(
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
        ),
      );
    } catch (e) {
      logD(_tag, 'show failed: $e');
    }
  }
}

/// Live Activity / Dynamic Island bridge (iOS 16.1+). No-op elsewhere and
/// fully silent until the CrewWidgets extension is added in Xcode.
class LiveActivityService {
  static const _tag = '[LiveActivity]';
  static const _ch = MethodChannel('crew/surfaces');

  Future<void> _call(String method, Map<String, dynamic> args) async {
    if (!Platform.isIOS) return;
    try {
      await _ch.invokeMethod(method, args);
    } catch (e) {
      logD(_tag, '$method skipped: $e');
    }
  }

  Future<void> start({
    required String orderId,
    required String tableName,
    required String subtitle,
  }) =>
      _call('startActivity', {
        'orderId': orderId,
        'tableName': tableName,
        'subtitle': subtitle,
      });

  Future<void> markReady(String orderId, String tableName) =>
      _call('updateActivity', {
        'orderId': orderId,
        'tableName': tableName,
        'status': 'ready',
      });

  Future<void> end(String orderId) => _call('endActivity', {'orderId': orderId});
}

/// Pushes a compact floor snapshot to the home-screen widgets
/// (throttled — call `schedule` freely from sync handlers).
class WidgetSyncService {
  static const _tag = '[WidgetSync]';
  Timer? _debounce;

  Future<void> init() async {
    try {
      if (Platform.isIOS) await HomeWidget.setAppGroupId(kAppGroupId);
    } catch (e) {
      logD(_tag, 'init: $e');
    }
  }

  void schedule(Ref ref) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () => _push(ref));
  }

  Future<void> _push(Ref ref) async {
    try {
      final tables = ref.read(tablesProvider);
      final ready = ref.read(readyOrdersProvider);
      final mine =
          tables.where((t) => t.state == TableState.mine).length;
      final free =
          tables.where((t) => t.state == TableState.free).length;
      // Summed in paise so the widget total can't drift from the floor.
      final revenue =
          tables.map((t) => t.bill ?? Money.zero).sumMoney();
      await HomeWidget.saveWidgetData<int>('w_mine', mine);
      await HomeWidget.saveWidgetData<int>('w_free', free);
      await HomeWidget.saveWidgetData<int>('w_ready', ready.length);
      await HomeWidget.saveWidgetData<String>(
          'w_revenue', formatRupeesCompact(revenue));
      final now = DateTime.now();
      await HomeWidget.saveWidgetData<String>('w_updated',
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}');
      await HomeWidget.updateWidget(
        androidName: 'CrewTablesWidgetProvider',
        iOSName: 'CrewTablesWidget',
      );
    } catch (e) {
      logD(_tag, 'push skipped: $e');
    }
  }
}
