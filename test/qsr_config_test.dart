import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:restro/models/qsr_config.dart';

/// `qsr_config` arrives in the sync and in `qsr_config:updated`. It decides
/// the home screen (Counter vs Tables) and which counter buttons exist, so a
/// malformed or missing one must always fall back to plain restaurant mode.
void main() {
  Map<String, dynamic> fixture() => (jsonDecode(
          File('test/fixtures/crew-qsr/sync_qsr_keys.json').readAsStringSync())
      as Map<String, dynamic>)['qsr_config'] as Map<String, dynamic>;

  group('QsrConfig.tryParse', () {
    test('reads the shared fixture', () {
      final cfg = QsrConfig.tryParse(fixture())!;
      expect(cfg.operatingMode, OperatingMode.qsr);
      expect(cfg.isQsr, isTrue);
      expect(cfg.paymentFlow, QsrPaymentFlow.hybrid);
      expect(cfg.tokenStrategy, TokenStrategy.prefixed);
      expect(cfg.tokenPrefixTakeaway, 'T');
      expect(cfg.tokenPrefixStanding, 'S');
      expect(cfg.tokenReadyClearMinutes, 10);
    });

    test('a non-map is null, so the caller decides what absence means', () {
      expect(QsrConfig.tryParse(null), isNull);
      expect(QsrConfig.tryParse('qsr'), isNull);
      expect(QsrConfig.tryParse(<Object>[]), isNull);
    });

    test('an empty map is the desk defaults: restaurant mode', () {
      final cfg = QsrConfig.tryParse(<String, dynamic>{})!;
      expect(cfg.isQsr, isFalse);
      expect(cfg.paymentFlow, QsrPaymentFlow.hybrid);
      expect(cfg.tokenStrategy, TokenStrategy.unified);
      expect(cfg.tokenPrefixTakeaway, 'T');
      expect(cfg.tokenPrefixStanding, 'S');
      expect(cfg.tokenReadyClearMinutes, 10);
    });

    test('unknown values fall back instead of throwing', () {
      final cfg = QsrConfig.tryParse(<String, dynamic>{
        'operating_mode': 'cafe',
        'qsr_payment_flow': 'barter',
        'token_strategy': 'random',
        'token_prefix_takeaway': '   ',
        'token_prefix_standing': 7,
        'token_ready_clear_minutes': 'soon',
      })!;
      expect(cfg.isQsr, isFalse, reason: 'only an explicit qsr opens Counter');
      expect(cfg.paymentFlow, QsrPaymentFlow.hybrid);
      expect(cfg.tokenStrategy, TokenStrategy.unified);
      expect(cfg.tokenPrefixTakeaway, 'T');
      expect(cfg.tokenPrefixStanding, '7');
      expect(cfg.tokenReadyClearMinutes, 10);
    });

    test('values are read case-insensitively and prefixes are upper-cased', () {
      final cfg = QsrConfig.tryParse(<String, dynamic>{
        'operating_mode': ' QSR ',
        'qsr_payment_flow': 'PrePaid',
        'token_strategy': 'PREFIXED',
        'token_prefix_takeaway': ' tk ',
        'token_prefix_standing': 'st',
      })!;
      expect(cfg.isQsr, isTrue);
      expect(cfg.paymentFlow, QsrPaymentFlow.prepaid);
      expect(cfg.tokenStrategy, TokenStrategy.prefixed);
      expect(cfg.tokenPrefixTakeaway, 'TK');
      expect(cfg.tokenPrefixStanding, 'ST');
    });

    test('the ready-clear minutes stay inside the desk\'s 1-120 range', () {
      int minutes(Object raw) => QsrConfig.tryParse(
              <String, dynamic>{'token_ready_clear_minutes': raw})!
          .tokenReadyClearMinutes;
      expect(minutes(0), 1);
      expect(minutes(500), 120);
      expect(minutes('15'), 15);
    });
  });

  group('QsrConfig.restaurant', () {
    test('is what a desk without QSR settings means', () {
      const cfg = QsrConfig.restaurant;
      expect(cfg.operatingMode, OperatingMode.restaurant);
      expect(cfg.isQsr, isFalse);
      expect(cfg.canPayNow, isTrue);
      expect(cfg.canPayLater, isTrue);
    });
  });

  group('payment flow', () {
    QsrConfig cfg(String mode, String flow) => QsrConfig.tryParse(
        <String, dynamic>{'operating_mode': mode, 'qsr_payment_flow': flow})!;

    test('only binds in QSR mode (spec 2.7)', () {
      expect(cfg('qsr', 'prepaid').canPayNow, isTrue);
      expect(cfg('qsr', 'prepaid').canPayLater, isFalse);
      expect(cfg('qsr', 'postpaid').canPayNow, isFalse);
      expect(cfg('qsr', 'postpaid').canPayLater, isTrue);
      expect(cfg('qsr', 'hybrid').canPayNow, isTrue);
      expect(cfg('qsr', 'hybrid').canPayLater, isTrue);
      for (final flow in <String>['prepaid', 'postpaid', 'hybrid']) {
        expect(cfg('restaurant', flow).canPayNow, isTrue, reason: flow);
        expect(cfg('restaurant', flow).canPayLater, isTrue, reason: flow);
      }
    });
  });
}
