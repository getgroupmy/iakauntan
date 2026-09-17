import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/ea_form_repository.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/hr/ea_form_pdf.dart';
import 'package:iakauntan/src/features/hr/ea_forms_screen.dart';

/// The EA form: the statement of remuneration an employer hands every
/// employee by the end of February.
///
/// `ea_form.sql` asserts the figures — that a previous employer's
/// salary is in no total, that the year is the year of the pay date,
/// that PCB and CP38 are two boxes. This is the other side: what the
/// screen and the printed form do with those figures once they arrive.
///
/// Two of these are about the same defect in opposite directions. An
/// employee who joined in July holds TWO EA forms for the year. If this
/// one included the first job they declare that salary twice; if it
/// silently omitted it they cannot tell whether it was forgotten. So the
/// figure is off every total and printed at the foot with the reason,
/// and both halves are asserted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Organization org() => Organization(
    id: 'o',
    name: 'Borang EA Sdn Bhd',
    slug: 'borang-ea',
    entityType: 'sdn_bhd',
    baseCurrency: 'MYR',
  );

  EaStatement statement({
    EaPreviousEmployer? previous,
    List<EaBox>? boxes,
    String? incomeTaxNo = 'SG 1111111111',
    String? nric = '900101015566',
    String? passportNo,
    String? epfNo = 'K9876543',
    double epfEmployee = 660,
    double zakat = 0,
  }) => EaStatement(
    taxYear: 2025,
    employerName: 'Borang EA Sdn Bhd',
    employerTaxNo: 'E 1234567890',
    employeeName: 'Nurul Huda',
    employeeNo: 'E1',
    nric: nric,
    passportNo: passportNo,
    incomeTaxNo: incomeTaxNo,
    employeeEpfNo: epfNo,
    employedFrom: DateTime(2025, 1, 1),
    employedTo: DateTime(2025, 12, 31),
    boxes:
        boxes ??
        const [
          EaBox(
            code: 'salary',
            part: 'B',
            box: '1(a)',
            label: 'Gross salary, wages or leave pay',
            amount: 60000,
          ),
          EaBox(
            code: 'fees_bonus',
            part: 'B',
            box: '1(b)',
            label: 'Fees, commission or bonus',
            amount: 5000,
          ),
          EaBox(
            code: 'exempt',
            part: 'F',
            box: '1',
            label: 'Tax exempt allowances, perquisites, gifts or benefits',
            amount: 2400,
            isExempt: true,
          ),
        ],
    grossPay: 67400,
    mtd: 3600,
    cp38: 1200,
    zakat: zakat,
    epfEmployee: epfEmployee,
    epfEmployer: 7800,
    socsoEmployee: 237.50,
    eisEmployee: 47.50,
    monthsPaid: 12,
    previousEmployer: previous,
  );

  group('what the form adds up', () {
    test('the exempt allowances are not in the remuneration total', () {
      // Part F is not taxed. An employee who adds it into their income
      // pays tax on money the law says they should not.
      final ea = statement();
      expect(ea.totalChargeable, 65000);
      expect(ea.exempt.single.amount, 2400);
    });

    test('and the deductions total is MTD, CP38 and zakat', () {
      expect(statement().totalDeductions, 4800);
      // Zakat is deducted through payroll and remitted to a state
      // authority. It is a third box on the form and a third number in
      // the total; leaving it out understates what was taken off the
      // employee's pay by exactly the amount they gave.
      expect(statement(zakat: 1500).totalDeductions, 6300);
    });

    test('a form with everything on it is missing nothing', () {
      expect(statement().missing, isEmpty);
    });

    test('and one without a tax file number says so', () {
      // The one that matters: the employee cannot file against a form
      // that does not carry it.
      expect(statement(incomeTaxNo: null).missing, contains('income tax number'));
      expect(statement(incomeTaxNo: '  ').missing,
          contains('income tax number'));
    });

    test('an EPF number is only missing where EPF was deducted', () {
      // Somebody over sixty with no EPF contribution does not need one
      // on the form, and flagging them would train an employer to
      // ignore the flag.
      expect(statement(epfNo: null, epfEmployee: 0).missing,
          isNot(contains('EPF number')));
      expect(statement(epfNo: null, epfEmployee: 660).missing,
          contains('EPF number'));
    });

    test('NRIC or passport, either one', () {
      expect(statement(nric: null).missing, contains('NRIC or passport'));
      // A non-citizen has a passport and no NRIC, and a form that
      // demanded one anyway would be flagged incomplete for every
      // foreign worker on the payroll — which is how an employer learns
      // to ignore the flag.
      expect(
        statement(nric: null, passportNo: 'A12345678').missing,
        isNot(contains('NRIC or passport')),
      );
    });
  });

  group('the printed form', () {
    test('is a real PDF', () async {
      final bytes = await buildEaFormPdf(org: org(), ea: statement());
      expect(
        String.fromCharCodes(bytes.take(5)),
        '%PDF-',
        reason: 'the magic number, so this is a PDF and not a hopeful blob',
      );
      expect(
        String.fromCharCodes(bytes.skip(bytes.length - 6)).trim(),
        '%%EOF',
      );
    });

    test('prints even where nothing was paid', () async {
      // A leaver who was paid in one year and issued a form for the
      // next. An empty form is still a form, and throwing here would
      // take the whole batch down with it.
      final bytes = await buildEaFormPdf(
        org: org(),
        ea: statement(boxes: const []),
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('and with a previous employer on it', () async {
      final bytes = await buildEaFormPdf(
        org: org(),
        ea: statement(
          previous: const EaPreviousEmployer(
            grossPay: 40000,
            epfEmployee: 4400,
            pcbPaid: 1500,
            zakatPaid: 0,
            benefitsInKind: 2000,
          ),
        ),
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      // Bigger than the one without it, because the block is on the
      // page. Not a proof of the words, but a proof that the branch
      // rendered rather than being compiled out.
      final without = await buildEaFormPdf(org: org(), ea: statement());
      expect(bytes.length, greaterThan(without.length));
    });

    test('an unverified rate table travels with the warning', () async {
      final warned = await buildEaFormPdf(
        org: org(),
        ea: statement(),
        schedulesVerified: false,
      );
      final quiet = await buildEaFormPdf(org: org(), ea: statement());
      expect(warned.length, greaterThan(quiet.length));
    });
  });

  group('the list of who is owed one', () {
    const ready = EaSummary(
      employeeId: 'a',
      employeeNo: 'E1',
      name: 'Nurul Huda',
      monthsPaid: 12,
      grossPay: 67400,
      mtd: 3600,
      cp38: 1200,
      missing: [],
    );
    const leaver = EaSummary(
      employeeId: 'b',
      employeeNo: 'E2',
      name: 'Sudah Pergi',
      employmentStatus: 'resigned',
      monthsPaid: 3,
      grossPay: 12000,
      mtd: 0,
      cp38: 0,
      hasPreviousEmployer: true,
      missing: ['income tax number'],
    );

    Widget harness(List<EaSummary> rows) => ProviderScope(
      overrides: [
        eaFormsProvider.overrideWith((ref, year) async => rows),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const EaFormsScreen()),
    );

    Future<void> wide(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('a leaver is on it', (tester) async {
      await wide(tester);
      await tester.pumpWidget(harness(const [ready, leaver]));
      await tester.pumpAndSettle();

      // Somebody who resigned in March is owed a form for the months
      // they were here, and is the person most likely to chase it.
      expect(find.text('Sudah Pergi'), findsOneWidget);
      expect(find.text('Left'), findsOneWidget);
    });

    testWidgets('and what is missing is said before the form is made', (
      tester,
    ) async {
      await wide(tester);
      await tester.pumpWidget(harness(const [ready, leaver]));
      await tester.pumpAndSettle();

      expect(find.text('Incomplete'), findsOneWidget);
      expect(
        find.textContaining('No income tax number'),
        findsOneWidget,
        reason: 'named on the row, not left to be found at the counter',
      );
      expect(
        find.textContaining('One form is missing something'),
        findsOneWidget,
      );
    });

    testWidgets('somebody with an earlier job is marked', (tester) async {
      await wide(tester);
      await tester.pumpWidget(harness(const [ready, leaver]));
      await tester.pumpAndSettle();

      // They hold two forms for the year and the two do not add up to
      // their income unless both are declared.
      expect(find.text('Earlier Job'), findsOneWidget);
    });

    testWidgets('a complete row carries no marks at all', (tester) async {
      await wide(tester);
      await tester.pumpWidget(harness(const [ready]));
      await tester.pumpAndSettle();

      expect(find.text('Incomplete'), findsNothing);
      expect(find.text('Left'), findsNothing);
      expect(find.text('Earlier Job'), findsNothing);
      expect(find.textContaining('missing something'), findsNothing);
      // And the download is offered, which is the point of the screen.
      expect(find.byKey(const ValueKey('ea-download-a')), findsOneWidget);
    });

    testWidgets('nobody paid that year says which year to try', (
      tester,
    ) async {
      await wide(tester);
      await tester.pumpWidget(harness(const []));
      await tester.pumpAndSettle();

      // "2025 payroll" and "the 2025 EA form" are not the same twelve
      // payslips, and somebody looking at an empty screen needs to be
      // told that rather than concluding the data is gone.
      expect(find.textContaining('PAID in a year'), findsOneWidget);
    });

    testWidgets('the year it opens on is the one that has finished', (
      tester,
    ) async {
      await wide(tester);
      await tester.pumpWidget(harness(const [ready]));
      await tester.pumpAndSettle();

      // An EA form is issued in February for the year just ended.
      // Opening on the current year shows a form nobody can file yet.
      final picker = tester.widget<DropdownButton<int>>(
        find.byKey(const ValueKey('ea-year')),
      );
      expect(picker.value, DateTime.now().year - 1);
    });
  });
}
