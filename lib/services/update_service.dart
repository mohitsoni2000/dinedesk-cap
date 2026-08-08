import 'dart:convert';
import 'dart:io';

import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'log.dart';

const _tag = '[Update]';

// Both stores list this app under the same bundle/package id.
const _storeId = 'com.command.crew';

/// Android drives its update through Play Core (in-app update flow); iOS has
/// no equivalent API, so it's just a "here's where to get the new version"
/// link resolved from the App Store listing itself.
class UpdateCheckResult {
  final bool available;
  final AppUpdateInfo? androidInfo;
  final String? iosStoreUrl;

  const UpdateCheckResult.none()
      : available = false,
        androidInfo = null,
        iosStoreUrl = null;
  const UpdateCheckResult.android(AppUpdateInfo info)
      : available = true,
        androidInfo = info,
        iosStoreUrl = null;
  const UpdateCheckResult.ios(String url)
      : available = true,
        androidInfo = null,
        iosStoreUrl = url;
}

class UpdateService {
  Future<UpdateCheckResult> check() async {
    try {
      if (Platform.isAndroid) return await _checkAndroid();
      if (Platform.isIOS) return await _checkIos();
    } catch (e) {
      logD(_tag, 'check failed: $e');
    }
    return const UpdateCheckResult.none();
  }

  Future<UpdateCheckResult> _checkAndroid() async {
    final info = await InAppUpdate.checkForUpdate();
    if (info.updateAvailability == UpdateAvailability.updateAvailable) {
      logD(_tag, 'Android update available '
          '(immediate: ${info.immediateUpdateAllowed}, flexible: ${info.flexibleUpdateAllowed})');
      return UpdateCheckResult.android(info);
    }
    return const UpdateCheckResult.none();
  }

  Future<UpdateCheckResult> _checkIos() async {
    final uri =
        Uri.https('itunes.apple.com', '/lookup', {'bundleId': _storeId});
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 8));
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return const UpdateCheckResult.none();

      final body = await res.transform(utf8.decoder).join();
      final results = (jsonDecode(body) as Map<String, dynamic>)['results'];
      if (results is! List || results.isEmpty) {
        return const UpdateCheckResult.none();
      }

      final listing = results.first as Map<String, dynamic>;
      final latest = listing['version']?.toString();
      final storeUrl = listing['trackViewUrl']?.toString();
      if (latest == null || storeUrl == null) {
        return const UpdateCheckResult.none();
      }

      final current = (await PackageInfo.fromPlatform()).version;
      if (_isNewer(latest, current)) {
        logD(_tag, 'iOS update available: $current -> $latest');
        return UpdateCheckResult.ios(storeUrl);
      }
    } finally {
      client.close();
    }
    return const UpdateCheckResult.none();
  }

  bool _isNewer(String latest, String current) {
    final l = latest.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final c = current.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final len = l.length > c.length ? l.length : c.length;
    for (var i = 0; i < len; i++) {
      final lv = i < l.length ? l[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (lv != cv) return lv > cv;
    }
    return false;
  }

  /// Prefers Play's immediate (full-screen, blocking) flow when Play allows
  /// it — a POS device sitting on a floor is never mid-task in a way worth
  /// protecting the way a flexible background download is designed for.
  /// Falls back to flexible, then to just opening the Play Store listing.
  Future<void> startAndroidUpdate(AppUpdateInfo info) async {
    try {
      if (info.immediateUpdateAllowed) {
        await InAppUpdate.performImmediateUpdate();
        return;
      }
      if (info.flexibleUpdateAllowed) {
        await InAppUpdate.startFlexibleUpdate();
        await InAppUpdate.completeFlexibleUpdate();
        return;
      }
    } catch (e) {
      logD(_tag, 'Android update flow failed: $e');
    }
    await openStoreUrl('https://play.google.com/store/apps/details?id=$_storeId');
  }

  Future<void> openStoreUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
