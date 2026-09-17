import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/settings/document_numbering_card.dart';

/// What the next invoice is called.
///
/// The card shows the sample the server composed; the dialog previews
/// the number as the fields are typed, composed here the same way. The
/// arithmetic tests pin the mirror to the numbers 0480 asserts of
/// `app.compose_document_number`, including the one that lost a digit:
/// the hundred-thousandth invoice padded to five must keep all six.
void main() {
  group('composeDocumentNumber', () {
    test('pads to the width', () {
      expect(composeDocumentNumber('INV-', '2026', 7, 5, ''), 'INV-2026-00007');
    });

    test('carries the suffix', () {
      expect(
        composeDocumentNumber('INV-', '2026', 7, 5, '/A'),
        'INV-2026-00007/A',
      );
    });

    test('has no period when the count never restarts', () {
      expect(composeDocumentNumber('QT/', null, 77, 4, ''), 'QT/0077');
      expect(composeDocumentNumber('QT/', '', 77, 4, ''), 'QT/0077');
    });

    test('keeps every digit past the padding', () {
      expect(
        composeDocumentNumber('INV-', '2026', 100000, 5, ''),
        'INV-2026-100000',
      );
      expect(
        composeDocumentNumber('INV-', '2026', 99999, 5, ''),
        'INV-2026-99999',
      );
    });

    test('an empty prefix leaves the period first', () {
      expect(composeDocumentNumber('', '2026', 1, 5, ''), '2026-00001');
    });
  });

  group('seriesPeriodKey', () {
    final now = DateTime(2026, 3, 9);
    test(
      'yearly is the year',
      () => expect(seriesPeriodKey('yearly', now), '2026'),
    );
    test('monthly is year and month', () {
      expect(seriesPeriodKey('monthly', now), '202603');
    });
    test(
      'never is nothing',
      () => expect(seriesPeriodKey('never', now), isNull),
    );
  });

  Map<String, dynamic> series(
    String docType,
    String label,
    String module, {
    String prefix = 'INV-',
    String suffix = '',
    int padding = 5,
    String reset = 'yearly',
    int next = 1,
    String? periodKey = '2026',
  }) => {
    'doc_type': docType,
    'label': label,
    'module': module,
    'prefix': prefix,
    'suffix': suffix,
    'padding': padding,
    'reset_policy': reset,
    'next_value': next,
    'last_issued': next > 1 ? next - 1 : null,
    'period_key': periodKey,
    'sample': composeDocumentNumber(prefix, periodKey, next, padding, suffix),
    'is_default': next == 1,
  };

  final rows = [
    series('quotation', 'Quotations', 'sales', prefix: 'QT-'),
    series('invoice', 'Invoices', 'sales', next: 413),
    series('bill', 'Bills', 'purchases', prefix: 'BILL-'),
    series('journal', 'Journal vouchers', 'accounting', prefix: 'JV-'),
  ];

  final catalogue = [
    ModuleInfo(
      code: 'sales',
      name: 'Sales & Invoicing',
      isCore: true,
      monthlyPrice: 0,
    ),
    ModuleInfo(
      code: 'purchases',
      name: 'Purchases',
      isCore: false,
      monthlyPrice: 0,
    ),
  ];

  Widget harness({String role = 'owner'}) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      documentNumberingProvider.overrideWith((_) async => rows),
      platformModulesProvider.overrideWith((_) async => catalogue),
      memberRoleProvider.overrideWith((_) async => role),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(
        body: SingleChildScrollView(child: DocumentNumberingCard()),
      ),
    ),
  );

  testWidgets('sales is open, named from the catalogue, with the samples', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('Sales & Invoicing'), findsOneWidget);
    expect(find.text('Invoices'), findsOneWidget);
    expect(find.text('INV-2026-00413'), findsOneWidget);
    expect(find.text('Last issued INV-2026-00412'), findsOneWidget);
    expect(find.text('Quotations'), findsOneWidget);
    expect(find.text('QT-2026-00001'), findsOneWidget);
    expect(find.text('None issued yet'), findsOneWidget);
  });

  testWidgets('a module the catalogue does not name is spelt out', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('Purchases'), findsOneWidget);
    expect(find.text('Accounting'), findsOneWidget);
    // Collapsed until opened.
    expect(find.text('JV-2026-00001'), findsNothing);
    await tester.tap(find.text('Accounting'));
    await tester.pumpAndSettle();
    expect(find.text('Journal vouchers'), findsOneWidget);
    expect(find.text('JV-2026-00001'), findsOneWidget);
  });

  testWidgets('an admin opens the dialog and the preview follows the fields', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('series-invoice')));
    await tester.pumpAndSettle();

    final year = DateTime.now().year.toString();
    String preview() =>
        tester.widget<Text>(find.byKey(const ValueKey('series-preview'))).data!;
    // The card behind the dialog shows the same number on its row, so
    // the preview is read by its key rather than found by its text.
    expect(preview(), 'INV-$year-00413');
    expect(
      find.textContaining('The last issued was number 412'),
      findsOneWidget,
    );

    await tester.enterText(find.byKey(const ValueKey('series-prefix')), 'INV/');
    await tester.enterText(find.byKey(const ValueKey('series-next')), '1');
    await tester.pump();
    expect(preview(), 'INV/$year-00001');

    await tester.enterText(find.byKey(const ValueKey('series-padding')), '4');
    await tester.enterText(find.byKey(const ValueKey('series-suffix')), '/KL');
    await tester.pump();
    expect(preview(), 'INV/$year-0001/KL');

    await tester.enterText(find.byKey(const ValueKey('series-next')), '100000');
    await tester.pump();
    expect(preview(), 'INV/$year-100000/KL');
  });

  testWidgets('an accountant reads and cannot open the dialog', (tester) async {
    await tester.pumpWidget(harness(role: 'accountant'));
    await tester.pumpAndSettle();

    expect(find.text('INV-2026-00413'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('series-invoice')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('series-preview')), findsNothing);
    expect(find.textContaining('Tap a series to set it'), findsNothing);
  });
}
