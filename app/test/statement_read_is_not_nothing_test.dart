import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/scan_kinds_repository.dart';
import 'package:iakauntan/src/features/shared/scan_all_data.dart';
import 'package:iakauntan/src/features/shared/scan_result_dialog.dart';

/// A bank statement that read perfectly, reported as unreadable.
///
///     Bank statement was sent for scanning but it did not scan and
///     recognise it, why ?
///
/// A CIMB Islamic statement — clean, digital, eight transactions and a
/// balance chain that foots — came back with "Nothing legible came
/// back" on the result dialog and "Nothing came back at all" on the
/// "All data" screen, every field showing "Not on the document".
///
/// Every one of those fields is an INVOICE's: supplier, SSM number, tax
/// number, email, phone, address, document number, subtotal, tax,
/// total. A bank statement has none of them. It has an account, a
/// period and its TRANSACTIONS, and those arrive in `rows` —
/// `scan_target_fields` asks for them by name and `bank_statement` is
/// the one destination that table is populated for.
///
/// Two screens each decided "did anything come back" for themselves,
/// and both asked the same three invoice questions. So the failure
/// reported here may well have been a reading that worked.
void main() {
  /// The statement in the report, as the reader hands it back.
  OcrExtraction statement({int howMany = 8}) => OcrExtraction(
        documentKind: 'bank_statement',
        rows: [
          for (var i = 0; i < howMany; i++)
            {
              'transaction_date': '0${i + 1}/01/2026',
              'description': 'DUITNOW TO ACCOUNT',
              'reference': 'MDN2601080087380${i}6',
              'amount': '-300.00',
              'running_balance': '1204.50',
            },
        ],
      );

  group('whether anything came back', () {
    test('a statement full of transactions is not nothing', () {
      expect(statement().foundNothing, isFalse);
    });

    test('and one transaction is not nothing either', () {
      expect(statement(howMany: 1).foundNothing, isFalse);
    });

    test('a reading with genuinely nothing on it says so', () {
      expect(const OcrExtraction().foundNothing, isTrue);
    });

    test('the three invoice questions are no longer the whole test', () {
      // The old answer: no supplier, no total, no document number means
      // nothing came back. All three are absent here and the page was
      // read in full.
      final read = statement();
      expect(read.supplierName, isNull);
      expect(read.totalAmount, isNull);
      expect(read.documentNo, isNull);
      expect(read.foundNothing, isFalse);
    });

    test('a reader that answered in columns is not nothing', () {
      // `0681`'s path: the reader is handed the destination's own
      // column names and answers with those rather than the generic
      // fields. Nothing else on the extraction is set.
      expect(
        const OcrExtraction(fields: {'transaction_date': '05/01/2026'})
            .foundNothing,
        isFalse,
      );
    });

    test('columns that came back empty are still nothing', () {
      // A key with no value is the reader saying "not on the page",
      // which is not content.
      expect(
        const OcrExtraction(fields: {'transaction_date': '  '}).foundNothing,
        isTrue,
      );
    });

    test('raw page text is not nothing', () {
      expect(
        const OcrExtraction(rawText: 'CIMB ISLAMIC').foundNothing,
        isFalse,
      );
    });

    test('a receipt with only a total is not nothing', () {
      // The ordinary case the old test was built for, still right.
      expect(const OcrExtraction(totalAmount: 23.45).foundNothing, isFalse);
    });

    test('a date alone is not nothing', () {
      // Was not among the three, so a document where the date was the
      // only legible thing reported as unreadable.
      expect(
        OcrExtraction(documentDate: DateTime(2026, 1, 31)).foundNothing,
        isFalse,
      );
    });
  });

  group('what the All data screen lists', () {
    test('the transactions, one line each', () {
      final lines = allDataLines(statement(howMany: 3));
      expect(lines.length, 3);
      expect(lines.first, contains('DUITNOW TO ACCOUNT'));
      expect(lines.first, contains('-300.00'));
    });

    test('and it listed none of them before', () {
      // The reported screen: thirteen labels reading "Still empty" over
      // "Nothing came back at all", about a page with eight
      // transactions on it.
      expect(allDataLines(const OcrExtraction()), isEmpty);
    });

    test('the columns are in a settled order', () {
      // A map has no order. A list that reshuffles between openings is
      // one nobody can check against the paper.
      final once = allDataLines(statement(howMany: 1)).single;
      final twice = allDataLines(statement(howMany: 1)).single;
      expect(once, twice);
      // Sorted by key: amount, description, reference, running_balance,
      // transaction_date.
      expect(once.startsWith('-300.00  DUITNOW'), isTrue);
    });

    test('an empty column is not a gap in the line', () {
      final lines = allDataLines(const OcrExtraction(rows: [
        {'amount': '40.00', 'reference': '', 'description': 'TNG RELOAD'},
      ]));
      expect(lines.single, '40.00  TNG RELOAD');
    });

    test('raw page text still wins where there is any', () {
      // A reader that returns the text of the page is showing what it
      // SAW; the rows are what it made of it. The text is the better
      // thing to correct against.
      final lines = allDataLines(const OcrExtraction(
        rawText: 'OPENING BALANCE  504.50',
        rows: [{'amount': '40.00'}],
      ));
      expect(lines, ['OPENING BALANCE  504.50']);
    });
  });

  group('what the result dialog says', () {
    Widget scoped(Widget child) => ProviderScope(
          overrides: [
            offeredScanKindsProvider.overrideWith(
              (ref) async => const [
                ScanKind(
                  code: 'bank_statement',
                  label: 'Bank statement',
                  destination: 'bank_import',
                  hint: 'Goes to the reconciliation screen.',
                  sortOrder: 35,
                ),
                ScanKind(
                    code: 'other', label: 'Something else', sortOrder: 999),
              ],
            ),
          ],
          child: child,
        );

    Future<void> open(WidgetTester tester, OcrExtraction read) async {
      await tester.pumpWidget(scoped(MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showScanResult(context, read, canApply: true),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('a statement is not reported as unreadable', (tester) async {
      await open(tester, statement());
      expect(find.textContaining('Nothing legible came back'), findsNothing);
    });

    testWidgets('and it says how many transactions came back',
        (tester) async {
      await open(tester, statement());
      expect(find.byKey(const ValueKey('scan-rows-read')), findsOneWidget);
      expect(
        find.text('8 transactions were read off this statement.'),
        findsOneWidget,
      );
    });

    testWidgets('one transaction is one, not 1', (tester) async {
      await open(tester, statement(howMany: 1));
      expect(
        find.text('One transaction was read off this statement.'),
        findsOneWidget,
      );
    });

    testWidgets('a page nothing was read off still says so', (tester) async {
      await open(tester, const OcrExtraction());
      expect(find.textContaining('Nothing legible came back'), findsOneWidget);
      expect(find.byKey(const ValueKey('scan-rows-read')), findsNothing);
    });

    testWidgets('and a receipt says nothing about transactions',
        (tester) async {
      await open(tester, const OcrExtraction(
        supplierName: 'Kedai Kopi',
        totalAmount: 23.45,
      ));
      expect(find.byKey(const ValueKey('scan-rows-read')), findsNothing);
      expect(find.textContaining('Nothing legible came back'), findsNothing);
    });
  });
}
