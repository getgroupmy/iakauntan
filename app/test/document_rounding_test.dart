import 'package:flutter_test/flutter_test.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/documents/document_editor.dart';
import 'package:iakauntan/src/features/documents/line_draft.dart';
import 'package:iakauntan/src/features/documents/scan_totals_check.dart';
import 'package:iakauntan/src/features/shared/attachments_card.dart';

/// Which rounding the supplier's paper applied.
///
/// Reported with the supplier's own PDF attached: a Google tax invoice
/// whose printed total is MYR 1,173.01 became RM 1,173.00 in this
/// system, with a one sen rounding adjustment nobody on either side of
/// the bill had made.
///
///     supplier invoice scanned in with no round up or round down, make
///     round up or round down automatic but not for all cases AI
///     SmartScan should be smart enough to identify
///
/// Bank Negara's rounding mechanism exists because there is no one sen
/// coin: it rounds the amount payable in CASH at a counter. A bill
/// settled by transfer, card or on credit terms is paid to the sen. But
/// `organizations.rounding_method` is one switch for the whole company,
/// so a company that takes cash — which is why the switch is on — had
/// that setting restating every supplier bill it received.
///
/// The paper settles it, with a printed figure rather than a guess. The
/// assertions that matter most are the ones where it answers NOTHING:
/// a wrong guess here silently overrides a company setting on a
/// document nobody looked at.

/// A saved bill with the reported figures on it.
///
/// One line at 1,086.12 net and 8% tax, which is the Google invoice
/// collapsed to a single line: net 1,086.12, tax 86.89, gross 1,173.01.
class _FakeRepo implements Repo {
  _FakeRepo({this.method, this.empty = false});

  /// What the stored document says about rounding.
  final String? method;

  /// A saved document with no lines on it yet, which is what a bill
  /// looks like when the paper is attached and read into it.
  final bool empty;

