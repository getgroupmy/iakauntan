import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/einvoice/einvoice_screen.dart';

/// The LHDN document list.
///
/// `pos_einvoice_test.dart` covers the consolidation panel at the top of
/// this screen. The list underneath it -- every document that has been
/// or will be submitted to MyInvois -- had nothing.
///
/// Three things live only here.
///
/// THE 72-HOUR WINDOW. LHDN lets a supplier cancel inside 72 hours of
/// validation and not one minute after. Past it the only remedy is a
/// credit note, which is a different document with different
/// consequences, and the screen has to say which of the two somebody is
/// looking at. The hours are clamped to 0..72, so a deadline the wrong
/// side of now cannot render a negative countdown on a button.
///
/// WHAT A REJECTION SAYS. LHDN nests its errors three different ways
/// depending on which stage failed, and a rejection nobody can read is
/// a rejection nobody can fix. All three shapes are asserted.
///
/// AND THE TYPE CODE. "01" and "11" are an invoice and a SELF-BILLED
/// invoice -- different documents, filed by different parties. A screen
/// showing the raw code tells a bookkeeper nothing; one showing the
/// wrong name tells them something false.
void main() {
  EinvoiceDocument doc({
    String id = 'e1',
    String docNo = 'INV-0001',
    String status = 'valid',
    String typeCode = '01',
    String? buyerName = 'Kedai Kopi Ah Seng Sdn Bhd',
    double payable = 1060,
    String? uuid = 'F9D425P6DS7D8IU',
    String? validationLink,
    String? errorMessage,
    List<dynamic> validationErrors = const [],
    DateTime? validatedAt,
    DateTime? cancelDeadline,
    String currency = 'MYR',
  }) => EinvoiceDocument(
    id: id,
    internalDocNo: docNo,
    status: status,
    typeCode: typeCode,
    issueDate: DateTime(2026, 8, 31),
    buyerName: buyerName,
    payableAmount: payable,
    myinvoisUuid: uuid,
    validationLink: validationLink,
    errorMessage: errorMessage,
    validationErrors: validationErrors,
    validatedAt: validatedAt,
    cancelDeadline: cancelDeadline,
    currency: currency,
  );

  Widget wrap(List<EinvoiceDocument> docs, {bool einvoiceEnabled = true}) =>
      ProviderScope(
        overrides: [
          einvoicesProvider('all').overrideWith((ref) async => docs),
          posEinvoiceOutstandingProvider.overrideWith((ref) async => const []),
          currentOrgProvider.overrideWith(
            (ref) async => Organization(
              id: 'o1',
              name: 'Rantaian Maju Sdn Bhd',
              slug: 'rantaian',
              einvoiceEnabled: einvoiceEnabled,
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const EinvoiceScreen(),
        ),
      );

  Future<void> show(
    WidgetTester tester,
    List<EinvoiceDocument> docs, {
    bool einvoiceEnabled = true,
  }) async {
    await tester.pumpWidget(wrap(docs, einvoiceEnabled: einvoiceEnabled));
    await tester.pumpAndSettle();
  }

  Future<void> expand(WidgetTester tester, [String docNo = 'INV-0001']) async {
    await tester.tap(find.text(docNo));
    await tester.pumpAndSettle();
  }

  group('the 72-hour window', () {
    testWidgets('an invoice inside it may be cancelled, and says how long',
        (tester) async {
      await show(tester, [
        doc(
          status: 'valid',
          validatedAt: DateTime.now().subtract(const Duration(hours: 2)),
          // Seventy hours and a half. `Duration.inHours` TRUNCATES, and
          // the widget computes the difference a moment after the test
          // builds it -- so an exact 70 arrives as 69, which is a real
          // property of the screen and a trap for the fixture.
          cancelDeadline:
              DateTime.now().add(const Duration(hours: 70, minutes: 30)),
        ),
      ]);
      await expand(tester);

      expect(find.textContaining('Cancel (70h left)'), findsOneWidget);
      expect(find.textContaining('Cancellation window'), findsOneWidget);
      expect(find.textContaining('closes'), findsOneWidget);
    });

    testWidgets('and one past it is told to issue a credit note instead',
        (tester) async {
      // Not merely "cannot cancel". A credit note is a different
      // document with different consequences, and this is the only
      // place the screen can say which remedy is left.
      await show(tester, [
        doc(
          status: 'valid',
          validatedAt: DateTime.now().subtract(const Duration(days: 5)),
          cancelDeadline: DateTime.now().subtract(const Duration(hours: 1)),
        ),
      ]);
      await expand(tester);

      expect(find.textContaining('closed — issue a credit note instead'),
          findsOneWidget);
      expect(find.textContaining('Cancel ('), findsNothing);
    });

    testWidgets('a deadline further out than LHDN allows is still 72',
        (tester) async {
      // The clamp. A deadline stored wrongly -- a day out, a timezone
      // out -- must not put "Cancel (240h left)" on a button and invite
      // somebody to rely on it.
      await show(tester, [
        doc(
          status: 'valid',
          validatedAt: DateTime.now(),
          cancelDeadline: DateTime.now().add(const Duration(days: 10)),
        ),
      ]);
      await expand(tester);

      expect(find.textContaining('Cancel (72h left)'), findsOneWidget);
    });

    testWidgets('a document with no deadline at all offers no cancel',
        (tester) async {
      await show(tester, [
        doc(status: 'valid', validatedAt: DateTime.now(),
            cancelDeadline: null),
      ]);
      await expand(tester);

      expect(find.textContaining('Cancel ('), findsNothing);
      expect(find.textContaining('issue a credit note instead'),
          findsOneWidget);
    });
  });

  group('what a rejection says', () {
    testWidgets('a bare string error is shown as it came', (tester) async {
      await show(tester, [
        doc(
          status: 'invalid',
          errorMessage: 'Document rejected',
          validationErrors: const ['Supplier TIN does not match the taxpayer'],
        ),
      ]);
      await expand(tester);

      expect(find.text('Document rejected'), findsOneWidget);
      expect(find.text('• Supplier TIN does not match the taxpayer'),
          findsOneWidget);
    });

    testWidgets('a flat map is joined on its own fields', (tester) async {
      await show(tester, [
        doc(
          status: 'invalid',
          errorMessage: 'Rejected',
          validationErrors: const [
            {'code': 'CF321', 'message': 'Invalid tax type', 'status': 'Invalid'},
          ],
        ),
      ]);
      await expand(tester);

      expect(find.text('• CF321 · Invalid tax type · Invalid'), findsOneWidget);
    });

    testWidgets('and a nested one reads the inner error', (tester) async {
      // The other shape LHDN uses, depending on which stage failed.
      // Joining the OUTER keys here would print nothing useful at all.
      await show(tester, [
        doc(
          status: 'invalid',
          errorMessage: 'Rejected',
          validationErrors: const [
            {
              'error': {'code': 'DS302', 'message': 'Digital signature invalid'},
            },
          ],
        ),
      ]);
      await expand(tester);

      expect(find.text('• DS302: Digital signature invalid'), findsOneWidget);
    });

    testWidgets('a failure with no message still says who rejected it',
        (tester) async {
      // `errorMessage` is null when the submission never reached a
      // validation stage. "Rejected by LHDN" is better than an empty
      // red box.
      await show(tester, [doc(status: 'failed', errorMessage: null)]);
      await expand(tester);

      expect(find.text('Rejected by LHDN'), findsOneWidget);
    });

    testWidgets('and a rejected document is offered a resubmit',
        (tester) async {
      await show(tester, [doc(status: 'invalid', errorMessage: 'Rejected')]);
      await expand(tester);

      expect(find.text('Resubmit'), findsOneWidget);
    });

    testWidgets('which a valid one is not', (tester) async {
      // The control. Resubmitting a validated invoice would file it
      // twice.
      await show(tester, [
        doc(status: 'valid', validatedAt: DateTime.now()),
      ]);
      await expand(tester);

      expect(find.text('Resubmit'), findsNothing);
    });
  });

  group('which document this is', () {
    testWidgets('an invoice and a self-billed invoice are named apart',
        (tester) async {
      // 01 and 11. Different documents, filed by different parties; the
      // raw code tells a bookkeeper nothing and the wrong name tells
      // them something false.
      await show(tester, [
        doc(id: 'a', docNo: 'INV-0001', typeCode: '01'),
        doc(id: 'b', docNo: 'SB-0001', typeCode: '11'),
      ]);

      // Exact, not containing: "Self-billed Invoice · ..." CONTAINS
      // "Invoice · ...", so a containing match finds both rows and the
      // assertion asks nothing.
      expect(
        find.text('Invoice · Kedai Kopi Ah Seng Sdn Bhd · 31/08/2026'),
        findsOneWidget,
      );
      expect(
        find.text(
            'Self-billed Invoice · Kedai Kopi Ah Seng Sdn Bhd · 31/08/2026'),
        findsOneWidget,
      );
    });

    testWidgets('a code nobody has mapped falls back to the code itself',
        (tester) async {
      // Better than a blank: a code on screen can be looked up in the
      // LHDN list, and an empty space cannot.
      await show(tester, [doc(typeCode: '99')]);

      expect(find.textContaining('99 · Kedai Kopi'), findsOneWidget);
    });

    testWidgets('and the payable amount carries its currency',
        (tester) async {
      await show(tester, [doc(payable: 5000, currency: 'USD')]);

      expect(find.text('USD 5,000.00'), findsOneWidget);
    });
  });

  group('when e-Invoice has not been switched on', () {
    testWidgets('the banner says what is missing and where it goes',
        (tester) async {
      await show(tester, const [], einvoiceEnabled: false);

      expect(find.textContaining('e-Invoice is switched off'), findsOneWidget);
      // Names both halves of the credential and where they are entered,
      // because "switched off" on its own is not something anybody can
      // act on.
      expect(find.textContaining('MyInvois client ID and secret'),
          findsOneWidget);
      expect(find.textContaining('under Settings'), findsOneWidget);
    });

    testWidgets('and is absent once it is on', (tester) async {
      await show(tester, const [], einvoiceEnabled: true);

      expect(find.textContaining('e-Invoice is switched off'), findsNothing);
    });
  });
}
