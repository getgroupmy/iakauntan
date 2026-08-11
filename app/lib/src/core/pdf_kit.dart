import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/models.dart';
import 'format.dart';

/// Whether the PDF draws the company's identity block or leaves room for
/// one already printed on the paper.
enum LetterheadMode {
  /// Draw it. The default, and the only right answer for a PDF that will
  /// be e-mailed, filed or kept — nothing outside the file supplies the
  /// company's details.
  printed,

  /// Leave the top of the first page empty, for a company that prints
  /// onto its own pre-printed stationery and would otherwise get two
  /// headers on one sheet.
  ///
  /// Statutory identifiers are still printed, small, under the reserved
  /// space: a tax invoice has to carry the registration and SST numbers,
  /// and printed stationery routinely shows a company's name and address
  /// but not its SST registration. Reserving the space is a layout
  /// convenience; dropping the numbers would make the document wrong.
  stationery,
}

/// The pieces every generated PDF shares: the typeface, the letterhead
/// and the money column.
///
/// Kept in one place because an invoice and a payslip that disagree about
/// the company's own address are two bugs, not one document each.
class PdfKit {
  const PdfKit._(this.regular, this.bold);

  final pw.Font regular;
  final pw.Font bold;

  static PdfKit? _cached;

  /// Blank space left above the content in [LetterheadMode.stationery],
  /// on top of the page's own 42pt margin — so the document starts 120pt,
  /// about 42 mm, below the edge of the sheet. That covers the usual
  /// depth of a printed header. It is a guess about somebody else's
  /// stationery, and the only honest thing to do with a guess is write it
  /// down where it can be changed.
  static const double stationeryReserve = 78;

  /// The app's own typeface, so a printed document looks like the system
  /// it came from. Loaded once: parsing a TTF for every download would
  /// be noticeable on a run of fifty payslips.
  static Future<PdfKit> load() async {
    if (_cached != null) return _cached!;
    final regular = pw.Font.ttf(
        await rootBundle.load('assets/fonts/PlusJakartaSans-Regular.ttf'));
    final bold = pw.Font.ttf(
        await rootBundle.load('assets/fonts/PlusJakartaSans-Bold.ttf'));
    return _cached = PdfKit._(regular, bold);
  }

  pw.ThemeData get theme => pw.ThemeData.withFont(base: regular, bold: bold)
      .copyWith(
          defaultTextStyle:
              pw.TextStyle(font: regular, fontSize: 9.5, lineSpacing: 1.6));

  pw.TextStyle style({double size = 9.5, bool strong = false, PdfColor? colour}) =>
      pw.TextStyle(
        font: strong ? bold : regular,
        fontSize: size,
        color: colour,
      );

  /// Who issued this. Everything is optional because a company that has
  /// not finished its settings should still be able to print — with gaps
  /// where the details are missing rather than the word "null".
  /// [logo] is the raw image bytes, or null. A company that has not
  /// uploaded one still prints a proper letterhead — the mark is an
  /// addition to the identity block, never a replacement for it, because
  /// a tax invoice has to carry the registered name and numbers whatever
  /// it looks like.
  ///
  /// [documentLabel] is the big grey word in the top right. It is
  /// optional: an invoice wants "INVOICE" there, a board resolution does
  /// not, because the resolution announces itself in its own first line.
  ///
  /// [mode] decides whether the block is drawn at all — see
  /// [LetterheadMode].
  pw.Widget letterhead(Organization org,
      {String? documentLabel,
      Uint8List? logo,
      LetterheadMode mode = LetterheadMode.printed}) {
    final address = [
      org.addressLine1,
      org.addressLine2,
      [org.postcode, org.city].where(_present).join(' '),
      org.stateCode,
    ].where(_present).cast<String>().toList();

    final ids = [
      if (_present(org.registrationNo)) 'Reg. No. ${org.registrationNo}',
      if (_present(org.tin)) 'TIN ${org.tin}',
      if (org.isSstRegistered && _present(org.sstRegistrationNo))
        'SST ${org.sstRegistrationNo}',
    ];

    if (mode == LetterheadMode.stationery) {
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(height: stationeryReserve),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Expanded(
                child: ids.isEmpty
                    ? pw.SizedBox()
                    : pw.Text(ids.join('  ·  '),
                        style: style(size: 8.5, colour: PdfColors.grey700)),
              ),
              if (documentLabel != null)
                pw.Text(documentLabel.toUpperCase(),
                    style:
                        style(size: 15, strong: true, colour: PdfColors.grey600)),
            ],
          ),
        ],
      );
    }

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (logo != null) ...[
          // Bounded, not scaled to fit: a tall logo would otherwise push
          // the whole identity block down the page, and a wide one would
          // squeeze it. `contain` keeps whatever aspect ratio was
          // uploaded inside a fixed corner.
          pw.Container(
            width: 92,
            height: 46,
            margin: const pw.EdgeInsets.only(right: 14),
            child: pw.Image(pw.MemoryImage(logo),
                fit: pw.BoxFit.contain,
                alignment: pw.Alignment.topLeft),
          ),
        ],
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(org.legalName ?? org.name, style: style(size: 13, strong: true)),
              for (final line in address)
                pw.Text(line, style: style(size: 8.5, colour: PdfColors.grey700)),
              if (ids.isNotEmpty)
                pw.Text(ids.join('  ·  '),
                    style: style(size: 8.5, colour: PdfColors.grey700)),
              if (_present(org.email) || _present(org.phone))
                pw.Text(
                    [org.email, org.phone].where(_present).join('  ·  '),
                    style: style(size: 8.5, colour: PdfColors.grey700)),
            ],
          ),
        ),
        if (documentLabel != null)
          pw.Text(documentLabel.toUpperCase(),
              style: style(size: 15, strong: true, colour: PdfColors.grey600)),
      ],
    );
  }

  pw.Widget rule() => pw.Container(
        margin: const pw.EdgeInsets.symmetric(vertical: 10),
        height: 0.7,
        color: PdfColors.grey400,
      );

  /// A label above its value, which is how the header blocks on both an
  /// invoice and a payslip are laid out.
  pw.Widget field(String label, String value, {bool strong = false}) =>
      pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(label.toUpperCase(),
              style: style(size: 7, colour: PdfColors.grey600)),
          pw.SizedBox(height: 1),
          pw.Text(value.isEmpty ? '—' : value, style: style(strong: strong)),
        ],
      );

  /// A right-aligned amount line: the shape of every total on both
  /// documents.
  pw.Widget amountRow(String label, num amount,
          {bool strong = false, double width = 190}) =>
      pw.Container(
        width: width,
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(label, style: style(strong: strong)),
            pw.Text(Fmt.money(amount.toDouble()), style: style(strong: strong)),
          ],
        ),
      );

  pw.Widget footer(pw.Context context, {String? note}) => pw.Container(
        alignment: pw.Alignment.centerRight,
        padding: const pw.EdgeInsets.only(top: 10),
        child: pw.Text(
          [
            if (note != null) note,
            'Page ${context.pageNumber} of ${context.pagesCount}',
          ].join('  ·  '),
          style: style(size: 7.5, colour: PdfColors.grey600),
        ),
      );

  static bool _present(String? s) => s != null && s.trim().isNotEmpty;
}
