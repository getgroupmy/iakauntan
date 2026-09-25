import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/banking/statement_import.dart';

/// Twelve kinds of financial document, ten ways each, all at once.
///
/// ## Where this comes from
///
/// The SmartScan Training/Handover v2 pack: 120 marked-synthetic fixture
/// PDFs — twelve document families (deposit, credit card, e-wallet,
/// loan, Islamic financing, fixed deposit, investment, merchant and
/// marketplace settlement, multi-currency, digital bank, payment
/// receipt) crossed with ten variants (standard, multiline, repeated
/// date, reversal, refund, fees and tax, foreign currency, negative
/// balance, no activity, high volume). No real institution, account,
/// person or balance appears anywhere in it.
///
/// What is committed here is the PDF TEXT LAYER and the ground truth,
/// not the PDFs: Dart cannot open a PDF on a test VM, and a corpus that
/// needs a Python library to run is a corpus that stops being run.
///
/// ## What it actually proves, and what it cannot
///
/// It proves OUR HALF. `rows` is the reading a perfect reader would
/// return, so every failure here is this repository's arithmetic, date
/// handling or sign logic — never the model's eyesight. That separation
/// is the point: until now a bad import could be blamed on the reader,
/// and there was nothing that could tell the two apart.
///
/// It does NOT prove that a vision model reads these pages correctly.
/// Nothing here runs a model. A green sweep means: given a correct
/// reading, we file it correctly.
void main() {
  late Map<String, dynamic> fixtures;

  setUpAll(() {
    final raw =
        File('test/fixtures/smartscan_corpus.json').readAsStringSync();
    fixtures = (jsonDecode(raw) as Map<String, dynamic>)['fixtures']
        as Map<String, dynamic>;
  });

  List<Map<String, String>> rowsOf(Map<String, dynamic> f, {bool signed = true}) =>
      (f['rows'] as List).map((r) {
        final m = (r as Map).map((k, v) => MapEntry(k as String, v as String));
        if (!signed) m['amount'] = m['amount']!.replaceFirst('-', '');
        return m;
      }).toList();

  test('the corpus is all here', () {
    // A corpus that silently shrinks is a gate that silently stops
    // gating. Both numbers are asserted so a truncated regeneration
    // fails rather than passes quietly.
    expect(fixtures, hasLength(120));
    expect(
      fixtures.values.fold<int>(
          0, (n, f) => n + ((f as Map)['expect'] as List).length),
      1488,
    );
    expect(
      fixtures.values.map((f) => (f as Map)['family']).toSet(),
      hasLength(12),
    );
  });

  test('every document files exactly as its ground truth says', () {
    final broken = <String>[];

    for (final e in fixtures.entries) {
      final f = e.value as Map<String, dynamic>;
      final want = (f['expect'] as List).cast<Map<String, dynamic>>();
      final parse =
          scannedStatement(OcrExtraction.fromJson({'rows': rowsOf(f)}));

      if (parse.rows.length != want.length) {
        broken.add('${e.key}: ${parse.rows.length} rows, wanted '
            '${want.length} — ${parse.problems.take(1)}');
        continue;
      }
      for (var i = 0; i < want.length; i++) {
        final date = DateTime.parse(want[i]['date'] as String);
        final amount = double.parse(want[i]['amount'] as String);
        if (parse.rows[i].date != date ||
            (parse.rows[i].amount - amount).abs() > 0.005) {
          broken.add('${e.key} line ${i + 1}: got '
              '${parse.rows[i].date} ${parse.rows[i].amount}, '
              'wanted $date $amount');
          break;
        }
      }
    }

    expect(broken, isEmpty, reason: broken.join('\n'));
  });

  /// The failure `balancesDecideTheSigns` exists for, across 1,488 rows.
  ///
  /// A Malaysian statement prints Debit and Credit as two columns and no
  /// sign at all, so a reader has to infer the direction from which
  /// column a figure sits in — and it gets that wrong often enough to
  /// matter. A wrong sign turns a withdrawal into a deposit, which is
  /// the most expensive mistake available here.
  ///
  /// So this hands the parser the WORST plausible reading: every amount
  /// positive, every direction lost. The running balance has to put all
  /// of it back.
  test('and still does when the reader loses every sign', () {
    final broken = <String>[];
    var repaired = 0;

    for (final e in fixtures.entries) {
      final f = e.value as Map<String, dynamic>;
      final want = (f['expect'] as List).cast<Map<String, dynamic>>();
      final parse = scannedStatement(
          OcrExtraction.fromJson({'rows': rowsOf(f, signed: false)}));

      if (parse.notices.isNotEmpty) repaired++;
      if (parse.rows.length != want.length) {
        broken.add('${e.key}: ${parse.rows.length}/${want.length} rows');
        continue;
      }
      for (var i = 0; i < want.length; i++) {
        final amount = double.parse(want[i]['amount'] as String);
        if ((parse.rows[i].amount - amount).abs() > 0.005) {
          broken.add('${e.key} line ${i + 1}: ${parse.rows[i].amount} '
              'not $amount');
          break;
        }
      }
    }

    expect(broken, isEmpty, reason: broken.join('\n'));
    // The twelve that raise nothing are the `no_activity` variants,
    // which have no rows to repair. Asserted so a version that silently
    // stopped repairing anything could not pass the loop above by
    // accident.
    expect(repaired, 108);
  });

  test('every document says which period it covers', () {
    final missing = <String>[];
    var placed = 0;

    for (final e in fixtures.entries) {
      final f = e.value as Map<String, dynamic>;
      final found = statementPeriodFromText(f['text'] as String);
      if (found == null) {
        missing.add(e.key);
        continue;
      }
      final want = (f['expect'] as List).cast<Map<String, dynamic>>();
      if (want.isEmpty) continue;
      final year = DateTime.parse(want.first['date'] as String).year;
      if (found.date.year != year) {
        missing.add('${e.key}: period ${found.date} but lines are $year');
        continue;
      }
      // The END of the period, not its start. Both ends share a year on
      // a one-month statement, so a year check alone cannot tell them
      // apart -- and taking the start would anchor a statement to the
      // day before its own first line.
      final last = DateTime.parse(want.last['date'] as String);
      if (found.date.isBefore(last)) {
        missing.add('${e.key}: period ends ${found.date} but a line is '
            'dated $last');
        continue;
      }
      placed++;
    }

    expect(missing, isEmpty, reason: missing.join('\n'));
    expect(placed, 108);
  });
}
