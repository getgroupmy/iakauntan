import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/contacts/contact_records.dart';

/// One company, one record per role.
///
/// Al Hardware is a customer coded C-2026-00007. When they start
/// supplying too, they are not retyped: a second record is made in the
/// S- series and the customer record keeps its invoices under its own
/// code. The options are the server's -- `contact_records` reads the
/// same helper `create_contact_as` refuses on -- so what these assert
/// is that the sheet shows that answer faithfully, including the part
/// where a role is already taken.
void main() {
  Map<String, dynamic> record(String id, String code, String type) => {
    'id': id,
    'code': code,
    'contact_type': type,
  };

  Map<String, dynamic> option(
    String as,
    String prefix, {
    Map<String, dynamic>? existing,
  }) => {'as': as, 'prefix': prefix, 'existing': existing};

  Map<String, dynamic> alHardware({
    List<Map<String, dynamic>> records = const [],
    List<Map<String, dynamic>> options = const [],
    String type = 'customer',
    String code = 'C-2026-00007',
  }) => {
    'id': 'c1',
    'code': code,
    'name': 'Al Hardware Sdn Bhd',
    'contact_type': type,
    'records': records,
    'options': options,
  };

  Widget harness(Map<String, dynamic> answer) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      contactRecordsProvider.overrideWith((_, _) async => answer),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              key: const ValueKey('open'),
              onPressed: () => showContactRecords(context, 'c1'),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester, Map<String, dynamic> answer) async {
    await tester.pumpWidget(harness(answer));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
  }

  testWidgets('the record is named by its code and role', (tester) async {
    await open(tester, alHardware());

    expect(find.text('Al Hardware Sdn Bhd'), findsOneWidget);
    expect(find.text('C-2026-00007 · Customer'), findsOneWidget);
  });

  testWidgets('a company with one record is told so', (tester) async {
    await open(
      tester,
      alHardware(options: [option('supplier', 'S-'), option('prospect', 'P-')]),
    );
    expect(find.text('None yet. This is their only record.'), findsOneWidget);
  });

  testWidgets('the other records of the company are listed by code', (
    tester,
  ) async {
    await open(
      tester,
      alHardware(
        records: [
          record('s1', 'S-2026-00001', 'supplier'),
          record('p1', 'P-2026-00343', 'prospect'),
        ],
        options: [
          option(
            'supplier',
            'S-',
            existing: {'id': 's1', 'code': 'S-2026-00001'},
          ),
          option(
            'prospect',
            'P-',
            existing: {'id': 'p1', 'code': 'P-2026-00343'},
          ),
        ],
      ),
    );

    expect(find.byKey(const ValueKey('record-s1')), findsOneWidget);
    expect(find.byKey(const ValueKey('record-p1')), findsOneWidget);
    expect(find.text('S-2026-00001'), findsOneWidget);
    expect(find.text('P-2026-00343'), findsOneWidget);
    expect(find.text('Supplier'), findsOneWidget);
    expect(find.text('Prospect'), findsOneWidget);
    expect(find.text('None yet. This is their only record.'), findsNothing);
  });

  testWidgets('an open role is offered with the series it will be coded in', (
    tester,
  ) async {
    await open(
      tester,
      alHardware(options: [option('supplier', 'S-'), option('prospect', 'P-')]),
    );

    expect(find.text('Create a Supplier record'), findsOneWidget);
    expect(find.textContaining('coded S-YYYY-NNNNN'), findsOneWidget);
    expect(find.text('Create a Prospect record'), findsOneWidget);
    expect(find.textContaining('coded P-YYYY-NNNNN'), findsOneWidget);
    // Not the role this record already is.
    expect(find.text('Create a Customer record'), findsNothing);
  });

  testWidgets('a role already filled shows which record fills it', (
    tester,
  ) async {
    await open(
      tester,
      alHardware(
        records: [record('s1', 'S-2026-00001', 'supplier')],
        options: [
          option(
            'supplier',
            'S-',
            existing: {'id': 's1', 'code': 'S-2026-00001'},
          ),
          option('prospect', 'P-'),
        ],
      ),
    );

    // Shown rather than hidden: somebody who came here to make a
    // supplier record needs to see that there is one, and which.
    expect(find.text('Create a Supplier record'), findsOneWidget);
    expect(find.text('Already S-2026-00001'), findsOneWidget);
    expect(find.textContaining('coded S-YYYY-NNNNN'), findsNothing);
  });

  testWidgets('a filled role cannot be tapped into a second record', (
    tester,
  ) async {
    await open(
      tester,
      alHardware(
        records: [record('s1', 'S-2026-00001', 'supplier')],
        options: [
          option(
            'supplier',
            'S-',
            existing: {'id': 's1', 'code': 'S-2026-00001'},
          ),
          option('prospect', 'P-'),
        ],
      ),
    );

    // With a null repo, a tap that got through would throw. It does not,
    // because the tile is disabled -- which is the assertion.
    await tester.tap(find.byKey(const ValueKey('create-as-supplier')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Already S-2026-00001'), findsOneWidget);
  });

  testWidgets('a customer-and-supplier record is named as both', (
    tester,
  ) async {
    await open(
      tester,
      alHardware(type: 'both', code: 'DH', options: [option('prospect', 'P-')]),
    );

    expect(find.text('DH · Customer & Supplier'), findsOneWidget);
    // Neither role can be split out of it; only a prospect is offered.
    expect(find.text('Create a Customer record'), findsNothing);
    expect(find.text('Create a Supplier record'), findsNothing);
    expect(find.text('Create a Prospect record'), findsOneWidget);
  });
}
