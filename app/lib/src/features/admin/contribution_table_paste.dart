/// Reading a gazetted contribution table that somebody pasted in.
///
/// README, under HRMS: *the seeded schedules carry the published
/// percentages and thresholds, which is enough to compute correctly, but
/// KWSP and PERKESO also gazette contribution TABLES whose band amounts
/// differ from a straight percentage by a few sen. Load the authority's
/// own table and mark the schedule verified before submitting real
/// returns.*
///
/// The mechanism to hold one has existed since `0025`:
/// `statutory_rates.employee_amount` and `employer_amount` are the band
/// amounts, and the console has an editor with gap and overlap checks.
/// What has stopped anybody loading a table is that KWSP's Third
/// Schedule runs to about ninety bands and PERKESO's to about seventy,
/// and typing them into a form four boxes at a time is an afternoon.
///
/// So this reads them instead. **It supplies no figures.** Every number
/// comes from what was pasted, out of the authority's own published
/// table; nothing here knows what an EPF band contributes and nothing
/// here fills a gap. A line it cannot read is REPORTED rather than
/// guessed at, because a band quietly dropped from the middle of a
/// table is a wage that lands in no band and a deduction of nothing.
library;

import '../../core/format.dart';
import 'statutory_rates_admin.dart' show RateDraft;

/// Which of the two amount columns comes first.
///
/// Chosen, never guessed, and this is the reason: KWSP prints *Majikan*
/// (employer) before *Pekerja* (employee) and most English-language
/// reproductions print employee first. Read the wrong way round, a
/// table publishes every employee's deduction as the employer's share
/// and every employer's as the employee's — smaller numbers where the
/// bigger ones belong, on every payslip, and nothing downstream can
/// tell because both figures are plausible.
enum AmountColumns {
  /// Employee's share first, then the employer's.
  employeeFirst,

  /// The employer's first, which is how KWSP prints it.
  employerFirst,
}

/// A line that was not read, and why.
class SkippedLine {
  const SkippedLine(this.line, this.because);

  final String line;
  final String because;
}

class ParsedTable {
  const ParsedTable({
    required this.bands,
    required this.skipped,
    this.headerSuggests,
  });

  final List<RateDraft> bands;

  /// Every line that produced no band, with the reason. Shown rather
  /// than counted: "read 88 of 91 lines" tells nobody which three.
  final List<SkippedLine> skipped;

  /// What the column headings imply, where they say anything — so a
  /// choice that contradicts the paste can be questioned before it is
  /// saved. Null when the paste carries no heading to go on.
  final AmountColumns? headerSuggests;
}

/// Numbers as a Malaysian statutory table prints them: `5,000.01`,
/// `RM 20.75`, `0.00`. Comma is the thousands separator and the point is
/// the decimal, which is what every table from KWSP, PERKESO and LHDN
/// uses.
final _number = RegExp(r'\d[\d,]*(?:\.\d+)?');

/// The words a top band uses instead of an upper bound.
final _openEnded = RegExp(
  r'melebihi|exceed|and above|ke atas|dan ke atas|onwards|\bover\b',
  caseSensitive: false,
);

/// Words that mean this line is a heading rather than a band.
final _heading = RegExp(
  r'gaji|wage|upah|majikan|employer|pekerja|employee|jumlah|total|'
  r'caruman|contribution|bulanan|monthly|kategori|category',
  caseSensitive: false,
);

double? _read(String raw) => Fmt.typedNumber(raw.replaceAll(',', ''));

/// What the headings say the column order is, or null.
///
/// Only where ONE of the two words appears before the other and both
/// are present: a table whose heading says "Majikan" and nothing else
/// is not evidence about order.
AmountColumns? detectColumnOrder(String text) {
  for (final line in text.split('\n')) {
    final lower = line.toLowerCase();
    final employer = RegExp(r'majikan|employer').firstMatch(lower)?.start;
    final employee = RegExp(r'pekerja|employee').firstMatch(lower)?.start;
    if (employer == null || employee == null) continue;
    if (employer == employee) continue;
    return employer < employee
        ? AmountColumns.employerFirst
        : AmountColumns.employeeFirst;
  }
  return null;
}

