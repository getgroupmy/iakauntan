import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/ocr_repository.dart';
import 'line_draft.dart';

/// Which of the three figures disagreed.
enum TotalPart { subtotal, tax, total }

/// The paper's figure beside the one the lines come to.
class TotalsDifference {
  const TotalsDifference({
    required this.part,
    required this.label,
    required this.paper,
    required this.lines,
  });

  final TotalPart part;

  /// What a person calls it — 'tax', not 'tax_amount'.
  final String label;

  /// What was printed on the supplier's document.
  final double paper;

  /// What this document's lines add up to.
  final double lines;

  /// Signed: positive where the paper is the larger figure.
  double get by => paper - lines;
}

/// Half a sen. Below this the two agree: every figure here has already
/// been rounded to the cent on both sides, and a screen that warned
/// about 0.000001 would warn about every document ever read.
const double totalsTolerance = 0.005;

/// What the paper said, against what the lines come to.
///
/// The reason this exists: this system computes tax per LINE — `app.
/// calc_document_line` charges each line at its own code and `0009`'s
/// trigger derives the header from the sum — while a supplier's
/// document often states ONE tax figure for the whole bill. The two
/// can differ for three reasons that all matter and none of which
/// announced itself before `0705`:
///
///  * a line carries the wrong tax code, so 8% was charged where the
///    paper charged 6% or nothing;
///  * the supplier rounded the whole bill where this rounds each line,
///    which is a sen or two and is the ordinary case;
///  * a line was mistyped, in which case the subtotal disagrees too and
///    the tax difference is a symptom.
///
/// Nothing is corrected here. Which of those it is takes a person, and
/// the two acceptable answers — change a line, or leave it — are not a
/// machine's to choose.
///
/// Empty where there is no paper, where the reader found none of the
/// three figures, and where everything agrees. A figure the reader did
/// NOT find is skipped rather than treated as zero: "the total is not
/// printed on this delivery order" is a real answer and warning that it
/// should have been RM 1,164.23 would be nonsense.
List<TotalsDifference> totalsDisagreement({
  required ScanTotals? paper,
  required double subtotal,
  required double tax,
  required double total,
}) {
  if (paper == null) return const [];

  final out = <TotalsDifference>[];

  void compare(TotalPart part, String label, double? said, double here) {
    if (said == null) return;
    if ((said - here).abs() < totalsTolerance) return;
    out.add(TotalsDifference(
      part: part,
      label: label,
      paper: said,
      lines: here,
    ));
  }

  compare(TotalPart.subtotal, 'subtotal', paper.subtotal, subtotal);
  compare(TotalPart.tax, 'tax', paper.tax, tax);
  compare(TotalPart.total, 'total', paper.total, total);
  return out;
}

/// The three ways a total can be rounded, as `0706` names them.
///
/// `'none'` is a rounding method: it means "to the sen", which is what
/// every non-cash bill in the country is paid to.
const roundingMethods = <String>['none', 'nearest_5cent', 'nearest_10cent'];

/// What [raw] comes to under [method].
double roundedTo(double raw, String method) => switch (method) {
      'nearest_5cent' => (raw * 20).round() / 20,
      'nearest_10cent' => (raw * 10).round() / 10,
      _ => (raw * 100).round() / 100,
    };

/// What rounding the PAPER applied, where the paper can say.
///
/// Bank Negara's rounding mechanism, in force since 1 April 2008, exists
/// because there is no one sen coin: it rounds the amount payable in
/// CASH at a counter. A bill settled by transfer, card or on credit
/// terms is paid to the sen and nobody rounds it. `organizations.
/// rounding_method` is one switch for the whole company, though, so a
/// company that takes cash — which is why the switch is set — had that
/// setting restating every supplier bill it received as well.
///
/// The supplier's paper settles it, and settles it with a printed
/// figure rather than a guess: whichever method takes the lines to the
/// total the paper states is the one the supplier used.
///
/// Null where it cannot be told, and that is the important half:
///
///  * no total was read — there is nothing to compare;
///  * MORE THAN ONE method produces the stated total. A bill that lands
///    on a 5 sen boundary reads identically however it was rounded, and
///    answering `none` there would turn every such document into an
///    override of a company setting on no evidence at all;
///  * NO method produces it, which means the lines do not tie to the
///    paper for some other reason. That is what `0705`'s banner is for,
///    and guessing a rounding method from a document that does not
///    reconcile would bury it.
String? roundingThePaperApplied({
  required double? paperTotal,
  required double rawTotal,
}) {
  if (paperTotal == null) return null;
  final matches = roundingMethods
      .where((m) => (roundedTo(rawTotal, m) - paperTotal).abs() < totalsTolerance)
      .toList();
  return matches.length == 1 ? matches.single : null;
}

