import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/features/documents/receipts_screen.dart';

/// Money in and money out.
///
/// Both were recordable from the day the settlement dialog was built
/// and neither was ever visible: a receipt sat posted in the database
/// with nothing able to show it. Two things live only in this widget.
///
/// MONEY LEFT ON ACCOUNT. A receipt with an unapplied balance is not
/// finished business, and the screen's own comment says it is invisible
/// on the invoice -- the invoice looks paid, the customer has been
/// over-credited, and nothing anywhere else says so. It is the number
/// people chase, and this is the only place it is shown.
///
/// AND WHICH DIRECTION THE ROW IS READ IN. A receipt keys on
/// `receipt_no` and `receipt_date`, a payment on `payment_no` and
/// `payment_date`. Every fixture here carries BOTH pairs with different
/// values, so a tile reading the wrong one shows a real-looking number
/// belonging to the other side of the ledger.
void main() {
  Map<String, dynamic> settlement({
    String id = 's1',
    String receiptNo = 'RC-0001',
    String paymentNo = 'PV-9999',
    String receiptDate = '2026-09-14',
    String paymentDate = '2026-01-02',
    String contact = 'Puan Aminah',
    num amount = 1200,
    num unapplied = 0,
    String currency = 'MYR',
    String status = 'posted',
    String? paymentMode = 'DD',
    String? reference = 'FT26091400123',
  }) => {
    'id': id,
    'receipt_no': receiptNo,
    'payment_no': paymentNo,
    'receipt_date': receiptDate,
    'payment_date': paymentDate,
    'contacts': {'name': contact, 'email': 'aminah@example.test'},
    'amount': amount,
    'unapplied_amount': unapplied,
    'currency': currency,
    'status': status,
    'payment_mode_code': paymentMode,
    'reference': reference,
  };

  Widget wrap(
    List<Map<String, dynamic>> rows, {
    String role = 'owner',
  }) => ProviderScope(
    overrides: [
      settlementsProvider(true).overrideWith((ref) async => rows),
      settlementsProvider(false).overrideWith((ref) async => rows),
      memberRoleProvider.overrideWith((ref) async => role),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      // The screen is a `PageBody` meant to be embedded, with no
      // Scaffold of its own.
      home: const Scaffold(body: ReceiptsScreen()),
    ),
  );

  Future<void> show(
    WidgetTester tester,
    List<Map<String, dynamic>> rows, {
    String role = 'owner',
  }) async {
    await tester.pumpWidget(wrap(rows, role: role));
    await tester.pumpAndSettle();
  }

  group('money left on account', () {
    testWidgets('is said on the row, in the receipt currency', (tester) async {
      // The invoice looks paid and says nothing about this. If the
      // screen does not show it, nobody finds it.
      await show(tester, [settlement(amount: 1200, unapplied: 300)]);

      expect(find.text('RM 300.00 on account'), findsOneWidget);
      // And not confused with the receipt total.
      expect(find.text('RM 1,200.00'), findsOneWidget);
    });

    testWidgets('and carries the currency the money arrived in',
        (tester) async {
      // A USD receipt with USD left on it must not read RM. The figure
      // would be right and the currency a factor of four out.
      await show(tester, [
        settlement(amount: 5000, unapplied: 1500, currency: 'USD'),
      ]);

      expect(find.text('USD 1,500.00 on account'), findsOneWidget);
      expect(find.textContaining('RM'), findsNothing);
    });

    testWidgets('a fully applied receipt says nothing about it',
        (tester) async {
      // The control. "RM 0.00 on account" on every settled receipt is
      // how a real one stops being noticed.
      await show(tester, [settlement(amount: 1200, unapplied: 0)]);

      expect(find.textContaining('on account'), findsNothing);
    });
  });

  group('which direction the row is read in', () {
    testWidgets('money in reads the receipt number and date', (tester) async {
      await show(tester, [
        settlement(receiptNo: 'RC-0001', paymentNo: 'PV-9999',
            receiptDate: '2026-09-14', paymentDate: '2026-01-02'),
      ]);

      expect(find.text('RC-0001'), findsOneWidget);
      // The payment fields are on the same row and belong to the other
      // tab. Showing either is showing somebody the wrong document.
      expect(find.text('PV-9999'), findsNothing);
      expect(find.textContaining('14/09/2026'), findsOneWidget);
      expect(find.textContaining('02/01/2026'), findsNothing);
    });

    testWidgets('and money out reads the payment number and date',
        (tester) async {
      await show(tester, [
        settlement(receiptNo: 'RC-0001', paymentNo: 'PV-9999',
            receiptDate: '2026-09-14', paymentDate: '2026-01-02'),
      ]);

      // The other side. Same row, read the other way.
      await tester.tap(find.text('Paid out'));
      await tester.pumpAndSettle();

      expect(find.text('PV-9999'), findsOneWidget);
      expect(find.text('RC-0001'), findsNothing);
      expect(find.textContaining('02/01/2026'), findsOneWidget);
    });
  });

  group('what else the row says', () {
    testWidgets('the contact, the mode and the bank reference',
        (tester) async {
      // The reference is what somebody matches against a statement
      // line, which is the reason this screen exists at all.
      await show(tester, [
        settlement(contact: 'Puan Aminah', paymentMode: 'DD',
            reference: 'FT26091400123'),
      ]);

      expect(
        find.textContaining('Puan Aminah  ·  14/09/2026  ·  DD  ·  '
            'FT26091400123'),
        findsOneWidget,
      );
      expect(find.byType(StatusChip), findsOneWidget);
    });

    testWidgets('and leaves out a mode and a reference it has not got',
        (tester) async {
      // Both are optional, and a row of dangling separators reads as
      // data that failed to load.
      await show(tester, [
        settlement(paymentMode: null, reference: null),
      ]);

      // Exact, not `textContaining`. An interpolation of a null field
      // renders the four letters "null", and a containing match on the
      // prefix finds the row happily with them on the end of it -- that
      // mutant survived until this assertion was pinned to the whole
      // string.
      expect(find.text('Puan Aminah  ·  14/09/2026'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
      // There is deliberately no `textContaining('·  ·')` check here.
      // The `.where((s) => s.trim().isNotEmpty)` below the list drops an
      // empty entry before it can double a separator, so that assertion
      // cannot fail whatever the guards above it do. The exact match is
      // what catches a dropped guard -- via the "null" it renders.
    });

    testWidgets('a reference of nothing but spaces is not a reference',
        (tester) async {
      // What an import leaves behind. A separator followed by blank is
      // worse than no separator, because it looks like something is
      // missing rather than absent.
      await show(tester, [settlement(reference: '   ')]);

      expect(find.text('Puan Aminah  ·  14/09/2026  ·  DD'), findsOneWidget);
      expect(find.textContaining('DD  ·'), findsNothing);
    });
  });

  group('the header at the width somebody holds', () {
    testWidgets('does not overflow on a phone', (tester) async {
      // This screen's header used to be a Row holding a segmented
      // control, "Across companies" and "Receive payment" with a Spacer
      // between: about 920 logical pixels of content. It overflowed by
      // 120 at the 800 the test surface defaults to, and by half the
      // screen again at the width below -- which is an ordinary phone,
      // and this app ships on phones.
      //
      // There is no assertion to write. A RenderFlex overflow IS a test
      // failure in Flutter, so rendering the screen at this size is the
      // whole check, and it fails against the Row it replaced.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 852);
      addTearDown(tester.view.reset);

      await show(tester, [settlement(unapplied: 300)]);

      expect(find.text('Received'), findsOneWidget);
      expect(find.text('Receive payment'), findsOneWidget);
    });

    testWidgets('and still fits when there are no buttons to fit',
        (tester) async {
      // A viewer gets neither action, so the header is the segmented
      // control alone -- the case that would have passed all along and
      // hidden the one above.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 852);
      addTearDown(tester.view.reset);

      await show(tester, [settlement()], role: 'viewer');

      expect(find.text('Received'), findsOneWidget);
      expect(find.text('Receive payment'), findsNothing);
      expect(find.text('Across companies'), findsNothing);
    });
  });

  group('nothing received', () {
    testWidgets('the screen is still usable', (tester) async {
      await show(tester, []);

      // Both directions reachable with no rows: the screen was
      // unreachable for its whole life before this, and an empty one
      // that throws is the same defect wearing a different hat.
      expect(find.text('Received'), findsOneWidget);
      expect(find.text('Paid out'), findsOneWidget);
      expect(find.byType(StatusChip), findsNothing);
      expect(find.text('No payments received yet'), findsOneWidget);
    });
  });
}
