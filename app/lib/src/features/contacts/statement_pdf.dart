import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/format.dart';
import '../../core/pdf_kit.dart';
import '../../data/models.dart';
import 'statement.dart';

/// A statement of account: the documents a customer has not paid, and
/// how old each one is.
///
/// This is an **open-item** statement — it lists what is still
/// outstanding, not every transaction in the period with a balance
/// brought forward. The two are different documents and a customer
/// reconciling against their own ledger needs to know which one they are
/// holding, so the statement says so on its face rather than leaving it
/// to be inferred from what is missing.
Future<Uint8List> buildStatementPdf({
  required Organization org,
  required Contact contact,
  required List<BusinessDocument> documents,
  required DateTime asAt,
  Uint8List? logo,
  LetterheadMode mode = LetterheadMode.printed,
}) async {
  final kit = await PdfKit.load();
  final pdf = pw.Document(title: 'Statement — ${contact.name}');

  final open = documents.where((d) => d.balanceAmount != 0).toList()
    ..sort((a, b) => a.docDate.compareTo(b.docDate));
  final aged = ageing(open, asAt);

  final address = [
    contact.addressLine1,
    contact.addressLine2,
    [contact.postcode, contact.city].where(_present).join(' '),
    contact.stateCode,
  ].where(_present).cast<String>().toList();

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(42, 42, 42, 36),
      theme: kit.theme,
      footer: (context) => kit.footer(context, note: contact.code),
      build: (context) => [
        kit.letterhead(org, documentLabel: 'Statement', logo: logo, mode: mode),
        kit.rule(),

        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              flex: 3,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  kit.field('To', contact.legalName ?? contact.name,
                      strong: true),
                  for (final line in address)
                    pw.Text(line,
                        style: kit.style(size: 8.5, colour: PdfColors.grey700)),
                ],
              ),
            ),
            pw.Expanded(flex: 2, child: kit.field('Account', contact.code)),
            pw.Expanded(
              flex: 2,
              child: kit.field('As at', Fmt.date(asAt), strong: true),
            ),
          ],
        ),

        pw.SizedBox(height: 16),

        if (open.isEmpty)
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(vertical: 16),
            child: pw.Text('Nothing outstanding. Thank you.',
                style: kit.style(size: 11, strong: true)),
          )
        else ...[
          pw.TableHelper.fromTextArray(
            headerAlignment: pw.Alignment.centerLeft,
            cellAlignments: {
              0: pw.Alignment.centerLeft,
              1: pw.Alignment.centerLeft,
              2: pw.Alignment.centerLeft,
              3: pw.Alignment.centerRight,
              4: pw.Alignment.centerRight,
              5: pw.Alignment.centerRight,
            },
            headerStyle: kit.style(size: 8, strong: true),
            cellStyle: kit.style(size: 9),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
            cellPadding:
                const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            headers: const [
              'Date',
              'Document',
              'Due',
              'Amount',
              'Paid',
              'Balance',
            ],
            data: [
              // The money columns are all in base currency, converted at
              // each document's own rate, so they foot to the total
              // underneath. What the customer was actually invoiced is
              // stated alongside the document number instead — dropping
              // it would leave them unable to match this against their
              // own ledger.
              for (final d in open)
                [
                  Fmt.date(d.docDate),
                  [
                    d.docNo,
                    if (_present(d.reference)) d.reference!,
                    if (d.currency != org.baseCurrency)
                      Fmt.money(d.balanceAmount, currency: d.currency),
                  ].join('  ·  '),
                  d.dueDate == null ? '—' : Fmt.date(d.dueDate!),
                  Fmt.money(d.totalAmount * d.exchangeRate,
                      currency: org.baseCurrency),
                  Fmt.money(d.paidAmount * d.exchangeRate,
                      currency: org.baseCurrency),
                  Fmt.money(d.balanceAmount * d.exchangeRate,
                      currency: org.baseCurrency),
                ],
            ],
          ),

          pw.SizedBox(height: 12),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.end,
            children: [
              pw.Container(
                width: 220,
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Total due ${org.baseCurrency}',
                        style: kit.style(size: 11, strong: true)),
                    pw.Text(Fmt.money(aged.total, currency: org.baseCurrency),
                        style: kit.style(size: 11, strong: true)),
                  ],
                ),
              ),
            ],
          ),

          pw.SizedBox(height: 18),
          pw.Text('AGE OF THE BALANCE',
              style:
                  kit.style(size: 8, strong: true, colour: PdfColors.grey700)),
          pw.SizedBox(height: 4),
          // The buckets are printed even when empty, so the columns line
          // up with the customer's own aged listing and a zero reads as
          // "nothing here" rather than as a missing band.
          pw.TableHelper.fromTextArray(
            headerAlignment: pw.Alignment.centerRight,
            cellAlignment: pw.Alignment.centerRight,
            headerStyle: kit.style(size: 8, strong: true),
            cellStyle: kit.style(size: 9),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
            cellPadding:
                const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            headers: [for (final (label, _) in aged.buckets) label],
            data: [
              [
                for (final (_, amount) in aged.buckets)
                  Fmt.money(amount, currency: org.baseCurrency),
              ],
            ],
          ),
        ],

        pw.SizedBox(height: 18),
        pw.Text(
          'This statement lists documents that are still unpaid as at the '
          'date above. It is not a full transaction history and carries no '
          'balance brought forward. Payments made after that date are not '
          'reflected — if you have already paid, please ignore the relevant '
          'line and let us know.',
          style: kit.style(size: 7.5, colour: PdfColors.grey600),
        ),
      ],
    ),
  );

  return pdf.save();
}

bool _present(String? s) => s != null && s.trim().isNotEmpty;
