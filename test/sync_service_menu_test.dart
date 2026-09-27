import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// operator:verify and operator:resync both carry the cached `menu_version`,
/// and a Desk that finds it current omits `sync.menu` from the reply. These
/// pin down that SyncService treats that absence as "keep what you have" on
/// every path — never as an empty menu and never as an error.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final menu = <String, dynamic>{
    'categories': [
      {'id': 'c1', 'name': 'Starters', 'type': 'food', 'sort_order': 1},
    ],
    'items': [
      {
        'id': 'i1',
        'name': 'Paneer Tikka',
        'category_id': 'c1',
        'price': 250,
        'is_veg': 1,
      },
    ],
  };

  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  test('a full sync applies the menu and remembers its version', () async {
    final sync = container.read(syncServiceProvider);
    expect(sync.cachedMenuVersion, isNull,
        reason: 'nothing cached yet, so verify must not claim a version');

    await sync.applyInitialSync({'menu': menu, 'menu_version': 'mv-1'});

    expect(container.read(menuProvider).map((i) => i.id), ['i1']);
    expect(sync.cachedMenuVersion, 'mv-1');
  });

  test('an omitted menu with a matching version keeps the cached menu',
      () async {
    final sync = container.read(syncServiceProvider);
    await sync.applyInitialSync({'menu': menu, 'menu_version': 'mv-1'});

    await sync.applyInitialSync({'tables': <Object>[], 'menu_version': 'mv-1'});

    expect(container.read(menuProvider).map((i) => i.id), ['i1']);
    expect(container.read(rawMenuDataProvider), isNotNull);
    expect(sync.cachedMenuVersion, 'mv-1');
    expect(container.read(connectionProvider).online, isTrue,
        reason: 'an omitted menu is not a failed sync');
  });

  test('an omitted menu with no version at all still keeps the cached menu',
      () async {
    final sync = container.read(syncServiceProvider);
    await sync.applyInitialSync({'menu': menu, 'menu_version': 'mv-1'});

    await sync.applyInitialSync({'tables': <Object>[]});

    expect(container.read(menuProvider).map((i) => i.id), ['i1']);
    expect(sync.cachedMenuVersion, 'mv-1',
        reason: 'the version must keep describing the menu actually held');
  });

  test('a non-string menu_version is ignored rather than thrown on', () async {
    final sync = container.read(syncServiceProvider);
    await sync.applyInitialSync({'menu': menu, 'menu_version': 'mv-1'});

    await expectLater(
      sync.applyInitialSync({'menu_version': 7}),
      completes,
    );
    expect(container.read(menuProvider).map((i) => i.id), ['i1']);
  });
}
