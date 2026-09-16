import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/scan_kinds_repository.dart';
import 'package:iakauntan/src/features/shared/scan_all_data.dart';
import 'package:iakauntan/src/features/shared/scan_result_dialog.dart';

/// Assigning a line of the document to a field by hand.
///
/// The reader finds most of it. This is for the rest — a figure printed
/// plainly on the page that nothing recognised, which until now could
/// only be retyped.
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
    subtotal: 316.95,
    rawText: 'TM Technology Services Sdn Bhd\n'
        '200201003726 (571389-H)\n'
        'Level 51, Menara TM\n'
        '50672 Kuala Lumpur\n'
        'Invoice 010043211993\n'
        '07/04/2026\n'
        'Jumlah Kecil 316.95\n'
        'SST 17.94\n'
        'JUMLAH 334.89\n'
        'TERIMA KASIH',
  );

  group('assigning a line to a field', () {
    test('text goes in as it stands', () {
      final out = assignToField(
          const OcrExtraction(), ScanField.documentNo, ' 010043211993 ');
      expect(out!.documentNo, '010043211993');
    });

    test('a figure is read as money', () {
      final out =
          assignToField(const OcrExtraction(), ScanField.total, 'JUMLAH 334.89');
      expect(out!.totalAmount, 334.89);
    });

    test('a date is read the Malaysian way', () {
      final out =
          assignToField(const OcrExtraction(), ScanField.date, '07/04/2026');
      expect(out!.documentDate, DateTime(2026, 4, 7));
    });

    test('a currency is filed as an ISO code', () {
      final out =
          assignToField(const OcrExtraction(), ScanField.currency, 'myr');
      expect(out!.currency, 'MYR');
    });

    test('address lines accumulate rather than replace', () {
      var out = assignToField(
          const OcrExtraction(), ScanField.address, 'Level 51, Menara TM')!;
      out = assignToField(out, ScanField.address, '50672 Kuala Lumpur')!;
      expect(out.supplierAddress, 'Level 51, Menara TM\n50672 Kuala Lumpur');
    });

    test('a line keeps its description and its figure apart', () {
      final out = assignToField(
          const OcrExtraction(), ScanField.line, 'Fibre 100Mbps 316.95')!;
      expect(out.lines.single.description, 'Fibre 100Mbps');
      expect(out.lines.single.amount, 316.95);
    });

    test('nothing else on the reading is disturbed', () {
      final out = assignToField(tmBill, ScanField.total, '334.89')!;
      expect(out.supplierName, 'TM Technology Services Sdn Bhd');
      expect(out.subtotal, 316.95);
      expect(out.rawText, isNotNull);
    });
  });

  group('what cannot be assigned', () {
    test('words are refused as a total rather than stored as zero', () {
      expect(assignToField(const OcrExtraction(), ScanField.total,
          'TERIMA KASIH'), isNull);
    });

    test('and as a date', () {
      expect(
          assignToField(const OcrExtraction(), ScanField.date, 'TERIMA KASIH'),
          isNull);
    });

    test('an empty line is refused for any field', () {
      expect(assignToField(const OcrExtraction(), ScanField.supplier, '   '),
          isNull);
    });
  });

  group('what the screen lists', () {
    test('every printed line, where the reader gave the text', () {
      final lines = allDataLines(tmBill);
      expect(lines.first, 'TM Technology Services Sdn Bhd');
      expect(lines, contains('SST 17.94'));
      expect(lines, contains('TERIMA KASIH'));
    });

    test('the fields themselves, where it did not', () {
      // The LLM readers answer with fields and no text. An empty screen
      // would read as a failure, so what they did return is listed.
      const fromLlm = OcrExtraction(
        supplierName: 'Teguh Hardware Sdn Bhd',
        documentNo: 'INV-2026-0042',
        totalAmount: 334.89,
      );
      final lines = allDataLines(fromLlm);
      expect(lines, contains('Teguh Hardware Sdn Bhd'));
      expect(lines, contains('INV-2026-0042'));
      expect(lines, contains('334.89'));
    });
  });

  /// A phone-sized window builds only the visible rows, and a document
  /// is longer than one. Given room, everything is on screen and the
  /// test is about assignment rather than about scrolling.
  Future<void> roomToSeeItAll(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('a line assigned on the page reaches the form', (tester) async {
    await roomToSeeItAll(tester);
    OcrExtraction? applied;

    await tester.pumpWidget(scoped(MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async => applied =
                  await showScanResult(context, tmBill, canApply: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Through to the document itself.
    await tester.tap(find.text('All data'));
    await tester.pumpAndSettle();
    expect(find.text('The form so far'), findsOneWidget);

    // The ninth line of the document, reached by key: `widgetWithText`
    // is an ancestor finder and a TextField holds its text in a
    // controller rather than in a child.
    const total = ValueKey('all-data-8');
    expect(
      (tester.widget<TextField>(find.byKey(total))).controller!.text,
      'JUMLAH 334.89',
    );

    // The total line, put where it belongs.
    final menu = find.descendant(
      of: find.ancestor(of: find.byKey(total), matching: find.byType(Row)).first,
      matching: find.byType(PopupMenuButton<ScanField>),
    );
    await tester.ensureVisible(menu);
    await tester.pumpAndSettle();
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Total').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // Back on the form, and it took.
    await tester.tap(find.text('Use these'));
    await tester.pumpAndSettle();

    expect(applied!.totalAmount, 334.89);
    // And the correction did not cost the reading everything else.
    expect(applied!.supplierName, 'TM Technology Services Sdn Bhd');
    expect(applied!.subtotal, 316.95);
  });

  testWidgets('leaving the page without Done keeps the form as it was',
      (tester) async {
    await roomToSeeItAll(tester);
    OcrExtraction? applied;

    await tester.pumpWidget(scoped(MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async => applied =
                  await showScanResult(context, tmBill, canApply: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All data'));
    await tester.pumpAndSettle();

    // Back out rather than Done.
    Navigator.of(tester.element(find.text('The form so far'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Use these'));
    await tester.pumpAndSettle();

    expect(applied!.totalAmount, isNull);
    expect(applied!.subtotal, 316.95);
  });
}
