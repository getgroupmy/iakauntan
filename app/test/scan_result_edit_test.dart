import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/scan_kinds_repository.dart';
import 'package:iakauntan/src/features/shared/scan_result_dialog.dart';

/// The reading is a first draft, and this dialog is where it stops being
/// one. Everything asserted here is a figure that ends up on a bill.
///
/// The case that prompted it: a TM bill read back with a subtotal of
/// 316.95, tax of 17.94 and a *total* of 17.94 — the total taken off the
/// tax line. Every figure was found and one was wrong, which is the
/// ordinary outcome and useless unless it can be corrected.
/// A `ProviderScope` with the kinds of document already answered.
///
/// `0614` put a picker on this dialog, and a picker reads a table. The
/// list is stubbed rather than left to fail: without a scope the dialog
/// throws, and with a scope that never answers the picker draws nothing
/// — and a picker that drew nothing would satisfy every assertion in
/// this file without ever having existed.
Widget scoped(Widget child) => ProviderScope(
      overrides: [
        offeredScanKindsProvider.overrideWith(
          (ref) async => const [
            ScanKind(
              code: 'bill',
              label: "Supplier's bill or invoice",
              destination: 'purchase_document',
              hint: 'Becomes a bill, with the supplier and the lines '
                  'filled in.',
              sortOrder: 10,
            ),
            ScanKind(code: 'other', label: 'Something else', sortOrder: 999),
          ],
        ),
      ],
      child: child,
    );

