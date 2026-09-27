import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/searchable_picker.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/documents/document_editor.dart';
import 'package:iakauntan/src/features/documents/line_draft.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/expenses/expenses_screen.dart';
import 'package:iakauntan/src/features/shared/receipt_capture.dart';

/// The matter a bill, an invoice and a claim belong to.
///
/// `0687` put `matter_id` on `gl_lines`, `0688` made every posting path
/// carry it and `0690` wrote the first entries that use it. `0691` and
/// `0692` put the column on the three tables a transaction actually
/// arrives through — sales lines, purchase lines and expenses — because
/// until then a matter's own trial balance could show its journals and
/// its client money and NOT ITS FEES.
///
/// These assert the Dart half: the line has to send the key, the editor
/// has to read it back, and the claim has to carry it as far as the
/// repository. A column nothing fills is a report of zeroes, which is
/// the whole reason `0639` exists.
class _FakeRepo implements Repo {
  String? sawMatter;
  bool called = false;

  @override
  String get orgId => 'org-1';

  @override
  Future<String> recordExpense({
    required String accountId,
    required double amount,
    required DateTime date,
    String? description,
    String? contactId,
    String? bankAccountId,
    String? paymentModeCode,
    String? taxCodeId,
    double taxAmount = 0,
    String? reference,
    String? projectCode,
    String? departmentCode,
    String? matterId,
    List<Map<String, dynamic>>? split,
  }) async {
    called = true;
    sawMatter = matterId;
    return 'exp-1';
  }

  /// The lines the editor last sent to be saved.
  List<Map<String, dynamic>> savedLines = const [];

  /// And the header it sent with them.
  Map<String, dynamic> savedHeader = const {};

  /// Where the saved document carries its matter: on the header, as
  /// `bill_matter_time` leaves it, or on the line.
  bool matterOnHeaderOnly = false;

