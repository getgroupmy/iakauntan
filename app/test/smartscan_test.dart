import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/smartscan/scan_detail_sheet.dart';
import 'package:iakauntan/src/features/smartscan/scan_kind_sheet.dart';
import 'package:iakauntan/src/features/smartscan/scan_supplier_picker.dart';

import 'package:iakauntan/src/core/format.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/scan_kinds_repository.dart';
import 'package:iakauntan/src/features/smartscan/scan_destination.dart';
import 'package:iakauntan/src/features/smartscan/scan_field_map.dart';
import 'package:iakauntan/src/features/smartscan/smartscan_screen.dart';

/// AI SmartScan: one door, and a list saying what came through it.
///
/// Scanning used to be four buttons on four screens, each knowing about
/// one destination. The same receipt became a bill or an expense
/// depending on which screen somebody happened to be standing on, and
/// none of them recorded what the paper became — so `ocr_scans` could
/// say what was read and what it cost and never what came of it.
///
/// What these assert is the judgement, which is where a consolidation
/// like this goes wrong: where a reading is sent, and what the list
/// says about a reading that became nothing, failed, or became
/// something that has since been deleted. Those three look alike from
/// a distance and mean completely different things.
void main() {
  OcrExtraction read({
    String? target,
    String? kind,
    String? supplier = 'Pejabat Tanah',
    String? docNo = 'PB-1041',
    DateTime? date,
    double? total = 106,
    double? tax = 6,
  }) =>
      OcrExtraction(
        target: target,
        documentKind: kind,
        supplierName: supplier,
        documentNo: docNo,
        documentDate: date ?? DateTime(2026, 9, 26),
        totalAmount: total,
        taxAmount: tax,
      );

  ScanKind kind(String code, {String? module, String? action}) => ScanKind(
        code: code,
        label: code,
        targetModule: module,
        targetAction: action,
      );

  group('where a reading goes', () {
    // `0681` had the READER choose, with the platform's destinations in
    // front of it and the page in its hand. That beats anything string
    // matching produces afterwards, so it is asked first.
    test('the reader has the first word', () {
      expect(
        destinationFor(read(target: 'purchases.bill'), const []),
        ScanDestination.bill,
      );
      expect(
        destinationFor(read(target: 'accounting.bank_statement'), const []),
        ScanDestination.bankStatement,
      );
      expect(
        destinationFor(read(target: 'contacts.contact'), const []),
        ScanDestination.contact,
      );
    });

    // And beats the classifier, which is the whole reason it is asked
    // first. A reading that carries both must not be routed by the
    // weaker answer.
    test('and beats the kind the classifier guessed', () {
      final r = read(target: 'accounting.expense', kind: 'bill');
      expect(
        destinationFor(r, [kind('bill', module: 'purchases', action: 'bill')]),
        ScanDestination.expense,
      );
    });

    test('the kind answers when the reader did not', () {
      expect(
        destinationFor(
          read(kind: 'bill'),
          [kind('bill', module: 'purchases', action: 'bill')],
        ),
        ScanDestination.bill,
      );
    });

    // A kind that exists and goes nowhere is not the same as a kind
    // nobody recognises, and both have to end up asking the person
    // rather than guessing. A document filed wrongly becomes a record
    // somebody has to find and undo.
    test('a kind that goes nowhere asks', () {
      expect(
        destinationFor(read(kind: 'filed_only'), [kind('filed_only')]),
        ScanDestination.unknown,
      );
    });

    test('and a kind nothing has heard of asks', () {
      expect(
        destinationFor(read(kind: 'no_such_thing'), const []),
        ScanDestination.unknown,
      );
    });

    test('a target nothing handles asks', () {
      expect(
        destinationFor(read(target: 'payroll.run'), const []),
        ScanDestination.unknown,
      );
      expect(destinationFromTarget('payroll.run'), isNull);
    });

    test('and no reading at all asks', () {
      expect(destinationFor(null, const []), ScanDestination.unknown);
    });

    // The capture is parked against a real table — the storage policies
    // read it out of the object path and a trigger refuses a row whose
    // path disagrees with its columns — so a friendly name here is a
    // failed upload.
    test('every destination parks against a real table', () {
      for (final d in ScanDestination.values) {
        expect(d.table, matches(RegExp(r'^[a-z_]+$')), reason: d.name);
      }
      expect(ScanDestination.bill.table, 'purchase_documents');
      expect(ScanDestination.invoice.table, 'sales_documents');
      expect(ScanDestination.contact.table, 'contacts');
      expect(ScanDestination.bankStatement.table, 'bank_transactions');
    });

    // `purchase_documents.contact_id` is NOT NULL, so a document
    // created before anybody has named a supplier is one the database
    // refuses. The first version of the old flow did exactly that.
    test('the four document kinds need a contact and the rest do not', () {
      expect(ScanDestination.bill.needsContact, isTrue);
      expect(ScanDestination.invoice.needsContact, isTrue);
      expect(ScanDestination.purchaseOrder.needsContact, isTrue);
      expect(ScanDestination.goodsReceived.needsContact, isTrue);
      expect(ScanDestination.expense.needsContact, isFalse);
      expect(ScanDestination.contact.needsContact, isFalse);
      expect(ScanDestination.bankStatement.needsContact, isFalse);
    });

    // Choosing "not sure" would be pressing a button to do nothing.
    test('unknown is an answer the machine gives, not one to offer', () {
      expect(offerableDestinations, isNot(contains(ScanDestination.unknown)));
      expect(offerableDestinations, contains(ScanDestination.bill));
      expect(offerableDestinations, contains(ScanDestination.bankStatement));
    });
  });

  group('which column each reading fills', () {
    test('a bill maps onto the purchase document', () {
      final fields = readingColumns(read(), ScanDestination.bill);
      final columns = {for (final f in fields) f.column: f.value};
      expect(columns['purchase_documents.contact_id'], 'Pejabat Tanah');
      expect(columns['purchase_documents.supplier_doc_no'], 'PB-1041');
      expect(columns['purchase_documents.total_amount'], '106.0');
    });

    // Their number for it, and only on the buying side: a sales
    // document's number is this company's own sequence, so writing the
    // read one there files a customer's reference as our invoice
    // number.
    test('but an invoice does not take their number as ours', () {
      final fields = readingColumns(read(), ScanDestination.invoice);
      expect(
        fields.map((f) => f.column),
        isNot(contains('sales_documents.supplier_doc_no')),
      );
      expect(
        fields.map((f) => f.column),
        contains('sales_documents.contact_id'),
      );
    });

    test('a contact maps onto the contact', () {
      final r = OcrExtraction(
        supplierName: 'Syarikat Maju',
        supplierTaxId: 'C1234567890',
        supplierRegistrationNo: '571389-H',
      );
      final columns = {
        for (final f in readingColumns(r, ScanDestination.contact))
          f.column: f.value,
      };
      expect(columns['contacts.name'], 'Syarikat Maju');
      // The two Malaysian numbers are different things and a letterhead
      // usually prints both. Putting one in the other's column is the
      // kind of wrong that validates against LHDN months later.
      expect(columns['contacts.tax_id'], 'C1234567890');
      expect(columns['contacts.registration_no'], '571389-H');
    });

    // "The tax number is not printed on this receipt" is a useful
    // answer and a blank row is not.
    test('nothing found is nothing shown', () {
      final r = OcrExtraction(supplierName: 'Kedai', supplierTaxId: '   ');
      final columns = readingColumns(r, ScanDestination.contact)
          .map((f) => f.column);
      expect(columns, contains('contacts.name'));
      expect(columns, isNot(contains('contacts.tax_id')));
    });

    test('and no reading at all is no rows', () {
      expect(readingColumns(null, ScanDestination.bill), isEmpty);
    });

    // A statement is its rows. Mapping a supplier name onto a table
    // with no such column would be inventing a destination.
    test('a statement claims no header columns', () {
      expect(readingColumns(read(), ScanDestination.bankStatement), isEmpty);
    });

    test('what the reader was asked for comes back by column', () {
      final r = OcrExtraction(
        // Written out of order on purpose. A Dart map literal keeps
        // its insertion order, so a fixture written alphabetically
        // passes whether or not anything sorts — which is exactly what
        // a mutant proved.
        fields: const {
          'total_amount': '106.00',
          'blank_one': '  ',
          'supplier_doc_no': 'PB-1041',
        },
      );
      final asked = readerColumns(r, ScanDestination.bill);
      expect(asked.map((f) => f.column), [
        // Sorted, because a map has no order and a list that reshuffles
        // between openings is one nobody trusts.
        'purchase_documents.supplier_doc_no',
        'purchase_documents.total_amount',
      ]);
      expect(asked.first.label, 'Supplier doc no');
    });

    test('and nothing asked for is nothing shown', () {
      expect(readerColumns(read(), ScanDestination.bill), isEmpty);
      expect(readerColumns(null, ScanDestination.bill), isEmpty);
    });
  });

  group('what the list says happened', () {
    ScanInboxEntry entry({
      String? kindLabel = 'Supplier bill',
      String? postedTable,
      String? postedLabel,
      DateTime? postedDate,
      String? status = 'ok',
      String? error,
    }) =>
        ScanInboxEntry(
          scanId: 's-1',
          scannedAt: DateTime(2026, 9, 26),
          fileName: 'xxxx.jpg',
          kindLabel: kindLabel,
          postedTable: postedTable,
          postedId: postedTable == null ? null : 'r-1',
          postedLabel: postedLabel,
          postedDate: postedDate,
          status: status,
          error: error,
        );

    // The line the whole screen exists for.
    test('it became a document, with its number and its date', () {
      final said = scanRowSubtitle(entry(
        postedTable: 'purchase_documents',
        postedLabel: 'RC-123-11',
        postedDate: DateTime(2026, 9, 26),
      ));
      expect(said, startsWith('Supplier bill · RC-123-11'));
      // The DATE, and not only the number. Two bills a month apart can
      // carry the same number from different suppliers, and a line that
      // gave only the number would leave somebody opening both.
      expect(said, contains(Fmt.date(DateTime(2026, 9, 26))));
    });

    test('and without one, just the number', () {
      expect(
        scanRowSubtitle(entry(
          postedTable: 'contacts',
          postedLabel: 'Syarikat Maju',
        )),
        endsWith('Syarikat Maju'),
      );
    });

    // Three states that look alike from a distance and are completely
    // different things. Getting any of them to read as another is the
    // failure this screen was built to end.
    test('it became nothing yet', () {
      final said = scanRowSubtitle(entry());
      expect(said, contains('Not filed'));
      expect(said, isNot(contains('deleted')));
    });

    test('it could not be read, and the reason is given', () {
      final said = scanRowSubtitle(
        entry(status: 'failed', error: 'The page was too dark'),
      );
      expect(said, contains('The page was too dark'));
      // Not "not filed against anything": it never could be.
      expect(said, isNot(contains('Not filed')));
    });

    test('and a failure with no reason still says it failed', () {
      expect(
        scanRowSubtitle(entry(status: 'failed')),
        contains('Could not be read'),
      );
    });

    // Posted, and the record deleted since. `delete_attachments_of_row`
    // takes the picture with the document, so this row survives with
    // its destination and no label — and reading it as "became
    // nothing" would be a lie about work that was done.
    test('it became something that has since been deleted', () {
      final said = scanRowSubtitle(entry(postedTable: 'purchase_documents'));
      expect(said, contains('deleted'));
      expect(said, isNot(contains('Not filed')));
    });

    test('a kind nobody set is simply left out', () {
      expect(
        scanRowSubtitle(entry(kindLabel: null)),
        'Not filed against anything yet',
      );
    });
  });

  group('the screens and sheets build', () {
    // `check_screens_built.py` and `check_dialogs_built.py` exist
    // because a screen nothing constructs is one nobody knows compiles
    // into a widget tree — and everything in this module is reached
    // only through a scan, which a test cannot perform.
    Widget wrap(Widget child, List<Override> overrides) => ProviderScope(
          overrides: overrides,
          child: MaterialApp(theme: AppTheme.light(), home: child),
        );

    Future<void> onAPhone(WidgetTester tester, Widget app) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
    }

    ScanInboxEntry filed() => ScanInboxEntry(
          scanId: 's-1',
          scannedAt: DateTime(2026, 9, 26),
          attachmentId: 'att-1',
          fileName: 'xxxx.jpg',
          storagePath: 'org/purchase_documents/d-1/xxxx.jpg',
          provider: 'gemini',
          status: 'ok',
          kindLabel: 'Supplier bill',
          postedTable: 'purchase_documents',
          postedId: 'd-1',
          postedLabel: 'RC-123-11',
          postedDate: DateTime(2026, 9, 26),
        );

    testWidgets('the list shows a scan and what it became', (tester) async {
      await onAPhone(
        tester,
        wrap(const SmartScanScreen(), [
          canWriteProvider.overrideWithValue(true),
          scanInboxProvider.overrideWith((ref, only) async => [filed()]),
        ]),
      );

      expect(find.text('AI SmartScan'), findsOneWidget);
      expect(find.text('xxxx.jpg'), findsOneWidget);
      // The whole point of the screen, on screen.
      expect(find.textContaining('RC-123-11'), findsOneWidget);
      expect(find.byKey(const ValueKey('smartscan-new')), findsOneWidget);
    });

    testWidgets('and says so when nothing has been scanned', (tester) async {
      await onAPhone(
        tester,
        wrap(const SmartScanScreen(), [
          canWriteProvider.overrideWithValue(true),
          scanInboxProvider.overrideWith((ref, only) async => []),
        ]),
      );
      expect(find.text('Nothing scanned yet'), findsOneWidget);
    });

    testWidgets('the detail sheet opens on a scan', (tester) async {
      await onAPhone(
        tester,
        wrap(const SmartScanScreen(), [
          canWriteProvider.overrideWithValue(true),
          scanInboxProvider.overrideWith((ref, only) async => [filed()]),
          scanReadingProvider.overrideWith(
            (ref, id) async => read(target: 'purchases.bill'),
          ),
          offeredScanKindsProvider.overrideWith((ref) async => <ScanKind>[]),
        ]),
      );

      // Opened by its own function rather than only by tapping the
      // row: `check_dialogs_built.py` looks for the CALL, and a sheet
      // reached only through a widget somewhere else is one nothing
      // names.
      // NOT awaited: `showModalBottomSheet`'s future completes when the
      // sheet is DISMISSED, so awaiting it here waits for something
      // this test is about to assert on and never closes.
      unawaited(showScanDetail(
        tester.element(find.byType(SmartScanScreen)),
        filed(),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('It became RC-123-11'), findsOneWidget);
      // The column, which is the thing the result dialog cannot say.
      expect(
        find.text('purchase_documents.supplier_doc_no'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('scan-view-image')), findsOneWidget);
    });

    testWidgets('the kind sheet offers every destination', (tester) async {
      await onAPhone(
        tester,
        wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showScanKindSheet(
                context,
                read: read(),
                because: 'Nothing on this names a supplier.',
              ),
              child: const Text('open'),
            ),
          ),
          const [],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('What is this?'), findsOneWidget);
      // The finding, said plainly. `0686`: a question asked without it
      // reads as the app having lost its place.
      expect(
        find.text('Nothing on this names a supplier.'),
        findsOneWidget,
      );
      for (final d in offerableDestinations) {
        expect(
          find.byKey(ValueKey('scan-kind-${d.name}')),
          findsOneWidget,
          reason: d.name,
        );
      }
    });

    testWidgets('the supplier picker opens', (tester) async {
      await onAPhone(
        tester,
        wrap(
          Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => pickSupplier(context, ref, read()),
              child: const Text('open'),
            ),
          ),
          [
            contactsProvider.overrideWith((ref, arg) async => <Contact>[]),
          ],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
    });

    // `0628`. A warning rather than a refusal: a supplier's corrected
    // re-issue and a genuine second delivery on one day are both
    // ordinary, and a check that is wrong a tenth of the time teaches
    // people to type the number differently.
    testWidgets('the duplicate warning opens and lets it go on',
        (tester) async {
      var answer = false;
      await onAPhone(
        tester,
        wrap(
          Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () async {
                answer = await clearOfDuplicates(
                  context,
                  ref,
                  contactId: 'c-1',
                  docType: 'bill',
                  read: read(),
                );
              },
              child: const Text('open'),
            ),
          ),
          [repoProvider.overrideWithValue(_DupeRepo())],
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('duplicate-headline')), findsOneWidget);
      // It must be possible to carry on, or a corrected re-issue can
      // never be entered at all.
      final go = find.textContaining('anyway');
      expect(go, findsWidgets);
      await tester.tap(go.last);
      await tester.pumpAndSettle();
      expect(answer, isTrue);
    });
  });
}


/// A repository with one bill already on the books.
///
/// Faked at `callRpc`, not at `duplicatePurchaseDocuments`, and that is
/// not a preference. `duplicatePurchaseDocuments` lives on an
/// `extension ... on Repo`, and an extension method binds to the STATIC
/// type — so a fake that declared it would never be called and the real
/// body would run against this object's `client`. `callRpc` is on the
/// class, so overriding it actually intercepts. See
/// `docs/widget-tests.md`; this has caught three tests out already.
class _DupeRepo implements Repo {
  @override
  String get orgId => 'org-1';

  @override
  Future<dynamic> callRpc(String fn, {Map<String, dynamic>? params}) async {
    if (fn != 'duplicate_purchase_documents') return null;
    return [
      {
        'id': 'd-9',
        'doc_no': 'PB-0001',
        'reason': 'same_supplier_doc_no',
        'total_amount': 106,
        'currency': 'MYR',
        'status': 'posted',
        'supplier_doc_no': 'PB-1041',
      },
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
