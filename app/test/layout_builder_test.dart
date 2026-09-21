import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/reports/layout_builder.dart';
import 'package:iakauntan/src/features/reports/report_spec.dart';

LayoutRow section(
  String key, {
  String? label,
  List<String> types = const ['revenue'],
  bool showAccounts = true,
}) => LayoutRow(
  rowKey: key,
  kind: 'section',
  label: label ?? key,
  accountTypes: types,
  showAccounts: showAccounts,
);

LayoutRow formula(String key, List<(String, int)> refs, {String? label}) =>
    LayoutRow(
      rowKey: key,
      kind: 'formula',
      label: label ?? key,
      formula: [
        for (final r in refs) {'row': r.$1, 'sign': r.$2},
      ],
    );

/// `0637`. Every rule here is also in the database. This copy exists to
/// tell somebody which row to fix while the builder is still open,
/// rather than after a round trip that comes back naming a constraint.
void main() {
  group('a row key', () {
    test('comes from the label so nobody invents identifiers', () {
      expect(layoutRowKey('Gross profit'), 'gross_profit');
      expect(layoutRowKey('Other income'), 'other_income');
    });

    test('strips what cannot be in a key', () {
      expect(layoutRowKey('Cost of sales (direct)'), 'cost_of_sales_direct');
      expect(layoutRowKey('  Revenue  '), 'revenue');
    });

    test('a label with nothing usable still yields a key', () {
      expect(layoutRowKey('***'), 'row');
      expect(layoutRowKey(''), 'row');
    });

    test('a second row of the same name does not become the first', () {
      // A layout with two "Other income" sections is a real thing, and
      // silently merging them would move money between rows.
      expect(
        layoutRowKey('Other income', taken: ['other_income']),
        'other_income_2',
      );
      expect(
        layoutRowKey('Other income', taken: ['other_income', 'other_income_2']),
        'other_income_3',
      );
    });
  });

  group('what a formula may refer to', () {
    final rows = [
      section('revenue'),
      section('cos'),
      formula('gp', [('revenue', 1), ('cos', -1)]),
      section('expenses'),
    ];

    test('only rows above it', () {
      expect(
        referenceableFrom(rows, 2).map((r) => r.rowKey),
        ['revenue', 'cos'],
      );
    });

    test('the first row may refer to nothing', () {
      expect(referenceableFrom(rows, 0), isEmpty);
    });

    test('a later row may refer to an earlier formula', () {
      expect(
        referenceableFrom(rows, 3).map((r) => r.rowKey),
        ['revenue', 'cos', 'gp'],
      );
    });

    test('a heading is not referenceable, having no amount', () {
      final withHeading = [
        LayoutRow(rowKey: 'h', kind: 'heading', label: 'Trading'),
        section('revenue'),
      ];
      expect(referenceableFrom(withHeading, 2).map((r) => r.rowKey),
          ['revenue']);
    });
  });

  group('what cannot be saved', () {
    test('an empty layout', () {
      expect(layoutProblem([]), contains('at least one row'));
    });

    test('a row with no name', () {
      expect(
        layoutProblem([section('a', label: '  ')]),
        contains('needs a name'),
      );
    });

    test('a section that selects nothing', () {
      expect(
        layoutProblem([section('a', types: [])]),
        contains('does not select any accounts'),
      );
    });

    test('a formula that adds up nothing', () {
      expect(
        layoutProblem([section('revenue'), formula('gp', [])]),
        contains('total of nothing'),
      );
    });

    test('a formula pointing at a row below it', () {
      final rows = [
        formula('gp', [('revenue', 1)]),
        section('revenue'),
      ];
      expect(layoutProblem(rows), contains('not above it'));
    });

    test('a formula pointing at itself', () {
      expect(
        layoutProblem([formula('loop', [('loop', 1)])]),
        contains('not above it'),
      );
    });

    test('a formula pointing at a row that does not exist', () {
      expect(
        layoutProblem([section('revenue'), formula('gp', [('ghost', 1)])]),
        contains('not above it'),
      );
    });

    test('two rows sharing a key', () {
      expect(
        layoutProblem([section('a', label: 'One'), section('a', label: 'Two')]),
        contains('Rename one'),
      );
    });

    test('a layout that is fine', () {
      expect(
        layoutProblem([
          section('revenue'),
          section('cos'),
          formula('gp', [('revenue', 1), ('cos', -1)]),
        ]),
        isNull,
      );
    });
  });

  group('moving a row', () {
    final rows = [
      section('revenue'),
      section('cos'),
      formula('gp', [('revenue', 1), ('cos', -1)]),
    ];

    test('an ordinary move', () {
      final moved = moveRow(rows, 0, 1);
      expect(moved, isNotNull);
      expect(moved!.map((r) => r.rowKey), ['cos', 'revenue', 'gp']);
    });

    test('a formula cannot move above what it adds up', () {
      // Returning null rather than reordering into a state the save
      // would refuse: the builder greys the arrow out instead of
      // letting somebody make a move it then rejects.
      expect(moveRow(rows, 2, 0), isNull);
      expect(moveRow(rows, 2, 1), isNull);
    });

    test('a row cannot move below a formula that needs it', () {
      expect(moveRow(rows, 0, 2), isNull);
    });

    test('moving nowhere is not a move', () {
      expect(moveRow(rows, 1, 1), isNull);
    });

    test('an index off the end is refused rather than thrown', () {
      expect(moveRow(rows, 0, 9), isNull);
      expect(moveRow(rows, -1, 0), isNull);
    });
  });

  group('what a row says about itself', () {
    test('a section names what it selects', () {
      expect(layoutRowSummary(section('a', types: ['revenue'])), 'revenue');
    });

    test('a section showing only its total says so', () {
      expect(
        layoutRowSummary(section('a', showAccounts: false)),
        contains('total only'),
      );
    });

    test('a section by subtype reads without underscores', () {
      final r = LayoutRow(
        rowKey: 'cos',
        kind: 'section',
        label: 'Cost of Sales',
        accountSubtypes: ['cost_of_sales'],
      );
      expect(layoutRowSummary(r), 'cost of sales');
    });

    test('named accounts are counted, and the plural agrees', () {
      final one = LayoutRow(
        rowKey: 'a', kind: 'section', label: 'A', accountIds: ['x'],
      );
      final two = LayoutRow(
        rowKey: 'b', kind: 'section', label: 'B', accountIds: ['x', 'y'],
      );
      expect(layoutRowSummary(one), contains('1 named account'));
      expect(layoutRowSummary(two), contains('2 named accounts'));
    });

    test('a formula reads as arithmetic', () {
      expect(
        layoutRowSummary(formula('gp', [('revenue', 1), ('cos', -1)])),
        'revenue − cos',
      );
    });

    test('a leading minus is kept but a leading plus is not', () {
      // "+ revenue − cos" reads as a typo rather than as arithmetic.
      expect(
        layoutRowSummary(formula('x', [('revenue', 1)])),
        'revenue',
      );
      expect(
        layoutRowSummary(formula('x', [('revenue', -1)])),
        '− revenue',
      );
    });

    test('a heading says what it is', () {
      expect(
        layoutRowSummary(
          LayoutRow(rowKey: 'h', kind: 'heading', label: 'Trading'),
        ),
        'Heading',
      );
    });
  });

  group('the composed report becomes blocks', () {
    List<Map<String, dynamic>> rows() => [
      {
        'row_key': 'revenue', 'kind': 'section', 'label': 'Revenue',
        'depth': 0, 'emphasise': false, 'amount': 1000, 'line_no': 0,
      },
      {
        'row_key': 'revenue', 'kind': 'section', 'label': 'Sales',
        'depth': 1, 'emphasise': false, 'amount': 1000, 'line_no': 1,
        'account_code': '4000', 'account_name': 'Sales',
      },
      {
        'row_key': 'admin', 'kind': 'section', 'label': 'Administrative',
        'depth': 0, 'emphasise': false, 'amount': 400, 'line_no': 0,
      },
      {
        'row_key': 'np', 'kind': 'formula', 'label': 'Net profit',
        'depth': 0, 'emphasise': true, 'amount': 600, 'line_no': 0,
      },
    ];

    test('a section carries its accounts', () {
      final spec = layoutSpec(rows(), title: 'P&L', subtitle: 'March');
      final first = spec.blocks.first as ReportSection;
      expect(first.title, 'Revenue');
      expect(first.lines.length, 1);
      expect(first.lines.first.code, '4000');
    });

    test('a section with no accounts keeps the total it was given', () {
      // The defect this exists to stop: summing the (absent) lines
      // renders a confident zero for an accountant's one-line block.
      final spec = layoutSpec(rows(), title: 'P&L', subtitle: 'March');
      final admin = spec.blocks[1] as ReportSection;
      expect(admin.lines, isEmpty);
      expect(admin.total, 400);
    });

    test('a formula is a highlight and keeps its emphasis', () {
      final spec = layoutSpec(rows(), title: 'P&L', subtitle: 'March');
      final np = spec.blocks.last as ReportHighlight;
      expect(np.label, 'Net profit');
      expect(np.value, 600);
      expect(np.emphasise, isTrue);
    });

    test('an account row does not become a block of its own', () {
      final spec = layoutSpec(rows(), title: 'P&L', subtitle: 'March');
      expect(spec.blocks.length, 3);
    });

    test('nothing here adds anything up', () {
      // The section total is what the database said, NOT the sum of the
      // lines: a second implementation in Dart is a second answer
      // waiting to disagree on a document somebody signs.
      final r = rows();
      r[1]['amount'] = 99;
      final spec = layoutSpec(r, title: 'P&L', subtitle: 'March');
      expect((spec.blocks.first as ReportSection).total, 1000);
    });

    test('a heading renders as a section with nothing under it', () {
      final spec = layoutSpec([
        {
          'row_key': 'h', 'kind': 'heading', 'label': 'Trading',
          'depth': 0, 'emphasise': false, 'amount': null, 'line_no': 0,
        },
      ], title: 'P&L', subtitle: 'March');
      final h = spec.blocks.single as ReportSection;
      expect(h.title, 'Trading');
      expect(h.lines, isEmpty);
    });

    test('the title, subtitle and note are carried', () {
      final spec = layoutSpec(
        rows(),
        title: 'Balance Sheet',
        subtitle: 'As at 31 March',
        note: 'Should be zero.',
      );
      expect(spec.title, 'Balance Sheet');
      expect(spec.subtitle, 'As at 31 March');
      expect(spec.note, 'Should be zero.');
    });
  });

  group('a layout row round-trips to what the database expects', () {
    test('an empty selector is omitted rather than sent as []', () {
      // The shape constraint reads [] as "a section that selects
      // nothing" and refuses it, so a builder that sent one would be
      // refused for a reason nobody typed.
      final j = section('a', types: []).toJson();
      expect(j.containsKey('account_types'), isFalse);
      expect(j.containsKey('account_subtypes'), isFalse);
      expect(j.containsKey('account_ids'), isFalse);
    });

    test('a section sends no formula', () {
      expect(section('a').toJson().containsKey('formula'), isFalse);
    });

    test('a formula sends its references', () {
      final j = formula('gp', [('revenue', 1), ('cos', -1)]).toJson();
      expect(j['formula'], [
        {'row': 'revenue', 'sign': 1},
        {'row': 'cos', 'sign': -1},
      ]);
    });

    test('a rename keeps the key, which is why the key exists', () {
      final r = section('gross_profit', label: 'Gross profit')
          .copyWith(label: 'GP');
      expect(r.rowKey, 'gross_profit');
      expect(r.label, 'GP');
    });

    test('reading a row back', () {
      final r = LayoutRow.fromJson({
        'row_key': 'gp',
        'kind': 'formula',
        'label': 'Gross profit',
        'depth': 1,
        'emphasise': true,
        'show_accounts': false,
        'formula': [
          {'row': 'revenue', 'sign': 1},
        ],
      });
      expect(r.rowKey, 'gp');
      expect(r.emphasise, isTrue);
      expect(r.showAccounts, isFalse);
      expect(r.formula.single['row'], 'revenue');
    });

    test('a missing show_accounts shows them', () {
      // The column is `not null default true`; defaulting the other way
      // would hide every account on every report.
      expect(
        LayoutRow.fromJson({'row_key': 'a', 'kind': 'section'}).showAccounts,
        isTrue,
      );
    });
  });
}
