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
import 'package:iakauntan/src/features/smartscan/scan_availability.dart';
import 'package:iakauntan/src/features/smartscan/scan_blocked_dialog.dart';
import 'package:iakauntan/src/features/smartscan/scan_destination.dart';
import 'package:iakauntan/src/features/smartscan/scan_field_map.dart';
import 'package:iakauntan/src/features/smartscan/smartscan_screen.dart';
import 'package:iakauntan/src/features/shared/supplier_from_scan.dart';

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

    ScanInboxEntry failed() => ScanInboxEntry(
          scanId: 's-2',
          scannedAt: DateTime(2026, 9, 23),
          attachmentId: 'att-2',
          fileName: '1790159599336-IMG_6156.jpeg',
          storagePath: 'org/expenses/p-1/IMG_6156.jpeg',
          provider: 'gemini',
          status: 'failed',
          error: 'The reader refused the document: HTTP 503',
          logRef: 'ocr.failed-7f3a',
        );

    // `0680` mints this and tells the person to quote it; `0694` built
    // the screen they would quote it from and did not show it. So the
    // one identifier the whole arrangement exists to hand over was on
    // the row, in the logs, and nowhere a person could read it.
    testWidgets('a failed scan shows the reference to quote', (tester) async {
      await onAPhone(
        tester,
        wrap(const SmartScanScreen(), [
          canWriteProvider.overrideWithValue(true),
          scanInboxProvider.overrideWith((ref, only) async => [failed()]),
          scanReadingProvider.overrideWith((ref, id) async => null),
          offeredScanKindsProvider.overrideWith((ref) async => <ScanKind>[]),
        ]),
      );

      unawaited(showScanDetail(
        tester.element(find.byType(SmartScanScreen)),
        failed(),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('ocr.failed-7f3a'), findsOneWidget);
      // And the reason, which is the other half of what somebody needs
      // before they ask anybody anything. `findsWidgets`, not
      // `findsOneWidget`: the row behind the sheet carries it too, and
      // it should — the list is where somebody notices, the sheet is
      // where they read it.
      expect(find.textContaining('HTTP 503'), findsWidgets);
    });

    testWidgets('and a scan that worked shows none', (tester) async {
      // A reference beside a scan that worked is an identifier somebody
      // would quote about nothing.
      await onAPhone(
        tester,
        wrap(const SmartScanScreen(), [
          canWriteProvider.overrideWithValue(true),
          scanInboxProvider.overrideWith((ref, only) async => [filed()]),
          scanReadingProvider.overrideWith((ref, id) async => read()),
          offeredScanKindsProvider.overrideWith((ref) async => <ScanKind>[]),
        ]),
      );

      unawaited(showScanDetail(
        tester.element(find.byType(SmartScanScreen)),
        filed(),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('Quote this'), findsNothing);
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

  group('when scanning cannot run at all', () {
    // From a report. Photographing a document in a company that had
    // never switched scanning on produced a raw `FunctionException` in
    // a snackbar, AFTER the photograph was taken -- and then the module
    // asked which kind of document the scan that never happened was.
    //
    // The ugly string is the smaller half. Asking somebody to
    // photograph a document in order to discover the feature is off is
    // the failure; `settings_screen` already draws this line for the
    // same setting.
    OcrSettings settings({
      bool enabled = true,
      bool hasModule = true,
      List<OcrProvider> providers = const [],
    }) =>
        OcrSettings(
          enabled: enabled,
          hasModule: hasModule,
          provider: 'claude',
          keySource: 'platform',
          hasOwnKey: false,
          keys: const {},
          balance: 0,
          price: 0.3,
          providers: providers,
        );

    OcrProvider provider({
      String code = 'mlkit',
      String name = 'On this device (free)',
      double price = 0,
      bool isActive = true,
    }) =>
        OcrProvider(
          code: code,
          name: name,
          price: price,
          takesKey: false,
          runsOnDevice: true,
          isActive: isActive,
          ready: true,
        );

    test('nothing blocks a company that has it on', () {
      expect(scanBlock(settings(), canAdmin: true), isNull);
      expect(scanBlock(settings(), canAdmin: false), isNull);
    });

    // Not a block. The question has not come back yet, and refusing on
    // it would be this file inventing an outage.
    test('nor does a setting that has not loaded', () {
      expect(scanBlock(null, canAdmin: true), isNull);
    });

    test('an administrator is offered the way out', () {
      final block = scanBlock(settings(enabled: false), canAdmin: true);
      expect(block, isNotNull);
      expect(block!.hasAction, isTrue);
      expect(block.route, '/settings');
    });

    // The half that matters more. `set_ocr_settings` refuses anybody
    // but an administrator, so a button to Settings would take an
    // ordinary user to a control they are about to be refused at --
    // worse than no button.
    test('and anybody else is told who can, with no door', () {
      final block = scanBlock(settings(enabled: false), canAdmin: false);
      expect(block, isNotNull);
      expect(block!.hasAction, isFalse);
      expect(block.route, isNull);
      expect(block.message.toLowerCase(), contains('administrator'));
    });

    // "Turn it on" reads as "start paying for something" unless the
    // free reader is named.
    test('the free reader is named where there is one', () {
      final block = scanBlock(
        settings(enabled: false, providers: [provider()]),
        canAdmin: true,
      );
      expect(block!.message, contains('On this device (free)'));
    });

    test('and nothing is promised where there is not', () {
      final block = scanBlock(
        settings(enabled: false, providers: [provider(price: 0.3)]),
        canAdmin: true,
      );
      expect(block!.message.toLowerCase(), isNot(contains('free')));
    });

    test('nor is a free reader the platform has withdrawn', () {
      final block = scanBlock(
        settings(enabled: false, providers: [provider(isActive: false)]),
        canAdmin: true,
      );
      expect(block!.message.toLowerCase(), isNot(contains('free')));
    });

    // A module before it is a setting. `0682`. The switch is under
    // Subscription and it is an OWNER's, so an administrator gets no
    // shortcut to Settings -- which would be a door onto a control that
    // will not help.
    test('a module that is off offers no settings shortcut', () {
      final block = scanBlock(settings(hasModule: false), canAdmin: true);
      expect(block, isNotNull);
      expect(block!.hasAction, isFalse);
      expect(block.message, contains('Subscription'));
    });

    // The module is asked about FIRST. A company whose module is off
    // and whose setting is also off must not be told to go and flip a
    // switch that will not help.
    testWidgets('the dialog offers the way out, and closes', (tester) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showScanBlocked(
                context,
                scanBlock(settings(enabled: false), canAdmin: true)!,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('scan-blocked')), findsOneWidget);
      expect(find.text('AI SmartScan is not switched on yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('scan-blocked-go')), findsOneWidget);
    });

    testWidgets('and offers no button where there is nothing to press',
        (tester) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showScanBlocked(
                context,
                scanBlock(settings(enabled: false), canAdmin: false)!,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('scan-blocked')), findsOneWidget);
      expect(find.byKey(const ValueKey('scan-blocked-go')), findsNothing);
      // And the one button there is says Close, because nothing was
      // started and there is nothing to cancel.
      expect(find.text('Close'), findsOneWidget);
    });

    test('and the module is the answer even when both are off', () {
      final block = scanBlock(
        settings(hasModule: false, enabled: false),
        canAdmin: true,
      );
      expect(block!.message, contains('Subscription'));
      expect(block.hasAction, isFalse);
    });
  });

  // ------------------------------------------------------------------
  // A PDF handed to a reader that cannot open one
  //
  // From a report, with the PDF attached. A company on Gemini uploaded
  // a supplier bill and the inbox came back "This reader takes
  // photographs, not PDFs." That refusal is `readOpenAiShaped` in the
  // edge function and it is correct -- chat-completions takes an image
  // part -- but it arrives after an upload, after a charge and after
  // the refund of it, for a question the app could have answered
  // before the file was chosen.
  //
  // `reads_pdf` comes off `ocr_status` (`0697`), tri-state, and the
  // tri-state is where this goes wrong if nobody watches it. So the
  // three cases are asserted separately, and in both directions.
  // ------------------------------------------------------------------
  group('a PDF and a reader that cannot open one', () {
    OcrProvider reader({
      required String code,
      required String name,
      bool? readsPdf,
      bool runsOnDevice = false,
      bool isActive = true,
      bool ready = true,
    }) =>
        OcrProvider(
          code: code,
          name: name,
          price: 0.3,
          takesKey: true,
          runsOnDevice: runsOnDevice,
          isActive: isActive,
          ready: ready,
          readsPdf: readsPdf,
        );

    final gemini = reader(code: 'gemini', name: 'Gemini', readsPdf: false);
    final claude = reader(code: 'claude', name: 'Claude', readsPdf: true);
    final docai = reader(code: 'google', name: 'Document AI', readsPdf: true);
    final onDevice = reader(
      code: 'mlkit',
      name: 'On this device',
      runsOnDevice: true,
    );

    OcrSettings on(String provider, List<OcrProvider> all) => OcrSettings(
          enabled: true,
          provider: provider,
          keySource: 'platform',
          hasOwnKey: false,
          keys: const {},
          balance: 0,
          price: 0.3,
          providers: all,
        );

    // The control for everything below it. Nothing here may fire on a
    // photograph, or the module refuses the commonest capture there is.
    test('a photograph is never blocked', () {
      expect(
        pdfBlock(on('gemini', [gemini, claude]),
            isPdf: false, canAdmin: true, deviceReadsPdf: false),
        isNull,
      );
    });

    test('a reader that opens one is not blocked', () {
      expect(
        pdfBlock(on('claude', [gemini, claude]),
            isPdf: true, canAdmin: true, deviceReadsPdf: false),
        isNull,
      );
    });

    // The reported case, and the whole point of the commit.
    test('the chat-completions shape is blocked before the upload', () {
      final block = pdfBlock(on('gemini', [gemini, claude]),
          isPdf: true, canAdmin: true, deviceReadsPdf: false);
      expect(block, isNotNull);
      expect(block!.message, contains('Gemini'));
      expect(block.message, contains('Claude'));
      expect(block.hasAction, isTrue);
      expect(block.route, '/settings');
    });

    // Not loaded. The same bargain `scanBlock` makes: the edge function
    // is the real gate, and refusing on a question that has not come
    // back would be this file inventing an outage.
    test('a setting that has not loaded blocks nothing', () {
      expect(
        pdfBlock(null, isPdf: true, canAdmin: true, deviceReadsPdf: false),
        isNull,
      );
    });

    // Null means "nobody has said", and it has to read as a yes HERE --
    // a false would withdraw a reader the platform had just added, for
    // a refusal nobody has checked would happen.
    test('a reader nobody has answered for is let through', () {
      final unknown = reader(code: 'novel', name: 'Novel');
      expect(
        pdfBlock(on('novel', [unknown]),
            isPdf: true, canAdmin: true, deviceReadsPdf: false),
        isNull,
      );
    });

    // And as a no when it comes to RECOMMENDING one, which is the
    // asymmetry this pair exists to pin down. Promising "Novel opens
    // them" and then refusing one setting later is worse than the
    // sentence it replaced.
    test('but is never named as the way out', () {
      final unknown = reader(code: 'novel', name: 'Novel');
      final block = pdfBlock(on('gemini', [gemini, unknown]),
          isPdf: true, canAdmin: true, deviceReadsPdf: false);
      expect(block!.message, isNot(contains('Novel')));
      // Nothing to switch to, so no door -- the whole of `2f012feb`.
      expect(block.hasAction, isFalse);
      expect(block.route, isNull);
    });

    // `set_ocr_settings` refuses anybody but an administrator, so a
    // button to Settings would take an ordinary user to a control they
    // are about to be refused at.
    test('anybody else is told who switches it, with no door', () {
      final block = pdfBlock(on('gemini', [gemini, claude]),
          isPdf: true, canAdmin: false, deviceReadsPdf: false);
      expect(block!.hasAction, isFalse);
      expect(block.route, isNull);
      expect(block.message.toLowerCase(), contains('administrator'));
    });

    // A withdrawn reader, and one the platform has not finished setting
    // up, are both on the list `ocr_status` sends -- and neither is
    // somewhere anybody can be sent.
    test('a retired or unready reader is not offered', () {
      final retired = reader(
          code: 'claude', name: 'Claude', readsPdf: true, isActive: false);
      final unready = reader(
          code: 'google', name: 'Document AI', readsPdf: true, ready: false);
      final block = pdfBlock(on('gemini', [gemini, retired, unready]),
          isPdf: true, canAdmin: true, deviceReadsPdf: false);
      expect(block!.message, isNot(contains('Claude')));
      expect(block.message, isNot(contains('Document AI')));
      expect(block.hasAction, isFalse);
    });

    test('two of them are named as a list', () {
      final block = pdfBlock(on('gemini', [gemini, claude, docai]),
          isPdf: true, canAdmin: true, deviceReadsPdf: false);
      expect(block!.message, contains('Claude and Document AI'));
      expect(block.message, contains('open them'));
    });

    // The database declines to answer for the on-device reader because
    // it is `pdf.js` in a browser and ML Kit on a phone. Both halves,
    // because sending `true` would put the refusal in front of nobody
    // on a phone and sending `false` would put it in front of everybody
    // in a browser.
    test('a browser opens one on the device', () {
      expect(
        pdfBlock(on('mlkit', [onDevice]),
            isPdf: true, canAdmin: true, deviceReadsPdf: true),
        isNull,
      );
    });

    test('and a phone does not', () {
      final block = pdfBlock(on('mlkit', [onDevice, claude]),
          isPdf: true, canAdmin: true, deviceReadsPdf: false);
      expect(block, isNotNull);
      expect(block!.message, contains('The reader on this device'));
      expect(block.message, contains('Claude'));
    });

    // Whatever else it says, there is always a way forward: a
    // photograph of the page is read by every reader there is.
    test('the way forward is stated whatever the platform offers', () {
      for (final block in [
        pdfBlock(on('gemini', [gemini, claude]),
            isPdf: true, canAdmin: true, deviceReadsPdf: false),
        pdfBlock(on('gemini', [gemini]),
            isPdf: true, canAdmin: false, deviceReadsPdf: false),
      ]) {
        expect(block!.message, contains('Photographing the page'));
      }
    });
  });

  // ------------------------------------------------------------------
  // The line above the supplier search box
  //
  // The second half of the same report. The PDF was refused, so there
  // was no reading -- and the flow then asked "Which supplier?" over an
  // empty box and an unfiltered list of every contact on file, none of
  // them the one on the document, and said nothing about why.
  // ------------------------------------------------------------------
  group('what the supplier picker says it knows', () {
    test('the name, when the document gave one', () {
      expect(
        pickerNote(read(supplier: 'Global Components Bhd'),
            ScanContactKind.supplier),
        contains('Global Components Bhd'),
      );
    });

    // Nobody has looked at this page. Saying "nothing on it names a
    // supplier" would be a guess wearing the clothes of a finding --
    // `0686`'s distinction, arriving on this screen.
    test('and that nothing was read, when nothing was', () {
      final note = pickerNote(null, ScanContactKind.supplier);
      expect(note, contains('could not be read'));
      expect(note, isNot(contains('names a supplier')));
    });

    // Somebody HAS looked, and the page genuinely has no supplier on
    // it. A different sentence, because it is a different fact.
    test('and that the page names none, when it was read', () {
      final note = pickerNote(read(supplier: null), ScanContactKind.supplier);
      expect(note, contains('names a supplier'));
      expect(note, isNot(contains('could not be read')));
    });

    // `0682`. The same picker runs on the sales side, and EVERY
    // sentence in it has to change nouns or it asks somebody which
    // supplier their own customer is. More than one branch, because a
    // mutant that hardcoded `supplier` into the read-but-unnamed
    // sentence survived an assertion that only exercised the unread
    // one.
    test('and it says customer on the sales side, in every branch', () {
      expect(
        pickerNote(null, ScanContactKind.customer),
        contains('customer'),
      );
      final none = pickerNote(read(supplier: null), ScanContactKind.customer);
      expect(none, contains('names a customer'));
      expect(none, isNot(contains('supplier')));
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
