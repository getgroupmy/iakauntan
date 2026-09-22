import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/document_list_screen.dart';

/// One list screen for every document type in both cycles.
///
/// `bulk_plan_test.dart` has the batch arithmetic and
/// `document_overdue_test.dart` has the getter. What only lives in this
/// widget is four things.
///
/// THE OVERDUE CHIP. `31fb0c0` fixed `BusinessDocument.isOverdue` to
/// agree with `v_ar_aging` — due today is CURRENT — and this is the
/// screen that draws it. The chip also REPLACES the status rather than
/// sitting beside it, so a posted invoice nobody has paid reads
/// "overdue" and not "posted".
///
/// WHICH CYCLE THIS IS. Scanning is offered on the purchase side only,
/// because a sales invoice is raised from what we are owed rather than
/// read off a piece of paper. Ticking is offered on the sales side
/// only, because both bulk functions are the sales side's. The band at
/// the top says "receivable" or "payable" accordingly, and a list that
/// said the wrong one is a figure somebody reads the wrong way round.
///
/// A BUTTON WITH A COUNT BEHIND IT. The late-orders and intercompany
/// buttons appear only when there is something to open. The screen's
/// own comment gives the rule twice: a permanent button is a door onto
/// an empty room.
///
/// WHAT IS OWED, WHERE IT WOULD BE READ TWICE. The trailing column
/// shows the balance under the total only when they DIFFER — on a
/// wholly unpaid document the total is already the balance, and
/// printing it again invites somebody to add the two together.
void main() {
  BusinessDocument doc({
    String id = 'd1',
    String docNo = 'INV-0001',
    String docType = 'invoice',
    String? contactName = 'Kedai Runcit Aminah',
    DateTime? docDate,
    DateTime? dueDate,
    String? supplierDocNo,
    num total = 1000,
    num balance = 1000,
    String status = 'posted',
    String einvoiceStatus = 'not_applicable',
  }) => BusinessDocument(
    id: id,
    docType: docType,
    docNo: docNo,
    docDate: docDate ?? DateTime(2026, 9, 1),
    contactId: 'c1',
    contactName: contactName,
    dueDate: dueDate,
    supplierDocNo: supplierDocNo,
    totalAmount: total.toDouble(),
    balanceAmount: balance.toDouble(),
    paidAmount: (total - balance).toDouble(),
    status: status,
    einvoiceStatus: einvoiceStatus,
  );

  /// Midnight today, which is what a `date` column arrives as.
  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// Scoped to a row. The app bar carries a Tooltip of its own -- the
  /// document-type switcher -- so an unscoped `find.byType(Tooltip)`
  /// finds one on a screen with no e-Invoice mark anywhere.
  Finder inRow(Finder matching) =>
      find.descendant(of: find.byType(ListTile), matching: matching);

  late GoRouter router;

  Widget wrap({
    String docType = 'invoice',
    List<BusinessDocument> docs = const [],
    String role = 'owner',
    List<Map<String, dynamic>> late = const [],
    List<Map<String, dynamic>> intercompany = const [],
  }) {
    final kind = docType == 'bill' || docType == 'purchase_order'
        ? DocKind.purchase
        : DocKind.sales;
    router = GoRouter(
      initialLocation: '/list',
      routes: [
        GoRoute(
          path: '/list',
          builder: (_, __) => DocumentListScreen(docType: docType),
        ),
        GoRoute(
          path: '/intercompany',
          builder: (_, __) => const Scaffold(body: Text('the group inbox')),
        ),
        GoRoute(
          path: '/sales/:type/:id',
          builder: (_, __) => const Scaffold(body: Text('one document')),
        ),
        GoRoute(
          path: '/purchases/:type/:id',
          builder: (_, __) => const Scaffold(body: Text('one document')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        memberRoleProvider.overrideWith((ref) async => role),
        documentsProvider((
          kind: kind,
          docType: docType,
          status: 'all',
          search: '',
        )).overrideWith((ref) async => docs),
        lateOrdersProvider.overrideWith((ref) async => late),
        intercompanyInboxProvider.overrideWith((ref) async => intercompany),
      ],
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    );
  }

  /// Renders the screen at a stated width.
  ///
  /// The width is not incidental. `tester.binding.setSurfaceSize`
  /// resizes the RENDER SURFACE, so it catches a `RenderFlex` overflow
  /// -- but `MediaQuery` goes on reporting 800, so every
  /// `MediaQuery.sizeOf(context).width < 700` in the app still takes
  /// the DESKTOP branch. These tests were written that way first and
  /// the narrow assertions failed against a screen behaving correctly.
  /// `tester.view.physicalSize` drives both.
  ///
  /// The default is a laptop, because most of what is asserted below is
  /// the wide layout; the narrow ones say so.
  Future<void> show(
    WidgetTester tester, {
    String docType = 'invoice',
    List<BusinessDocument> docs = const [],
    String role = 'owner',
    List<Map<String, dynamic>> late = const [],
    List<Map<String, dynamic>> intercompany = const [],
    double width = 1400,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrap(
        docType: docType,
        docs: docs,
        role: role,
        late: late,
        intercompany: intercompany,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The chip text on a tile, read off the widget rather than searched
  /// for: `find.text('overdue')` would also match a chip somewhere else
  /// on the screen, and the point is that this row carries ONE chip.
  List<String> chips(WidgetTester tester) => [
    for (final w in tester.widgetList<StatusChip>(find.byType(StatusChip)))
      w.status,
  ];

  group('the overdue chip', () {
    testWidgets('is not shown on the day it falls due', (tester) async {
      // `v_ar_aging`: `current_date <= d.due_date then 'current'`. This
      // is the case 31fb0c0 was about — from 00:01 the list said
      // overdue while the aging report and the collections worklist
      // said current.
      await show(tester, docs: [doc(dueDate: today())]);

      expect(chips(tester), ['posted']);
    });

    testWidgets('is shown the day after', (tester) async {
      await show(
        tester,
        docs: [doc(dueDate: today().subtract(const Duration(days: 1)))],
      );

      expect(chips(tester), ['overdue']);
    });

    testWidgets('replaces the status rather than joining it', (tester) async {
      // Both on one screen, because "the late one says overdue" passes
      // against a list that writes overdue on every row.
      await show(
        tester,
        docs: [
          doc(id: 'a', docNo: 'INV-0001', dueDate: today()),
          doc(
            id: 'b',
            docNo: 'INV-0002',
            dueDate: today().subtract(const Duration(days: 30)),
          ),
        ],
      );

      expect(chips(tester), ['posted', 'overdue']);
    });

    testWidgets('is not shown on a settled document however old', (
      tester,
    ) async {
      // A red chip on a paid invoice sends somebody to chase money that
      // has arrived.
      await show(
        tester,
        docs: [
          doc(dueDate: DateTime(2020, 1, 1), balance: 0, status: 'posted'),
        ],
      );

      expect(chips(tester), ['posted']);
    });
  });

  group('what is still owed', () {
    testWidgets('is shown under the total when they differ', (tester) async {
      await show(tester, docs: [doc(total: 1000, balance: 400)]);

      expect(find.text('RM 400.00 due'), findsOneWidget);
    });

    testWidgets('and not when the total IS the balance', (tester) async {
      // Nothing has been paid, so the total on the line above is
      // already the amount owed. Printing it twice invites somebody to
      // add them together.
      await show(tester, docs: [doc(total: 1000, balance: 1000)]);

      expect(find.textContaining('due'), findsNothing);
    });

    testWidgets('and not on a settled one', (tester) async {
      await show(tester, docs: [doc(total: 1000, balance: 0)]);

      expect(find.textContaining('due'), findsNothing);
    });

    testWidgets('and not at phone width, where the row has no space', (
      tester,
    ) async {
      await show(tester, docs: [doc(total: 1000, balance: 400)], width: 393);

      expect(find.text('RM 400.00 due'), findsNothing);
      // The total is still there. Dropping the whole column would be
      // the other way to make it fit, and the wrong one.
      expect(find.textContaining('1,000.00'), findsOneWidget);
    });
  });

  group('the band across the top', () {
    testWidgets('counts the list and totals what is outstanding', (
      tester,
    ) async {
      await show(
        tester,
        docs: [
          doc(id: 'a', docNo: 'INV-0001', total: 1000, balance: 400),
          doc(id: 'b', docNo: 'INV-0002', total: 700, balance: 700),
        ],
      );

      expect(find.text('2 documents · RM 1,100.00 receivable'), findsOneWidget);
    });

    testWidgets('says payable on the purchase side', (tester) async {
      // The same figure read the wrong way round is money coming in
      // rather than going out.
      await show(
        tester,
        docType: 'bill',
        docs: [doc(docType: 'bill', docNo: 'BILL-01', balance: 400)],
      );

      expect(find.textContaining('payable'), findsOneWidget);
      expect(find.textContaining('receivable'), findsNothing);
    });

    testWidgets('and is absent when nothing is outstanding', (tester) async {
      // A band reading "RM 0.00 receivable" is a line of chrome saying
      // nothing.
      await show(tester, docs: [doc(balance: 0)]);

      expect(find.textContaining('documents ·'), findsNothing);
    });
  });

  group('which cycle this is', () {
    testWidgets('a bill can be scanned', (tester) async {
      await show(tester, docType: 'bill');

      expect(find.text('Scan bill'), findsOneWidget);
    });

    testWidgets('and so can an invoice', (tester) async {
      // It could not, until `0682`. The reason given was that a sales
      // invoice is raised from what we are owed rather than read off a
      // piece of paper — which is true of most of them and not of the
      // ones that matter: a copy returned with a payment, and every
      // invoice raised on somebody else's system during a migration.
      //
      // The real obstacle was the wording. Everything under the button
      // asked "which supplier?", which is the wrong question about your
      // own customer, and `ScanContactKind` carries the noun now.
      await show(tester);

      expect(find.text('Scan invoice'), findsOneWidget);
    });

    testWidgets('invoices can be ticked for a batch', (tester) async {
      await show(tester, docs: [doc()]);

      expect(find.byType(Checkbox), findsOneWidget);
    });

    testWidgets('bills cannot', (tester) async {
      // Both bulk functions are the sales side's, so a tick box on a
      // bill is a box with no button behind it.
      await show(
        tester,
        docType: 'bill',
        docs: [doc(docType: 'bill', docNo: 'BILL-01')],
      );

      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('and neither can somebody who may only look', (tester) async {
      await show(tester, docs: [doc()], role: 'viewer');

      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('New invoice'), findsNothing);
    });
  });

  group('a button with a count behind it', () {
    testWidgets('late orders appear only when something is late', (
      tester,
    ) async {
      await show(
        tester,
        docType: 'sales_order',
        docs: [doc(docType: 'sales_order', docNo: 'SO-01', status: 'draft')],
        late: const [
          {'id': 'x'},
          {'id': 'y'},
        ],
      );

      expect(find.text('Late (2)'), findsOneWidget);
    });

    testWidgets('and not when nothing is', (tester) async {
      await show(
        tester,
        docType: 'sales_order',
        docs: [doc(docType: 'sales_order', docNo: 'SO-01', status: 'draft')],
      );

      expect(find.byKey(const ValueKey('late-orders')), findsNothing);
    });

    testWidgets('and never on another list', (tester) async {
      // The provider is watched inside an `if (docType == ...)`, so a
      // company with late orders must not carry the button onto the
      // invoice list.
      await show(
        tester,
        docs: [doc()],
        late: const [
          {'id': 'x'},
        ],
      );

      expect(find.byKey(const ValueKey('late-orders')), findsNothing);
    });

    testWidgets('the group inbox counts only what is not billed yet', (
      tester,
    ) async {
      // Two waiting, one of which has already become a bill here. A
      // count of 3 sends somebody to a screen with one row on it.
      await show(
        tester,
        docType: 'bill',
        docs: [doc(docType: 'bill', docNo: 'BILL-01')],
        intercompany: const [
          {'id': 'a', 'already_billed': false},
          {'id': 'b'},
          {'id': 'c', 'already_billed': true},
        ],
      );

      expect(find.text('From the group (2)'), findsOneWidget);
    });

    testWidgets('and is absent when every one has been billed', (tester) async {
      await show(
        tester,
        docType: 'bill',
        docs: [doc(docType: 'bill', docNo: 'BILL-01')],
        intercompany: const [
          {'id': 'c', 'already_billed': true},
        ],
      );

      expect(find.byKey(const ValueKey('open-intercompany')), findsNothing);
    });
  });

  group('the line under the number', () {
    testWidgets('names the contact, the date, the due date and the ref', (
      tester,
    ) async {
      await show(
        tester,
        docType: 'bill',
        docs: [
          doc(
            docType: 'bill',
            docNo: 'BILL-01',
            contactName: 'Syarikat Maju',
            docDate: DateTime(2026, 9, 1),
            dueDate: DateTime(2026, 10, 1),
            supplierDocNo: 'S-778',
          ),
        ],
      );

      // The whole line. A `textContaining` on any part of it passes
      // while a field beside it goes missing.
      expect(
        find.text('Syarikat Maju · 01/09/2026 · due 01/10/2026 · ref S-778'),
        findsOneWidget,
      );
    });

    testWidgets('and drops the parts a document does not have', (tester) async {
      // A quotation has no due date and a sales document has no
      // supplier reference, so neither label appears — rather than
      // "due —", which reads as a date somebody failed to enter.
      await show(
        tester,
        docType: 'quotation',
        docs: [
          doc(
            docType: 'quotation',
            docNo: 'QT-01',
            contactName: 'Syarikat Maju',
            docDate: DateTime(2026, 9, 1),
            status: 'draft',
          ),
        ],
      );

      expect(find.text('Syarikat Maju · 01/09/2026'), findsOneWidget);
    });

    testWidgets('and says so when there is no contact name', (tester) async {
      await show(
        tester,
        docs: [doc(contactName: null, docDate: DateTime(2026, 9, 1))],
      );

      expect(find.text('— · 01/09/2026'), findsOneWidget);
    });
  });

  group('the e-Invoice mark', () {
    testWidgets('is absent where LHDN does not apply', (tester) async {
      await show(tester, docs: [doc(einvoiceStatus: 'not_applicable')]);

      expect(inRow(find.byType(Tooltip)), findsNothing);
    });

    testWidgets('names the state it is in', (tester) async {
      // A tooltip rather than a chip, because the row already carries
      // one and two chips reading different words is how somebody comes
      // to quote the wrong one.
      await show(tester, docs: [doc(einvoiceStatus: 'valid')]);

      expect(inRow(find.byType(Tooltip)), findsOneWidget);
      expect(
        tester.widget<Tooltip>(inRow(find.byType(Tooltip))).message,
        'e-Invoice: Valid',
      );
    });
  });

  group('when there is nothing', () {
    testWidgets('the empty state offers a way to start one', (tester) async {
      await show(tester);

      expect(find.text('No invoices yet'), findsOneWidget);
      expect(find.text('Create your first invoice.'), findsOneWidget);
    });

    testWidgets('and offers nothing to somebody who may only look', (
      tester,
    ) async {
      await show(tester, role: 'viewer');

      expect(find.text('No invoices yet'), findsOneWidget);
      expect(find.text('New invoice'), findsNothing);
    });
  });

  testWidgets('opening a row goes to that document', (tester) async {
    await show(tester, docs: [doc(id: 'the-one')]);

    await tester.tap(find.text('INV-0001'));
    await tester.pumpAndSettle();

    expect(find.text('one document'), findsOneWidget);
    expect(
      router.routerDelegate.currentConfiguration.uri.toString(),
      '/sales/invoice/the-one',
    );
  });

  testWidgets('ticking a row does not open it', (tester) async {
    // The checkbox sits inside the tile, and a tile whose onTap fires
    // through it takes somebody off the list every time they try to
    // build a batch.
    await show(tester, docs: [doc(id: 'the-one')]);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    expect(find.text('1 selected'), findsOneWidget);
    expect(find.text('one document'), findsNothing);
  });

  /// Every combination that reaches this screen, at every width one is
  /// opened at.
  ///
  /// This is the guard on `_actionWidth` and `_chromeWidth`, which are
  /// estimates of how much room a button takes and would otherwise
  /// drift the first time somebody lengthens a label. A `RenderFlex`
  /// overflow IS a test failure in Flutter, so nothing here needs an
  /// assertion beyond rendering -- and in a release build it is not an
  /// error at all, just the right-hand end of the bar quietly clipped,
  /// which is how all of this shipped.
  ///
  /// Every one of these overflowed before: a bill list at 800 by 174
  /// pixels, and every list on a phone in three places at once -- the
  /// filter row, the app bar, and the title of every line in the list.
  group('nothing runs off the edge', () {
    const types = {
      'invoice': DocKind.sales,
      'quotation': DocKind.sales,
      'sales_order': DocKind.sales,
      'bill': DocKind.purchase,
      'purchase_order': DocKind.purchase,
    };

    for (final width in [1400.0, 1000.0, 800.0, 700.0, 600.0, 412.0, 360.0]) {
      for (final type in types.entries) {
        for (final role in ['owner', 'viewer']) {
          testWidgets('${type.key}, $role, ${width.toInt()} wide', (
            tester,
          ) async {
            // Everything that can be on the bar at once, and the
            // longest text a line can carry.
            await show(
              tester,
              docType: type.key,
              role: role,
              width: width,
              docs: [
                doc(
                  docType: type.key,
                  docNo: 'DOC-000001',
                  contactName: 'Syarikat Perniagaan Maju Jaya Sendirian Berhad',
                  dueDate: today().subtract(const Duration(days: 4)),
                  supplierDocNo: 'S-77812',
                  einvoiceStatus: 'valid',
                  total: 123456.78,
                  balance: 4000,
                ),
              ],
              late: const [
                {'id': 'x'},
                {'id': 'y'},
              ],
              intercompany: const [
                {'id': 'a'},
                {'id': 'b'},
              ],
            );

            expect(find.byType(DocumentListScreen), findsOneWidget);
          });
        }
      }
    }
  });

  group('when the bar runs out of room', () {
    testWidgets('the secondary actions fold into a menu', (tester) async {
      // A bill list for a company in a group carries three of them.
      // Folded rather than dropped: each is the only way to reach what
      // is behind it from this screen.
      await show(
        tester,
        docType: 'bill',
        docs: [doc(docType: 'bill', docNo: 'BILL-01')],
        intercompany: const [
          {'id': 'a'},
        ],
        width: 412,
      );

      expect(find.text('From the group (1)'), findsNothing);
      expect(find.text('Scan bill'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('more-actions')));
      await tester.pumpAndSettle();

      expect(find.text('From the group (1)'), findsOneWidget);
      expect(find.text('Scan bill'), findsOneWidget);
      expect(find.text('Pay supplier'), findsOneWidget);
    });

    testWidgets('and stay buttons when there is room', (tester) async {
      // The control for the fold. Without it, "they are in the menu"
      // passes against a screen that always uses the menu.
      await show(
        tester,
        docType: 'bill',
        docs: [doc(docType: 'bill', docNo: 'BILL-01')],
        intercompany: const [
          {'id': 'a'},
        ],
      );

      expect(find.text('From the group (1)'), findsOneWidget);
      expect(find.text('Scan bill'), findsOneWidget);
      expect(find.byKey(const ValueKey('more-actions')), findsNothing);
    });

    testWidgets('there is no menu when there was nothing to fold', (
      tester,
    ) async {
      // A viewer looking at quotations has no secondary action at all,
      // and a "More" button is a menu that opens onto nothing.
      await show(tester, docType: 'quotation', role: 'viewer', width: 412);

      expect(find.byKey(const ValueKey('more-actions')), findsNothing);
    });

    testWidgets('New keeps its button and loses its noun', (tester) async {
      // The one action that is never folded, because starting a
      // document is what somebody opened the list to do. "New invoice"
      // does not fit beside everything else on a phone; "New" does, and
      // the list behind it says which kind.
      // With a document on the list, so the empty state's own
      // "New invoice" button is not on the screen to be found instead.
      await show(tester, docs: [doc()], width: 412);

      expect(find.text('New'), findsOneWidget);
      expect(find.text('New invoice'), findsNothing);
    });

    testWidgets('and the filters go under the search box', (tester) async {
      // The segmented control alone is 504 wide, which is more than a
      // phone has. Side by side it lost "Outstanding" off the edge.
      await show(tester, docs: [doc()], width: 412);

      final search = find.byType(TextField);
      final filters = find.byType(SegmentedButton<String>);
      expect(
        tester.getCenter(filters).dy,
        greaterThan(tester.getCenter(search).dy),
      );
    });

    testWidgets('and sit beside it when there is room', (tester) async {
      await show(tester, docs: [doc()]);

      final search = find.byType(TextField);
      final filters = find.byType(SegmentedButton<String>);
      expect(
        tester.getCenter(filters).dy,
        closeTo(tester.getCenter(search).dy, 1),
      );
      expect(
        tester.getCenter(filters).dx,
        greaterThan(tester.getCenter(search).dx),
      );
    });
  });
}
