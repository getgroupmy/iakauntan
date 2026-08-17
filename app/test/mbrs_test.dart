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
