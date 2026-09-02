import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/contacts/convert_contact.dart';

/// Saying what a contact is now.
///
/// A supplier who starts selling to you, a prospect who places an
/// order. The options are the server's — `contact_conversions` reads
/// the same helper the trigger enforces on — so what these assert is
/// that the sheet shows that answer faithfully, including the part
/// where the answer is no.
void main() {
  Map<String, dynamic> option(
    String to, {
    bool allowed = true,
    List<String> blockedBy = const [],
  }) => {'to': to, 'allowed': allowed, 'blocked_by': blockedBy};

  Widget harness(Map<String, dynamic> answer) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      contactConversionsProvider.overrideWith((_, _) async => answer),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              key: const ValueKey('open'),
              onPressed: () => showConvertContact(context, 'c1'),
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

  testWidgets('a prospect is offered every road out', (tester) async {
    await open(tester, {
      'contact_type': 'prospect',
      'name': 'Bakal Pelanggan',
      'roles_in_use': <String>[],
      'options': [option('customer'), option('supplier'), option('both')],
    });

    expect(find.text('Bakal Pelanggan'), findsOneWidget);
    expect(find.text('Currently Prospect'), findsOneWidget);
    expect(find.text('Make them a Customer'), findsOneWidget);
    expect(find.text('Make them a Supplier'), findsOneWidget);
    // The one people do not think of, and usually the right answer.
    expect(find.text('Make them a Both'), findsOneWidget);
  });

  testWidgets('and is not offered the thing it already is', (tester) async {
    await open(tester, {
      'contact_type': 'prospect',
      'name': 'Bakal Pelanggan',
      'roles_in_use': <String>[],
      'options': [option('customer'), option('supplier'), option('both')],
    });
    expect(find.text('Make them a Prospect'), findsNothing);
  });

  testWidgets('a supplier with bills is shown why, not just refused', (
    tester,
  ) async {
    // Shown rather than hidden: somebody who came here to make this
    // change needs to know it was considered, or they will go and try
    // it in the editor instead.
    await open(tester, {
      'contact_type': 'supplier',
      'name': 'Pembekal Lama',
      'roles_in_use': ['supplier'],
      'options': [
        option('customer', allowed: false, blockedBy: ['supplier']),
        option('both'),
        option('prospect', allowed: false, blockedBy: ['supplier']),
      ],
    });

    expect(find.text('Make them a Customer'), findsOneWidget);
    expect(
      find.textContaining('You have bought from them'),
      findsWidgets,
    );
    // And it points at the answer that works.
    expect(find.textContaining('Use Both to add a role'), findsWidgets);
  });

  testWidgets('a blocked option cannot be tapped', (tester) async {
    await open(tester, {
      'contact_type': 'supplier',
      'name': 'Pembekal Lama',
      'roles_in_use': ['supplier'],
      'options': [
        option('customer', allowed: false, blockedBy: ['supplier']),
        option('both'),
      ],
    });

    // With a null repo, a tap that got through would throw. It does not,
    // because the tile is disabled — which is the assertion.
    await tester.tap(find.byKey(const ValueKey('convert-to-customer')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Make them a Both'), findsOneWidget);
  });

  testWidgets('a customer with invoices is blocked the other way round', (
    tester,
  ) async {
    await open(tester, {
      'contact_type': 'customer',
      'name': 'Pelanggan Lama',
      'roles_in_use': ['customer'],
      'options': [
        option('supplier', allowed: false, blockedBy: ['customer']),
        option('both'),
      ],
    });
    expect(find.textContaining('You have sold to them'), findsWidgets);
  });

  testWidgets('both roles in use reads as a sentence, not a list', (
    tester,
  ) async {
    await open(tester, {
      'contact_type': 'both',
      'name': 'Kedua-duanya',
      'roles_in_use': ['customer', 'supplier'],
      'options': [
        option(
          'prospect',
          allowed: false,
          blockedBy: ['customer', 'supplier'],
        ),
      ],
    });
    expect(
      find.textContaining('You have sold to them and bought from them'),
      findsOneWidget,
    );
  });
}
