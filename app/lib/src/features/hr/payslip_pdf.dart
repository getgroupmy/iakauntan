import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/format.dart';
import '../../core/pdf_kit.dart';
import '../../data/models.dart';

/// The payslip an employee is entitled to.
///
/// Section 19 of the Employment Act 1955 requires the employer to give a
/// statement of wages showing what was earned and what was deducted. So
/// earnings and deductions are separate blocks with their own totals,
/// rather than a single column of numbers that happens to net off.
///
/// The employer's own contributions are shown too, below the net pay and
/// clearly outside it. They are not the employee's money and must never
/// read as though they were — but leaving them off makes the cost of
/// employment invisible to the person it is spent on.
Future<Uint8List> buildPayslipPdf({
  required Organization org,
  required Payslip payslip,
  String? periodLabel,
}) async {
  final kit = await PdfKit.load();
  final period = periodLabel ?? payslip.periodCode ?? '';
  final pdf = pw.Document(title: 'Payslip ${payslip.employeeName} $period');

  // The lines are the itemisation, and they already contain everything:
  // basic salary is an earning line, and EPF, SOCSO, EIS and PCB are
  // deduction lines. Adding the scalar fields beside them would print
  // every statutory figure twice — the totals would still foot, which is
  // exactly what would make it hard to spot.
  List<(String, double)> of(String kind) => [
        for (final l in payslip.lines.where((l) => l.kind == kind))
          (l.description, l.amount),
      ];

  final earnings = of('earning');
  final deductions = of('deduction');
  final employer = of('employer_contribution');

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(42, 42, 42, 36),
      theme: kit.theme,
      footer: (context) => kit.footer(context,
          note: 'Private and confidential'),
      build: (context) => [
        kit.letterhead(org, documentLabel: 'Payslip'),
        kit.rule(),

        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              flex: 3,
              child: kit.field('Employee', payslip.employeeName, strong: true),
            ),
            pw.Expanded(
              flex: 2,
              child: kit.field('Staff number', payslip.employeeNo ?? ''),
            ),
            pw.Expanded(
              flex: 3,
              child: kit.field('Department', payslip.departmentName ?? ''),
            ),
            pw.Expanded(
              flex: 2,
              child: kit.field('Period', period, strong: true),
            ),
          ],
        ),
        if (payslip.positionTitle != null) ...[
          pw.SizedBox(height: 8),
          kit.field('Position', payslip.positionTitle!),
        ],

        pw.SizedBox(height: 18),
        _block(kit, 'Earnings', earnings,
            total: ('Gross pay', payslip.grossPay)),

        pw.SizedBox(height: 14),
        _block(kit, 'Deductions', deductions,
            total: ('Total deductions', payslip.totalDeductions)),

        pw.SizedBox(height: 14),
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('Net pay', style: kit.style(size: 11, strong: true)),
              pw.Text(Fmt.money(payslip.netPay),
                  style: kit.style(size: 11, strong: true)),
            ],
          ),
        ),

        if (employer.isNotEmpty) ...[
          pw.SizedBox(height: 16),
          pw.Text('Paid by the employer, not deducted from you',
              style: kit.style(size: 8, colour: PdfColors.grey700)),
          pw.SizedBox(height: 4),
          for (final (label, amount) in employer)
            kit.amountRow(label, amount, width: 260),
          kit.amountRow(
              'Employer cost',
              employer.fold<double>(0, (sum, entry) => sum + entry.$2),
              strong: true,
              width: 260),
        ],

        if (payslip.otHours != 0) ...[
          pw.SizedBox(height: 12),
          kit.field('Overtime hours', Fmt.qty(payslip.otHours)),
        ],

        // Stated on the document itself, because a payslip is what an
        // employee keeps, and a figure worked out from an unverified
        // table should not be able to travel without saying so.
        if (!payslip.schedulesVerified) ...[
          pw.SizedBox(height: 18),
          pw.Container(
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.orange700, width: 0.7),
            ),
            child: pw.Text(
              'The EPF, SOCSO, EIS and PCB figures on this payslip were '
              'calculated from contribution tables that have not been '
              'checked against the gazetted schedules. Do not rely on them '
              'for a statutory return.',
              style: kit.style(size: 8, colour: PdfColors.orange900),
            ),
          ),
        ],

        pw.SizedBox(height: 18),
        pw.Text(
          'This is a computer-generated statement of wages issued under '
          'section 19 of the Employment Act 1955 and needs no signature.',
          style: kit.style(size: 7.5, colour: PdfColors.grey600),
        ),
      ],
    ),
  );

  return pdf.save();
}

/// A titled list of amounts with its own total — the shape both the
/// earnings and the deductions halves take.
pw.Widget _block(
  PdfKit kit,
  String title,
  List<(String, double)> rows, {
  required (String, double) total,
}) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(title.toUpperCase(),
          style: kit.style(size: 8, strong: true, colour: PdfColors.grey700)),
      pw.SizedBox(height: 4),
      for (final (label, amount) in rows)
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(label, style: kit.style()),
              pw.Text(Fmt.money(amount), style: kit.style()),
            ],
          ),
        ),
      pw.Container(
        margin: const pw.EdgeInsets.symmetric(vertical: 4),
        height: 0.7,
        color: PdfColors.grey400,
      ),
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(total.$1, style: kit.style(strong: true)),
          pw.Text(Fmt.money(total.$2), style: kit.style(strong: true)),
        ],
      ),
    ],
  );
}