  /// A saved invoice with one line already on a matter, so the editor
  /// can be opened on it rather than typed into.
  @override
  Future<BusinessDocument> document(DocKind kind, String id) async =>
      BusinessDocument(
        id: id,
        docType: 'invoice',
        docNo: 'FN-1',
        docDate: DateTime(2026, 9, 1),
        contactId: 'c-1',
        contactName: 'Puan Aminah',
        subtotal: 100,
        totalAmount: 100,
        balanceAmount: 100,
        matterId: matterOnHeaderOnly ? 'm-1' : null,
        lines: [
          DocumentLine.fromJson({
            'id': 'l-1',
            'line_no': 1,
            // The item, because the editor refuses to save a line that
            // names none — a line carrying only typed words is one
            // nothing can cost and no report can group by.
            'item_id': 'i-1',
            'description': 'Professional fees',
            'quantity': 1,
            'unit_price': 100,
            if (!matterOnHeaderOnly) 'matter_id': 'm-1',
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
  Future<({String docNo, String id})> saveDocument({
    required DocKind kind,
    String? id,
    required String docType,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  }) async {
    savedLines = lines;
    savedHeader = header;
    return (id: id ?? 'doc-1', docNo: 'FN-1');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Matter matter({
    String id = 'm-1',
    String no = 'M-1042',
    String name = 'Sale of a house',
  }) =>
      Matter(
        id: id,
        matterNo: no,
        name: name,
        clientId: 'c-1',
        clientName: 'Puan Aminah',
        status: 'open',
      );

  group('a document line carries its matter', () {
    // `saveDocument` inserts this map straight into
    // `sales_document_lines` or `purchase_document_lines`. A key that is
    // not in it is a matter that never reaches the ledger, and the
    // document still saves and still posts and still balances.
    test('and sends it under the column name the table uses', () {
      final line = LineDraft(description: 'Professional fees', matterId: 'm-1');
      expect(line.toJson()['matter_id'], 'm-1');
    });

    // Null is how a line is cleared, and it is also the ordinary case:
    // most of what any company posts belongs to no matter at all.
    test('and sends null when there is none', () {
      expect(LineDraft(description: 'Rent').toJson().containsKey('matter_id'),
          isTrue);
      expect(LineDraft(description: 'Rent').toJson()['matter_id'], isNull);
    });

    // Reopening a saved document rebuilds its drafts from the rows. A
    // draft that dropped the matter here would clear it on the next
    // save — silently, because the editor would show no matter and the
    // save would faithfully write no matter.
    test('and keeps it when the document is reopened', () {
      final draft = LineDraft.fromLine(
        DocumentLine.fromJson(const {
          'line_no': 1,
          'description': 'Fees on the sale',
          'quantity': 1,
          'unit_price': 100,
          'matter_id': 'm-1',
        }),
      );
      expect(draft.matterId, 'm-1');
    });

    test('and reads it off the row', () {
      expect(
        DocumentLine.fromJson(const {
          'line_no': 1,
          'quantity': 1,
          'unit_price': 0,
          'matter_id': 'm-9',
        }).matterId,
        'm-9',
      );
    });
  });

  group('the invoice and bill editor', () {
    Widget wrapEditor(
      List<Matter> matters, {
      Repo? repo,
      String? documentId,
    }) =>
        ProviderScope(
          overrides: [
            // The editor's `_load` returns early when there is no repo,
            // and it is the only thing that clears `_loading` — so
            // without this the screen is a spinner for ever and every
            // assertion below is about nothing.
            repoProvider.overrideWithValue(repo ?? _FakeRepo()),
            canPostProvider.overrideWithValue(true),
            canWriteProvider.overrideWithValue(true),
            // Read with `.value`, not `valueOrNull`, so an unresolved
            // one throws while the header builds and the screen goes
            // blank rather than showing an error.
            currentOrgProvider.overrideWith((ref) async => null),
            // Every list the header reads. Each is stubbed rather than
            // left to reach Supabase, which is not initialised in a
            // test — and the editor reads several with `.value`, so one
            // unstubbed provider blanks the whole screen.
            accountsProvider.overrideWith((ref) async => <Account>[]),
            projectsProvider.overrideWith((ref) async => []),
            departmentsProvider.overrideWith((ref) async => []),
            salespeopleProvider.overrideWith((ref) async => []),
            currenciesProvider.overrideWith((ref) async => []),
            taxCodesProvider.overrideWith((ref) async => []),
            itemsProvider.overrideWith((ref, arg) async => <Item>[]),
            mattersProvider.overrideWith(
              (ref, arg) async => arg.status == 'open' ? matters : <Matter>[],
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: DocumentEditor(docType: 'invoice', documentId: documentId),
          ),
        );

    Future<void> openEditor(
      WidgetTester tester,
      List<Matter> matters, {
      Repo? repo,
      String? documentId,
    }) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          wrapEditor(matters, repo: repo, documentId: documentId));
      // Not `pumpAndSettle`: the editor draws a skeleton while the
      // company's lists load, and a shimmer never settles, so the
      // settle times out rather than telling you anything. Three frames
      // is past the first build and past the providers resolving.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // The same gate the job and the department already stand behind, and
    // it is what keeps a Matter box off every invoice in every company
    // that is not a law firm — without anything having to ask whether
    // the module is switched on.
    testWidgets('asks for no matter when the company has none',
        (tester) async {
      await openEditor(tester, const []);
      expect(find.text('Matter'), findsNothing);
    });

    testWidgets('and offers one when it has', (tester) async {
      await openEditor(tester, [matter()]);
      expect(find.text('Matter'), findsOneWidget);

      // Opened, because a picker drawn over an empty list is a control
      // that teaches people to ignore controls — and a picker filled
      // from the wrong query would draw exactly the same box. By number
      // as well as by name: a file is referred to by its number on
      // every letter and every attendance note.
      await tester.tap(find.descendant(
        of: find.ancestor(
          of: find.text('Matter'),
          matching: find.byType(SearchablePicker<String>),
        ),
        matching: find.byType(TextFormField),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('M-1042 — Sale of a house'), findsWidgets);
    });

    // Reopening a saved document, and saving it again. Two things could
    // go wrong here and neither would show on screen: the editor could
    // fail to read the matter back off the lines, and the save could
    // fail to stamp it onto them. Either one CLEARS the matter on a
    // document somebody only opened to fix a typo — silently, because
    // the editor would show no matter and the save would faithfully
    // write no matter.
    testWidgets('and keeps it when a saved document is edited again',
        (tester) async {
      final repo = _FakeRepo();
      await openEditor(tester, [matter()], repo: repo, documentId: 'doc-1');

      expect(find.text('M-1042 — Sale of a house'), findsWidgets,
          reason: 'the saved matter was not read back onto the form');

      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(repo.savedLines, isNotEmpty,
          reason: 'nothing pressed Save, so nothing was asserted');
      expect(repo.savedLines.first['matter_id'], 'm-1');
    });

    // Moving a fee note to the right file. The choice is per document
    // and the column is per line, so the save has to stamp the header's
    // matter onto every line — without that the picker changes, the
    // screen agrees, the document saves, and the ledger keeps the old
    // matter. Reading the matter back off the lines is not enough to
    // catch it: on a document that already had one, both behave the
    // same.
    testWidgets('and a fee note can be moved to another file',
        (tester) async {
      final repo = _FakeRepo();
      await openEditor(
        tester,
        [matter(), matter(id: 'm-2', no: 'M-2099', name: 'A tenancy dispute')],
        repo: repo,
        documentId: 'doc-1',
      );

      await tester.tap(find.descendant(
        of: find.ancestor(
          of: find.text('Matter'),
          matching: find.byType(SearchablePicker<String>),
        ),
        matching: find.byType(TextFormField),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('M-2099 — A tenancy dispute').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(repo.savedLines, isNotEmpty,
          reason: 'nothing pressed Save, so nothing was asserted');
      expect(repo.savedLines.first['matter_id'], 'm-2');
      // The header too, because `bill_matter_time` and the matter
      // screens read `sales_documents.matter_id`. A document whose
      // header said one file while its lines said another would be
      // right in the ledger and wrong in every list.
      expect(repo.savedHeader['matter_id'], 'm-2');
    });

    // The shape `bill_matter_time` leaves: the matter on the header and
    // on no line at all. Reading the lines alone would open this note
    // with the box empty — and then save it with the matter cleared,
    // which is worse than not showing it, because the document arrived
    // knowing its matter.
    testWidgets('and reads a fee note that carries its matter on the header',
        (tester) async {
      final repo = _FakeRepo()..matterOnHeaderOnly = true;
      await openEditor(tester, [matter()], repo: repo, documentId: 'doc-1');

      expect(find.text('M-1042 — Sale of a house'), findsWidgets,
          reason: "the header's matter never reached the form");

      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(repo.savedLines, isNotEmpty,
          reason: 'nothing pressed Save, so nothing was asserted');
      expect(repo.savedLines.first['matter_id'], 'm-1');
    });
  });

  group('the expense form', () {
    Widget wrap(List<Matter> matters, {Repo? repo}) => ProviderScope(
          overrides: [
            expensesProvider.overrideWith((ref) async => []),
            canPostProvider.overrideWithValue(true),
            accountsProvider.overrideWith((ref) async => <Account>[
              Account(
                id: 'a-1',
                code: '6100',
                name: 'Disbursements',
                accountType: 'expense',
                accountSubtype: 'operating_expense',
              ),
            ]),
            bankAccountsProvider.overrideWith((ref) async => []),
            paymentModesProvider.overrideWith((ref) async => []),
            projectsProvider.overrideWith((ref) async => []),
            departmentsProvider.overrideWith((ref) async => []),
            taxCodesProvider.overrideWith((ref) async => []),
            // Only the OPEN query answers. A form that asked for every
            // matter would be offering a file closed last year, which
            // is what `matter_closing.dart` exists to stop — and an
            // override that answered both would hide that.
            mattersProvider.overrideWith(
              (ref, arg) async => arg.status == 'open' ? matters : <Matter>[],
            ),
            if (repo != null) repoProvider.overrideWithValue(repo),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const ExpensesScreen(),
          ),
        );

    Future<void> openForm(
      WidgetTester tester,
      List<Matter> matters, {
      Repo? repo,
    }) async {
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(matters, repo: repo));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(ExpensesScreen));
      unawaited(showExpenseFromScan(
        context,
        StagedReceipt(
          attachmentId: 'att-1',
          placeholderId: 'ph-1',
          read: OcrExtraction(
            documentNo: '16851',
            documentDate: DateTime(2026, 1, 22),
            totalAmount: 120.00,
            documentKind: 'payment_voucher',
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    // The rule the job and the department already follow: a control
    // with nothing in it teaches people to skip controls. It is also
    // what keeps this off every company that is not a law firm, without
    // anything having to ask whether the module is switched on.
    testWidgets('asks for no matter when the company has none',
        (tester) async {
      await openForm(tester, const []);
      expect(find.byKey(const ValueKey('expense-matter')), findsNothing);
    });

    testWidgets('and offers the open ones when it has', (tester) async {
      await openForm(tester, [matter()]);
      expect(find.byKey(const ValueKey('expense-matter')), findsOneWidget);
      // By number as well as name. A file is referred to by its number
      // on every letter and every attendance note.
      await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('expense-matter')),
        matching: find.byType(TextFormField),
      ));
      await tester.pumpAndSettle();
      expect(find.text('M-1042 — Sale of a house'), findsOneWidget);
    });

    // The one that matters. Everything above would pass with the
    // picker drawn and `matterId` never sent — the claim would save,
    // post, balance, and reach the ledger with no matter on it, which
    // is exactly the state 0692 was written to end.
    testWidgets('and sends the chosen matter as far as the repository',
        (tester) async {
      final repo = _FakeRepo();
      await openForm(tester, [matter()], repo: repo);

      Future<void> choose(Finder picker, String option) async {
        await tester.tap(find.descendant(
          of: picker,
          matching: find.byType(TextFormField),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text(option).last);
        await tester.pumpAndSettle();
      }

      await choose(
        find.ancestor(
          of: find.text('Expense account *'),
          matching: find.byType(SearchablePicker<String>),
        ),
        '6100 — Disbursements',
      );
      await choose(
        find.byKey(const ValueKey('expense-matter')),
        'M-1042 — Sale of a house',
      );

      await tester.tap(find.text('Record and post'));
      await tester.pumpAndSettle();

      expect(repo.called, isTrue,
          reason: 'nothing pressed Save, so nothing was asserted');
      expect(repo.sawMatter, 'm-1');
    });
  });
}
