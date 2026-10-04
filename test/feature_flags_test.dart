import 'package:flutter_test/flutter_test.dart';
import 'package:restro/models/feature_flags.dart';

void main() {
  group('FeatureFlags.tableUnlink', () {
    test('follows the desk\'s own Unlink tables permission', () {
      final off = FeatureFlags.fromMap(
          {'flag_table_link': 1, 'flag_table_unlink': 0});
      final on = FeatureFlags.fromMap(
          {'flag_table_link': 0, 'flag_table_unlink': 1});

      expect(off.tableUnlink, isFalse);
      expect(on.tableUnlink, isTrue);
    });

    test('falls back to Link tables on a desk that predates the permission',
        () {
      expect(FeatureFlags.fromMap({'flag_table_link': 0}).tableUnlink, isFalse);
      expect(FeatureFlags.fromMap({'flag_table_link': 1}).tableUnlink, isTrue);
      expect(FeatureFlags.fromMap({}).tableUnlink, isTrue);
    });
  });
}
