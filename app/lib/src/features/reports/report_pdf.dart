import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/format.dart';
import '../../core/pdf_kit.dart';
import '../../data/models.dart';
import 'report_spec.dart';

/// A management report as a document somebody can file or send on.
///
/// It carries the letterhead for the same reason an invoice does: once
/// the PDF leaves the app, nothing else says which company's numbers
/// these are. A balance sheet with no name on it is not evidence of
/// anything.
///
/// [generatedAt] is stamped in the footer. A report drawn from an open
/// period is a snapshot, not a fact, and the date is what lets somebody
/// holding two copies tell which one is later.
Future<Uint8List> buildReportPdf({
  required Organization org,
  required ReportSpec spec,
  required DateTime generatedAt,
  Uint8List? logo,
  LetterheadMode mode = LetterheadMode.printed,
}) async {
  final kit = await PdfKit.load();
  final pdf = pw.Document(title: '${spec.title} — ${org.name}');

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(42, 42, 42, 36),
      theme: kit.theme,
      footer: (context) => kit.footer(context,
          note: 'Generated ${Fmt.dateTime(generatedAt)}'),
      build: (context) => [
        // No big grey word in the corner: the report names itself in
        // bold two lines below, and "REPORT" above "Profit & Loss" is
        // one label too many.
        kit.letterhead(org, logo: logo, mode: mode),
        kit.rule(),

        pw.Text(spec.title, style: kit.style(size: 13, strong: true)),
        pw.SizedBox(height: 2),
        pw.Text(spec.subtitle,
            style: kit.style(size: 8.5, colour: PdfColors.grey700)),
        pw.SizedBox(height: 14),

        for (final block in spec.blocks) ..._block(kit, block),

        if (spec.note != null) ...[
          pw.SizedBox(height: 16),
          pw.Text(spec.note!, style: kit.style(size: 8, colour: PdfColors.grey700)),
        ],
      ],
    ),
  );

  return pdf.save();
}

List<pw.Widget> _block(PdfKit kit, ReportBlock block) => switch (block) {
      // An empty section is left out entirely. A printed "Total Cost of
      // Sales: 0.00" under a heading with nothing beneath it invites the
      // reader to wonder what went missing.
      ReportSection s when s.lines.isEmpty => const [],
      ReportSection s => [_section(kit, s), pw.SizedBox(height: 6)],
      ReportGrid g => [_grid(kit, g), pw.SizedBox(height: 12)],
      ReportHighlight h => [_highlight(kit, h), pw.SizedBox(height: 6)],
    };

pw.Widget _section(PdfKit kit, ReportSection s) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(height: 8),
        pw.Text(s.title.toUpperCase(),
            style: kit.style(size: 8, strong: true, colour: PdfColors.grey700)),
        pw.SizedBox(height: 4),
        for (final line in s.lines)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
            child: pw.Row(children: [
              pw.SizedBox(
                width: 54,
                child: pw.Text(line.code,
                    style: kit.style(size: 8.5, colour: PdfColors.grey700)),
              ),
              pw.Expanded(child: pw.Text(line.name, style: kit.style())),
              pw.Text(Fmt.money(line.amount), style: kit.style()),
            ]),
          ),
        pw.Container(
          margin: const pw.EdgeInsets.symmetric(vertical: 4),
          height: 0.7,
          color: PdfColors.grey400,
        ),
        pw.Row(children: [
          pw.SizedBox(width: 54),
          pw.Expanded(
              child: pw.Text('Total ${s.title}',
                  style: kit.style(strong: true))),
          pw.Text(Fmt.money(s.total), style: kit.style(strong: true)),
        ]),
      ],
    );

pw.Widget _grid(PdfKit kit, ReportGrid g) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (g.title != null) ...[
          pw.Text(g.title!.toUpperCase(),
              style:
                  kit.style(size: 8, strong: true, colour: PdfColors.grey700)),
          pw.SizedBox(height: 4),
        ],
        if (g.rows.isEmpty)
          pw.Text('None', style: kit.style(size: 8.5, colour: PdfColors.grey600))
        else
          pw.TableHelper.fromTextArray(
            // A number that is not right-aligned cannot be read down a
            // column; a label that is right-aligned looks like one.
            cellAlignments: {
              for (var i = 0; i < g.headers.length; i++)
                i: g.isNumeric(i)
                    ? pw.Alignment.centerRight
                    : pw.Alignment.centerLeft,
            },
            headerAlignments: {
              for (var i = 0; i < g.headers.length; i++)
                i: g.isNumeric(i)
                    ? pw.Alignment.centerRight
                    : pw.Alignment.centerLeft,
            },
            headerStyle: kit.style(size: 8, strong: true),
            cellStyle: kit.style(size: 9),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
            cellPadding:
                const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            headers: g.headers,
            data: [
              for (final row in g.rows) [for (final c in row) _cell(c)],
              if (g.total != null) [for (final c in g.total!) _cell(c)],
            ],
          ),
      ],
    );

String _cell(Cell c) => switch (c) {
      TextCell t => t.text,
      // An unsigned zero prints as a blank so the eye runs past it: a
      // trial balance is mostly empty cells and printing "0.00" in every
      // one of them hides the figures that matter.
      MoneyCell m when !m.signed && m.value == 0 => '',
      MoneyCell m => Fmt.money(m.value),
    };

pw.Widget _highlight(PdfKit kit, ReportHighlight h) => pw.Container(
      margin: const pw.EdgeInsets.only(top: 8),
      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: pw.BoxDecoration(
          color: h.emphasise ? PdfColors.grey200 : PdfColors.grey100),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(h.label,
              style: kit.style(size: h.emphasise ? 11 : 9.5, strong: true)),
          pw.Text(Fmt.money(h.value),
              style: kit.style(size: h.emphasise ? 11 : 9.5, strong: true)),
        ],
      ),
    );
