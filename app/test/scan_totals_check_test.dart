import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/documents/document_editor.dart';
import 'package:iakauntan/src/features/documents/scan_totals_check.dart';

/// What the paper said, against what the lines come to.
///
/// The report this answers: "in some cases the tax is calculated in
/// total instead of in single item". It is calculated per line here and
/// that is not changing — MyInvois requires tax per line item and the
/// header figure is derived from the lines by trigger — so what was
/// missing is the CHECK, and these are its two halves.
///
/// The pure half decides WHETHER the two disagree, and the three
/// answers that are not "they differ" are the ones worth asserting: no
/// paper at all, a figure the reader did not find, and a difference too
/// small to be one. Each of those, got wrong, puts a warning on a
/// document that is perfectly fine — and a warning that shows on
/// everything is one nobody reads by the second week.

/// A saved bill with one line, so the editor has totals to disagree
/// with. Everything else the editor asks for is stubbed in [_wrap].
class _FakeRepo implements Repo {
  @override
  String get orgId => 'org-1';

  @override
  Future<BusinessDocument> document(DocKind kind, String id) async =>
      BusinessDocument(
        id: id,
        docType: 'bill',
        docNo: 'BILL-2026-00013',
        docDate: DateTime(2026, 9, 1),
        contactId: 'c-1',
        contactName: 'Google Asia Pacific',
        subtotal: 1077.99,
        totalAmount: 1077.99,
        balanceAmount: 1077.99,
        lines: [
          DocumentLine.fromJson(const {
            'id': 'l-1',
            'line_no': 1,
            'item_id': 'i-1',
            'description': 'Langganan bulanan',
            'quantity': 1,
            'unit_price': 1077.99,
          }),
        ],
      );

