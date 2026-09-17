import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/amount_words.dart';
import '../../core/format.dart';
import '../../core/pdf_kit.dart';
import '../../data/models.dart';

/// The company's own record that it paid something out.
///
/// An expense was recordable and postable and could not be printed,
/// which is a gap with a practical cost: a payment voucher is what a
/// Malaysian SME staples the receipt to, what the person who authorised
/// it signs, and what an auditor asks for when a cash payment has no
/// supplier invoice behind it. "It is in the system" is not that.
///
/// Not the same document as `receipt_pdf`'s payment voucher, which is
/// for a settlement against a supplier's bill and lists the invoices it
/// paid. This one is for money that never had a bill: a toll, a courier,
/// a parking ticket, a deposit paid at a counter. What it carries
/// instead of an invoice list is the **account it was charged to**,
/// because that is the decision somebody made and the one an auditor
/// queries.
///
/// The three signature blocks are the point of the paper. A voucher
/// nobody signed is a printout.
Future<Uint8List> buildExpenseVoucherPdf({
  required Organization org,
  required Map<String, dynamic> expense,
  Uint8List? logo,
  LetterheadMode mode = LetterheadMode.printed,
}) async {
  final kit = await PdfKit.load();

  final no = '${expense['expense_no'] ?? ''}';
  final pdf = pw.Document(title: 'Payment voucher $no');

  final account = (expense['accounts'] as Map?)?.cast<String, dynamic>();
  final payee = (expense['contacts'] as Map?)?.cast<String, dynamic>();
  final bank = (expense['bank_accounts'] as Map?)?.cast<String, dynamic>();

  final currency = '${expense['currency'] ?? org.baseCurrency}';
  final net = _num(expense['amount']);
  final tax = _num(expense['tax_amount']);
  final total = _num(expense['total_amount']);
  final date = DateTime.tryParse('${expense['expense_date'] ?? ''}');

  pw.Widget field(String label, String value) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 3),
    child: pw.Row(
      children: [
        pw.SizedBox(
          width: 90,
          child: pw.Text(
            label,
            style: kit.style(size: 8.5, colour: PdfColors.grey700),
          ),
        ),
        pw.Expanded(child: pw.Text(value, style: kit.style())),
      ],
    ),
  );

  pw.Widget signature(String label) => pw.Expanded(
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(height: 34),
        pw.Container(height: 0.8, color: PdfColors.grey600),
        pw.SizedBox(height: 4),
        pw.Text(label, style: kit.style(size: 8.5, colour: PdfColors.grey700)),
        pw.Text(
          'Name and date',
          style: kit.style(size: 7.5, colour: PdfColors.grey500),
        ),
      ],
    ),
  );

  pdf.addPage(
    pw.MultiPage(
      theme: kit.theme,
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 36, 36, 40),
      build: (context) => [
        kit.letterhead(
          org,
          documentLabel: 'Payment voucher',
          logo: logo,
          mode: mode,
        ),
        pw.SizedBox(height: 18),

        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'Paid to',
                    style: kit.style(size: 8.5, colour: PdfColors.grey700),
                  ),
                  pw.SizedBox(height: 2),
                  // An expense often has no contact at all — a parking
                  // ticket has no payee in the contact list — and a
                  // blank is more honest than the company's own name.
                  pw.Text(
                    '${payee?['name'] ?? '—'}',
                    style: kit.style(size: 11, strong: true),
                  ),
                ],
              ),
            ),
            pw.SizedBox(width: 24),
            pw.SizedBox(
              width: 230,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  field('Voucher no.', no),
                  field('Date', Fmt.longDate(date)),
                  if (expense['payment_mode_code'] != null)
                    field('Method', '${expense['payment_mode_code']}'),
                  if ('${expense['reference'] ?? ''}'.trim().isNotEmpty)
                    field('Reference', '${expense['reference']}'),
                  if (bank?['name'] != null) field('Paid from', '${bank!['name']}'),
                ],
              ),
            ),
          ],
        ),

        pw.SizedBox(height: 18),

        // What it was for, and what it was charged to. The account is
        // the decision somebody made, and it is what an auditor queries.
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
          columnWidths: const {
            0: pw.FlexColumnWidth(5),
            1: pw.FlexColumnWidth(2),
            2: pw.FlexColumnWidth(2),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey100),
              children: [
                _cell(kit, 'Particulars', head: true),
                _cell(kit, 'Account', head: true),
                _cell(kit, 'Amount', head: true, right: true),
              ],
            ),
            pw.TableRow(
              children: [
                _cell(kit, '${expense['description'] ?? ''}'),
                _cell(
                  kit,
                  account == null
                      ? '—'
                      : '${account['code']} ${account['name']}',
                ),
                _cell(
                  kit,
                  Fmt.money(net, currency: currency),
                  right: true,
                ),
              ],
            ),
            if (tax != 0)
              pw.TableRow(
                children: [
                  _cell(kit, 'Tax'),
                  _cell(kit, ''),
                  _cell(kit, Fmt.money(tax, currency: currency), right: true),
                ],
              ),
          ],
        ),

        pw.SizedBox(height: 12),

        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: pw.BoxDecoration(
            color: PdfColors.grey100,
            borderRadius: pw.BorderRadius.circular(4),
          ),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'Total paid',
                      style: kit.style(size: 8.5, colour: PdfColors.grey700),
                    ),
                    pw.SizedBox(height: 2),
                    // Words as well as figures: a voucher is handled by
                    // hand and signed by hand.
                    pw.Text(
                      amountInWords(total, currency),
                      style: kit.style(size: 9, colour: PdfColors.grey800),
                    ),
                  ],
                ),
              ),
              pw.Text(
                Fmt.money(total, currency: currency),
                style: kit.style(size: 16, strong: true),
              ),
            ],
          ),
        ),

        pw.SizedBox(height: 30),

        // The three hands a voucher passes through. Printed even when
        // the company is one person, because the auditor asking for it
        // is asking whether anybody but the payer approved it.
        pw.Row(
          children: [
            signature('Prepared by'),
            pw.SizedBox(width: 20),
            signature('Approved by'),
            pw.SizedBox(width: 20),
            signature('Received by'),
          ],
        ),
      ],
    ),
  );

  return pdf.save();
}

pw.Widget _cell(
  PdfKit kit,
  String text, {
  bool head = false,
  bool right = false,
}) => pw.Padding(
  padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
  child: pw.Text(
    text,
    textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
    style: head
        ? kit.style(size: 8.5, strong: true, colour: PdfColors.grey700)
        : kit.style(size: 9),
  ),
);

double _num(dynamic v) =>
    v == null ? 0 : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);