/// The rounding the paper implies for the lines as they stand now.
///
/// The one seam between [roundingThePaperApplied] and the editor, so
/// that the arithmetic in between — what the drafted lines actually
/// come to, tax and all — is asserted over real [LineDraft]s rather
/// than over a figure a test worked out by hand.
///
/// Asked again every time the lines move, and that is not an
/// optimisation to skip: when a reading first lands, its lines carry NO
/// TAX CODE. `_applyScan` leaves them alone deliberately — a rate
/// guessed off a printed figure is a posted amount that does not match
/// the return — so a taxed bill reads as 1,086.12 against a paper that
/// says 1,173.01 and ties to nothing at all. It is only once somebody
/// has put the codes on that the two can be compared, which is minutes
/// later and several keystrokes away from the scan.
///
/// [current] is returned untouched wherever the paper cannot say, which
/// is what stops a half-typed document from undoing an answer already
/// reached — and what stops a second reading that found no total from
/// clearing the first one's.
String? roundingForLines({
  required double? paperTotal,
  required List<LineDraft> lines,
  String? current,
}) =>
    roundingThePaperApplied(
      paperTotal: paperTotal,
      rawTotal: lines.fold<double>(0, (sum, l) => sum + l.totals.total),
    ) ??
    current;

/// How to say it in the totals card.
String roundingMethodSaid(String method) => switch (method) {
      'none' => 'The paper does not round — this totals to the sen.',
      'nearest_5cent' => 'The paper rounds to the nearest 5 sen.',
      'nearest_10cent' => 'The paper rounds to the nearest 10 sen.',
      _ => 'The paper sets how this rounds.',
    };

/// One difference, as a sentence.
String differenceSentence(TotalsDifference d, {required String currency}) =>
    'The paper says ${d.label} ${Fmt.money(d.paper, currency: currency)}; '
    'these lines come to ${Fmt.money(d.lines, currency: currency)}.';

/// How far out, for the summary line.
///
/// The largest of the differences rather than their sum: they are three
/// views of the same document and adding them would report a bill that
/// is a sen out as being three sen out.
double worstDifference(List<TotalsDifference> found) => found.fold(
      0,
      (worst, d) => d.by.abs() > worst ? d.by.abs() : worst,
    );

/// What the scanned paper said, where the lines say otherwise.
///
/// Silent in every ordinary case — no paperwork, nothing read, or the
/// figures agree — which is deliberate: a banner that appears on every
/// document is one nobody reads by the second week.
class ScanTotalsBanner extends ConsumerWidget {
  const ScanTotalsBanner({
    super.key,
    required this.table,
    required this.recordId,
    required this.subtotal,
    required this.tax,
    required this.total,
    required this.currency,
  });

  final String table;
  final String recordId;
  final double subtotal;
  final double tax;
  final double total;
  final String currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paper = ref
        .watch(documentScanTotalsProvider(
          (table: table, recordId: recordId),
        ))
        .valueOrNull;

    final found = totalsDisagreement(
      paper: paper,
      subtotal: subtotal,
      tax: tax,
      total: total,
    );
    if (found.isEmpty) return const SizedBox.shrink();

    final colour = context.colors.warning;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        key: const Key('scan-totals-banner'),
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.rule_outlined, size: 20, color: colour),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'This does not tie to ${paper!.fileName}',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: colour,
                      ),
                    ),
                    const SizedBox(height: 4),
                    for (final d in found)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          differenceSentence(d, currency: currency),
                          key: Key('scan-totals-${d.part.name}'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      'Tax is charged on each line here, and a supplier '
                      'often prints one figure for the whole bill, so a '
                      'sen or two is rounding. More than that is usually '
                      'a line on the wrong tax code.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