  @override
  Future<Map<String, List<Map<String, dynamic>>>> lotsForDocument({
    required DocKind kind,
    required List<String> lineIds,
  }) async =>
      const {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  ScanTotals paper({double? subtotal, double? tax, double? total}) =>
      ScanTotals(
        scanId: 's-1',
        readAt: DateTime(2026, 9, 24),
        fileName: 'bil.pdf',
        subtotal: subtotal,
        tax: tax,
        total: total,
      );

  group('whether the paper and the lines disagree', () {
    test('the reported case: one tax figure for the whole bill', () {
      // 1077.99 at 8% is 86.2392 on one line, and the same money split
      // across lines each rounded to the sen is a few sen off. This is
      // the ordinary difference and it is still worth saying.
      final found = totalsDisagreement(
        paper: paper(subtotal: 1077.99, tax: 86.24, total: 1164.23),
        subtotal: 1077.99,
        tax: 86.21,
        total: 1164.20,
      );
      expect(found.map((d) => d.part),
          [TotalPart.tax, TotalPart.total]);
      expect(found.first.paper, 86.24);
      expect(found.first.lines, 86.21);
      expect(found.first.by, closeTo(0.03, 0.0001));
    });

    test('a document nobody scanned says nothing', () {
      // Not zeroes. "No paper" and "the paper said zero" are different
      // answers, and confusing them warns about every typed-in bill.
      expect(
        totalsDisagreement(
            paper: null, subtotal: 100, tax: 8, total: 108),
        isEmpty,
      );
    });

    test('a figure the reader did not find is not a difference', () {
      // A delivery order with no total printed on it. Treating the
      // missing figure as zero would report the whole document as out.
      final found = totalsDisagreement(
        paper: paper(subtotal: 100, tax: null, total: null),
        subtotal: 100,
        tax: 8,
        total: 108,
      );
      expect(found, isEmpty);
    });

    test('agreement is silence', () {
      expect(
        totalsDisagreement(
          paper: paper(subtotal: 100, tax: 8, total: 108),
          subtotal: 100,
          tax: 8,
          total: 108,
        ),
        isEmpty,
      );
    });

    test('under half a sen is agreement', () {
      // Both sides are money already rounded to the cent; what is left
      // is floating point, not a discrepancy.
      final found = totalsDisagreement(
        paper: paper(subtotal: 100, tax: 8, total: 108),
        subtotal: 100.004,
        tax: 7.9961,
        total: 108,
      );
      expect(found, isEmpty);
    });

    test('half a sen is a difference', () {
      final found = totalsDisagreement(
        paper: paper(tax: 8.01),
        subtotal: 100,
        tax: 8.0,
        total: 108.01,
      );
      expect(found.single.part, TotalPart.tax);
    });

    test('the lines being the larger figure is still a difference', () {
      // Signed the other way: a line on 8% where the paper charged 6%.
      final found = totalsDisagreement(
        paper: paper(tax: 6),
        subtotal: 100,
        tax: 8,
        total: 108,
      );
      expect(found.single.by, closeTo(-2, 0.0001));
    });

    test('all three can disagree at once', () {
      final found = totalsDisagreement(
        paper: paper(subtotal: 200, tax: 16, total: 216),
        subtotal: 100,
        tax: 8,
        total: 108,
      );
      expect(found.map((d) => d.part),
          [TotalPart.subtotal, TotalPart.tax, TotalPart.total]);
    });

    test('how far out is the worst of them, not their sum', () {
      // Three views of one document. Adding them reports a bill that is
      // a sen out as being three sen out.
      final found = totalsDisagreement(
        paper: paper(subtotal: 100.01, tax: 8.01, total: 108.02),
        subtotal: 100,
        tax: 8,
        total: 108,
      );
      expect(worstDifference(found), closeTo(0.02, 0.0001));
    });

    test('nothing out is nothing out', () {
      expect(worstDifference(const []), 0);
    });

    test('the sentence names both figures and the currency', () {
      final found = totalsDisagreement(
        paper: paper(tax: 86.24),
        subtotal: 1077.99,
        tax: 86.21,
        total: 1164.20,
      );
      expect(
        differenceSentence(found.single, currency: 'MYR'),
        'The paper says tax RM 86.24; these lines come to RM 86.21.',
      );
    });
  });

  group('the banner', () {
    Widget host({
      ScanTotals? read,
      double subtotal = 1077.99,
      double tax = 86.21,
      double total = 1164.20,
    }) =>
        ProviderScope(
          overrides: [
            documentScanTotalsProvider.overrideWith((ref, args) async => read),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: ScanTotalsBanner(
                table: 'purchase_documents',
                recordId: 'doc-1',
                subtotal: subtotal,
                tax: tax,
                total: total,
                currency: 'MYR',
              ),
            ),
          ),
        );

    testWidgets('says what the paper said and what the lines come to',
        (tester) async {
      await tester.pumpWidget(host(
        read: paper(subtotal: 1077.99, tax: 86.24, total: 1164.23),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('scan-totals-banner')), findsOneWidget);
      expect(find.byKey(const Key('scan-totals-tax')), findsOneWidget);
      expect(
        find.text('The paper says tax RM 86.24; '
            'these lines come to RM 86.21.'),
        findsOneWidget,
      );
      // And which file it is disputing, because a document can have
      // several and only one of them was read.
      expect(find.textContaining('bil.pdf'), findsOneWidget);
    });

    testWidgets('a figure that agrees is not listed', (tester) async {
      await tester.pumpWidget(host(
        read: paper(subtotal: 1077.99, tax: 86.24, total: 1164.23),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-totals-subtotal')), findsNothing);
    });

    testWidgets('nothing read, nothing shown', (tester) async {
      await tester.pumpWidget(host(read: null));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-totals-banner')), findsNothing);
    });

    testWidgets('agreement shows nothing', (tester) async {
      await tester.pumpWidget(host(
        read: paper(subtotal: 1077.99, tax: 86.21, total: 1164.20),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-totals-banner')), findsNothing);
    });

    testWidgets('nothing is shown while the answer is still coming',
        (tester) async {
      // A read that has not landed yet. A banner that flashed "does not
      // tie" on every open, then took it back once the figures arrived,
      // would be read as the document being wrong.
      final answer = Completer<ScanTotals?>();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          documentScanTotalsProvider.overrideWith((ref, args) => answer.future),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: ScanTotalsBanner(
              table: 'purchase_documents',
              recordId: 'doc-1',
              subtotal: 1077.99,
              tax: 86.21,
              total: 1164.20,
              currency: 'MYR',
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(find.byKey(const Key('scan-totals-banner')), findsNothing);

      answer.complete(paper(subtotal: 1077.99, tax: 86.24, total: 1164.23));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-totals-banner')), findsOneWidget);
    });
  });


  /// And that it is actually ON the document.
  ///
  /// The banner's own tests would all pass with it deleted from
  /// `document_editor.dart` — `docs/widget-tests.md` lists that as the
  /// first of the ten ways a green test covers a broken screen, and it
  /// is the reason this group opens the editor rather than the widget.
  group('on the bill itself', () {
    /// What the editor actually asked the database for. A banner that
    /// is on the screen but asking about the wrong table describes some
    /// other document, and looks exactly like one that is right.
    final asked = <({String table, String recordId})>[];

    Widget editor({ScanTotals? read, String? documentId = 'doc-1'}) =>
        ProviderScope(
          overrides: [
            repoProvider.overrideWithValue(_FakeRepo()),
            canPostProvider.overrideWithValue(true),
            canWriteProvider.overrideWithValue(true),
            currentOrgProvider.overrideWith((ref) async => null),
            accountsProvider.overrideWith((ref) async => <Account>[]),
            projectsProvider.overrideWith((ref) async => []),
            departmentsProvider.overrideWith((ref) async => []),
            salespeopleProvider.overrideWith((ref) async => []),
            currenciesProvider.overrideWith((ref) async => []),
            taxCodesProvider.overrideWith((ref) async => []),
            itemsProvider.overrideWith((ref, arg) async => <Item>[]),
            mattersProvider.overrideWith((ref, arg) async => <Matter>[]),
            documentScanTotalsProvider.overrideWith((ref, args) async {
              asked.add(args);
              return read;
            }),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: DocumentEditor(docType: 'bill', documentId: documentId),
          ),
        );

    testWidgets('a saved bill that does not tie says so', (tester) async {
      tester.view.physicalSize = const Size(1400, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(editor(
        read: ScanTotals(
          scanId: 's-1',
          readAt: DateTime(2026, 9, 24),
          fileName: 'bil.pdf',
          subtotal: 1077.99,
          tax: 86.24,
          total: 1164.23,
        ),
      ));
      await tester.pumpAndSettle();

      // The line carries no tax code, so the lines come to zero tax on
      // a bill whose paper charged RM 86.24. That is the reported case
      // at its worst and the editor showed nothing at all about it.
      expect(find.byKey(const Key('scan-totals-banner')), findsOneWidget);
      expect(find.byKey(const Key('scan-totals-tax')), findsOneWidget);

      // And it asked about THIS bill. `purchase_documents`, because a
      // bill's paperwork is filed against the buying table — asking the
      // sales one would answer about whatever document happens to share
      // the id.
      expect(asked.single.table, 'purchase_documents');
      expect(asked.single.recordId, 'doc-1');
    });

    testWidgets('a bill nobody scanned is quiet', (tester) async {
      tester.view.physicalSize = const Size(1400, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(editor(read: null));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-totals-banner')), findsNothing);
    });

    testWidgets('a document not yet saved has nothing to compare',
        (tester) async {
      // The reading hangs off an attachment and an attachment hangs off
      // a record id, so there is no answer to ask for — and asking with
      // a null id is how `widget.documentId!` throws.
      tester.view.physicalSize = const Size(1400, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(editor(
        documentId: null,
        read: ScanTotals(
          scanId: 's-1',
          readAt: DateTime(2026, 9, 24),
          fileName: 'bil.pdf',
          tax: 86.24,
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-totals-banner')), findsNothing);
    });
  });

  group('what comes back off the function', () {
    test('reads the row 0705 returns', () {
      final t = ScanTotals.fromJson(const {
        'scan_id': 's-9',
        'read_at': '2026-09-24T10:00:00Z',
        'file_name': 'bil.pdf',
        'subtotal': 1077.99,
        'tax_amount': 86.24,
        'total': 1164.23,
      });
      expect(t.scanId, 's-9');
      expect(t.fileName, 'bil.pdf');
      expect(t.tax, 86.24);
      expect(t.total, 1164.23);
      expect(t.hasFigures, isTrue);
    });

    test('figures that arrive as strings are still figures', () {
      // `numeric` over the wire is a string more often than not.
      final t = ScanTotals.fromJson(const {
        'scan_id': 's-9',
        'file_name': 'bil.pdf',
        'subtotal': '1077.99',
        'tax_amount': '86.24',
        'total': '1164.23',
      });
      expect(t.subtotal, 1077.99);
      expect(t.tax, 86.24);
    });

    test('a page with no totals on it has nothing to compare', () {
      final t = ScanTotals.fromJson(const {
        'scan_id': 's-9',
        'file_name': 'nota.pdf',
      });
      expect(t.hasFigures, isFalse);
      expect(
        totalsDisagreement(paper: t, subtotal: 100, tax: 8, total: 108),
        isEmpty,
      );
    });
  });
}
