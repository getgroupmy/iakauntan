import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/documents/line_draft.dart';
import 'package:iakauntan/src/features/documents/scan_recheck.dart';

/// Checking a document against the page it was read from.
///
///     After the AI Scan button should have a rescan icon which will
///     check if any data went diffrent or missing so it will show a
///     popup to revert back or add what was was missed out / able to
///     select item by item not all items at one click / or ignore and
///     proceed with changes
///
/// A document filled in from a reading gets edited afterwards — by a
/// person, by assigning an item, by a rounding rule — and until this
/// nothing ever compared it with the page again. `0705`'s banner says
/// the totals disagree; this says WHERE, and offers each one back on
/// its own.
///
/// The assertions that carry the most weight are the ones about what is
/// NOT a difference. This sits behind a button on every scanned
/// document, and one that opens a list of nine rows on paperwork nobody
/// has anything to fix is one nobody presses twice.
void main() {
  /// The Google bill, as the reader gave it back.
  const paperLines = [
    OcrLine(description: 'Google Workspace Business Starter',
        quantity: 29, unitPrice: 2.258),
    OcrLine(description: 'Business Starter Usage',
        quantity: 30, unitPrice: 1.129),
  ];

  const paper = OcrExtraction(
    documentNo: '5665871390',
    currency: 'MYR',
    lines: paperLines,
  );

  /// The same bill as it stands on screen, unless something is changed.
  List<LineDraft> asRead() => [
        LineDraft(
            description: 'Google Workspace Business Starter',
            quantity: 29,
            unitPrice: 2.258),
        LineDraft(
            description: 'Business Starter Usage',
            quantity: 30,
            unitPrice: 1.129),
      ];

  List<PaperDifference> check({
    OcrExtraction read = paper,
    List<LineDraft>? lines,
    String supplierDocNo = '5665871390',
    DateTime? documentDate,
    String currency = 'MYR',
    void Function(String)? setSupplierDocNo,
    void Function(DateTime)? setDocumentDate,
    void Function(String)? setCurrency,
    void Function(LineDraft)? addLine,
  }) =>
      differencesFromPaper(
        paper: read,
        lines: lines ?? asRead(),
        supplierDocNo: supplierDocNo,
        documentDate: documentDate,
        currency: currency,
        setSupplierDocNo: setSupplierDocNo ?? (_) {},
        setDocumentDate: setDocumentDate ?? (_) {},
        setCurrency: setCurrency ?? (_) {},
        addLine: addLine ?? (_) {},
      );

  group('what counts as a difference', () {
    test('a document that still matches the paper reports nothing', () {
      expect(check(), isEmpty);
    });

    test('a description somebody changed', () {
      // The reported case from two days ago: keying an item number
      // rewrote the description that came off the PDF.
      final lines = asRead();
      lines[0].description = 'Google Workspace Business Starter';
      lines[1].description = 'Langganan bulanan';
      final found = check(lines: lines);
      expect(found.single.part, RecheckPart.lineDescription);
      expect(found.single.lineNo, 2);
      expect(found.single.onDocument, 'Langganan bulanan');
      expect(found.single.onPaper, 'Business Starter Usage');
    });

    test('a unit price sent to zero', () {
      final lines = asRead();
      lines[0].unitPrice = 0;
      final found = check(lines: lines);
      expect(found.single.part, RecheckPart.lineUnitPrice);
      expect(found.single.onDocument, '0.00');
      expect(found.single.onPaper, '2.26');
    });

    test('a quantity reads as a person typed it', () {
      final lines = asRead();
      lines[0].quantity = 1;
      final found = check(lines: lines);
      expect(found.single.onDocument, '1');
      expect(found.single.onPaper, '29');
    });

    test('a line deleted from the document is missing, not changed', () {
      // "Add what was missed out". A row that says "Not there" beside
      // the paper's version reads differently from one somebody edited.
      final found = check(lines: [asRead().first]);
      expect(found.single.part, RecheckPart.lineMissing);
      expect(found.single.isMissing, isTrue);
      expect(found.single.onPaper, contains('Business Starter Usage'));
      expect(found.single.onPaper, contains('× 30'));
    });

    test('a line somebody added is not the paper\'s business', () {
      final lines = asRead()
        ..add(LineDraft(description: 'Delivery', unitPrice: 10));
      expect(check(lines: lines), isEmpty);
    });

    test('the supplier invoice number, cleared', () {
      final found = check(supplierDocNo: '');
      expect(found.single.part, RecheckPart.supplierDocNo);
      expect(found.single.isMissing, isTrue);
    });

    test('a field the reader never found is not a difference', () {
      // The paper cannot disagree about something it did not say. This
      // is the row that would otherwise appear on every document.
      final found = check(
        read: const OcrExtraction(lines: paperLines),
        supplierDocNo: 'whatever this says',
        currency: 'SGD',
      );
      expect(found, isEmpty);
    });

    test('under half a sen is not a difference', () {
      final lines = asRead();
      lines[0].unitPrice = 2.2581;
      expect(check(lines: lines), isEmpty);
    });

    test('stray spaces are not a difference', () {
      // A field somebody pasted into with a trailing space reads as the
      // same number to a person, and a row saying so is a row that
      // appears on documents nobody has anything to fix.
      expect(check(supplierDocNo: '  5665871390  '), isEmpty);
    });

    test('and the derived price is what a wrong one is measured against',
        () {
      // The other direction of the case below: with the price worked
      // out from amount over quantity, a document that disagrees has to
      // be reported — and reported against 25.00, not against nothing.
      final found = check(
        read: const OcrExtraction(lines: [
          OcrLine(description: 'Usage', quantity: 4, amount: 100),
        ]),
        lines: [LineDraft(description: 'Usage', quantity: 4, unitPrice: 30)],
      );
      expect(found.single.part, RecheckPart.lineUnitPrice);
      expect(found.single.onPaper, '25.00');
      expect(found.single.onDocument, '30.00');
    });

    test('a reader that gave an amount and a quantity, not a price', () {
      // `_applyScan` divides one by the other, so comparing any other
      // way would report a difference against a figure this app put
      // there itself.
      final found = check(
        read: const OcrExtraction(lines: [
          OcrLine(description: 'Usage', quantity: 4, amount: 100),
        ]),
        lines: [LineDraft(description: 'Usage', quantity: 4, unitPrice: 25)],
      );
      expect(found, isEmpty);
    });

    test('a continuation row is folded before anything is compared', () {
      // The reader splits a wrapped description across two rows. The
      // document has one line, correctly; comparing against the raw
      // rows would call the second one missing.
      final found = check(
        read: const OcrExtraction(lines: [
          OcrLine(description: 'Google Workspace', quantity: 1, amount: 100),
          OcrLine(description: 'Business Starter Usage'),
        ]),
        lines: [
          LineDraft(
              description: 'Google Workspace\nBusiness Starter Usage',
              quantity: 1,
              unitPrice: 100),
        ],
      );
      expect(found, isEmpty);
    });

    test('several at once, each on its own row', () {
      final lines = asRead();
      lines[0].unitPrice = 0;
      lines[1].description = 'Something else';
      final found = check(lines: lines, supplierDocNo: 'WRONG');
      expect(found.map((d) => d.part), [
        RecheckPart.supplierDocNo,
        RecheckPart.lineUnitPrice,
        RecheckPart.lineDescription,
      ]);
      expect(found.map((d) => d.id).toSet().length, 3);
    });
  });

  group('putting one back', () {
    test('restores that field and touches nothing else', () {
      final lines = asRead();
      lines[0].unitPrice = 0;
      lines[1].description = 'Something else';
      final found = check(lines: lines);

      found.firstWhere((d) => d.part == RecheckPart.lineUnitPrice).restore();
      expect(lines[0].unitPrice, 2.258);
      expect(lines[1].description, 'Something else');
    });

    test('a missing line is added back with its figures', () {
      final added = <LineDraft>[];
      final found = check(lines: [asRead().first], addLine: added.add);
      found.single.restore();
      expect(added.single.description, 'Business Starter Usage');
      expect(added.single.quantity, 30);
      expect(added.single.unitPrice, 1.129);
    });

    test('a header field goes back through the setter it was given', () {
      var no = '';
      final found = check(supplierDocNo: '', setSupplierDocNo: (v) => no = v);
      found.single.restore();
      expect(no, '5665871390');
    });
  });

  group('the dialog', () {
    /// Opens the dialog and hands back the list the button handler
    /// appends to.
    ///
    /// Not a helper that RETURNS the answer: that returns before
    /// anybody has pressed anything, and then every tester call after
    /// it collides with the pump it never finished. `docs/widget-tests.md`
    /// lists this one.
    Future<List<Set<String>?>> open(
      WidgetTester tester,
      List<PaperDifference> found,
    ) async {
      final answers = <Set<String>?>[];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  final got = await askWhatToRestore(
                    context,
                    differences: found,
                    fileName: '5665871390.pdf',
                  );
                  answers.add(got);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return answers;
    }

    List<PaperDifference> two() {
      final lines = asRead();
      lines[0].unitPrice = 0;
      lines[1].description = 'Something else';
      return check(lines: lines);
    }

    testWidgets('nothing is ticked to begin with', (tester) async {
      final found = two();
      await open(tester, found);
      // The button that puts things back is unusable until something is
      // chosen, so the obvious press cannot change the document.
      final apply = tester.widget<FilledButton>(
        find.byKey(const Key('recheck-apply')),
      );
      expect(apply.onPressed, isNull);
      expect(find.text('Put back'), findsOneWidget);
    });

    testWidgets('one at a time, which is what was asked for',
        (tester) async {
      final found = two();
      final answers = await open(tester, found);

      await tester.tap(find.byKey(Key('recheck-take-${found.first.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Put back 1'), findsOneWidget);

      await tester.tap(find.byKey(const Key('recheck-apply')));
      await tester.pumpAndSettle();
      expect(answers.single, {found.first.id});
    });

    testWidgets('both sides of every difference are on screen',
        (tester) async {
      final found = two();
      await open(tester, found);
      for (final d in found) {
        expect(find.byKey(Key('recheck-now-${d.id}')), findsOneWidget);
        expect(find.byKey(Key('recheck-paper-${d.id}')), findsOneWidget);
      }
      expect(find.text('0.00'), findsOneWidget);
      expect(find.text('2.26'), findsOneWidget);
    });

    testWidgets('leaving it alone returns nothing to do', (tester) async {
      final answers = await open(tester, two());
      await tester.tap(find.byKey(const Key('recheck-ignore')));
      await tester.pumpAndSettle();
      expect(answers.single, isEmpty);
    });

    testWidgets('tick everything is offered, and is not the default',
        (tester) async {
      final found = two();
      final answers = await open(tester, found);
      await tester.tap(find.byKey(const Key('recheck-take-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('recheck-apply')));
      await tester.pumpAndSettle();
      expect(answers.single, found.map((d) => d.id).toSet());
    });

    testWidgets('a single difference is not offered a tick-everything',
        (tester) async {
      final found = check(supplierDocNo: 'WRONG');
      await open(tester, found);
      expect(find.byKey(const Key('recheck-take-all')), findsNothing);
    });

    testWidgets('a missing line says it is not there', (tester) async {
      final found = check(lines: [asRead().first]);
      await open(tester, found);
      expect(find.text('Not there'), findsOneWidget);
      expect(find.textContaining('missing from the document'), findsOneWidget);
    });
  });
}
