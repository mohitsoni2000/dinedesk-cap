class FeatureFlags {
  final bool discounts;
  final bool complimentary;
  final bool voidBills;
  final bool splitPayment;
  final bool liquorBilling;
  final bool beveragesBilling;
  final bool serviceCharge;
  final bool reservations;
  final bool customers;
  final bool inventory;
  final bool kotPrinting;
  final bool packages;
  final bool multiFloor;
  final bool operatorPinAuth;
  final String operatorPinMode;
  final int operatorPinSessionMinutes;
  final bool operatorPinKot;
  final bool operatorPinHold;
  final bool operatorPinKotAndBill;
  final bool operatorPinGenerateBill;
  final bool operatorPinPayment;
  final bool operatorPinCancelOrder;
  final bool operatorPinKotEdit;
  final bool operatorPinQuickSettle;

  const FeatureFlags({
    this.discounts = true,
    this.complimentary = false,
    this.voidBills = true,
    this.splitPayment = true,
    this.liquorBilling = false,
    this.beveragesBilling = false,
    this.serviceCharge = true,
    this.reservations = false,
    this.customers = false,
    this.inventory = false,
    this.kotPrinting = true,
    this.packages = false,
    this.multiFloor = false,
    this.operatorPinAuth = true,
    this.operatorPinMode = 'per_action',
    this.operatorPinSessionMinutes = 5,
    this.operatorPinKot = false,
    this.operatorPinHold = false,
    this.operatorPinKotAndBill = false,
    this.operatorPinGenerateBill = false,
    this.operatorPinPayment = false,
    this.operatorPinCancelOrder = false,
    this.operatorPinKotEdit = false,
    this.operatorPinQuickSettle = false,
  });

  factory FeatureFlags.fromMap(Map<String, dynamic> map) {
    bool flag(String key, [bool fallback = false]) {
      final v = map[key];
      if (v == null) return fallback;
      if (v is bool) return v;
      if (v is int) return v == 1;
      if (v is String) return v == '1' || v == 'true';
      return fallback;
    }

    return FeatureFlags(
      discounts: flag('flag_discounts', true),
      complimentary: flag('flag_complimentary'),
      voidBills: flag('flag_void_bills', true),
      splitPayment: flag('flag_split_payment', true),
      liquorBilling: flag('flag_liquor_billing'),
      beveragesBilling: flag('flag_beverages_billing'),
      serviceCharge: flag('flag_service_charge', true),
      reservations: flag('flag_reservations'),
      customers: flag('flag_customers'),
      inventory: flag('flag_inventory'),
      kotPrinting: flag('flag_kot_printing', true),
      packages: flag('flag_packages'),
      multiFloor: flag('flag_multi_floor'),
      operatorPinAuth: flag('flag_operator_pin_auth', true),
      operatorPinMode: map['operator_pin_mode']?.toString() ?? 'per_action',
      operatorPinSessionMinutes: int.tryParse('${map['operator_pin_session_minutes']}') ?? 5,
      operatorPinKot: flag('operator_pin_kot'),
      operatorPinHold: flag('operator_pin_hold'),
      operatorPinKotAndBill: flag('operator_pin_kot_and_bill'),
      operatorPinGenerateBill: flag('operator_pin_generate_bill'),
      operatorPinPayment: flag('operator_pin_payment'),
      operatorPinCancelOrder: flag('operator_pin_cancel_order'),
      operatorPinKotEdit: flag('operator_pin_kot_edit'),
      operatorPinQuickSettle: flag('operator_pin_quick_settle'),
    );
  }
}
