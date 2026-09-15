import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/features/documents/withholding_screen.dart';

/// Tax deducted from non-residents, and when it has to reach LHDN.
///
/// Three things live only in this widget, and each is the reason
/// somebody opens the screen at all.
///
/// GROUPING IS BY FORM, not by supplier, because the form is the unit
/// of work: CP37 and CP37A are filed separately and somebody sitting
/// down to file one does not want the other interleaved. The group
/// heading carries a total, and a total folded over the whole list
/// instead of the group would hand the person filing a CP37 the figure
/// for both forms together -- which is a wrong number on a return.
///
/// THE LATE PANEL is s.109(2): ten per cent on tax that misses its
/// month, and the expense stays disallowed until it is paid. It sums
/// only the overdue rows. Summing all of them inflates the figure with
/// penalties nobody is at risk of, and summing none of them is a screen
/// that stopped warning.
///
/// AND WHO MAY REMIT. Marking tax as remitted says the money went to
/// LHDN. A viewer must not be offered that button.
void main() {
  Map<String, dynamic> cert({
    String id = 'c1',
    String form = 'CP37',
    String contact = 'Trinity Systems Pte Ltd',
    String certificateNo = 'WHT-0001',
    String section = 's.109',
    num gross = 10000,
    num rate = 10,
    num tax = 1000,
    num penalty = 0,
    String due = '2026-09-30',
    String? remittedOn,
  }) => {
    'certificate_id': id,
    'form_code': form,
    'contact_name': contact,
    'certificate_no': certificateNo,
    'section': section,
    'gross_amount': gross,
    'rate': rate,
    'base_tax_amount': tax,
    'penalty_if_unpaid': penalty,
    'due_date': due,
    'remitted_on': remittedOn,
  };

  Widget wrap(List<Map<String, dynamic>> rows, {String role = 'owner'}) =>
      ProviderScope(
        overrides: [
          withholdingReportProvider.overrideWith((ref) async => rows),
          memberRoleProvider.overrideWith((ref) async => role),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const WithholdingScreen(),
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

  group('the form is the unit of work', () {
    testWidgets('each form gets its own heading and its own total',
        (tester) async {
      await show(tester, [
        cert(id: 'a', form: 'CP37', tax: 1000),
        cert(id: 'b', form: 'CP37', tax: 500, contact: 'Alpha Consulting'),
        cert(id: 'c', form: 'CP37A', tax: 250, contact: 'Beta Holdings'),
      ]);

      expect(find.text('CP37'), findsOneWidget);
      expect(find.text('CP37A'), findsOneWidget);

      // RM 1,500 under CP37 and RM 250 under CP37A. A fold over the
      // whole list would put RM 1,750 under both, which is the figure
      // somebody would carry onto a return.
      expect(find.textContaining('RM 1,500.00 deducted'), findsOneWidget);
      expect(find.textContaining('RM 250.00 deducted'), findsOneWidget);
      expect(find.textContaining('RM 1,750.00 deducted'), findsNothing);
    });

    testWidgets('a form holding one certificate says certificate, not '
        'certificates', (tester) async {
      await show(tester, [cert(form: 'CP37A', tax: 250)]);

      expect(find.textContaining('1 certificate ·'), findsOneWidget);
      expect(find.textContaining('certificates'), findsNothing);
    });

    testWidgets('and two say certificates', (tester) async {
      await show(tester, [
        cert(id: 'a', form: 'CP37'),
        cert(id: 'b', form: 'CP37', contact: 'Alpha Consulting'),
      ]);

      expect(find.textContaining('2 certificates'), findsOneWidget);
    });

    testWidgets('a row with no form code is still shown', (tester) async {
      // Grouped under an em dash rather than dropped: a certificate the
      // screen cannot classify is still tax somebody withheld, and
      // silently omitting it is how it goes unfiled.
      await show(tester, [cert(form: '', tax: 400)..remove('form_code')]);

      expect(find.text('—'), findsOneWidget);
      expect(find.textContaining('RM 400.00 deducted'), findsOneWidget);
      expect(find.text('Trinity Systems Pte Ltd'), findsOneWidget);
    });
  });

  group('what section 109(2) costs', () {
    testWidgets('the late panel counts and sums only the overdue rows',
        (tester) async {
      await show(tester, [
        cert(id: 'a', penalty: 100, tax: 1000),
        cert(id: 'b', penalty: 50, tax: 500, contact: 'Alpha Consulting'),
        cert(id: 'c', penalty: 0, tax: 250, contact: 'Beta Holdings'),
      ]);

      expect(find.text('2 past their month'), findsOneWidget);
      // RM 150, not RM 250: the third row is not late and nobody is at
      // risk of a penalty on it.
      expect(find.textContaining('RM 150.00 on these'), findsOneWidget);
    });

    testWidgets('and says what the section does, including the disallowance',
        (tester) async {
      await show(tester, [cert(penalty: 100)]);

      expect(find.textContaining('Section 109(2)'), findsOneWidget);
      expect(find.textContaining('ten per cent'), findsOneWidget);
      // The consequence a company does not expect. Losing the deduction
      // usually costs more than the penalty.
      expect(
        find.textContaining('the expense stays disallowed until the tax is '
            'paid'),
        findsOneWidget,
      );
    });

    testWidgets('nothing late, no panel', (tester) async {
      // The control. The panel is conditional, and a test that only ever
      // sees it present cannot tell it from one always drawn.
      await show(tester, [cert(penalty: 0), cert(id: 'b', penalty: 0)]);

      expect(find.textContaining('past their month'), findsNothing);
      expect(find.textContaining('Section 109(2)'), findsNothing);
    });
  });

  group('the certificate itself', () {
    testWidgets('carries the number, the section, the gross and the rate',
        (tester) async {
      await show(tester, [
        cert(
          certificateNo: 'WHT-0007',
          section: 's.109B',
          gross: 24000,
          rate: 10,
          tax: 2400,
          due: '2026-09-30',
        ),
      ]);

      // The rate is fixed to two places: a statutory rate reading "10%"
      // and one reading "10.00%" are the same number, but 4.5 rendering
      // as "4.5%" beside "10.00%" is what makes a reader check.
      expect(
        find.text('WHT-0007 · s.109B · RM 24,000.00 at 10.00% · '
            'due 30/09/2026'),
        findsOneWidget,
      );
    });

    testWidgets('a remitted one says when, and is not offered again',
        (tester) async {
      await show(tester, [cert(remittedOn: '2026-09-12', due: '2026-09-30')]);

      // The remittance date replaces the due date -- once the money has
      // gone, when it was due is no longer the question.
      expect(find.textContaining('remitted 12/09/2026'), findsOneWidget);
      expect(find.textContaining('due 30/09/2026'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Remit'), findsNothing);
      expect(find.byType(StatusChip), findsOneWidget);
    });

    testWidgets('an outstanding one is offered to somebody who may post',
        (tester) async {
      await show(tester, [cert()]);

      expect(find.widgetWithText(TextButton, 'Remit'), findsOneWidget);
    });

    testWidgets('and never to a viewer', (tester) async {
      // Marking tax as remitted asserts the money reached LHDN. Somebody
      // who cannot post must not be able to say so.
      await show(tester, [cert()], role: 'viewer');

      expect(find.widgetWithText(TextButton, 'Remit'), findsNothing);
      // The row is still readable -- this is not a permission that hides
      // the tax, only one that withholds the button.
      expect(find.text('Trinity Systems Pte Ltd'), findsOneWidget);
    });
  });

  group('nothing withheld', () {
    testWidgets('says how one comes to exist', (tester) async {
      // An empty list here is the ordinary case for most companies, so
      // the screen explains rather than looking broken.
      await show(tester, []);

      expect(find.text('Nothing withheld'), findsOneWidget);
      expect(find.textContaining('Open a posted bill from a non-resident'),
          findsOneWidget);
      expect(find.textContaining('Withhold tax'), findsOneWidget);
    });
  });
}
