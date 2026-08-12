import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';

/// The register's arithmetic and the way a life reads on it.
///
/// The screen itself needs a repository, but these are the parts that
/// can be wrong without anything throwing: a net book value that does
/// not equal cost less depreciation, and a basis that says five years
/// when the asset is on reducing balance.
void main() {
  FixedAsset asset({
    double cost = 60000,
    double accumulated = 0,
    String method = 'straight_line',
    int? life = 60,
    double? rate,
  }) =>
      FixedAsset(
        id: 'a1',
        assetNo: 'FA-001',
        name: 'Delivery van',
        acquisitionDate: DateTime(2026, 1, 1),
        cost: cost,
        accumulatedDepreciation: accumulated,
        method: method,
        usefulLifeMonths: life,
        ratePercent: rate,
      );

  test('net book value is cost less what has been charged', () {
    expect(asset(accumulated: 6000).netBookValue, 54000);
  });

  test('a fully depreciated asset is worth nothing, not less', () {
    expect(asset(accumulated: 60000).netBookValue, 0);
  });

  group('how the basis reads', () {
    test('whole years say years', () {
      expect(asset(life: 60).basis, '5 year straight line');
    });

    test('and anything else says months', () {
      expect(asset(life: 30).basis, '30 month straight line');
    });

    test('reducing balance says its rate, not a life', () {
      final a = asset(method: 'reducing_balance', life: 60, rate: 20);
      expect(a.basis, '20.00% reducing');
      expect(a.basis, isNot(contains('year')),
          reason: 'the stored life is kept but must not be shown as the '
              'basis when the method does not use it');
    });
  });

  group('what is sent to the database', () {
    test('a straight-line asset sends its life and no rate', () {
      final json = asset(method: 'straight_line', life: 60, rate: 20).toJson();
      expect(json['useful_life_months'], 60);
      expect(json['rate_percent'], isNull,
          reason: 'a stale rate from the other method would sit there '
              'looking authoritative');
    });

    test('a reducing-balance asset sends its rate and no life', () {
      final json =
          asset(method: 'reducing_balance', life: 60, rate: 20).toJson();
      expect(json['rate_percent'], 20);
      expect(json['useful_life_months'], isNull);
    });
  });

  testWidgets('the register totals do not overflow a phone', (tester) async {
    tester.view.physicalSize = const Size(412, 830);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: ListTile(
          title: const Text('FA-001 · Delivery van'),
          subtitle: const Text('5 year straight line · bought 01/01/2026'),
          trailing: const Text('RM 54,000.00'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
