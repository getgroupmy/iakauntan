import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';

import 'package:iakauntan/src/features/hr/hr_setup_screen.dart';

/// Which way a switch on the HR setup screen starts, against the column
/// it writes to.
///
/// This dialog sends EVERY switch it draws. So a switch that starts the
/// wrong way does not fall back to the column's default — it overwrites
/// it, on every row created through the screen.
///
/// Three were wrong, all of them `true` here against a column that is
/// `not null default false`. The worst is `is_additional_remuneration`,
/// and `0446_the_bonus_that_was_taxed_every_month.sql` had already
/// written down what it costs. Its own list of mutants records this one
/// SURVIVING the first run:
///
///   "`is_additional_remuneration` defaulted to true rather than false
///    — SURVIVED. Nothing asserted what an ordinary component does when
///    nobody mentions the flag, which is the migration's most
///    consequential silent claim: every allowance in every company
///    would have stopped being annualised the day this applied."
///
/// The migration then guarded the column and nothing guarded the form.
/// PCB annualises a month's pay to project the year — right for a
/// salary, wrong for a bonus — so an ordinary monthly allowance marked
/// paid-once is left out of the projection and the month's tax comes
/// out short. Under-withholding, which the employee discovers at the
/// end of the year.
///
/// The other two: a new leave type demanding a document before anybody
/// can apply, and a new work shift counting its hours into tomorrow.
///
/// So this reads the MIGRATIONS rather than restating them. A test that
/// said `expect(field.defaultOn, isFalse)` would be the same claim
/// twice and would go stale the day somebody changes the column.
void main() {
  /// Every `.sql` in the migrations, concatenated in order.
  late final String ddl = (Directory('../supabase/migrations')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.sql'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      .map((f) => f.readAsStringSync())
      .join('\n');

  /// What `table.column` defaults to in the schema, or null if this
  /// cannot find it.
  ///
  /// The LAST match wins: a column added by `alter table` in a later
  /// migration, or one whose default was changed, is the one in force.
  bool? columnDefault(String table, String column) {
    bool? answer;
    // `create table ... ( ... );` for this table.
    for (final m in RegExp(
      'create table[^;]*?\\b$table\\b\\s*\\((.*?)\\n\\);',
      dotAll: true,
      caseSensitive: false,
    ).allMatches(ddl)) {
      final f = RegExp(
        '\\b$column\\s+boolean[^,\\n]*?default\\s+(true|false)',
        caseSensitive: false,
      ).firstMatch(m.group(1)!);
      if (f != null) answer = f.group(1)!.toLowerCase() == 'true';
    }
    // `alter table ... add column ... default ...`
    for (final m in RegExp(
      'alter table[^;]*?\\b$table\\b(.*?);',
      dotAll: true,
      caseSensitive: false,
    ).allMatches(ddl)) {
      final f = RegExp(
        '\\b$column\\s+boolean[^;]*?default\\s+(true|false)',
        caseSensitive: false,
      ).firstMatch(m.group(1)!);
      if (f != null) answer = f.group(1)!.toLowerCase() == 'true';
    }
    return answer;
  }

  test('the migrations are readable from here', () {
    // The control for every assertion below. Without it a broken path
    // or a regex that matches nothing reports a clean sweep, which is
    // the failure this whole file exists to prevent.
    expect(ddl.length, greaterThan(100000));
    expect(columnDefault('salary_components', 'is_taxable'), isTrue);
    expect(
      columnDefault('salary_components', 'is_additional_remuneration'),
      isFalse,
    );
    expect(columnDefault('salary_components', 'no_such_column'), isNull);
  });

  test('every switch starts the way its column does', () {
    final wrong = <String>[];
    var checked = 0;

    hrSetupTables.forEach((table, fields) {
      for (final f in fields.where((f) => f.boolean)) {
        final want = columnDefault(table, f.key);
        expect(
          want,
          isNotNull,
          reason: 'no default found for $table.${f.key} — the schema '
              'moved, or this test can no longer read it',
        );
        checked++;
        if (f.defaultOn != want) {
          wrong.add('$table.${f.key}: the switch starts '
              '${f.defaultOn ? "on" : "off"} and the column defaults '
              '${want! ? "true" : "false"}');
        }
      }
    });

    expect(checked, greaterThan(10), reason: 'the tables were found');
    expect(wrong, isEmpty);
  });

  group('and the dialog actually uses them', () {
    // The two mutants the assertions above cannot kill. `defaultOn` can
    // be declared correctly on every field and the dialog can still
    // seed its switches with a bare `true` — which is the defect as it
    // shipped, with the declarations all correct and unread.

    Widget wrap() => ProviderScope(
      overrides: [
        setupRowsProvider((table: 'salary_components', orderBy: 'name'))
            .overrideWith((ref) async => const <Map<String, dynamic>>[]),
        repoProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: ComponentsTab()),
      ),
    );

    testWidgets('a new pay component starts with paid-once OFF and the '
        'statutory switches ON', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // The list loaded, rather than erroring behind the button. The
      // Add button sits on the Scaffold OUTSIDE the AsyncView, so this
      // test passed with a mis-keyed provider override and an error
      // panel behind the dialog — which is a test passing for the wrong
      // reason, even though what it asserts is real.
      expect(find.textContaining('Could not'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(find.widgetWithText(FloatingActionButton, 'Add'));
      await tester.pumpAndSettle();

      bool switchFor(String label) {
        final tile = find.ancestor(
          of: find.text(label),
          matching: find.byType(SwitchListTile),
        );
        expect(tile, findsOneWidget, reason: '$label is on the dialog');
        return tester.widget<SwitchListTile>(tile).value;
      }

      // The one that costs money. PCB annualises a month's pay to
      // project the year; a component marked paid-once is left out of
      // that projection, so an ordinary allowance starting ON here
      // under-withholds every month.
      expect(switchFor('Paid once, not monthly'), isFalse);

      // And the ones that must stay on, so a fix that turned every
      // switch off would fail here rather than quietly letting a new
      // allowance escape EPF.
      expect(switchFor('Charged to EPF'), isTrue);
      expect(switchFor('Charged to SOCSO'), isTrue);
      expect(switchFor('Taxable'), isTrue);
      expect(switchFor('Active'), isTrue);
    });

    testWidgets('and an existing row keeps what it was saved with',
        (tester) async {
      // The other survivor: seeding every switch from the default would
      // pass the test above and silently rewrite a bonus that somebody
      // had already marked paid-once.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            setupRowsProvider((table: 'salary_components', orderBy: 'name'))
                .overrideWith((ref) async => [
                      {
                        'id': 'c1',
                        'code': 'BONUS',
                        'name': 'Annual bonus',
                        'is_additional_remuneration': true,
                        'is_epf_liable': false,
                      },
                    ]),
            repoProvider.overrideWithValue(null),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: ComponentsTab()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Annual bonus'));
      await tester.pumpAndSettle();

      SwitchListTile tileFor(String label) => tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(SwitchListTile),
        ),
      );

      expect(tileFor('Paid once, not monthly').value, isTrue);
      expect(tileFor('Charged to EPF').value, isFalse);
    });
  });

  test('and the three that were wrong are named, so this does not read '
      'as arbitrary', () {
    // Each of these was `true` on the screen against a `false` column.
    bool startsOn(String table, String column) => hrSetupTables[table]!
        .firstWhere((f) => f.key == column)
        .defaultOn;

    expect(startsOn('salary_components', 'is_additional_remuneration'),
        isFalse);
    expect(startsOn('leave_types', 'requires_attachment'), isFalse);
    expect(startsOn('work_shifts', 'crosses_midnight'), isFalse);

    // And the ones that were right stay right — a fix that turned every
    // switch off would pass the three above and would be a different
    // bug, with a new allowance escaping EPF instead.
    expect(startsOn('salary_components', 'is_epf_liable'), isTrue);
    expect(startsOn('salary_components', 'is_socso_liable'), isTrue);
    expect(startsOn('salary_components', 'is_taxable'), isTrue);
    expect(startsOn('salary_components', 'is_active'), isTrue);
  });
}
