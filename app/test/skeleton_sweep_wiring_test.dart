import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/entity_types_repository.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/contacts/contact_editor.dart';
import 'package:iakauntan/src/features/reports/layout_builder_screen.dart';
import 'package:iakauntan/src/features/stock/lots_screen.dart';

/// The screens that were still spinning, and one that should be.
///
/// `skeletons_test.dart` asserts the shapes; `card_row_skeleton_wiring_
/// test.dart` asserts three screens that call `.when()` themselves.
/// Neither says anything about a `FutureBuilder` or a plain `_loading`
/// ternary, and those are what the rest of the spinners were hiding in
/// -- outside the reach of `scripts/check_loading_spinners.py`, which
/// reads `loading:` arms and nothing else.
///
/// Asserted here at three of them, chosen because they are reachable
/// from a test: the other seven sit behind private dialog classes with
/// no exported entry point, and reaching those would mean making them
/// public for the test's benefit, which is a worse trade than the
/// assertion is worth.
///
/// ## Why nothing here calls `pumpAndSettle`
///
/// A skeleton shimmers, so the frames never stop being scheduled and
/// `pumpAndSettle` runs to its timeout. Two `pump`s draw one frame of
/// an outline that is still going.
void main() {
  Widget wrap(Widget child, Repo repo) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(repo),
      currentOrgProvider.overrideWith(
        (ref) async => Organization(id: 'o1', name: 'Kedai Kita', slug: 'kedai'),
      ),
      memberRoleProvider.overrideWith((ref) async => 'owner'),
      allEntityTypesProvider.overrideWith(
        (ref) async =>
            const [EntityType(code: 'sdn_bhd', label: 'Sdn Bhd', sortOrder: 10)],
      ),
      orgLogoProvider.overrideWith((ref) async => null),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: child),
  );

  Future<void> show(WidgetTester t, Widget child, Repo repo) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1400, 2000);
    addTearDown(t.view.reset);
    await t.pumpWidget(wrap(child, repo));
    await t.pump();
  }

  testWidgets('a list of batches on its way is outlined, not spun', (t) async {
    await show(t, const LotsScreen(), _Never());

    expect(find.byType(ListTile), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a report layout on its way is outlined, not spun', (t) async {
    await show(
      t,
      const LayoutBuilderScreen(kind: 'profit_loss'),
      _Never(),
    );

    expect(find.byKey(const ValueKey('skeleton-card-row-0')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('an existing contact is outlined while it is read', (t) async {
    await show(t, const ContactEditor(contactId: 'c1'), _Never());

    expect(find.byKey(const ValueKey('skeleton-form-field-0')), findsOneWidget);
    // And boxes, plural. An outline with no boxes in it satisfies
    // "no fields and no spinner" exactly as well as the right one
    // does, and looks like a blank page.
    expect(find.byKey(const ValueKey('skeleton-form-field-5')), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a NEW contact keeps its circle', (t) async {
    // Deliberately the opposite assertion, and the reason is in
    // `skeletons.dart`: an outline is honest where the LAYOUT is
    // already decided and only the values are missing. A new contact's
    // layout is not decided -- the form opens at the entity-type
    // question and draws the rest only once it is answered -- so six
    // outlined boxes would be a claim about a shape the screen is
    // about to choose not to draw.
    await show(t, const ContactEditor(), _Never());

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('and the outline goes when the record lands', (t) async {
    // The control for the two above. Without it, a screen that drew
    // bones and never anything else would pass every assertion here.
    await show(t, const ContactEditor(contactId: 'c1'), _Answers());
    await t.pump(const Duration(milliseconds: 600));

    expect(find.byType(TextFormField), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

/// A repository whose every answer is still on the way.
///
/// Futures that never complete, deliberately: the loading branch is the
/// whole subject, and one that resolved between two pumps would assert
/// the data branch by accident.
class _Never implements Repo {
  @override
  Future<List<Map<String, dynamic>>> lotBalances({String? itemId}) =>
      Completer<List<Map<String, dynamic>>>().future;

  @override
  Future<List<Map<String, dynamic>>> expiringStock({int withinDays = 90}) =>
      Completer<List<Map<String, dynamic>>>().future;

  @override
  Future<Contact> contact(String id) => Completer<Contact>().future;

  @override
  Future<String> nextContactCode(String contactType) =>
      Completer<String>().future;

  /// A Dart extension method binds to the STATIC type, so overriding
  /// one on this fake would not be an override at all -- it would sit
  /// there unused while the real extension ran. `reportLayouts` is one
  /// of those, and an earlier draft of this file did exactly that: the
  /// layout screen still drew its outline, but because the real
  /// extension blew up on a fake that answers nothing, not because
  /// anything was on its way. Green, and about the wrong thing.
  ///
  /// So the hang goes where the extension actually goes -- `callRpc` --
  /// and every extension method built on it is genuinely still waiting.
  @override
  Future<dynamic> callRpc(String fn, {Map<String, dynamic>? params}) =>
      Completer<dynamic>().future;

  @override
  Future<List<Map<String, dynamic>>> groupCompanies() async => const [];

  @override
  Future<List<Map<String, dynamic>>> priceLevels() async => const [];

  @override
  Future<List<Map<String, dynamic>>> states() async => const [];

  @override
  Future<List<Account>> accounts({bool postableOnly = false}) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'the screen called Repo.${invocation.memberName}, '
    'which this fake does not answer',
  );
}

/// The same, except the contact arrives.
class _Answers extends _Never {
  /// And the extensions answer emptily rather than hanging, so the
  /// form finishes loading instead of stopping half way.
  @override
  Future<dynamic> callRpc(String fn, {Map<String, dynamic>? params}) async =>
      null;

  @override
  Future<Contact> contact(String id) async => Contact(
    id: 'c1',
    code: 'CUST-0004',
    name: 'Bumi Maju Enterprise',
    contactType: 'customer',
    entityType: 'sdn_bhd',
  );
}
