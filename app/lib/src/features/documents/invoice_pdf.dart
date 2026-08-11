import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/format.dart';
import '../../core/pdf_kit.dart';
import '../../data/models.dart';

/// The invoice a customer actually receives.
///
/// A tax invoice under the Sales Tax Act has to identify the supplier and
/// its registration, the customer, what was supplied, and the tax charged
/// on it. That is why the letterhead carries the registration numbers and
/// why tax is a column rather than a single line at the bottom: a bill
/// with two tax rates on it has to show which line bore which.
Future<Uint8List> buildInvoicePdf({
  required Organization org,
  required BusinessDocument doc,
  required String documentLabel,
}) async {
  final kit = await PdfKit.load();
  final pdf = pw.Document(title: '$documentLabel ${doc.docNo}');

  final anyDiscount = doc.lines.any((l) => l.discountAmount != 0);
  final anyTax = doc.lines.any((l) => l.taxAmount != 0) || doc.taxAmount != 0;

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(42, 42, 42, 36),
      theme: kit.theme,
      footer: (context) => kit.footer(context, note: doc.docNo),
      build: (context) => [
        kit.letterhead(org, documentLabel: documentLabel),
        kit.rule(),

        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              flex: 3,
              child: kit.field('Bill to', doc.contactName ?? '', strong: true),
            ),
            pw.Expanded(
              flex: 2,
              child: kit.field('Number', doc.docNo, strong: true),
            ),
            pw.Expanded(
              flex: 2,
              child: kit.field('Date', Fmt.date(doc.docDate)),
            ),
            pw.Expanded(
              flex: 2,
              child: kit.field(
                  'Due', doc.dueDate == null ? '' : Fmt.date(doc.dueDate!)),
            ),
          ],
        ),
        if (doc.reference != null && doc.reference!.trim().isNotEmpty) ...[
          pw.SizedBox(height: 8),
          kit.field('Reference', doc.reference!),
        ],

        pw.SizedBox(height: 16),

        pw.TableHelper.fromTextArray(
          headerAlignment: pw.Alignment.centerLeft,
          cellAlignments: {
            0: pw.Alignment.centerLeft,
            1: pw.Alignment.centerRight,
            2: pw.Alignment.centerRight,
            if (anyDiscount) 3: pw.Alignment.centerRight,
            if (anyTax) (anyDiscount ? 4 : 3): pw.Alignment.centerRight,
            (anyDiscount ? 1 : 0) + (anyTax ? 1 : 0) + 3:
                pw.Alignment.centerRight,
          },
          headerStyle: kit.style(size: 8, strong: true),
          cellStyle: kit.style(size: 9),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          cellPadding:
              const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          headers: [
            'Description',
            'Qty',
            'Unit price',
            if (anyDiscount) 'Discount',
            if (anyTax) 'Tax',
            'Amount',
          ],
          data: [
            for (final line in doc.lines)
              [
                line.description,
                Fmt.qty(line.quantity),
                Fmt.money(line.unitPrice),
                if (anyDiscount) Fmt.money(line.discountAmount),
                if (anyTax) Fmt.money(line.taxAmount),
                Fmt.money(line.lineTotal),
              ],
          ],
        ),

        pw.SizedBox(height: 12),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.end,
          children: [
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                kit.amountRow('Subtotal', doc.subtotal),
                if (doc.discountAmount != 0)
                  kit.amountRow('Discount', -doc.discountAmount),
                if (doc.shippingAmount != 0)
                  kit.amountRow('Shipping', doc.shippingAmount),
                if (doc.taxAmount != 0) kit.amountRow('Tax', doc.taxAmount),
                // Malaysia rounds cash settlement to the nearest 5 sen and
                // the adjustment is shown, not folded into the total.
                if (doc.roundingAmount != 0)
                  kit.amountRow('Rounding', doc.roundingAmount),
                pw.Container(
                  width: 190,
                  margin: const pw.EdgeInsets.symmetric(vertical: 4),
                  height: 0.7,
                  color: PdfColors.grey500,
                ),
                kit.amountRow('Total ${doc.currency}', doc.totalAmount,
                    strong: true),
                if (doc.paidAmount != 0) ...[
                  kit.amountRow('Paid', doc.paidAmount),
                  kit.amountRow('Balance due', doc.balanceAmount, strong: true),
                ],
              ],
            ),
          ],
        ),

        if (_present(doc.notes) || _present(doc.termsConditions)) ...[
          pw.SizedBox(height: 18),
          if (_present(doc.notes)) ...[
            kit.field('Notes', doc.notes!),
            pw.SizedBox(height: 8),
          ],
          if (_present(doc.termsConditions))
            kit.field('Terms', doc.termsConditions!),
        ],

        // Status is stated rather than implied. A draft that looks like a
        // tax invoice is a document somebody will pay against.
        pw.SizedBox(height: 20),
        pw.Text(_statusNote(doc),
            style: kit.style(size: 8, colour: PdfColors.grey700)),
      ],
    ),
  );

  return pdf.save();
}

bool _present(String? s) => s != null && s.trim().isNotEmpty;

String _statusNote(BusinessDocument doc) {
  final bits = <String>[];
  if (!doc.isPosted) {
    bits.add('DRAFT — not yet posted to the ledger.');
  }
  switch (doc.einvoiceStatus) {
    case 'valid':
      bits.add('Validated by LHDN MyInvois.');
    case 'submitted':
      bits.add('Submitted to LHDN MyInvois, awaiting validation.');
    case 'rejected':
      bits.add('Rejected by LHDN MyInvois.');
    case 'cancelled':
      bits.add('Cancelled in LHDN MyInvois.');
    case 'not_applicable':
      break;
    default:
      bits.add('e-Invoice not yet submitted.');
  }
  return bits.join('  ');
}
