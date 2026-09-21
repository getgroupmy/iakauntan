import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/format.dart';
import '../../core/pdf_kit.dart';
import '../../data/models.dart';
import 'brought_forward.dart';

/// A brought-forward statement: an opening balance, everything that
/// moved it, and a closing balance.
///
/// The other document in this folder — `statement_pdf.dart` — is the
/// open-item statement, and it says on its own face that it "carries no
/// balance brought forward". This is the one that does. Neither
/// replaces the other and both say which they are, because a customer
/// reconciling a statement against their own ledger has to know whether
/// the absence of a paid invoice means it was paid or means the page
/// only lists what is unpaid.
///
/// Customer side only. `report_statement_of_account` reads
/// `sales_documents` and `receipts`, so there is no supplier form of
/// this document and one is not faked here.
Future<Uint8List> buildBroughtForwardPdf({
  required Organization org,
  required Contact contact,
  required List<StatementLine> lines,
  required DateTime from,
  required DateTime to,
  Uint8List? logo,
  LetterheadMode mode = LetterheadMode.printed,
}) async {
  final kit = await PdfKit.load();
  final pdf = pw.Document(title: 'Statement — ${contact.name}');

  final opening = statementOpening(lines);
  final closing = statementClosing(lines);
  final movements = statementMovements(lines);

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
                  kit.field(
                    'To',
                    contact.legalName ?? contact.name,
                    strong: true,
                  ),
                  for (final line in address)
                    pw.Text(
                      line,
                      style: kit.style(size: 8.5, colour: PdfColors.grey700),
                    ),
                ],
              ),
            ),
            pw.Expanded(flex: 2, child: kit.field('Account', contact.code)),
            pw.Expanded(
              flex: 3,
              child: kit.field(
                'Period',
                statementPeriodLabel(from, to),
                strong: true,
              ),
            ),
          ],
        ),

        pw.SizedBox(height: 16),

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
          cellPadding: const pw.EdgeInsets.symmetric(
            horizontal: 6,
            vertical: 5,
          ),
          headers: const [
            'Date',
            'Document',
            'Due',
            'Charges',
            'Payments',
            'Balance',
          ],
          data: [
            // The opening row is the point of the document, so it is
            // printed as a row of the table rather than as a caption
            // above it: the running balance in the last column has to
            // start from a figure the reader can see, or the first
            // document's balance looks like arithmetic that does not
            // work.
            [
              Fmt.date(from.subtract(const Duration(days: 1))),
              statementKindLabel('opening'),
              '',
              '',
              '',
              Fmt.money(opening, currency: org.baseCurrency),
            ],
            // Charges and payments are in BASE currency, because that
            // is the column the balance runs in and a page whose
            // columns do not foot to its own last figure is worse than
            // one with fewer columns. What the document was raised in
            // is stated alongside its number instead -- that is the
            // figure the customer will recognise, and dropping it would
            // leave a foreign invoice unmatchable against their ledger.
            for (final l in movements)
              [
                Fmt.date(l.entryDate),
                [
                  statementKindLabel(l.kind),
                  if (_present(l.docNo)) l.docNo!,
                  if (l.currency != null &&
                      l.currency != org.baseCurrency &&
                      (l.debit != 0 || l.credit != 0))
                    Fmt.money(
                      l.debit != 0 ? l.debit : l.credit,
                      currency: l.currency!,
                    ),
                ].join('  ·  '),
                l.dueDate == null ? '' : Fmt.date(l.dueDate!),
                l.baseDebit == 0
                    ? ''
                    : Fmt.money(l.baseDebit, currency: org.baseCurrency),
                l.baseCredit == 0
                    ? ''
                    : Fmt.money(l.baseCredit, currency: org.baseCurrency),
                Fmt.money(l.balance, currency: org.baseCurrency),
              ],
          ],
        ),

        pw.SizedBox(height: 12),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.end,
          children: [
            pw.Container(
              width: 240,
              padding: const pw.EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Balance due ${org.baseCurrency}',
                    style: kit.style(size: 11, strong: true),
                  ),
                  pw.Text(
                    Fmt.money(closing, currency: org.baseCurrency),
                    style: kit.style(size: 11, strong: true),
                  ),
                ],
              ),
            ),
          ],
        ),

        pw.SizedBox(height: 18),
        pw.Text(
          'This statement lists every posted document and every payment '
          'received on this account between the dates above, with the '
          'balance brought forward at the start of the period. It is a '
          'transaction history, not a list of what is overdue — an '
          'invoice that has been paid still appears, with the payment '
          'under it. If anything here disagrees with your own records, '
          'please tell us.',
          style: kit.style(size: 7.5, colour: PdfColors.grey600),
        ),
      ],
    ),
  );

  return pdf.save();
}

bool _present(String? s) => s != null && s.trim().isNotEmpty;
