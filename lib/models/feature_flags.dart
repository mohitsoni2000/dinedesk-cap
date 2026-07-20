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
  final bool directKot;
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
  final bool operatorPinRenameTable;
  final bool operatorPinKotReprint;
  final bool operatorPinBillReprint;
  final bool autoKot;
  final int autoKotThreshold;
  final bool itemVariations;
  final bool waiterAssignment;
  final bool manualEntry;
  final bool kotEdit;
  final bool kitchenDisplay;
  final bool readyToServe;

  final bool cashOnlyDiscounts;
  final bool reports;
  final bool advancedReports;
  final bool multiTerminal;
  final bool takeaway;
  final bool billPrinting;
  final bool tableReservationAlerts;
  final bool customerCredit;
  final bool companyBill;
  final bool tableMerge;
  final bool shiftManagement;
  final bool tableZones;
  final bool floorSeparateRevenue;
  final bool floorCapacityLimit;
  final bool auditTrail;
  final bool secureSearch;
  final bool twoFactorAuth;
  final bool onlineOrders;
  final bool onlineWebview;
  final bool zomatoIntegration;
  final bool swiggyIntegration;
  final bool onlineBrandSelection;
  final bool rooms;
  final bool printGroups;
  final bool itemScheduling;
  final bool kotEditSkipPrint;
  final bool kotEditReasonOptional;
  final bool favouriteItems;
  final bool tempTable;
  final bool kotReprint;
  final bool billReprint;
  final bool customPrintLayouts;
  final bool offers;
  final bool menuAccessGroups;
  final bool weighedItems;
  final bool billingButton;

  const FeatureFlags({
    this.discounts = false,
    this.complimentary = false,
    this.voidBills = false,
    this.splitPayment = false,
    this.liquorBilling = false,
    this.beveragesBilling = false,
    this.serviceCharge = true,
    this.reservations = false,
    this.customers = false,
    this.inventory = false,
    this.kotPrinting = true,
    this.directKot = false,
    this.packages = false,
    this.multiFloor = false,
    this.operatorPinAuth = true,
    this.operatorPinMode = 'per_action',
    this.operatorPinSessionMinutes = 15,
    this.operatorPinKot = false,
    this.operatorPinHold = false,
    this.operatorPinKotAndBill = false,
    this.operatorPinGenerateBill = false,
    this.operatorPinPayment = false,
    this.operatorPinCancelOrder = false,
    this.operatorPinKotEdit = false,
    this.operatorPinQuickSettle = false,
    this.operatorPinRenameTable = false,
    this.operatorPinKotReprint = false,
    this.operatorPinBillReprint = false,
    this.autoKot = false,
    this.autoKotThreshold = 5,
    this.itemVariations = false,
    this.waiterAssignment = false,
    this.manualEntry = false,
    this.kotEdit = false,
    this.kitchenDisplay = false,
    this.readyToServe = false,
    this.cashOnlyDiscounts = false,
    this.reports = false,
    this.advancedReports = false,
    this.multiTerminal = false,
    this.takeaway = false,
    this.billPrinting = false,
    this.tableReservationAlerts = false,
    this.customerCredit = false,
    this.companyBill = false,
    this.tableMerge = false,
    this.shiftManagement = false,
    this.tableZones = false,
    this.floorSeparateRevenue = false,
    this.floorCapacityLimit = false,
    this.auditTrail = false,
    this.secureSearch = false,
    this.twoFactorAuth = false,
    this.onlineOrders = false,
    this.onlineWebview = false,
    this.zomatoIntegration = false,
    this.swiggyIntegration = false,
    this.onlineBrandSelection = false,
    this.rooms = false,
    this.printGroups = false,
    this.itemScheduling = false,
    this.kotEditSkipPrint = false,
    this.kotEditReasonOptional = false,
    this.favouriteItems = false,
    this.tempTable = false,
    this.kotReprint = false,
    this.billReprint = false,
    this.customPrintLayouts = false,
    this.offers = false,
    this.menuAccessGroups = false,
    this.weighedItems = false,
    this.billingButton = false,
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
      discounts: flag('flag_discounts'),
      complimentary: flag('flag_complimentary'),
      voidBills: flag('flag_void_bills'),
      splitPayment: flag('flag_split_payment'),
      liquorBilling: flag('flag_liquor_billing'),
      beveragesBilling: flag('flag_beverages_billing'),
      serviceCharge: flag('flag_service_charge', true),
      reservations: flag('flag_reservations'),
      customers: flag('flag_customers'),
      inventory: flag('flag_inventory'),
      kotPrinting: flag('flag_kot_printing', true),
      directKot: flag('flag_direct_kot'),
      packages: flag('flag_packages'),
      multiFloor: flag('flag_multi_floor'),
      operatorPinAuth: flag('flag_operator_pin_auth', true),
      operatorPinMode: map['operator_pin_mode']?.toString() ?? 'per_action',
      operatorPinSessionMinutes:
          int.tryParse('${map['operator_pin_session_minutes']}') ?? 15,
      operatorPinKot: flag('operator_pin_kot'),
      operatorPinHold: flag('operator_pin_hold'),
      operatorPinKotAndBill: flag('operator_pin_kot_and_bill'),
      operatorPinGenerateBill: flag('operator_pin_generate_bill'),
      operatorPinPayment: flag('operator_pin_payment'),
      operatorPinCancelOrder: flag('operator_pin_cancel_order'),
      operatorPinKotEdit: flag('operator_pin_kot_edit'),
      operatorPinQuickSettle: flag('operator_pin_quick_settle'),
      operatorPinRenameTable: flag('operator_pin_rename_table'),
      operatorPinKotReprint: flag('operator_pin_kot_reprint'),
      operatorPinBillReprint: flag('operator_pin_bill_reprint'),
      autoKot: flag('flag_auto_kot'),
      autoKotThreshold: int.tryParse('${map['auto_kot_threshold']}') ?? 5,
      itemVariations: flag('flag_item_variations'),
      waiterAssignment: flag('flag_waiter_assignment'),
      manualEntry: flag('flag_manual_entry'),
      kotEdit: flag('flag_kot_edit'),
      kitchenDisplay: flag('flag_kitchen_display'),
      readyToServe: flag('flag_ready_to_serve'),
      cashOnlyDiscounts: flag('flag_cash_only_discounts'),
      reports: flag('flag_reports', true),
      advancedReports: flag('flag_advanced_reports'),
      multiTerminal: flag('flag_multi_terminal'),
      takeaway: flag('flag_takeaway', true),
      billPrinting: flag('flag_bill_printing', true),
      tableReservationAlerts: flag('flag_table_reservation_alerts'),
      customerCredit: flag('flag_customer_credit'),
      companyBill: flag('flag_company_bill'),
      tableMerge: flag('flag_table_merge', true),
      shiftManagement: flag('flag_shift_management'),
      tableZones: flag('flag_table_zones'),
      floorSeparateRevenue: flag('flag_floor_separate_revenue'),
      floorCapacityLimit: flag('flag_floor_capacity_limit'),
      auditTrail: flag('flag_audit_trail'),
      secureSearch: flag('flag_secure_search'),
      twoFactorAuth: flag('flag_two_factor_auth'),
      onlineOrders: flag('flag_online_orders'),
      onlineWebview: flag('flag_online_webview'),
      zomatoIntegration: flag('flag_zomato_integration', true),
      swiggyIntegration: flag('flag_swiggy_integration', true),
      onlineBrandSelection: flag('flag_online_brand_selection', true),
      rooms: flag('flag_rooms'),
      printGroups: flag('flag_print_groups'),
      itemScheduling: flag('flag_item_scheduling'),
      kotEditSkipPrint: flag('flag_kot_edit_skip_print'),
      kotEditReasonOptional: flag('flag_kot_edit_reason_optional'),
      favouriteItems: flag('flag_favourite_items'),
      tempTable: flag('flag_temp_table'),
      kotReprint: flag('flag_kot_reprint'),
      billReprint: flag('flag_bill_reprint'),
      customPrintLayouts: flag('flag_custom_print_layouts'),
      offers: flag('flag_offers'),
      menuAccessGroups: flag('flag_menu_access_groups'),
      weighedItems: flag('flag_weighed_items'),
      billingButton: flag('flag_billing_button'),
    );
  }
}