  /// The header the editor last sent to be saved.
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
        contactName: 'Google Asia Pacific Pte. Ltd.',
        roundingMethod: method,
        lines: empty ? const [] : [
          DocumentLine.fromJson(const {
            'id': 'l-1',
            'line_no': 1,
            'item_id': 'i-1',
            'description': 'Google Workspace Business Starter',
            'quantity': 1,
            'unit_price': 1086.12,
            'tax_rate': 8,
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
  group('what the paper rounded to', () {
    test('the reported invoice: MYR 1,173.01, not rounded', () {
      // Subtotal 1,086.12 + service tax 8% 86.89 = 1,173.01, and that
      // is what Google printed. Rounding to 5 sen would have made it
      // 1,173.00 and left the supplier's statement a sen short for ever.
      expect(
        roundingThePaperApplied(paperTotal: 1173.01, rawTotal: 1173.01),
        'none',
      );
    });

    test('a cash receipt that printed its own adjustment', () {
      // The lines come to 23.47 and the till printed 23.45. That is the
      // mechanism working as intended, and this document should keep
      // rounding.
      expect(
        roundingThePaperApplied(paperTotal: 23.45, rawTotal: 23.47),
        'nearest_5cent',
      );
    });

    test('and one that rounds to ten sen', () {
      expect(
        roundingThePaperApplied(paperTotal: 23.50, rawTotal: 23.47),
        'nearest_10cent',
      );
    });

    test('a total already on a 5 sen boundary decides nothing', () {
      // 23.45 under every method is 23.45. Answering 'none' here would
      // override the company's setting on no evidence at all — and on
      // the most ordinary document there is.
      expect(
        roundingThePaperApplied(paperTotal: 23.45, rawTotal: 23.45),
        isNull,
      );
    });

    test('a whole ringgit decides nothing either', () {
      expect(
        roundingThePaperApplied(paperTotal: 100, rawTotal: 100),
        isNull,
      );
    });

    test('a paper the lines do not tie to decides nothing', () {
      // No method takes 1,173.01 to 1,200.00. Something else is wrong
      // with this document and `0705`'s banner is what says so;
      // inventing a rounding method would bury it.
      expect(
        roundingThePaperApplied(paperTotal: 1200, rawTotal: 1173.01),
        isNull,
      );
    });

    test('no total was read, so nothing is decided', () {
      expect(
        roundingThePaperApplied(paperTotal: null, rawTotal: 1173.01),
        isNull,
      );
    });

    test('a sen out is not a rounding method', () {
      // 1,173.02 is neither the raw figure nor any rounding of it.
      expect(
        roundingThePaperApplied(paperTotal: 1173.02, rawTotal: 1173.01),
        isNull,
      );
    });

    test('a reader that kept the extra decimals still reads as unrounded',
        () {
      // 1,086.12 at 8% is 1,173.0096 before anybody rounds it, and a
      // reader that returns its own arithmetic rather than the printed
      // string hands back exactly that. Half a sen of tolerance is what
      // makes that the same answer as 1,173.01 — compared for exact
      // equality it decides nothing, and the bill goes back to
      // RM 1,173.00.
      expect(
        roundingThePaperApplied(paperTotal: 1173.0096, rawTotal: 1173.01),
        'none',
      );
    });

    test('rounding up is read as readily as rounding down', () {
      // .03 goes up to .05 under the mechanism; the reported case went
      // down. A check written only around subtraction would miss this.
      expect(
        roundingThePaperApplied(paperTotal: 10.05, rawTotal: 10.03),
        'nearest_5cent',
      );
    });
  });

  group('what each method comes to', () {
    test('to the sen', () {
      expect(roundedTo(1173.014, 'none'), 1173.01);
    });

    test('to the nearest five sen, both directions', () {
      expect(roundedTo(1173.01, 'nearest_5cent'), 1173.00);
      expect(roundedTo(10.03, 'nearest_5cent'), 10.05);
    });

    test('to the nearest ten sen', () {
      expect(roundedTo(23.47, 'nearest_10cent'), 23.50);
      expect(roundedTo(23.44, 'nearest_10cent'), 23.40);
    });

    test('a method nobody implements falls back to the sen', () {
      // The database refuses one of these outright; this is what the
      // screen does while it is being typed.
      expect(roundedTo(1173.014, 'nearest_ringgit'), 1173.01);
    });

    test('the three the database accepts, and only those', () {
      expect(roundingMethods, ['none', 'nearest_5cent', 'nearest_10cent']);
    });
  });

  group('how it reads on the totals card', () {
    test('none is a rounding method, and says what it means', () {
      expect(roundingMethodSaid('none'),
          'The paper does not round — this totals to the sen.');
    });

    test('and each of the other two names its own step', () {
      expect(roundingMethodSaid('nearest_5cent'),
          'The paper rounds to the nearest 5 sen.');
      expect(roundingMethodSaid('nearest_10cent'),
          'The paper rounds to the nearest 10 sen.');
    });
  });


  group('over the lines a reading actually produced', () {
    // The seam the editor calls. What is asserted here is the
    // arithmetic in between: the lines a reading produced have to add
    // up the way the database will add them up, tax and all, or the
    // method is decided against the wrong figure.
    test('the reported invoice, as four lines with tax on each', () {
      // The four Google Workspace usage lines off the PDF, at 8%.
      // 65.48 + 33.87 + 770.00 + 216.77 = 1,086.12 net, and the paper
      // says 1,173.01 gross.
      final lines = [
        for (final net in [65.48, 33.87, 770.00, 216.77])
          LineDraft(description: 'Usage', unitPrice: net, taxRate: 8),
      ];
      expect(
        roundingForLines(paperTotal: 1173.01, lines: lines),
        'none',
      );
    });

    test('a till receipt keeps rounding', () {
      final lines = [LineDraft(description: 'Nasi lemak', unitPrice: 23.47)];
      expect(
        roundingForLines(paperTotal: 23.45, lines: lines),
        'nearest_5cent',
      );
    });

    test('a second reading that cannot say leaves the first answer', () {
      // Re-scanning with another reader is ordinary since `0698`. One
      // that returns no total must not undo what the first one decided.
      expect(
        roundingForLines(
          paperTotal: null,
          lines: [LineDraft(description: 'Usage', unitPrice: 100)],
          current: 'none',
        ),
        'none',
      );
    });

    test('and with nothing decided before, it stays undecided', () {
      expect(
        roundingForLines(
          paperTotal: null,
          lines: [LineDraft(description: 'Usage', unitPrice: 100)],
        ),
        isNull,
      );
    });

    test('lines with no tax code yet cannot tie to a taxed paper', () {
      // This is why the answer is asked for again as the lines move.
      // `_applyScan` leaves tax codes alone on purpose, so at the
      // instant a reading lands a taxed bill is 1,086.12 against a
      // paper that says 1,173.01 — nothing ties, and nothing should be
      // decided from it.
      expect(
        roundingForLines(
          paperTotal: 1173.01,
          lines: [LineDraft(description: 'Usage', unitPrice: 1086.12)],
        ),
        isNull,
      );

      // The same lines once somebody has put 8% on them.
      expect(
        roundingForLines(
          paperTotal: 1173.01,
          lines: [
            LineDraft(description: 'Usage', unitPrice: 1086.12, taxRate: 8),
          ],
        ),
        'none',
      );
    });

    test('a reading with no lines decides nothing', () {
      // Zero against a stated total ties to nothing, and `0705`'s
      // banner is what says so.
      expect(
        roundingForLines(paperTotal: 1173.01, lines: const []),
        isNull,
      );
    });
  });


  /// And that the bill on screen is the one the database will store.
  ///
  /// Every test above passes with the editor never reading the column,
  /// never honouring it, and never sending it back — which is three
  /// separate ways for a document to go back to RM 1,173.00 on the next
  /// save with nothing to show for it.
  group('on the bill itself', () {
    Widget editor(_FakeRepo repo, {ScanTotals? paper}) => ProviderScope(
          overrides: [
            repoProvider.overrideWithValue(repo),
            canPostProvider.overrideWithValue(true),
            canWriteProvider.overrideWithValue(true),
            // The company takes cash over a counter, which is why the
            // switch is on and why the bill was being restated.
            currentOrgProvider.overrideWith((ref) async => Organization(
                  id: 'org-1',
                  name: 'Kedai Kopi Sdn Bhd',
                  slug: 'kedai-kopi',
                  roundingMethod: 'nearest_5cent',
                )),
            accountsProvider.overrideWith((ref) async => <Account>[]),
            projectsProvider.overrideWith((ref) async => []),
            departmentsProvider.overrideWith((ref) async => []),
            salespeopleProvider.overrideWith((ref) async => []),
            currenciesProvider.overrideWith((ref) async => []),
            taxCodesProvider.overrideWith((ref) async => []),
            itemsProvider.overrideWith((ref, arg) async => <Item>[]),
            mattersProvider.overrideWith((ref, arg) async => <Matter>[]),
            documentScanTotalsProvider.overrideWith((ref, args) async => paper),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const DocumentEditor(docType: 'bill', documentId: 'doc-1'),
          ),
        );

    Future<void> open(WidgetTester tester, _FakeRepo repo,
        {ScanTotals? paper}) async {
      tester.view.physicalSize = const Size(1400, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(editor(repo, paper: paper));
      await tester.pumpAndSettle();
    }

    testWidgets('a bill the paper did not round totals to the sen',
        (tester) async {
      await open(tester, _FakeRepo(method: 'none'));

      expect(find.text('RM 1,173.01'), findsWidgets);
      expect(find.text('RM 1,173.00'), findsNothing);
      // No rounding row, and a line saying why there is none.
      expect(find.text('Rounding'), findsNothing);
      expect(find.byKey(const Key('rounding-from-the-paper')), findsOneWidget);
      expect(
        find.text('The paper does not round — this totals to the sen.'),
        findsOneWidget,
      );
    });

    testWidgets('a bill that says nothing still rounds the company way',
        (tester) async {
      // Every document raised before `0706` is this one, and not one of
      // them may move by a sen.
      await open(tester, _FakeRepo());

      expect(find.text('RM 1,173.00'), findsWidgets);
      expect(find.text('Rounding'), findsOneWidget);
      expect(find.byKey(const Key('rounding-from-the-paper')), findsNothing);
    });

    testWidgets('a paper that ties the moment it is read decides then',
        (tester) async {
      // The whole path, through the real `_applyScan`. Nothing else in
      // this file drives the scan, so without this the reading could
      // stop deciding anything and every other test would still pass.
      //
      // Untaxed, because that is the case that CAN tie at the instant
      // of reading: `_applyScan` puts no tax code on a line. The stated
      // total is what the line comes to, so the supplier did not round
      // — and the company's own setting would have made it RM 23.45.
      final repo = _FakeRepo(empty: true);
      await open(tester, repo);

      final card = tester.widget<AttachmentsCard>(
        find.byType(AttachmentsCard),
      );
      card.onExtracted!(const OcrExtraction(
        totalAmount: 23.47,
        lines: [
          OcrLine(description: 'Nasi lemak', quantity: 1, unitPrice: 23.47),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('RM 23.47'), findsWidgets);
      expect(find.text('RM 23.45'), findsNothing);
      expect(find.byKey(const Key('rounding-from-the-paper')), findsOneWidget);
    });

    testWidgets('a taxed bill is decided once the codes are on it',
        (tester) async {
      // The reported case, and the reason the question is asked again
      // rather than only at the scan. `_applyScan` puts no tax code on
      // a line, so when the paper was read this bill came to 1,086.12
      // against a stated 1,173.01 and tied to nothing. This one is
      // already on 8%, and the paper's total is the one `0705` fetched.
      final repo = _FakeRepo();
      await open(
        tester,
        repo,
        paper: ScanTotals(
          scanId: 's-1',
          readAt: DateTime(2026, 9, 24),
          fileName: '5665871390.pdf',
          subtotal: 1086.12,
          tax: 86.89,
          total: 1173.01,
        ),
      );

      // Nothing has moved yet, so the company's setting still shows.
      expect(find.text('RM 1,173.00'), findsWidgets);

      // Anything that marks the document dirty asks the question again.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Visible on the printed document'),
        'Bayar melalui kad',
      );
      await tester.pumpAndSettle();

      expect(find.text('RM 1,173.01'), findsWidgets);
      expect(find.text('RM 1,173.00'), findsNothing);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.savedHeader['rounding_method'], 'none');
    });

    testWidgets('editing away from the paper does not undo its answer',
        (tester) async {
      // The bill already knows the supplier does not round. Somebody
      // then changes a line, so the lines no longer come to what the
      // paper says — which is a document to look at, not a reason to
      // start rounding it again. `0705`'s banner is what raises it.
      final repo = _FakeRepo(method: 'none');
      await open(
        tester,
        repo,
        paper: ScanTotals(
          scanId: 's-1',
          readAt: DateTime(2026, 9, 24),
          fileName: '5665871390.pdf',
          total: 1200,
        ),
      );

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Visible on the printed document'),
        'Satu baris ditambah',
      );
      await tester.pumpAndSettle();

      expect(find.text('RM 1,173.01'), findsWidgets);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.savedHeader['rounding_method'], 'none');
    });

    testWidgets('and the method goes back with the save', (tester) async {
      final repo = _FakeRepo(method: 'none');
      await open(tester, repo);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(repo.savedHeader['rounding_method'], 'none');
    });

    testWidgets('a bill that says nothing sends null, not a guess',
        (tester) async {
      final repo = _FakeRepo();
      await open(tester, repo);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(repo.savedHeader.containsKey('rounding_method'), isTrue);
      expect(repo.savedHeader['rounding_method'], isNull);
    });
  });

  group('the document carries it back', () {
    test('a saved document reopens with what it decided', () {
      // Without this the editor opens on null, sends null on the next
      // save, and the bill silently goes back to RM 1,173.00.
      final doc = BusinessDocument.fromJson(const {
        'id': 'd-1',
        'doc_type': 'bill',
        'doc_no': 'BILL-2026-00016',
        'doc_date': '2026-09-24',
        'contact_id': 'c-1',
        'rounding_method': 'none',
        'total_amount': 1173.01,
      });
      expect(doc.roundingMethod, 'none');
      expect(doc.totalAmount, 1173.01);
    });

    test('and an ordinary one carries nothing, which is the default', () {
      final doc = BusinessDocument.fromJson(const {
        'id': 'd-1',
        'doc_type': 'bill',
        'doc_no': 'BILL-2026-00017',
        'doc_date': '2026-09-24',
        'contact_id': 'c-1',
      });
      expect(doc.roundingMethod, isNull);
    });
  });
}
