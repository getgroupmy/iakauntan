import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthState;

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

/// Adding a company is a door, and Multi-Company is the key.
///
/// The company switcher used to open only for somebody who already had
/// two companies, which made the only way to a second company one that
/// needed a second company to reach. 0486 opens it for anybody the
/// server says may add one, and leaves it shut for anybody it does not
/// — absent rather than present and refusing, because the refusal is
/// the server's and the button would only be repeating it late.
void main() {
  Organization org(String id, String name) =>
      Organization(id: id, name: name, slug: id, baseCurrency: 'MYR');

  Widget shell({required List<Organization> orgs, required bool canAdd}) =>
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWithValue(null),
          authStateProvider.overrideWith(
            (_) => const Stream<AuthState>.empty(),
          ),
          isPlatformAdminProvider.overrideWith((_) async => false),
          organizationsProvider.overrideWith((_) async => orgs),
          currentOrgProvider.overrideWith((_) async => orgs.first),
          enabledModulesProvider.overrideWith((_) async => <String>{}),
          canAddCompanyProvider.overrideWith((_) async => canAdd),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const AppShell(
            location: '/',
            child: Scaffold(body: Text('body')),
          ),
        ),
      );

  Future<void> pump(WidgetTester t, Widget w) async {
    t.view.physicalSize = const Size(1400, 1600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(w);
    await t.pumpAndSettle();
  }

  testWidgets('one company and the module: the door is there', (t) async {
    await pump(t, shell(orgs: [org('o1', 'Kedai Satu')], canAdd: true));
    await t.tap(find.text('Kedai Satu'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-company')), findsOne);
  });

  testWidgets('one company and no module: nothing opens at all', (t) async {
    await pump(t, shell(orgs: [org('o1', 'Kedai Satu')], canAdd: false));
    await t.tap(find.text('Kedai Satu'));
    await t.pumpAndSettle();
    // No sheet, so no list of companies and no door.
    expect(find.text('Switch organization'), findsNothing);
    expect(find.byKey(const ValueKey('add-company')), findsNothing);
  });

  testWidgets('two companies and no module: switch, but no door', (t) async {
    await pump(
      t,
      shell(
        orgs: [org('o1', 'Kedai Satu'), org('o2', 'Kedai Dua')],
        canAdd: false,
      ),
    );
    await t.tap(find.text('Kedai Satu'));
    await t.pumpAndSettle();
    expect(find.text('Switch organization'), findsOne);
    expect(find.text('Kedai Dua'), findsOne);
    expect(find.byKey(const ValueKey('add-company')), findsNothing);
  });
}