void main() {
  const tmBill = OcrExtraction(
    supplierName: 'TM Technology Services Sdn Bhd',
    documentNo: '010043211993',
    currency: 'MYR',
    subtotal: 316.95,
    taxAmount: 17.94,
    totalAmount: 17.94,
    lines: [
      OcrLine(description: 'Credit Limit:', amount: 1100),
      OcrLine(description: 'Deposit:', amount: 0),
    ],
    note: 'The printed figures do not add up: 316.95 + 17.94 is not 17.94.',
  );

  /// Opens the dialog over a bare page and hands back a getter for
  /// whatever it eventually returns.
  Future<OcrExtraction? Function()> open(
    WidgetTester tester,
    OcrExtraction read,
  ) async {
    OcrExtraction? applied;
    await tester.pumpWidget(scoped(MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async =>
                  applied = await showScanResult(context, read, canApply: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => applied;
  }

  Finder field(String label) => find.byKey(ValueKey('scan-$label'));

  /// The dialog scrolls, and in a 600px test window the footing warning
  /// and the line rows start below the fold. A tap on an off-screen
  /// widget only *warns* and then lands wherever the finder's centre
  /// happens to be, so it has to be scrolled to first.
  Future<void> press(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('what was read is what is offered for editing', (tester) async {
    await open(tester, tmBill);

    expect(find.text('TM Technology Services Sdn Bhd'), findsOneWidget);
    expect(find.text('010043211993'), findsOneWidget);
    expect(find.text('316.95'), findsOneWidget);
    // Tax and the wrongly-read total are the same figure, so it appears
    // twice.
    expect(find.text('17.94'), findsNWidgets(2));
  });

  testWidgets('a total that does not foot is reported, and the sum offered',
      (tester) async {
    await open(tester, tmBill);

    expect(find.textContaining('do not add up'), findsOneWidget);
    expect(find.text('Set total to RM 334.89'), findsOneWidget);
  });

  testWidgets('correcting the total clears the warning', (tester) async {
    await open(tester, tmBill);

    await press(tester, find.text('Set total to RM 334.89'));

    expect(find.textContaining('do not add up'), findsNothing);
  });

  testWidgets('the corrected figure comes back, not the read one',
      (tester) async {
    final applied = await open(tester, tmBill);

    await press(tester, find.text('Set total to RM 334.89'));
    await tester.tap(find.text('Use these'));
    await tester.pumpAndSettle();

    final out = applied()!;
    expect(out.totalAmount, 334.89);
    expect(out.subtotal, 316.95);
    expect(out.taxAmount, 17.94);
    // Corrected, so there is nothing left to warn about.
    expect(out.note, isNull);
    // Fields nobody touched survive the round trip.
    expect(out.supplierName, 'TM Technology Services Sdn Bhd');
    expect(out.documentNo, '010043211993');
    expect(out.currency, 'MYR');
  });

  testWidgets('a typed correction is what comes back', (tester) async {
    final applied = await open(tester, tmBill);

    await tester.enterText(field('Total'), '334.89');
    await tester.enterText(field('Supplier'), 'TM Technology Services Sdn Bhd');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use these'));
    await tester.pumpAndSettle();

    expect(applied()!.totalAmount, 334.89);
  });

  testWidgets('a footer line read as a charge can be removed', (tester) async {
    final applied = await open(tester, tmBill);

    expect(find.widgetWithText(TextField, 'Credit Limit:'), findsOneWidget);

    // Both dropped: a credit limit is not a charge, and neither is a
    // deposit of nothing.
    await press(tester, find.byTooltip('Remove this line').first);
    await press(tester, find.byTooltip('Remove this line').first);

    await tester.tap(find.text('Use these'));
    await tester.pumpAndSettle();

    expect(applied()!.lines, isEmpty);
  });

  testWidgets('discarding returns nothing at all', (tester) async {
    final applied = await open(tester, tmBill);

    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    expect(applied(), isNull);
  });

  testWidgets('a blank figure stays absent rather than becoming zero',
      (tester) async {
    final applied = await open(
      tester,
      const OcrExtraction(supplierName: 'Kedai Runcit Aman', totalAmount: 12.5),
    );

    await tester.tap(find.text('Use these'));
    await tester.pumpAndSettle();

    // The receipt carried no tax line. That has to survive as "not on
    // the document" rather than as RM 0.00, which is a different claim
    // and the wrong one to file.
    final out = applied()!;
    expect(out.taxAmount, isNull);
    expect(out.subtotal, isNull);
    expect(out.supplierTaxId, isNull);
    expect(out.totalAmount, 12.5);
  });

  testWidgets('a figure typed with separators is read as a number',
      (tester) async {
    final applied = await open(
      tester,
      const OcrExtraction(supplierName: 'Teguh Hardware Sdn Bhd'),
    );

    await tester.enterText(field('Subtotal'), 'RM 1,234.56');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use these'));
    await tester.pumpAndSettle();

    expect(applied()!.subtotal, 1234.56);
  });

  testWidgets('a lower-case currency is filed as an ISO code',
      (tester) async {
    final applied = await open(
      tester,
      const OcrExtraction(supplierName: 'Teguh Hardware Sdn Bhd'),
    );

    await tester.enterText(field('Currency'), 'myr');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use these'));
    await tester.pumpAndSettle();

    expect(applied()!.currency, 'MYR');
  });

  testWidgets('nothing legible still opens a form worth typing into',
      (tester) async {
    final applied = await open(tester, const OcrExtraction());

    expect(find.textContaining('Nothing legible'), findsOneWidget);

    await tester.enterText(field('Supplier'), 'Kedai Runcit Aman');
    await tester.enterText(field('Total'), '48.00');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use these'));
    await tester.pumpAndSettle();

    final out = applied()!;
    expect(out.supplierName, 'Kedai Runcit Aman');
    expect(out.totalAmount, 48.0);
  });

  // ---- what the paper IS, above what it says (0614) ----

  testWidgets('the dialog says what kind of paper it thinks this is',
      (tester) async {
    await open(
      tester,
      const OcrExtraction(
        supplierName: 'TM Technology Services Sdn Bhd',
        totalAmount: 334.89,
        rawText: 'TM Technology Services Sdn Bhd\nTAX INVOICE\n'
            'Invoice No 010043211993\nJUMLAH 334.89',
      ),
    );

    // The picker exists and has chosen. `_KindField` draws nothing at
    // all while the list is loading, so finding it is the assertion
    // that the stub arrived as well as that the guess was made.
    final picker = find.byKey(const ValueKey('scan-document-kind'));
    expect(picker, findsOneWidget);
    expect(
      find.descendant(
        of: picker,
        matching: find.text("Supplier's bill or invoice"),
      ),
      findsOneWidget,
    );

    // The reason in words rather than a percentage, and the hint that
    // says what pressing the button will do.
    expect(find.textContaining('Says "tax invoice"'), findsOneWidget);
    expect(
      find.textContaining('Becomes a bill'),
      findsOneWidget,
    );
  });

  testWidgets('and says "something else" when the paper does not say',
      (tester) async {
    // The negative half, and the one that makes the assertion above
    // mean anything: "Supplier's bill" is also the first row in the
    // stub, so a picker that ignored the guess entirely and fell back
    // to the head of the list would pass that test and fail this one.
    await open(tester, const OcrExtraction(supplierName: 'Kedai Aman'));

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scan-document-kind')),
        matching: find.text('Something else'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('and lets somebody say otherwise', (tester) async {
    await open(
      tester,
      const OcrExtraction(
        supplierName: 'TM Technology Services Sdn Bhd',
        totalAmount: 334.89,
        rawText: 'TAX INVOICE\nJUMLAH 334.89',
      ),
    );

    final picker = find.byKey(const ValueKey('scan-document-kind'));
    await tester.ensureVisible(picker);
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Something else').last);
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: picker, matching: find.text('Something else')),
      findsOneWidget,
    );
    // The hint follows the choice rather than the guess: the two rows
    // in the stub carry different ones, so a hint that stayed put would
    // show here.
    expect(find.textContaining('Becomes a bill'), findsNothing);
  });

  testWidgets('and the choice is what comes back, not the guess',
      (tester) async {
    // The half that matters outside this dialog. A picker that draws
    // the new label and hands back the old code files the scan as
    // something nobody chose, and the screen would look right.
    final applied = await open(
      tester,
      const OcrExtraction(
        supplierName: 'TM Technology Services Sdn Bhd',
        totalAmount: 334.89,
        rawText: 'TAX INVOICE\nJUMLAH 334.89',
      ),
    );

    final picker = find.byKey(const ValueKey('scan-document-kind'));
    await tester.ensureVisible(picker);
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Something else').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use these'));
    await tester.pumpAndSettle();

    expect(applied()!.documentKind, 'other');
  });

  testWidgets('a guess at a kind nobody offers is corrected, not shown',
      (tester) async {
    // The stub offers a bill and "something else". A receipt is read
    // as a receipt, which is not on the list — the kind was switched
    // off, or added to the classifier before it was added to the
    // table. Without the correction the dropdown asserts on a value
    // that is not among its items, and the document somebody is
    // looking at is not the place to find that out.
    final applied = await open(
      tester,
      const OcrExtraction(
        supplierName: 'Kedai Runcit Aman',
        totalAmount: 48.0,
        rawText: 'RESIT RASMI\nJUALAN TUNAI\nJUMLAH 48.00',
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scan-document-kind')),
        matching: find.text("Supplier's bill or invoice"),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Use these'));
    await tester.pumpAndSettle();

    // And what comes back is what was SHOWN. A dialog that displayed
    // the fallback and handed back the unoffered guess would pass the
    // assertion above.
    expect(applied()!.documentKind, 'bill');
  });
}
