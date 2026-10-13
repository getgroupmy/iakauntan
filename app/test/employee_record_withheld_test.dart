import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/hr/employee_editor.dart';

/// A manager sees the person, not the record (`0869`).
///
/// `authenticated` reads the columns that say who somebody is; the rest
/// of the row -- pay, identity, bank, family, statutory numbers -- comes
/// back through `employee_private_fields` to HR, payroll and the
/// employee themselves. The editor is that record, so it is shown to the
/// people who may read it and to nobody else, who is told why rather
/// than handed a form of blanks and noughts.
void main() {
  group('the editor', () {
    var asked = 0;
    setUp(() => asked = 0);

    Widget harness(String role) => ProviderScope(
      overrides: [
        repoProvider.overrideWithValue(null),
        memberRoleProvider.overrideWith((ref) async => role),
        employeeProvider.overrideWith((ref, id) async {
          asked++;
          return Employee.fromJson(const {
            'id': 'e2',
            'employee_no': 'E2',
            'full_name': 'Aminah binti Ali',
          });
        }),
        departmentsProvider.overrideWith((ref) async => const []),
        positionsProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const EmployeeEditor(employeeId: 'e2'),
      ),
    );

    testWidgets('a manager outside HR is told the record is HR\'s, and it '
        'is not asked for', (tester) async {
      await tester.pumpWidget(harness('sales'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('ledger-withheld')), findsOneWidget);
      expect(
        find.text(
          "An employee's record is kept by HR and payroll. Your own is "
          'under My HR.',
        ),
        findsOneWidget,
      );
      expect(find.text('Edit employee'), findsNothing);
      expect(asked, 0);
    });

    for (final role in ['hr_manager', 'accountant']) {
      testWidgets('$role opens the record', (tester) async {
        await tester.pumpWidget(harness(role));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('ledger-withheld')), findsNothing);
        expect(find.text('Edit employee'), findsOneWidget);
        expect(asked, 1);
      });
    }
  });

  group('the record, put back', () {
    test('the table is asked for the person, and none of the record', () {
      final columns = RepoHr.employeeColumns.split(', ');
      expect(columns, containsAll(['id', 'employee_no', 'full_name']));
      for (final private in [
        'basic_salary',
        'nric',
        'bank_account_no',
        'date_of_birth',
        'address_line1',
      ]) {
        expect(columns, isNot(contains(private)));
      }
    });

    test('each row takes the fields given for it, and only those', () {
      final merged = RepoHr.withPrivateFields(
        [
          {'id': 'e1', 'full_name': 'Ketua'},
          {'id': 'e2', 'full_name': 'Aminah'},
        ],
        [
          {
            'employee_id': 'e2',
            'fields': {'basic_salary': 3800, 'nric': '900101-14-5678'},
          },
        ],
      );
      expect(merged.first.containsKey('basic_salary'), isFalse);
      expect(merged.last['basic_salary'], 3800);
      expect(merged.last['nric'], '900101-14-5678');
      expect(merged.map((r) => r['full_name']), ['Ketua', 'Aminah']);
    });
  });
}
