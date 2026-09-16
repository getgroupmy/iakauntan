import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/format.dart';
import '../../core/pdf_kit.dart';
import '../../data/ea_form_repository.dart';
import '../../data/models.dart';

/// The EA form: C.P.8A, the statement of remuneration an employer gives
/// every employee by the end of February.
///
/// It is not a machine file. Nothing parses it — the employee reads it
/// and copies the figures onto their own return — so what has to be
/// right is the arithmetic and the labelling, and both come from
/// `ea_statement` in `0608` rather than being worked out again here.
///
/// ## Two things are said on the paper rather than left to be inferred
///
/// **What a previous employer paid.** It is in no total on this form,
/// and it is printed at the foot with the reason. An employee who
/// joined in July holds two EA forms for the year; if this one silently
/// omitted the first job they would reasonably wonder whether it had
/// been forgotten, and if it included it they would declare the salary
/// twice.
///
/// **Boxes with nothing in them are not printed.** A C.P.8A with a
/// column of dashes against ten boxes is harder to read than one with
/// three lines on it, and an empty box carries no information: the form
/// is a statement of what was paid.
Future<Uint8List> buildEaFormPdf({
  required Organization org,
  required EaStatement ea,
  Uint8List? logo,
  LetterheadMode mode = LetterheadMode.printed,
  bool schedulesVerified = true,
}) async {
  final kit = await PdfKit.load();
  final pdf = pw.Document(
    title: 'EA ${ea.taxYear} ${ea.employeeName}',
  );

  String date(DateTime? d) => d == null ? '' : Fmt.date(d);

  final chargeable = ea.chargeable.where((b) => b.amount != 0).toList();
  final exempt = ea.exempt.where((b) => b.amount != 0).toList();

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(42, 42, 42, 36),
      theme: kit.theme,
      footer: (context) =>
          kit.footer(context, note: 'Private and confidential'),
      build: (context) => [
        kit.letterhead(
          org,
          documentLabel: 'Borang EA  ·  C.P.8A  ·  ${ea.taxYear}',
          logo: logo,
          mode: mode,
        ),
        kit.rule(),

        pw.Text(
          'STATEMENT OF REMUNERATION FROM EMPLOYMENT '
          'FOR THE YEAR ENDED 31 DECEMBER ${ea.taxYear}',
          style: kit.style(size: 9, strong: true),
        ),
        pw.SizedBox(height: 12),

        // ------------------------------------------------------------
        // Part A: who this is about, and who paid them
        // ------------------------------------------------------------
        _heading(kit, 'A  Particulars of employee'),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              flex: 3,
              child: kit.field('Name', ea.employeeName, strong: true),
            ),
            pw.Expanded(
              flex: 2,
              child: kit.field('Staff number', ea.employeeNo ?? ''),
            ),
            pw.Expanded(
              flex: 2,
              // Whichever they have. A non-citizen has a passport and no
              // NRIC, and a form with an empty NRIC box and nothing else
              // does not identify anybody.
              child: kit.field(
                ea.nric != null ? 'NRIC' : 'Passport',
                ea.nric ?? ea.passportNo ?? '',
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              flex: 3,
              child: kit.field(
                'Income tax number',
                ea.incomeTaxNo ?? '',
                strong: true,
              ),
            ),
            pw.Expanded(
              flex: 2,
              child: kit.field('EPF number', ea.employeeEpfNo ?? ''),
            ),
            pw.Expanded(
              flex: 2,
              child: kit.field(
                'Period of employment',
                [date(ea.employedFrom), date(ea.employedTo)]
                    .where((s) => s.isNotEmpty)
                    .join(' – '),
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              flex: 3,
              child: kit.field('Employer', ea.employerName, strong: true),
            ),
            pw.Expanded(
              flex: 2,
              child: kit.field("Employer's number", ea.employerTaxNo ?? ''),
            ),
            pw.Expanded(
              flex: 2,
              child: kit.field('Months paid', '${ea.monthsPaid}'),
            ),
          ],
        ),

        pw.SizedBox(height: 16),

        // ------------------------------------------------------------
        // Parts B and C: what was paid
        // ------------------------------------------------------------
        _heading(kit, 'B and C  Remuneration'),
        if (chargeable.isEmpty)
          pw.Text(
            'Nothing was paid in this year of assessment.',
            style: kit.style(colour: PdfColors.grey700),
          )
        else
          for (final b in chargeable) _boxRow(kit, b),
        pw.Container(
          margin: const pw.EdgeInsets.symmetric(vertical: 5),
          height: 0.7,
          color: PdfColors.grey400,
        ),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Total remuneration',
              style: kit.style(size: 10, strong: true),
            ),
            pw.Text(
              Fmt.money(ea.totalChargeable),
              style: kit.style(size: 10, strong: true),
            ),
          ],
        ),

        pw.SizedBox(height: 16),

        // ------------------------------------------------------------
        // Part D: what was taken off
        // ------------------------------------------------------------
        _heading(kit, 'D  Deductions'),
        kit.amountRow('D 1  Monthly tax deduction (MTD/PCB)', ea.mtd,
            width: 300),
        kit.amountRow('D 2  CP38 instalment', ea.cp38, width: 300),
        kit.amountRow('D 3  Zakat paid through salary deduction', ea.zakat,
            width: 300),
        kit.amountRow('Total deductions', ea.totalDeductions,
            strong: true, width: 300),

        pw.SizedBox(height: 16),

        // ------------------------------------------------------------
        // Part E: contributions
        // ------------------------------------------------------------
        _heading(kit, 'E  Contributions'),
        kit.amountRow("Employee's EPF", ea.epfEmployee, width: 300),
        kit.amountRow("Employer's EPF", ea.epfEmployer, width: 300),
        kit.amountRow("Employee's SOCSO", ea.socsoEmployee, width: 300),
        kit.amountRow("Employee's EIS", ea.eisEmployee, width: 300),

        if (exempt.isNotEmpty) ...[
          pw.SizedBox(height: 16),
          _heading(kit, 'F  Tax exempt allowances, perquisites and gifts'),
          for (final b in exempt) _boxRow(kit, b),
          pw.SizedBox(height: 4),
          pw.Text(
            'Not included in the total remuneration above, and not '
            'taxable.',
            style: kit.style(size: 7.5, colour: PdfColors.grey600),
          ),
        ],

        // ------------------------------------------------------------
        // What somebody else paid, which is on no line above
        // ------------------------------------------------------------
        if (ea.previousEmployer != null) ...[
          pw.SizedBox(height: 18),
          pw.Container(
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey500, width: 0.7),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'Paid by a previous employer in ${ea.taxYear} — '
                  'NOT included in any figure on this form',
                  style: kit.style(size: 8, strong: true),
                ),
                pw.SizedBox(height: 4),
                kit.amountRow(
                  'Gross remuneration',
                  ea.previousEmployer!.grossPay,
                  width: 300,
                ),
                kit.amountRow(
                  'Tax deducted',
                  ea.previousEmployer!.pcbPaid,
                  width: 300,
                ),
                kit.amountRow(
                  "Employee's EPF",
                  ea.previousEmployer!.epfEmployee,
                  width: 300,
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  'Recorded here so this year’s tax was deducted on the '
                  'right cumulative figure. That employer issues their own '
                  'EA form for it; declare it from theirs, not from this.',
                  style: kit.style(size: 7.5, colour: PdfColors.grey700),
                ),
              ],
            ),
          ),
        ],

        // The same warning the payslip carries, for the same reason and
        // about the same tables: an EA form is a year of payslips added
        // up, so a figure that could not travel on one of those must not
        // travel on their total either.
        if (!schedulesVerified) ...[
          pw.SizedBox(height: 18),
          pw.Container(
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.orange700, width: 0.7),
            ),
            child: pw.Text(
              'The EPF, SOCSO, EIS and PCB figures on this form were '
              'calculated from contribution tables that have not been '
              'checked against the gazetted schedules. Do not rely on them '
              'for a statutory return.',
              style: kit.style(size: 8, colour: PdfColors.orange900),
            ),
          ),
        ],

        pw.SizedBox(height: 18),
        pw.Text(
          'This is a computer-generated statement of remuneration and '
          'needs no signature. Keep it for seven years — you may be asked '
          'for it after you have filed.',
          style: kit.style(size: 7.5, colour: PdfColors.grey600),
        ),
      ],
    ),
  );

  return pdf.save();
}

pw.Widget _heading(PdfKit kit, String text) => pw.Padding(
  padding: const pw.EdgeInsets.only(bottom: 5),
  child: pw.Text(
    text.toUpperCase(),
    style: kit.style(size: 8, strong: true, colour: PdfColors.grey700),
  ),
);

/// One box: its part, its printed number, its name and its amount.
pw.Widget _boxRow(PdfKit kit, EaBox b) => pw.Padding(
  padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
  child: pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      pw.Expanded(child: pw.Text(b.heading, style: kit.style())),
      pw.Text(Fmt.money(b.amount), style: kit.style()),
    ],
  ),
);
