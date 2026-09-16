import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/ledger/journals_screen.dart';

/// The general ledger, as journals.
///
/// Everything posts through `create_gl_entry`, so this is the one screen
/// where an invoice, a payroll run and a hand-written correction can be
/// compared side by side. Three things live only in this widget.
///
/// WHICH COLUMN A FIGURE LANDS IN. Debit and credit are two Expanded
/// cells side by side holding the same `Money` widget, and swapping them
/// is a one-line change that renders a perfectly tidy journal saying the
/// opposite of what was posted. The fixture uses DIFFERENT debit and
/// credit totals so the two columns cannot be confused for each other,
/// which a balanced fixture -- the ordinary case -- would hide
/// completely.
///
/// A ZERO IS BLANK. Every line of a double-entry journal has a zero on
/// one side, and printing "RM 0.00" in both columns of every row is how
/// a ledger becomes unreadable.
///
/// AND VOID IS NOT DELETED. A reversed journal stays in the ledger,
/// struck through, still adding up -- "a ledger you can erase is not a
/// ledger" -- and it must not be offered for reversal a second time.
void main() {
  JournalLine line({
    int no = 1,
    String code = '1100',
    String name = 'Trade Debtors',
    String? description,
    double debit = 0,
    double credit = 0,
  }) =>
      JournalLine(
        lineNo: no,
        accountCode: code,
        accountName: name,
        description: description,
        debit: debit,
        credit: credit,
      );

  JournalEntry entry({
    String id = 'j1',
    String entryNo = 'JE-0001',
    String source = 'sales_invoice',
    String status = 'posted',
    String? description = 'Invoice INV-0001',
    double totalDebit = 1060,
    double totalCredit = 1060,
    bool isReversal = false,
    List<JournalLine>? lines,
  }) =>
      JournalEntry(
        id: id,
        entryNo: entryNo,
        entryDate: DateTime(2026, 8, 31),
        source: source,
        status: status,
        description: description,
        totalDebit: totalDebit,
        totalCredit: totalCredit,
        isReversal: isReversal,
        lines: lines ??
            [
              line(code: '1100', name: 'Trade Debtors', debit: 1060),
              line(no: 2, code: '4000', name: 'Sales', credit: 1000),
              line(no: 3, code: '2200', name: 'SST Payable', credit: 60),
            ],
      );

  Widget wrap(List<JournalEntry> entries, {String role = 'owner'}) =>
      ProviderScope(
        overrides: [
          journalsProvider.overrideWith((ref) async => entries),
          memberRoleProvider.overrideWith((ref) async => role),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const JournalsScreen(),
        ),
      );

  Future<void> show(
    WidgetTester tester,
    List<JournalEntry> entries, {
    String role = 'owner',
  }) async {
    await tester.pumpWidget(wrap(entries, role: role));
    await tester.pumpAndSettle();
  }

  /// Open the one journal on screen.
  Future<void> expand(WidgetTester tester, [String entryNo = 'JE-0001']) async {
    await tester.tap(find.text(entryNo));
    await tester.pumpAndSettle();
  }

  group('which column a figure lands in', () {
    testWidgets('a debit is on the left and a credit on the right',
        (tester) async {
      await show(tester, [entry()]);
      await expand(tester);

      // Read the row for the debtors line and the row for sales, and
      // check the figure is under the column it belongs to. Deliberately
      // unequal amounts: 1060 against 1000 and 60.
      expect(find.text('RM 1,060.00'), findsWidgets);
      expect(find.text('RM 1,000.00'), findsOneWidget);
      expect(find.text('RM 60.00'), findsOneWidget);

      // Four of them, and the breakdown is the point: the debtors LINE,
      // the totals row's debit, the totals row's CREDIT -- this journal
      // balances, so both sides of the total are the same figure -- and
      // the collapsed trailing summary. Which is also why the balanced
      // case cannot tell a swapped pair of columns from a correct one,
      // and why the test below uses a journal that does not balance.
      expect(find.text('RM 1,060.00'), findsNWidgets(4));
    });

    testWidgets('an unbalanced journal shows each side as it is',
        (tester) async {
      // The fixture a balanced one cannot be: if the columns were
      // swapped, or one total read from the other, this fails. A real
      // journal always balances, which is exactly why a test made only
      // of real journals cannot see the mistake.
      await show(tester, [
        entry(
          totalDebit: 900,
          totalCredit: 400,
          lines: [
            line(code: '5000', name: 'Purchases', debit: 900),
            line(no: 2, code: '2000', name: 'Trade Creditors', credit: 400),
          ],
        ),
      ]);
      await expand(tester);

      expect(find.text('RM 900.00'), findsNWidgets(3),
          reason: 'the line, the totals row and the collapsed trailing figure');
      expect(find.text('RM 400.00'), findsNWidgets(2),
          reason: 'the line and the totals row');

      // And WHERE they are, which is the whole assertion. Counting text
      // finds a figure whichever cell it sits in, so a swapped pair of
      // columns passes every count above -- it survived the mutation
      // run exactly that way.
      //
      // Tree order is fixed by the build method: the collapsed trailing
      // figure in the header first, then the line rows, then the totals
      // row.
      Offset at(String money, int i) => tester.getCenter(find.text(money).at(i));
      final debitLine = at('RM 900.00', 1);
      final creditLine = at('RM 400.00', 0);
      final debitTotal = at('RM 900.00', 2);
      final creditTotal = at('RM 400.00', 1);

      expect(debitLine.dx, lessThan(creditLine.dx),
          reason: 'the debit line sits in the left-hand column');
      // The totals row, separately: its debit and credit are a pair, and
      // reading both from the same side is its own mistake.
      expect(debitTotal.dx, lessThan(creditTotal.dx),
          reason: 'the totals row puts debit left and credit right');
      expect(debitTotal.dy, creditTotal.dy,
          reason: 'and they really are the one totals row');
    });

    testWidgets('a zero side is blank, not RM 0.00', (tester) async {
      // Every line of a double-entry journal has a zero on one side.
      await show(tester, [entry()]);
      await expand(tester);

      expect(find.text('RM 0.00'), findsNothing);
    });
  });

  group('void is not deleted', () {
    testWidgets('a voided journal is struck through and still there',
        (tester) async {
      await show(tester, [entry(status: 'void')]);

      final title = tester.widget<Text>(find.text('JE-0001'));
      expect(title.style?.decoration, TextDecoration.lineThrough);
      // Still listed, still carrying its figure: it adds up, it just no
      // longer counts.
      expect(find.text('RM 1,060.00'), findsOneWidget);
    });

    testWidgets('and is not offered for reversal again', (tester) async {
      await show(tester, [entry(status: 'void')]);
      await expand(tester);

      // On the text, not on `widgetWithText(OutlinedButton, ...)`:
      // `OutlinedButton.icon` builds a private subclass that `byType`
      // does not match, so that finder is vacuous and this assertion
      // passed against a screen that DID offer the button -- which is
      // how the mutation run caught it.
      expect(find.text('Reverse'), findsNothing);
    });

    testWidgets('a posted one is offered, to somebody who may post',
        (tester) async {
      await show(tester, [entry(status: 'posted')]);
      await expand(tester);

      expect(
        find.ancestor(
          of: find.text('Reverse'),
          matching: find.byWidgetPredicate((w) => w is OutlinedButton),
        ),
        findsOneWidget,
      );
    });

    testWidgets('and never to a viewer', (tester) async {
      // Reversing posts the mirror image into the ledger. Reading it is
      // not posting it.
      await show(tester, [entry(status: 'posted')], role: 'viewer');
      await expand(tester);

      expect(find.text('Reverse'), findsNothing);
      // The journal is still fully readable.
      expect(find.text('Trade Debtors'), findsOneWidget);
      expect(find.text('RM 1,000.00'), findsOneWidget);
    });

    testWidgets('a reversal says it is one', (tester) async {
      // Two chips: the status, and that this entry exists to undo
      // another. Without the second, a correction reads as an ordinary
      // posting to whoever finds it later.
      await show(tester, [entry(isReversal: true)]);

      expect(find.byType(StatusChip), findsNWidgets(2));
      expect(find.text('Reversal'), findsOneWidget);
    });

    testWidgets('and an ordinary one does not', (tester) async {
      await show(tester, [entry(isReversal: false)]);

      expect(find.byType(StatusChip), findsOneWidget);
      expect(find.text('Reversal'), findsNothing);
    });
  });

  group('what the row says', () {
    testWidgets('the date, where it came from, and what it was for',
        (tester) async {
      await show(tester, [
        entry(source: 'payroll', description: 'August payroll'),
      ]);

      expect(find.text('31/08/2026 · Payroll · August payroll'),
          findsOneWidget);
    });

    testWidgets('and leaves out a description it does not have',
        (tester) async {
      // The control: a journal with no description must not render a
      // trailing separator with nothing after it.
      await show(tester, [entry(source: 'payroll', description: null)]);

      expect(find.text('31/08/2026 · Payroll'), findsOneWidget);
    });

    testWidgets('a line carries its account code and name', (tester) async {
      await show(tester, [
        entry(lines: [
          line(code: '1100', name: 'Trade Debtors', debit: 500,
              description: 'Puan Aminah'),
          line(no: 2, code: '4000', name: 'Sales', credit: 500),
        ]),
      ]);
      await expand(tester);

      expect(find.text('1100'), findsOneWidget);
      expect(find.text('Trade Debtors'), findsOneWidget);
      expect(find.text('Puan Aminah'), findsOneWidget);
      expect(find.text('4000'), findsOneWidget);
    });
  });

  group('filtering by where a journal came from', () {
    testWidgets('All is selected until a source is chosen', (tester) async {
      await show(tester, [entry()]);

      final all = tester.widget<FilterChip>(
          find.widgetWithText(FilterChip, 'All'));
      expect(all.selected, isTrue);

      final payroll = tester.widget<FilterChip>(
          find.widgetWithText(FilterChip, 'Payroll'));
      expect(payroll.selected, isFalse);
    });

    testWidgets('choosing one selects it and leaves All', (tester) async {
      await show(tester, [entry()]);

      await tester.tap(find.widgetWithText(FilterChip, 'Payroll'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<FilterChip>(
            find.widgetWithText(FilterChip, 'Payroll')).selected,
        isTrue,
      );
      expect(
        tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'All'))
            .selected,
        isFalse,
      );
    });

    testWidgets('and unchoosing it comes back to All', (tester) async {
      // Deselecting a chip sets the filter to null rather than leaving
      // it on a source nothing is highlighting -- a list filtered by
      // something no chip shows is the worst of both.
      await show(tester, [entry()]);

      await tester.tap(find.widgetWithText(FilterChip, 'Payroll'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, 'Payroll'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'All'))
            .selected,
        isTrue,
      );
    });
  });

  group('an empty ledger', () {
    testWidgets('says every posted document writes one', (tester) async {
      // Not "no data". A company that has posted nothing has an empty
      // ledger, and one whose journals failed to load has an empty
      // screen; the difference is worth a sentence.
      await show(tester, []);

      expect(find.text('No journals'), findsOneWidget);
      expect(find.textContaining('Every posted document writes one'),
          findsOneWidget);
    });
  });
}
