import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/format.dart';
import '../../core/amount_words.dart';
import '../../core/pdf_kit.dart';
import '../../data/models.dart';

/// The customer's proof that they paid.
///
/// An invoice says what is owed; this says it arrived. They are not the
/// same document and one cannot stand in for the other — a customer
/// closing their own books needs a dated acknowledgement naming the
/// amount and what it settled, and "look at the invoice, it says paid"
/// is not that.
///
/// Deliberately plain. It carries the letterhead because it is issued by
/// the company and may be filed for years, the receipt number and date
/// because that is what makes it referable, the amount in words because
/// a receipt is the one document people still alter by hand, and the
/// list of what it was set against because a payment covering four
/// invoices is the case that causes arguments.
Future<Uint8List> buildReceiptPdf({
  required Organization org,
  required Map<String, dynamic> settlement,
  required bool isSales,
  Uint8List? logo,
  LetterheadMode mode = LetterheadMode.printed,
}) async {
  final kit = await PdfKit.load();

  final no = (settlement[isSales ? 'receipt_no' : 'payment_no'] ?? '') as String;
  final label = isSales ? 'Receipt' : 'Payment voucher';
  final pdf = pw.Document(title: '$label $no');

  final contact = (settlement['contacts'] as Map?)?.cast<String, dynamic>();
  final bank = (settlement['bank_accounts'] as Map?)?.cast<String, dynamic>();
  final allocations = (settlement['allocations'] as List? ?? const [])
      .cast<Map<String, dynamic>>();

  final currency = (settlement['currency'] ?? 'MYR') as String;
  final amount = _num(settlement['amount']);
  final unapplied = _num(settlement['unapplied_amount']);
  final charges = _num(settlement['bank_charges']);
  final rate = _num(settlement['exchange_rate']);
  final date = DateTime.tryParse(
      (settlement[isSales ? 'receipt_date' : 'payment_date'] ?? '') as String);

  final address = [
    contact?['address_line1'],
    contact?['address_line2'],
    [contact?['postcode'], contact?['city']]
        .where((v) => v != null && '$v'.trim().isNotEmpty)
        .join(' '),
    contact?['state_code'],
  ].where((v) => v != null && '$v'.trim().isNotEmpty).cast<String>().toList();

  pw.Widget field(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 3),
        child: pw.Row(children: [
          pw.SizedBox(
            width: 90,
            child: pw.Text(label,
                style: kit.style(size: 8.5, colour: PdfColors.grey700)),
          ),
          pw.Expanded(child: pw.Text(value, style: kit.style())),
        ]),
      );

  pdf.addPage(pw.MultiPage(
    theme: kit.theme,
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(36, 36, 36, 40),
    build: (context) => [
      kit.letterhead(org, documentLabel: label, logo: logo, mode: mode),
      pw.SizedBox(height: 18),

      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(isSales ? 'Received from' : 'Paid to',
                    style: kit.style(size: 8.5, colour: PdfColors.grey700)),
                pw.SizedBox(height: 2),
                pw.Text('${contact?['name'] ?? ''}',
                    style: kit.style(size: 11, strong: true)),
                for (final line in address)
                  pw.Text(line, style: kit.style(size: 9)),
              ],
            ),
          ),
          pw.SizedBox(width: 24),
          pw.SizedBox(
            width: 230,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                field('$label no.', no),
                field('Date', Fmt.longDate(date)),
                if (settlement['payment_mode_code'] != null)
                  field('Method', '${settlement['payment_mode_code']}'),
                if (settlement['reference'] != null &&
                    '${settlement['reference']}'.trim().isNotEmpty)
                  field('Reference', '${settlement['reference']}'),
                if (bank?['name'] != null) field('Into', '${bank!['name']}'),
              ],
            ),
          ),
        ],
      ),

      pw.SizedBox(height: 18),

      // The figure, given room. This is the line somebody looks for.
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
                  pw.Text(isSales ? 'Amount received' : 'Amount paid',
                      style: kit.style(size: 8.5, colour: PdfColors.grey700)),
                  pw.SizedBox(height: 2),
                  // Words as well as figures. A receipt is the document
                  // people still amend with a pen.
                  pw.Text(amountInWords(amount, currency),
                      style: kit.style(size: 9, colour: PdfColors.grey800)),
                ],
              ),
            ),
            pw.Text(Fmt.money(amount, currency: currency),
                style: kit.style(size: 16, strong: true)),
          ],
        ),
      ),

      if (currency != org.baseCurrency) ...[
        pw.SizedBox(height: 6),
        pw.Text(
          'Converted at $rate — '
          '${Fmt.money(_num(settlement['base_amount']), currency: org.baseCurrency)}',
          style: kit.style(size: 8.5, colour: PdfColors.grey700),
        ),
      ],

      if (allocations.isNotEmpty) ...[
        pw.SizedBox(height: 18),
        pw.Text(isSales ? 'Set against' : 'Settling',
            style: kit.style(size: 9, strong: true)),
        pw.SizedBox(height: 6),
        pw.Table(
          columnWidths: const {
            0: pw.FlexColumnWidth(2),
            1: pw.FlexColumnWidth(2),
            2: pw.FlexColumnWidth(2),
            3: pw.FlexColumnWidth(2),
          },
          children: [
            pw.TableRow(
              decoration:
                  const pw.BoxDecoration(color: PdfColors.grey200),
              children: [
                _cell(kit, 'Document', strong: true),
                _cell(kit, 'Dated', strong: true),
                _cell(kit, 'Document total', strong: true, right: true),
                _cell(kit, 'Applied', strong: true, right: true),
              ],
            ),
            for (final a in allocations)
              pw.TableRow(children: [
                _cell(kit, _docNo(a, isSales)),
                _cell(kit, Fmt.date(DateTime.tryParse(
                    '${_doc(a, isSales)?['doc_date'] ?? ''}'))),
                _cell(
                    kit,
                    Fmt.money(_num(_doc(a, isSales)?['total_amount']),
                        currency: currency),
                    right: true),
                _cell(kit, Fmt.money(_num(a['amount']), currency: currency),
                    right: true),
              ]),
          ],
        ),
      ],

      if (unapplied > 0) ...[
        pw.SizedBox(height: 8),
        pw.Text(
          '${Fmt.money(unapplied, currency: currency)} of this '
          '${isSales ? 'receipt' : 'payment'} is not yet set against any '
          'document and remains on account.',
          style: kit.style(size: 8.5, colour: PdfColors.grey700),
        ),
      ],

      if (charges != 0) ...[
        pw.SizedBox(height: 4),
        pw.Text(
          'Bank charges of ${Fmt.money(charges, currency: currency)} were '
          'borne on this ${isSales ? 'receipt' : 'payment'}.',
          style: kit.style(size: 8.5, colour: PdfColors.grey700),
        ),
      ],

      pw.SizedBox(height: 28),
      pw.Row(children: [
        pw.Expanded(
          child: pw.Text(
            settlement['status'] == 'posted'
                ? 'This is a computer-generated $label and needs no signature.'
                : 'DRAFT — not yet posted to the ledger.',
            style: kit.style(
                size: 8,
                colour: settlement['status'] == 'posted'
                    ? PdfColors.grey600
                    : PdfColors.red700),
          ),
        ),
        pw.SizedBox(
          width: 170,
          child: pw.Column(children: [
            pw.Divider(color: PdfColors.grey400, height: 1),
            pw.SizedBox(height: 3),
            pw.Text('for ${org.name}',
                style: kit.style(size: 8, colour: PdfColors.grey700)),
          ]),
        ),
      ]),
    ],
  ));

  return pdf.save();
}

Map<String, dynamic>? _doc(Map<String, dynamic> a, bool isSales) =>
    (a[isSales ? 'sales_documents' : 'purchase_documents'] as Map?)
        ?.cast<String, dynamic>();

String _docNo(Map<String, dynamic> a, bool isSales) =>
    '${_doc(a, isSales)?['doc_no'] ?? 'On account'}';

double _num(dynamic v) =>
    v == null ? 0 : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);

pw.Widget _cell(PdfKit kit, String text,
        {bool strong = false, bool right = false}) =>
    pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: pw.Text(text,
          style: kit.style(size: 8.5, strong: strong),
          textAlign: right ? pw.TextAlign.right : pw.TextAlign.left),
    );
