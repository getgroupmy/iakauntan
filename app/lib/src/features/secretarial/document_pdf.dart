import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/pdf_kit.dart';
import '../../data/models.dart';

/// Turns a generated document into a PDF fit for a minute book.
///
/// The generator writes Markdown, which is right for storage — it diffs,
/// it is hashed for signatures, and it stays readable in the database.
/// It is wrong for the thing a secretary prints, signs and lodges, which
/// is why this exists.
///
/// The subset rendered is the subset the templates actually use:
/// paragraphs separated by blank lines, `**bold**` within a line, and
/// single newlines kept as line breaks — an address block and a list of
/// directors' names both depend on those breaks surviving.
///
/// [letterhead] is the organisation that prepared the document, with
/// [logo] its uploaded mark; both null gives a bare copy.
///
/// Optional on purpose, and never the default. A board resolution belongs
/// to the company whose board passed it — its name is the first line of
/// the text — so a secretarial practice's mark at the top could be read as
/// though the practice resolved something. Hence the "Prepared by" line
/// under the letterhead and the rule beneath it: the identity block is
/// stated as the preparer's, and the document proper starts below the
/// line, still announcing its own company in its own first words.
Future<Uint8List> buildDocumentPdf({
  required String title,
  required String body,
  String? footerNote,
  Organization? letterhead,
  Uint8List? logo,
}) async {
  final kit = await PdfKit.load();
  final regular = kit.regular;
  final bold = kit.bold;

  final doc = pw.Document(title: title);

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(56, 56, 56, 48),
      theme: pw.ThemeData.withFont(base: regular, bold: bold).copyWith(
        defaultTextStyle: pw.TextStyle(font: regular, fontSize: 11, lineSpacing: 2.2),
      ),
      footer: (context) => pw.Container(
        alignment: pw.Alignment.centerRight,
        padding: const pw.EdgeInsets.only(top: 12),
        child: pw.Text(
          footerNote == null
              ? 'Page ${context.pageNumber} of ${context.pagesCount}'
              : '$footerNote  ·  Page ${context.pageNumber} of ${context.pagesCount}',
          style: pw.TextStyle(
              font: regular, fontSize: 8, color: PdfColors.grey600),
        ),
      ),
      build: (context) => [
        if (letterhead != null) ...[
          kit.letterhead(letterhead, logo: logo),
          pw.SizedBox(height: 6),
          pw.Text('Prepared by ${letterhead.legalName ?? letterhead.name}',
              style: pw.TextStyle(
                  font: regular, fontSize: 8, color: PdfColors.grey600)),
          kit.rule(),
        ],
        pw.Header(
          level: 0,
          padding: const pw.EdgeInsets.only(bottom: 10),
          decoration: const pw.BoxDecoration(
            border: pw.Border(
              bottom: pw.BorderSide(color: PdfColors.grey400, width: 0.7),
            ),
          ),
          child: pw.Text(title,
              style: pw.TextStyle(font: bold, fontSize: 14)),
        ),
        pw.SizedBox(height: 14),
        for (final block in _paragraphs(body)) ...[
          pw.RichText(
            text: pw.TextSpan(children: _inline(block, regular, bold)),
          ),
          pw.SizedBox(height: 10),
        ],
      ],
    ),
  );

  return doc.save();
}

/// Blank lines separate paragraphs; single newlines stay inside one.
List<String> _paragraphs(String body) => body
    .replaceAll('\r\n', '\n')
    .split(RegExp(r'\n[ \t]*\n'))
    .map((p) => p.trim())
    .where((p) => p.isNotEmpty)
    .toList();

/// Splits a paragraph on `**` and alternates weight. An unclosed `**`
/// simply renders as the rest of the paragraph in bold rather than
/// swallowing it or throwing, because half-written markup should still
/// print something a person can read and correct.
List<pw.TextSpan> _inline(String text, pw.Font regular, pw.Font bold) {
  final spans = <pw.TextSpan>[];
  final parts = text.split('**');
  for (var i = 0; i < parts.length; i++) {
    if (parts[i].isEmpty) continue;
    spans.add(pw.TextSpan(
      text: parts[i],
      style: pw.TextStyle(
        font: i.isOdd ? bold : regular,
        fontSize: 11,
        lineSpacing: 2.2,
      ),
    ));
  }
  return spans;
}
