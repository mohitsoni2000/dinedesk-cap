import 'package:flutter_test/flutter_test.dart';
import 'package:restro/motion/motion.dart';

void main() {
  group('HeroTags', () {
    test('all static tags are unique', () {
      const Set<String> tags = <String>{
        HeroTags.appLogo,
        HeroTags.pairingCore,
        HeroTags.connectionIndicator,
        HeroTags.cartBar,
        HeroTags.orderTotal,
        HeroTags.kotBadge,
      };
      expect(tags.length, 6);
    });

    test('table number tags disambiguate by id', () {
      expect(HeroTags.tableNumber('T1'),
          isNot(equals(HeroTags.tableNumber('T2'))));
      expect(HeroTags.tableNumber('T1'), startsWith('hero.table-num.'));
    });

    test('table return ring tags do not collide with table card tags', () {
      expect(
        HeroTags.tableReturnRing('T1'),
        isNot(equals(HeroTags.tableCard('T1'))),
      );
    });
  });
}
