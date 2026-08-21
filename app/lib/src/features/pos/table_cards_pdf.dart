import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/pdf_kit.dart';
import '../../data/models.dart';

/// The cards that go on the tables.
///
/// `pos_table_by_code` turns a scanned string into a table, and the
/// till's assign-table sheet reads a wedge scanner into it. Both were
/// useless on the day they shipped, because a shop had nothing to scan:
/// the codes existed in the database and nowhere in the room. This is
/// the missing half — a sheet of cards to print, cut and stand on the
/// tables.
///
/// ## What the QR holds
///
/// The bare code, `T7`. Not a URL.
///
/// The lookup accepts three shapes — a bare code, a URL, a `table:T7`
/// token — because a shop that already prints stickers from some other
/// system should not have to reprint them. That tolerance is for
/// stickers this app did not make. What it makes itself should be the
/// shortest of the three, for two reasons that both matter on a card
/// that lives on a restaurant table:
///
///   * a short payload is a coarser QR, and a coarse QR survives being
///     wiped down, scratched and read at an angle in poor light;
///   * a URL is a promise. `https://iakauntan.com/t/T7` is not a page,
///     and a customer who points a phone at it and gets nothing has
///     been misled by us rather than by their own curiosity.
///
/// The code is printed under the QR in plain text as well, because the
/// fallback for every scanner that ever fails is somebody reading it
/// and typing it, and the sheet the cashier types into accepts exactly
/// that.
///
/// ## Six to a page
///
/// A4, two across and three down, each card about 95 by 88 mm — a
/// tent card folded once, or a flat card in a stand. Cut lines are
/// drawn as a thin grey rule rather than a dashed crop mark: a shop
/// cuts these with scissors, not a guillotine.
Future<Uint8List> buildTableCardsPdf({
  required Organization org,
  required String outletName,
  required List<Map<String, dynamic>> tables,
}) async {
  final kit = await PdfKit.load();
  final pdf = pw.Document(title: 'Table cards — $outletName');

  final cards = tableCardsFrom(tables);
  for (var start = 0; start < cards.length; start += tableCardsPerPage) {
    final page = cards.sublist(
      start,
      (start + tableCardsPerPage).clamp(0, cards.length),
    );
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        theme: kit.theme,
        margin: const pw.EdgeInsets.all(18),
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                children: [
                  for (var row = 0; row < 3; row++)
                    pw.Expanded(
                      child: pw.Row(
                        children: [
                          for (var col = 0; col < 2; col++)
                            pw.Expanded(
                              child: row * 2 + col < page.length
                                  ? _card(kit, page[row * 2 + col],
                                      outletName: outletName, org: org)
                                  // An empty slot is still drawn as a
                                  // box, so the last page cuts on the
                                  // same lines as every other one.
                                  : _blank(),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  return pdf.save();
}

/// How many cards fit on one A4 sheet, two across and three down.
const int tableCardsPerPage = 6;

/// The cards a floor plan's rows amount to.
///
/// The plan returns one row per open bill, so a table with two bills on
/// it — which a split leaves, legitimately — arrives twice. Folded by
/// code, keeping the order the plan gave: by area then code, which is
/// the order somebody walking the room would want to cut them in.
///
/// A row with no code is dropped rather than printed blank. There is
/// nothing to encode and nothing to type, so a card for it would be a
/// square of ink that no scan can ever resolve.
///
/// Separate from the drawing so it can be asserted. The deduplication
/// is the part that is wrong in a way a rendered PDF does not announce.
List<Map<String, dynamic>> tableCardsFrom(List<Map<String, dynamic>> rows) {
  final seen = <String>{};
  final cards = <Map<String, dynamic>>[];
  for (final t in rows) {
    final code = '${t['table_code'] ?? ''}'.trim();
    if (code.isEmpty || !seen.add(code.toUpperCase())) continue;
    cards.add(t);
  }
  return cards;
}

/// What the QR on a card holds.
///
/// The bare code, deliberately — see the note on [buildTableCardsPdf].
/// It is a function rather than an inline expression so the choice has
/// somewhere to be asserted: `pos_table_by_code` accepts a URL too, so
/// encoding one here would pass every scan test and still be the wrong
/// thing to print.
String tableCardPayload(Map<String, dynamic> table) =>
    '${table['table_code'] ?? ''}'.trim();

pw.Widget _blank() => pw.Container(
      margin: const pw.EdgeInsets.all(4),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300, width: 0.4),
      ),
    );

pw.Widget _card(
  PdfKit kit,
  Map<String, dynamic> table, {
  required String outletName,
  required Organization org,
}) {
  final code = '${table['table_code'] ?? ''}'.trim();
  final name = '${table['table_name'] ?? code}'.trim();
  final area = table['area'] == null ? null : '${table['area']}'.trim();
  final seats = (table['seats'] as num?)?.toInt();

  return pw.Container(
    margin: const pw.EdgeInsets.all(4),
    padding: const pw.EdgeInsets.all(10),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: PdfColors.grey300, width: 0.4),
    ),
    child: pw.Column(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            // The table's name, big enough to be the thing a waiter
            // reads rather than the QR.
            pw.Text(name, style: kit.style(size: 26, strong: true)),
            if (area != null && area.isNotEmpty)
              pw.Text(
                [area, if (seats != null) '$seats seats'].join('  ·  '),
                style: kit.style(size: 9, colour: PdfColors.grey700),
              )
            else if (seats != null)
              pw.Text('$seats seats',
                  style: kit.style(size: 9, colour: PdfColors.grey700)),
          ],
        ),
        pw.BarcodeWidget(
          barcode: pw.Barcode.qrCode(
            // The highest correction level the payload can afford,
            // which for a two- or three-character code is all of it.
            // A card on a table gets wet, greasy and scratched.
            errorCorrectLevel: pw.BarcodeQRCorrectionLevel.high,
          ),
          data: tableCardPayload(table),
          width: 108,
          height: 108,
          drawText: false,
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            // Printed as well as encoded: every scanner eventually
            // fails, and the sheet at the till takes a typed code.
            pw.Text(code,
                style: kit.style(size: 13, strong: true)),
            pw.SizedBox(height: 2),
            pw.Text(
              outletName.isEmpty ? org.name : outletName,
              style: kit.style(size: 8, colour: PdfColors.grey600),
              maxLines: 1,
            ),
          ],
        ),
      ],
    ),
  );
}