/// Reads a pasted contribution table.
///
/// A closed band needs four numbers — from, to, and the two amounts —
/// and an open-ended top band needs three, with a word like *melebihi*
/// saying so. Anything else is skipped and named. That is deliberately
/// strict: a line with five numbers might be a band with a serial
/// number in front of it or a band with a total on the end, and
/// choosing between those is guessing at a statutory figure.
ParsedTable parseContributionTable(
  String text, {
  required AmountColumns order,
  String category = 'default',
}) {
  final bands = <RateDraft>[];
  final skipped = <SkippedLine>[];

  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    final numbers = _number
        .allMatches(line)
        .map((m) => _read(m.group(0)!))
        .whereType<double>()
        .toList();

    if (numbers.isEmpty) {
      // A heading is expected and is not worth reporting; anything else
      // without a number is.
      if (!_heading.hasMatch(line)) {
        skipped.add(SkippedLine(line, 'no figures on it'));
      }
      continue;
    }

    final open = _openEnded.hasMatch(line);

    // A heading carrying a number — "Tahun 2026", a page number — is a
    // heading. Checked after the open-ended test, because "Melebihi
    // RM20,000" contains the word "gaji" in some printings and IS a
    // band.
    if (!open && numbers.length < 3 && _heading.hasMatch(line)) continue;

    double from;
    double? to;
    double first;
    double second;

    if (open) {
      if (numbers.length < 3) {
        skipped.add(SkippedLine(
          line,
          'reads as the top band but carries ${numbers.length} '
          'figure${numbers.length == 1 ? '' : 's'}, not three',
        ));
        continue;
      }
      from = numbers[0];
      to = null;
      first = numbers[numbers.length - 2];
      second = numbers[numbers.length - 1];
      if (numbers.length > 3) {
        skipped.add(SkippedLine(
          line,
          'the top band carries ${numbers.length} figures and only three '
          'were expected — check what was read',
        ));
        continue;
      }
    } else {
      if (numbers.length != 4) {
        skipped.add(SkippedLine(
          line,
          'carries ${numbers.length} '
          'figure${numbers.length == 1 ? '' : 's'}, and a band needs four: '
          'from, to, and the two amounts',
        ));
        continue;
      }
      from = numbers[0];
      to = numbers[1];
      first = numbers[2];
      second = numbers[3];

      if (to < from) {
        skipped.add(SkippedLine(
          line,
          'the band ends below where it starts',
        ));
        continue;
      }
    }

    final employee = order == AmountColumns.employeeFirst ? first : second;
    final employer = order == AmountColumns.employeeFirst ? second : first;

    bands.add(
      RateDraft(
        category: category,
        wageFrom: from,
        wageTo: to,
        employeeAmount: employee,
        employerAmount: employer,
      ),
    );
  }

  // In wage order, whatever order the paste was in. A table copied out
  // of a PDF in two columns arrives interleaved, and the gap and
  // overlap check downstream reads consecutive bands.
  bands.sort((a, b) => a.wageFrom.compareTo(b.wageFrom));

  return ParsedTable(
    bands: bands,
    skipped: skipped,
    headerSuggests: detectColumnOrder(text),
  );
}

/// What to say about a parse before anybody saves it — or null.
///
/// Separate from [parseContributionTable] so the warning can be shown
/// beside the preview rather than instead of it: somebody who meant the
/// order they chose should be able to look at the figures and confirm
/// it, and somebody who did not should be stopped by reading them.
String? columnOrderWarning(ParsedTable parsed, AmountColumns chosen) {
  final suggested = parsed.headerSuggests;
  if (suggested == null || suggested == chosen) return null;
  return suggested == AmountColumns.employerFirst
      ? 'The headings in what you pasted put the employer’s column '
          'first, and you have chosen employee first. Read the wrong way '
          'round, every employee is deducted the employer’s share.'
      : 'The headings in what you pasted put the employee’s column '
          'first, and you have chosen employer first. Read the wrong way '
          'round, every employee is deducted the employer’s share.';
}
