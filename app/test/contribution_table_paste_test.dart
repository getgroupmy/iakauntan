import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/admin/contribution_table_paste.dart';

/// Reading a gazetted contribution table somebody pasted in.
///
/// ## No figure in this file is a statutory figure
///
/// Every number below was invented for the test and none of it is
/// anybody's contribution table. That is deliberate and it is the point
/// of the parser: it supplies no figures, so a test of it needs none.
/// The shapes are real — how KWSP and PERKESO print a wage range, a top
/// band, a heading — and the amounts are not.
///
/// ## The fault worth the most care
///
/// KWSP prints *Majikan* before *Pekerja*; most English reproductions
/// print employee first. Read the wrong way round, every employee is
/// deducted the employer's share — smaller numbers where the bigger
/// ones belong, on every payslip, and nothing downstream can tell
/// because both figures are plausible. So the order is chosen rather
/// than guessed, and a choice that contradicts the pasted headings is
/// questioned.
void main() {
  group('a band', () {
    test('four figures is a band', () {
      final out = parseContributionTable(
        '5,000.01\t5,020.00\t11.11\t22.22',
        order: AmountColumns.employeeFirst,
      );
      expect(out.bands, hasLength(1));
      expect(out.bands.single.wageFrom, 5000.01);
      expect(out.bands.single.wageTo, 5020.00);
      expect(out.bands.single.employeeAmount, 11.11);
      expect(out.bands.single.employerAmount, 22.22);
    });

    test('the order chosen is the order used', () {
      final out = parseContributionTable(
        '0.00 10.00 11.11 22.22',
        order: AmountColumns.employerFirst,
      );
      // The same line, the other way round. Nothing about the figures
      // says which is which, which is exactly why this is a choice.
      expect(out.bands.single.employerAmount, 11.11);
      expect(out.bands.single.employeeAmount, 22.22);
    });

    test('RM, commas and an en dash are read through', () {
      final out = parseContributionTable(
        'RM 1,000.01 – RM 1,020.00    RM 5.50    RM 9.75',
        order: AmountColumns.employeeFirst,
      );
      expect(out.bands.single.wageFrom, 1000.01);
      expect(out.bands.single.wageTo, 1020.00);
      expect(out.bands.single.employeeAmount, 5.50);
    });

    test('a comma is thousands, not a decimal point', () {
      // Every Malaysian statutory table prints it this way. Read as a
      // decimal separator, a band starting at RM 5,000.01 starts at
      // five ringgit and swallows the eighty bands below it.
      final out = parseContributionTable(
        '5,000.01 5,020.00 1.00 2.00',
        order: AmountColumns.employeeFirst,
      );
      expect(out.bands.single.wageFrom, 5000.01);
    });

    test('a zero amount is a real amount, not a missing one', () {
      // The lowest EPF band contributes nothing and SOCSO's second
      // category takes nothing from the employee. A parser that treated
      // 0.00 as absent would drop the band.
      final out = parseContributionTable(
        '0.00 10.00 0.00 0.00',
        order: AmountColumns.employeeFirst,
      );
      expect(out.bands, hasLength(1));
      expect(out.bands.single.employeeAmount, 0);
      expect(out.bands.single.employerAmount, 0);
    });
  });

  group('the top band', () {
    test('"Melebihi" with three figures is open-ended', () {
      final out = parseContributionTable(
        'Melebihi RM20,000.00    102.50    205.00',
        order: AmountColumns.employeeFirst,
      );
      expect(out.bands.single.wageFrom, 20000.00);
      expect(out.bands.single.wageTo, isNull);
      expect(out.bands.single.employeeAmount, 102.50);
    });

    test('and so is "and above"', () {
      final out = parseContributionTable(
        '20,000.01 and above   102.50   205.00',
        order: AmountColumns.employeeFirst,
      );
      expect(out.bands.single.wageTo, isNull);
      expect(out.bands.single.wageFrom, 20000.01);
    });

    test('three figures with no such word is NOT a band', () {
      // It is a band missing an amount, or a heading with a year in it.
      // Deciding between them is guessing at a statutory figure.
      final out = parseContributionTable(
        '5,000.01 5,020.00 11.11',
        order: AmountColumns.employeeFirst,
      );
      expect(out.bands, isEmpty);
      expect(out.skipped.single.because, contains('needs four'));
    });
  });

  group('what it refuses to guess at', () {
    test('a line with five figures is reported, not trimmed', () {
      // A serial number in front, or a total on the end — and choosing
      // wrongly publishes the total as the employer's share.
      final out = parseContributionTable(
        '12  5,000.01  5,020.00  11.11  22.22',
        order: AmountColumns.employeeFirst,
      );
      expect(out.bands, isEmpty);
      expect(out.skipped.single.because, contains('5 figures'));
    });

    test('a band that ends below where it starts is reported', () {
      final out = parseContributionTable(
        '5,020.00 5,000.01 11.11 22.22',
        order: AmountColumns.employeeFirst,
      );
      expect(out.bands, isEmpty);
      expect(out.skipped.single.because, contains('ends below'));
    });

    test('the skipped line itself is shown, not just a count', () {
      // "Read 88 of 91 lines" tells nobody which three.
      final out = parseContributionTable(
        '12  5,000.01  5,020.00  11.11  22.22',
        order: AmountColumns.employeeFirst,
      );
      expect(out.skipped.single.line, contains('12'));
    });

    test('a heading is dropped quietly', () {
      // Every paste has one and reporting it as a problem trains
      // somebody to ignore the list that matters.
      final out = parseContributionTable(
        'Gaji Bulanan\tMajikan\tPekerja\n0.00 10.00 1.00 2.00',
        order: AmountColumns.employerFirst,
      );
      expect(out.bands, hasLength(1));
      expect(out.skipped, isEmpty);
    });

    test('but a line with no figures and no heading words is not', () {
      // A stray footer rather than a column heading. "see overleaf for
      // category two" would NOT do here: it carries the word
      // "category", which is a heading word, and the parser is right to
      // drop it — which is what the first draft of this test got wrong.
      final out = parseContributionTable(
        'continued on the next page\n0.00 10.00 1.00 2.00',
        order: AmountColumns.employeeFirst,
      );
      expect(out.bands, hasLength(1));
      expect(out.skipped.single.because, contains('no figures'));
    });
  });

  group('the order of the bands', () {
    test('a table pasted out of order comes back in wage order', () {
      // A PDF printed in two columns arrives interleaved, and the gap
      // and overlap check downstream reads consecutive bands.
      final out = parseContributionTable(
        '20.01 30.00 3.00 6.00\n'
        '0.00 10.00 1.00 2.00\n'
        '10.01 20.00 2.00 4.00',
        order: AmountColumns.employeeFirst,
      );
      expect(
        out.bands.map((b) => b.wageFrom).toList(),
        [0.00, 10.01, 20.01],
      );
    });
  });

  group('which column is which', () {
    test('Malay headings say employer first, the way KWSP prints it', () {
      expect(
        detectColumnOrder('Gaji Bulanan | Majikan | Pekerja'),
        AmountColumns.employerFirst,
      );
    });

    test('English headings usually say employee first', () {
      expect(
        detectColumnOrder('Wages | Employee | Employer'),
        AmountColumns.employeeFirst,
      );
    });

    test('one word alone is not evidence about order', () {
      expect(detectColumnOrder('Caruman Majikan'), isNull);
      expect(detectColumnOrder('0.00 10.00 1.00 2.00'), isNull);
    });

    test('a choice that agrees with the headings is not questioned', () {
      final out = parseContributionTable(
        'Gaji | Majikan | Pekerja\n0.00 10.00 1.00 2.00',
        order: AmountColumns.employerFirst,
      );
      expect(columnOrderWarning(out, AmountColumns.employerFirst), isNull);
    });

    test('a choice that contradicts them says what it would cost', () {
      final out = parseContributionTable(
        'Gaji | Majikan | Pekerja\n0.00 10.00 1.00 2.00',
        order: AmountColumns.employeeFirst,
      );
      final warning = columnOrderWarning(out, AmountColumns.employeeFirst);
      expect(warning, isNotNull);
      // Not "the order may be wrong". What it costs, so somebody can
      // weigh it: the figures are both plausible and nothing downstream
      // can tell.
      expect(warning, contains('deducted the employer'));
    });

    test('a paste with no headings is not questioned either way', () {
      final out = parseContributionTable(
        '0.00 10.00 1.00 2.00',
        order: AmountColumns.employeeFirst,
      );
      expect(columnOrderWarning(out, AmountColumns.employeeFirst), isNull);
      expect(columnOrderWarning(out, AmountColumns.employerFirst), isNull);
    });
  });

  group('a table of the shape a real one has', () {
    test('ninety-ish bands and a top band read as one set', () {
      // The shape, not the figures. A KWSP schedule is bands of twenty
      // ringgit up to five thousand and a hundred after that, ending in
      // "Melebihi".
      final lines = <String>['Gaji Bulanan\tMajikan\tPekerja'];
      for (var i = 0; i < 90; i++) {
        final from = (i * 20).toStringAsFixed(2);
        final to = (i * 20 + 19.99).toStringAsFixed(2);
        lines.add('$from\t$to\t${i + 1}.00\t${i + 2}.00');
      }
      lines.add('Melebihi 1,800.00\t95.00\t96.00');

      final out = parseContributionTable(
        lines.join('\n'),
        order: AmountColumns.employerFirst,
      );
      expect(out.bands, hasLength(91));
      expect(out.skipped, isEmpty);
      expect(out.bands.last.wageTo, isNull);
      // Employer first, so the first of the two amounts is theirs.
      expect(out.bands.first.employerAmount, 1.00);
      expect(out.bands.first.employeeAmount, 2.00);
    });
  });
}
