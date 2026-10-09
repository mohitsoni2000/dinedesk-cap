import 'wire.dart';

/// How the desk runs: a classic table restaurant, or a quick-service counter
/// (tokens, Counter as the home screen, Tables closed on the phone).
enum OperatingMode {
  restaurant('restaurant'),
  qsr('qsr');

  const OperatingMode(this.wire);
  final String wire;
}

/// When a QSR counter takes the money. Only binds in [OperatingMode.qsr].
enum QsrPaymentFlow {
  /// Pay, then the order is fired.
  prepaid('prepaid'),

  /// Fired now, paid at pickup.
  postpaid('postpaid'),

  /// Either, per order.
  hybrid('hybrid');

  const QsrPaymentFlow(this.wire);
  final String wire;
}

/// How token labels are made: one daily sequence (`42`) or one per
/// fulfillment with a prefix (`T-07`, `S-03`).
enum TokenStrategy {
  unified('unified'),
  prefixed('prefixed');

  const TokenStrategy(this.wire);
  final String wire;
}

/// The desk's QSR settings, as `qsr_config` in the sync and in the
/// `qsr_config:updated` broadcast.
///
/// Parsing never throws: an unknown value falls back to the desk's own
/// default, and only an explicit `operating_mode: 'qsr'` turns QSR on, so a
/// strange reply can never close the Tables screen on a restaurant.
class QsrConfig {
  final OperatingMode operatingMode;
  final QsrPaymentFlow paymentFlow;
  final TokenStrategy tokenStrategy;
  final String tokenPrefixTakeaway;
  final String tokenPrefixStanding;

  /// How long a ready token stays on the TV after it was called.
  final int tokenReadyClearMinutes;

  const QsrConfig({
    this.operatingMode = OperatingMode.restaurant,
    this.paymentFlow = QsrPaymentFlow.hybrid,
    this.tokenStrategy = TokenStrategy.unified,
    this.tokenPrefixTakeaway = 'T',
    this.tokenPrefixStanding = 'S',
    this.tokenReadyClearMinutes = 10,
  });

  /// What a desk without QSR settings (or an older desk) means.
  static const QsrConfig restaurant = QsrConfig();

  bool get isQsr => operatingMode == OperatingMode.qsr;

  /// "Pay & fire" is allowed: everywhere except a post-paid QSR counter.
  bool get canPayNow => !isQsr || paymentFlow != QsrPaymentFlow.postpaid;

  /// "Fire, pay at pickup" is allowed: everywhere except a pre-paid QSR
  /// counter.
  bool get canPayLater => !isQsr || paymentFlow != QsrPaymentFlow.prepaid;

  /// Null when [raw] is not a map, so the caller decides what a missing
  /// config means (see SyncService: an older desk is restaurant mode).
  static QsrConfig? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    return QsrConfig(
      operatingMode: _pick(OperatingMode.values, (v) => v.wire,
          m['operating_mode'], OperatingMode.restaurant),
      paymentFlow: _pick(QsrPaymentFlow.values, (v) => v.wire,
          m['qsr_payment_flow'], QsrPaymentFlow.hybrid),
      tokenStrategy: _pick(TokenStrategy.values, (v) => v.wire,
          m['token_strategy'], TokenStrategy.unified),
      tokenPrefixTakeaway: _prefix(m, 'token_prefix_takeaway', 'T'),
      tokenPrefixStanding: _prefix(m, 'token_prefix_standing', 'S'),
      tokenReadyClearMinutes:
          intOr(m, 'token_ready_clear_minutes', 10).clamp(1, 120),
    );
  }

  static T _pick<T>(
    List<T> values,
    String Function(T) wireOf,
    Object? raw,
    T fallback,
  ) {
    final key = raw?.toString().trim().toLowerCase();
    for (final v in values) {
      if (wireOf(v) == key) return v;
    }
    return fallback;
  }

  static String _prefix(
          Map<String, dynamic> m, String field, String fallback) =>
      optionalString(m, field)?.toUpperCase() ?? fallback;
}
