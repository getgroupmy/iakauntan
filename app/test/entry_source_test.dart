import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/documents/document_editor.dart';
import 'package:iakauntan/src/features/shared/attachments_card.dart';

/// "AI Scan", beside the status, on a record a model filled in.
///
///     all entry which are created with AI SmartScan will be tagged as
///     "AI Scan" in the background database and in any where that shows
///     posted draft overdue complete it should show "Ai Scan" beside it
///     also
///
/// A bill somebody typed off a PDF and a bill a model read off the same
/// PDF were the same row in every list in this product. The second is
/// the one worth a second look: a reader that mistakes 1,086.12 for
/// 1,086.72 produces a document that balances, posts and reconciles to
/// nothing.
///
/// The assertion that matters most is the silence. This appears beside
/// the status on every document, expense and contact in the company, so
/// a chip that showed on a typed row would be on nearly every row in
/// the system and would mean nothing within a week.

/// A saved bill with no lines, so a reading can fill it in.
class _FakeRepo implements Repo {
  _FakeRepo({this.source, this.empty = false});

  final String? source;

  /// A saved bill with no lines yet, which is what one looks like when
  /// the paper is attached and read into it.
  final bool empty;

  Map<String, dynamic> savedHeader = const {};

  @override
  String get orgId => 'org-1';

  @override
  Future<BusinessDocument> document(DocKind kind, String id) async =>
      BusinessDocument(
        id: id,
        docType: 'bill',
        docNo: 'BILL-2026-00016',
        docDate: DateTime(2026, 9, 24),
        contactId: 'c-1',
        entrySource: source,
        lines: empty
            ? const []
            : [
                DocumentLine.fromJson(const {
                  'id': 'l-1',
                  'line_no': 1,
                  'item_id': 'i-1',
                  'description': 'Bayaran KWSP',
                  'quantity': 1,
                  'unit_price': 1320,
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
    savedHeader = header;
    return (id: id ?? 'doc-1', docNo: 'BILL-2026-00016');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Widget host(Widget child) => MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: Center(child: child)),
      );

  group('the chip', () {
    testWidgets('says AI Scan on a record a reader filled in',
        (tester) async {
      await tester.pumpWidget(host(const EntrySourceChip('ai_smartscan')));
      expect(find.text('AI Scan'), findsOneWidget);
      expect(find.byKey(const Key('entry-source-chip')), findsOneWidget);
    });

    testWidgets('and nothing at all on one a person typed', (tester) async {
      await tester.pumpWidget(host(const EntrySourceChip(null)));
      expect(find.byKey(const Key('entry-source-chip')), findsNothing);
      expect(find.text('AI Scan'), findsNothing);
    });

    testWidgets('a source this version does not know stays silent',
        (tester) async {
      // Rather than a chip with a raw column value in it. The database
      // refuses an unknown value outright; this is what the screen does
      // if one ever arrives from a newer server.
      await tester.pumpWidget(host(const EntrySourceChip('telepathy')));
      expect(find.byKey(const Key('entry-source-chip')), findsNothing);
    });

    test('what each source is called', () {
      expect(EntrySourceChip.labelFor('ai_smartscan'), 'AI Scan');
      expect(EntrySourceChip.labelFor(null), isNull);
      expect(EntrySourceChip.labelFor('telepathy'), isNull);
    });

    testWidgets('it explains itself to somebody who has not seen it',
        (tester) async {
      await tester.pumpWidget(host(const EntrySourceChip('ai_smartscan')));
      final tip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tip.message, contains('AI SmartScan'));
      expect(tip.message, contains('against the paper'));
    });
  });


  /// And that the bill itself carries it.
  ///
  /// Every test above passes with the editor never reading the column,
  /// never showing it and never sending it back — which is three ways
  /// for a scanned bill to look exactly like a typed one.
  group('on the bill', () {
    Widget editor(_FakeRepo repo) => ProviderScope(
          overrides: [
            repoProvider.overrideWithValue(repo),
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
            documentScanTotalsProvider.overrideWith((ref, args) async => null),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const DocumentEditor(docType: 'bill', documentId: 'doc-1'),
          ),
        );

    Future<void> open(WidgetTester tester, _FakeRepo repo) async {
      tester.view.physicalSize = const Size(1400, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(editor(repo));
      await tester.pumpAndSettle();
    }

    testWidgets('a stored bill shows the tag and sends it back',
        (tester) async {
      final repo = _FakeRepo(source: 'ai_smartscan');
      await open(tester, repo);

      expect(find.text('AI Scan'), findsOneWidget);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.savedHeader['entry_source'], 'ai_smartscan');
    });

    testWidgets('a bill somebody typed shows nothing', (tester) async {
      final repo = _FakeRepo();
      await open(tester, repo);
      expect(find.text('AI Scan'), findsNothing);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.savedHeader.containsKey('entry_source'), isTrue);
      expect(repo.savedHeader['entry_source'], isNull);
    });

    testWidgets('reading the paper into it tags it', (tester) async {
      // `record_scan_posting` stamps the record where a READING BECOMES
      // one. This is the other path and the one the report came from: a
      // bill that already existed, whose lines a reading filled in.
      // Nothing calls that function here, so the editor has to.
      final repo = _FakeRepo(empty: true);
      await open(tester, repo);
      expect(find.text('AI Scan'), findsNothing);

      final card = tester.widget<AttachmentsCard>(
        find.byType(AttachmentsCard),
      );
      card.onExtracted!(const OcrExtraction(
        totalAmount: 1320,
        lines: [
          OcrLine(
            description: 'September 2023 payment',
            quantity: 1,
            unitPrice: 1320,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      // The chip, not the save: a reading fills lines in with no ITEM
      // on them, and the editor refuses to save a line that names none.
      expect(find.text('AI Scan'), findsOneWidget);
    });
  });

  group('what the record carries', () {
    test('a bill a reader filled in says so', () {
      final doc = BusinessDocument.fromJson(const {
        'id': 'd-1',
        'doc_type': 'bill',
        'doc_no': 'BILL-2026-00016',
        'doc_date': '2026-09-24',
        'contact_id': 'c-1',
        'entry_source': 'ai_smartscan',
      });
      expect(doc.entrySource, 'ai_smartscan');
    });

    test('and one somebody typed carries nothing', () {
      final doc = BusinessDocument.fromJson(const {
        'id': 'd-2',
        'doc_type': 'bill',
        'doc_no': 'BILL-2026-00017',
        'doc_date': '2026-09-24',
        'contact_id': 'c-1',
      });
      expect(doc.entrySource, isNull);
    });

    test('a contact a reader made from a letterhead says so', () {
      final c = Contact.fromJson(const {
        'id': 'c-1',
        'code': 'S-1',
        'name': 'KWSP',
        'contact_type': 'supplier',
        'entry_source': 'ai_smartscan',
      });
      expect(c.entrySource, 'ai_smartscan');
      // And it survives the one place a contact is rebuilt by hand.
      expect(c.withCode('S-2').entrySource, 'ai_smartscan');
    });
  });
}
