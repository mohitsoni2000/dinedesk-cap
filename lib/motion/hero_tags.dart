

class HeroTags {
  const HeroTags._();

  static const String appLogo = 'hero.app-logo';
  static const String pairingCore = 'hero.pairing-core';
  static const String connectionIndicator = 'hero.connection-indicator';
  static String tableNumber(String tableId) => 'hero.table-num.$tableId';
  static String tableCard(String tableId) => 'hero.table-card.$tableId';
  static const String cartBar = 'hero.cart-bar';
  static const String orderTotal = 'hero.order-total';
  static const String kotBadge = 'hero.kot-badge';
  static String tableReturnRing(String tableId) => 'hero.table-return.$tableId';
}
