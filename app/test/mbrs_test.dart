import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/features/financials/mtool_csv.dart';

/// Financial statements, on the screen side.
///
/// The arithmetic — that the statements balance, that the freeze holds,
/// that six months from 31 August is 28 February, that Practice
/// Directive 3/2018 looks at three years — is asserted in
/// `supabase/tests/mbrs.sql`, against a real ledger.
///
/// What is asserted here is the export and the two judgements the screen
/// makes on its own. The export matters most: it is the only artefact
/// that leaves the system, a preparer will paste it into mTool without
/// re-reading it, and a comma in a company's account name that split a
/// row would move money between lines in a statutory filing.
void main() {
  // What is NOT in the export, which the screen used to say nothing
  // about.
  //
  // `mbrs_elements` seeds `sofp` (16 elements) and `soploci` (9) and
  // nothing else, so on today's taxonomy `socie`, `socf` and
  // `disclosure` have no elements at all. `fs_prepare` iterates the
  // table, `fs_freeze` stores what it returns, and the screen draws a
  // section per statement PRESENT — so a preparer read two sections,
  // exported them, and was three statements short at the counter with
  // nothing having said so.
  group('the statements a lodgement is missing', () {
    test('three of five, on the taxonomy as seeded', () {
      expect(
        missingStatements(['sofp', 'soploci']),
        ['Changes in equity', 'Cash flows', 'Disclosures'],
      );
    });

    test('and they are named in the order a lodgement presents them', () {
      // Not alphabetical and not the order the export happened to
      // return. A preparer reads this against a template.
      expect(
        missingStatements([]),
        [
          'Statement of financial position',
          'Profit or loss and other comprehensive income',
          'Changes in equity',
          'Cash flows',
          'Disclosures',
        ],
      );
    });

    test('nothing is missing when all five are there', () {
      expect(
        missingStatements(fsStatements.keys),
        isEmpty,
      );
      expect(missingStatementsNote(fsStatements.keys), isNull);
    });

    test('the note names them rather than counting them', () {
      // "Three statements are missing" is something somebody then has
      // to work out, and the point of saying it is that they should
      // not have to.
      final said = missingStatementsNote(['sofp', 'soploci'])!;

      expect(said, contains('Changes in equity'));
      expect(said, contains('Cash flows'));
      expect(said, contains('Disclosures'));
      expect(said, isNot(contains('3 ')));
    });

    test('and reads as a sentence with one missing', () {
      // `a, b and c` for three; no stray "and" for one.
      final said = missingStatementsNote([
        'sofp',
        'soploci',
        'socie',
        'socf',
      ])!;

      expect(said, contains('Not in this export: Disclosures.'));
      expect(said, isNot(contains(' and Disclosures')));
    });

    test('it says a lodgement needs all five', () {
      // The fact a preparer is missing. Without it the sentence reads
      // as a note about this company rather than about the file.
      expect(missingStatementsNote(['sofp'])!, contains('all five'));
    });

    test('and does not claim which of the two reasons applies', () {
      // A statement is absent either because no taxonomy element for
      // it is loaded or because this company has no figures for it,
      // and the export cannot tell those apart. Claiming one would be
      // wrong half the time.
      final said = missingStatementsNote(['sofp'])!;

      expect(said, isNot(contains('no figures')));
      expect(said, isNot(contains('nothing posted')));
      // It names both ways out instead.
      expect(said, contains('mbrs_elements'));
      expect(said, contains('mTool'));
    });

    test('an unknown statement code does not hide a real one', () {
      // `fs_export` returns whatever `mbrs_elements.statement` holds,
      // and the enum could gain a member before this map does. An
      // unrecognised code must not make a missing statement look
      // present.
      expect(
        missingStatements(['sofp', 'soploci', 'something_new']),
        ['Changes in equity', 'Cash flows', 'Disclosures'],
      );
    });
  });

  group('the mTool export', () {
    test('one row per element, in the order the database gave', () {
      final csv = mtoolCsv(const [
        {
          'statement': 'sofp',
          'section': 'current_assets',
          'element_code': 'CashAndCashEquivalents',
          'label': 'Cash and cash equivalents',
          'current_amount': 170000,
          'prior_amount': 0,
        },
        {
          'statement': 'soploci',
          'section': 'trading',
          'element_code': 'Revenue',
          'label': 'Revenue',
          'current_amount': 250000,
          'prior_amount': 100000,
        },
      ]);

      final lines = csv.trim().split('\n');
      expect(
        lines.first,
        'Statement,Section,Element,Label,CurrentYear,PriorYear',
      );
      expect(lines.length, 3);
      // Taxonomy order, not alphabetical: the balance sheet line came
      // back first and stays first.
      expect(lines[1], startsWith('sofp,current_assets,'));
      expect(lines[2], startsWith('soploci,trading,Revenue,'));
    });

    test('amounts always carry two decimals', () {
      // A statutory filing of "170000" and one of "170000.00" are the
      // same number, but mTool is an Excel template and a bare integer
      // is the kind of thing that arrives as text in a numeric cell.
      final csv = mtoolCsv(const [
        {
          'statement': 'sofp',
          'element_code': 'ShareCapital',
          'label': 'Share capital',
          'current_amount': 170000,
          'prior_amount': 0.5,
        },
      ]);
      expect(csv, contains(',170000.00,0.50'));
    });

    test('a comma in a label does not split the row', () {
      // "Property, plant and equipment" is the very first line of every
      // Malaysian balance sheet, and it has a comma in it.
      final csv = mtoolCsv(const [
        {
          'statement': 'sofp',
          'section': 'non_current_assets',
          'element_code': 'PropertyPlantAndEquipment',
          'label': 'Property, plant and equipment',
          'current_amount': 1,
          'prior_amount': 2,
        },
      ]);
      final row = csv.trim().split('\n').last;
      expect(row, contains('"Property, plant and equipment"'));
      // Six fields, not seven — the quoting is what keeps it six.
      expect(row.split('","').length, lessThan(3));
      expect(row.endsWith(',1.00,2.00'), isTrue);
    });

    test('a quote in a label is doubled, not dropped', () {
      final csv = mtoolCsv(const [
        {
          'statement': 'disclosure',
          'element_code': 'X',
          'label': 'Directors\' "emoluments"',
          'current_amount': 0,
          'prior_amount': 0,
        },
      ]);
      expect(csv, contains('""emoluments""'));
    });

    test('a missing amount exports as nil rather than as nothing', () {
      // An empty cell in mTool is not zero; it is a fact the preparer
      // has to go and find.
      final csv = mtoolCsv(const [
        {'statement': 'sofp', 'element_code': 'X', 'label': 'X'},
      ]);
      expect(csv.trim().split('\n').last, endsWith(',0.00,0.00'));
    });
  });

  group('the filename', () {
    test('a draft export says so', () {
      // Draft figures follow the ledger, so two exports an hour apart
      // can differ. The filename is the only thing distinguishing them
      // once the file is on somebody's desktop.
      expect(
        mtoolFilename(const [
          {'is_frozen': false},
        ]),
        'mbrs-figures-DRAFT.csv',
      );
      expect(mtoolFilename(const []), 'mbrs-figures-DRAFT.csv');
    });

    test('and a frozen one does not', () {
      expect(
        mtoolFilename(const [
          {'is_frozen': true},
        ]),
        'mbrs-figures.csv',
      );
    });
  });

  group('audit exemption, as the screen reads it', () {
    /// The card's judgement: the dangerous state is claiming exemption
    /// with no ground for it, which is filing unaudited accounts that
    /// needed an audit.
    String verdict(String auditStatus, List<Map<String, dynamic>> grounds) {
      final any = grounds.any((g) => g['qualifies'] == true);
      if (auditStatus == 'audit_exempt' && !any) return 'unsupported';
      return any ? 'available' : 'audit required';
    }

    test('claiming exemption with no ground is the state to shout about', () {
      expect(
        verdict('audit_exempt', const [
          {'ground': 'dormant', 'qualifies': false},
          {'ground': 'zero_revenue', 'qualifies': false},
          {'ground': 'threshold_qualified', 'qualifies': false},
        ]),
        'unsupported',
      );
    });

    test('one ground is enough', () {
      expect(
        verdict('audit_exempt', const [
          {'ground': 'dormant', 'qualifies': true},
          {'ground': 'zero_revenue', 'qualifies': false},
          {'ground': 'threshold_qualified', 'qualifies': false},
        ]),
        'available',
      );
    });

    test('an audited company that could have been exempt is not an error', () {
      // Being entitled to exemption and choosing an audit anyway is a
      // perfectly ordinary decision — a bank asked for one, usually.
      expect(
        verdict('audited', const [
          {'ground': 'dormant', 'qualifies': true},
        ]),
        'available',
      );
    });
  });

  group('the filings list', () {
    test('is newest year first', () async {
      final c = ProviderContainer(
        overrides: [
          repoProvider.overrideWithValue(null),
          fsFilingsProvider.overrideWith(
            (ref) async => const [
              {'id': '1', 'fy_end': '2025-12-31', 'status': 'lodged'},
              {'id': '2', 'fy_end': '2024-12-31', 'status': 'lodged'},
            ],
          ),
        ],
      );
      addTearDown(c.dispose);

      final rows = await c.read(fsFilingsProvider.future);
      expect(rows.first['fy_end'], '2025-12-31');
    });
  });
}
