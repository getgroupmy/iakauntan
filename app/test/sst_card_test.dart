import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/settings/sst_card.dart';

/// What the company is told about its own tax registration.
///
/// The rules are in 0145 and asserted in
/// `supabase/tests/sst_registration.sql` — the database is what refuses
/// a registration missing its date, its number or its rate. What is
/// asserted here is the part that made the old switch useless: that the
/// card says which tax code new lines will actually be charged at, and
/// that the chooser cannot offer a zero-rated one.
void main() {
  Organization org({bool registered = false, String? number, DateTime? from}) =>
      Organization(
        id: 'o1',
        name: 'Kabeer Holdings Sdn Bhd',
        slug: 'kabeer',
        baseCurrency: 'MYR',
        isSstRegistered: registered,
        sstRegistrationNo: number,
        sstRegisteredFrom: from,
      );

  TaxCode code(String c, String name, double rate, {bool isDefault = false}) =>
      TaxCode(
        id: c,
        code: c,
        name: name,
        rate: rate,
        taxTypeCode: '02',
        isDefault: isDefault,
      );

  final codes = [
    code('NA', 'Not Applicable', 0, isDefault: true),
    code('ST8', 'Service Tax 8%', 8),
    code('ST6', 'Service Tax 6%', 6),
    code('SL10', 'Sales Tax 10%', 10),
    code('ZR', 'Zero Rated / Export', 0),
  ];

  Widget harness(
    Organization o, {
    List<TaxCode>? taxCodes,
    bool admin = true,
  }) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      currentOrgProvider.overrideWith((ref) async => o),
      taxCodesProvider.overrideWith((ref) async => taxCodes ?? codes),
      canAdminProvider.overrideWithValue(admin),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: SingleChildScrollView(child: SstCard())),
    ),
  );

  testWidgets('an unregistered company is told what its lines are taxed at', (
    tester,
  ) async {
    await tester.pumpWidget(harness(org()));
    await tester.pumpAndSettle();

    expect(find.textContaining('not registered for SST'), findsOneWidget);
    expect(find.text('Register for SST'), findsOneWidget);
  });

  testWidgets('a registered one shows the number, the date and — the part '
      'that used to be missing — the code new lines default to', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        org(
          registered: true,
          number: 'W10-1234567890',
          from: DateTime(2026, 9, 1),
        ),
        taxCodes: [
          code('NA', 'Not Applicable', 0),
          code('ST8', 'Service Tax 8%', 8, isDefault: true),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('W10-1234567890'), findsOneWidget);
    expect(find.textContaining('ST8'), findsOneWidget);
  });

  testWidgets('a company registered with no code marked default is told so, '
      'rather than shown a blank', (tester) async {
    // This is the state a real company in this database was in: flagged
    // registered, with NA still the default, charging nothing.
    await tester.pumpWidget(
      harness(
        org(registered: true, number: 'W10-1', from: DateTime(2026, 9, 1)),
        taxCodes: [
          code('NA', 'Not Applicable', 0),
          code('ST8', 'Service Tax 8%', 8),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('no tax code is marked default'),
      findsOneWidget,
    );
  });

  testWidgets('the effective date comes with what it means', (tester) async {
    await tester.pumpWidget(
      harness(
        org(registered: true, number: 'W10-1', from: DateTime(2026, 9, 1)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('cannot carry tax'), findsOneWidget);
  });

  testWidgets(
    'somebody who cannot administer the company is offered no button',
    (tester) async {
      await tester.pumpWidget(harness(org(), admin: false));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sst-change')), findsNothing);
      // The control: an administrator is.
      await tester.pumpWidget(harness(org(), admin: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sst-change')), findsOneWidget);
    },
  );

  testWidgets('the chooser offers only codes that charge something', (
    tester,
  ) async {
    await tester.pumpWidget(harness(org()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sst-change')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sst-registered')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sst-code')));
    await tester.pumpAndSettle();

    expect(find.textContaining('ST8'), findsWidgets);
    expect(find.textContaining('ST6'), findsWidgets);
    expect(find.textContaining('SL10'), findsWidgets);
    // 'Zero Rated' rather than 'Not Applicable': NA appears in the
    // card's own copy behind the dialog, so it would match whether or
    // not it was on the menu, and an assertion that cannot fail is not
    // one.
    expect(
      find.textContaining('Zero Rated'),
      findsNothing,
      reason:
          'registering and defaulting to 0% is the bug 0145 exists to '
          'stop, so a zero-rated code is not on the menu',
    );
  });

  testWidgets('and the date and number are asked for in the same breath', (
    tester,
  ) async {
    await tester.pumpWidget(harness(org()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sst-change')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sst-registered')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sst-number')), findsOneWidget);
    expect(find.byKey(const ValueKey('sst-date')), findsOneWidget);
    expect(find.byKey(const ValueKey('sst-code')), findsOneWidget);
  });
}
