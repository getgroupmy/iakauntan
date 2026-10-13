import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/documents/salespeople_screen.dart';

/// Who sold what, and the commission that is only a working paper.
///
/// Three things live only in this widget.
///
/// SALES ATTRIBUTED TO NOBODY. The report is only worth reading if you
/// know how much of it is missing a name. A manager comparing two
/// people cannot tell a quiet quarter from a quarter where half the
/// invoices went out with the salesperson field blank, and the figure
/// that tells them is computed here and nowhere else.
///
/// COMMISSION IS NOT AN ACCRUAL. The screen says so in its own words:
/// no journal is raised, nothing reaches payroll, and when commission
/// falls due -- on invoice, on payment, on margin -- is a policy this
/// does not decide. Remove that sentence and the column reads as a
/// liability somebody can rely on.
///
/// AND A RATE THAT IS NOT SET IS NOT A RATE OF ZERO. "RM 0.00" against
/// a salesperson reads as "earned nothing"; an em dash reads as "no
/// rate on file", which is a different conversation.
void main() {
  Map<String, dynamic> line({
    String? salespersonId = 'sp1',
    String name = 'Aisyah Binti Omar',
    num invoiced = 120000,
    num credited = 5000,
    num netSales = 115000,
    int documents = 24,
    num? commissionRate = 2.5,
    num? commission = 2875,
    bool isActive = true,
  }) => {
    'salesperson_id': salespersonId,
    'name': name,
    'invoiced': invoiced,
    'credited': credited,
    'net_sales': netSales,
    'documents': documents,
    'commission_rate': commissionRate,
    'commission': commission,
    'is_active': isActive,
  };

  late _FakeRepo repo;
  // How many times the list with rates was fetched: once on opening, and
  // again after anything that changes it.
  var withRatesAsked = 0;
  setUp(() => withRatesAsked = 0);

  Widget wrap(
    List<Map<String, dynamic>> report, {
    String base = 'MYR',
    String role = 'owner',
    List<Map<String, dynamic>> people = const [],
  }) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(repo = _FakeRepo(report)),
      // What each provider would be given: the table's columns, which
      // carry no rate since `0866`, and those merged with the rates.
      salespeopleProvider.overrideWith(
        (ref) async => [
          for (final p in people) {...p}..remove('commission_rate'),
        ],
      ),
      salespeopleWithRatesProvider.overrideWith((ref) async {
        withRatesAsked++;
        return people;
      }),
      currentOrgProvider.overrideWith(
        (ref) async => Organization(
          id: 'o1',
          name: 'Rantaian Maju Sdn Bhd',
          slug: 'rantaian',
          baseCurrency: base,
        ),
      ),
      memberRoleProvider.overrideWith((ref) async => role),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: SalespeopleScreen()),
    ),
  );

  Future<void> show(
    WidgetTester tester,
    List<Map<String, dynamic>> report, {
    String base = 'MYR',
    String role = 'owner',
    List<Map<String, dynamic>> people = const [],
  }) async {
    await tester.pumpWidget(
      wrap(report, base: base, role: role, people: people),
    );
    await tester.pumpAndSettle();
  }

  final siti = {
    'id': 'sp2',
    'code': 'SITI',
    'name': 'Siti Binti Hassan',
    'commission_rate': 4,
    'is_active': true,
  };

  group('sales attributed to nobody', () {
    testWidgets('are counted against the whole, in money', (tester) async {
      // 40,000 of 140,000 went out with the field blank. A manager
      // comparing two people cannot otherwise tell a quiet quarter from
      // a quarter that was not attributed.
      await show(tester, [
        line(salespersonId: 'sp1', name: 'Aisyah', netSales: 100000),
        line(salespersonId: null, name: 'Unattributed', netSales: 40000),
      ]);

      expect(
        find.textContaining(
            'RM 40,000.00 of RM 140,000.00 was not attributed to anybody'),
        findsOneWidget,
      );
    });

    testWidgets('and a fully attributed report says what it covers instead',
        (tester) async {
      // The control, and it is not silence: the subtitle still has to
      // say that this is posted documents only, net of credit notes,
      // or the figures are not comparable with anything.
      await show(tester, [
        line(salespersonId: 'sp1', netSales: 100000),
      ]);

      expect(find.textContaining('was not attributed'), findsNothing);
      expect(
        find.textContaining('Invoices less credit notes, posted documents '
            'only'),
        findsOneWidget,
      );
    });

    testWidgets('an unattributed row is set in italic', (tester) async {
      // "Unattributed" is not a person, and a manager scanning the
      // column should not read it as one.
      await show(tester, [
        line(salespersonId: 'sp1', name: 'Aisyah', netSales: 100000),
        line(salespersonId: null, name: 'Unattributed', netSales: 40000),
      ]);

      expect(tester.widget<Text>(find.text('Unattributed')).style?.fontStyle,
          FontStyle.italic);
      expect(tester.widget<Text>(find.text('Aisyah')).style?.fontStyle,
          FontStyle.normal);
    });

    testWidgets('and somebody who has left is greyed rather than dropped',
        (tester) async {
      // Their sales are still in the period being reported on. Removing
      // the row would change the total; greying it says why the name is
      // there.
      await show(tester, [
        line(name: 'Lim Wei Jian', isActive: false, netSales: 30000),
      ]);

      expect(tester.widget<Text>(find.text('Lim Wei Jian')).style?.color,
          isNotNull);
      expect(find.text('RM 30,000.00'), findsOneWidget);
    });
  });

  group('commission is a working paper', () {
    testWidgets('and the screen says so, in full', (tester) async {
      await show(tester, [line()]);

      // All three claims. Any one of them alone leaves the column
      // readable as a liability.
      expect(find.textContaining('is not posted anywhere'), findsOneWidget);
      expect(find.textContaining('No journal is raised'), findsOneWidget);
      expect(find.textContaining('nothing reaches payroll'), findsOneWidget);
      expect(
        find.textContaining('when it falls due is a policy this does not '
            'decide'),
        findsOneWidget,
      );
    });

    testWidgets('a rate on file is shown as a percentage', (tester) async {
      await show(tester, [line(commissionRate: 2.5, commission: 2875)]);

      // `Fmt.rate` is `#,##0.00####`: two places always, four more if
      // the rate needs them. 2.5 reads "2.50%".
      expect(find.text('2.50%'), findsOneWidget);
      expect(find.text('RM 2,875.00'), findsOneWidget);
    });

    testWidgets('and no rate on file is a dash, not nought', (tester) async {
      // "RM 0.00" reads as "earned nothing". An em dash reads as "no
      // rate set", which is a different conversation with a different
      // person.
      await show(tester, [
        line(commissionRate: null, commission: null, netSales: 115000),
      ]);

      expect(find.text('—'), findsNWidgets(2));
      expect(find.text('RM 0.00'), findsNothing);
      expect(find.text('0.00%'), findsNothing);
    });
  });

  group('what each column carries', () {
    testWidgets('invoiced, credited, net and the document count',
        (tester) async {
      await show(tester, [
        line(invoiced: 120000, credited: 5000, netSales: 115000,
            documents: 24),
      ]);

      expect(find.text('RM 120,000.00'), findsOneWidget);
      expect(find.text('RM 5,000.00'), findsOneWidget);
      expect(find.text('RM 115,000.00'), findsOneWidget);
      expect(find.text('24'), findsOneWidget);
    });

    testWidgets('and every figure follows the company base currency',
        (tester) async {
      // A company keeping books in Singapore dollars.
      await show(tester, [
        line(invoiced: 1000, credited: 0, netSales: 1000,
            commissionRate: 5, commission: 50),
      ], base: 'SGD');

      expect(find.text('SGD 1,000.00'), findsNWidgets(2));
      expect(find.text('SGD 50.00'), findsOneWidget);
      expect(find.textContaining('RM '), findsNothing);
    });
  });

  // `0866`: the figures and the rates are the ledger's, and a rate is
  // set by whoever would pay it.
  group('the ledger\'s', () {
    testWidgets('a salesman is shown who sells, and neither the figures nor '
        'a rate, and the report is not asked for', (tester) async {
      await show(tester, [line()], role: 'sales', people: [siti]);

      expect(find.text('Siti Binti Hassan'), findsOneWidget);
      expect(find.text('Net sales'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      expect(repo.reportAsked, 0);
    });

    testWidgets('a reader is shown the report and each rate on file', (
      tester,
    ) async {
      await show(tester, const [], role: 'accounts_clerk', people: [siti]);

      expect(find.text('Net sales'), findsOneWidget);
      expect(find.text('SITI  ·  4.00%'), findsOneWidget);
      expect(repo.reportAsked, 1);
    });

    testWidgets('a reader who may not post edits a salesperson without the '
        'rate, and sends none', (tester) async {
      await show(tester, const [], role: 'accounts_clerk', people: [siti]);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Commission rate'), findsNothing);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.saved, isNotNull);
      expect(repo.saved!['name'], 'Siti Binti Hassan');
      expect(repo.saved!.containsKey('commission_rate'), isFalse);
    });

    testWidgets('and whoever may post sets it', (tester) async {
      await show(tester, const [], role: 'accountant', people: [siti]);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Commission rate'),
        '3.5',
      );
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.saved!['commission_rate'], 3.5);
      expect(withRatesAsked, 2, reason: 'the list is fetched again');
    });

    testWidgets('and a removal fetches the list with its rates again', (
      tester,
    ) async {
      await show(tester, const [], role: 'accountant', people: [siti]);
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(repo.removed, 'sp2');
      expect(withRatesAsked, 2);
    });
  });

  group('the rates, put back', () {
    test('the table is asked for every column the grant leaves, and not '
        'the rate', () {
      final columns = Repo.salespersonColumns.split(', ');
      expect(columns, isNot(contains('commission_rate')));
      expect(columns, containsAll(['id', 'code', 'name', 'is_active']));
    });

    test('each person takes the rate named for them, and none where none '
        'is named', () {
      final merged = Repo.withCommissionRates(
        [
          {'id': 'sp1', 'name': 'Ali'},
          {'id': 'sp2', 'name': 'Siti'},
        ],
        [
          {'salesperson_id': 'sp2', 'commission_rate': 4},
        ],
      );
      expect(merged.map((p) => p['commission_rate']), [null, 4]);
      expect(merged.map((p) => p['name']), ['Ali', 'Siti']);
    });
  });
}

/// Only the calls the screen makes.
class _FakeRepo implements Repo {
  _FakeRepo(this.report);

  final List<Map<String, dynamic>> report;
  int reportAsked = 0;
  Map<String, dynamic>? saved;

  @override
  Future<List<Map<String, dynamic>>> salesByPerson({
    required DateTime from,
    required DateTime to,
  }) async {
    reportAsked++;
    return report;
  }

  @override
  Future<void> saveSalesperson(Map<String, dynamic> row) async => saved = row;

  String? removed;

  @override
  Future<void> deleteSalesperson(String id) async => removed = id;

  @override
  Future<List<Map<String, dynamic>>> salespeople({
    bool activeOnly = false,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'the salespeople screen called Repo.${invocation.memberName}, which '
        'this fake does not answer',
      );
}
