import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/admin/reservations_admin.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

/// The two pickers that say what one address is for.
///
/// Module, then the feature inside it — Point of Sale, then Till. The
/// first version listed raw module codes, which reads as a debugging
/// aid rather than a menu and puts `property_strata` and `mbrs` in
/// front of somebody choosing between them.
///
/// Opened and pressed rather than inspected, for the reason the colour
/// picker taught: a dropdown full of the right data that nobody can
/// reach is indistinguishable from an empty one.
void main() {
  Widget wrap({
    String? module,
    String? path,
    void Function(String?, String?)? onChanged,
    List<ModuleInfo> catalogue = const [],
  }) => ProviderScope(
    overrides: [
      platformModulesProvider.overrideWith((ref) async => catalogue),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ConfinementFields(
          module: module,
          path: path,
          onChanged: onChanged ?? (_, __) {},
        ),
      ),
    ),
  );

  ModuleInfo mod(String code, String name) =>
      ModuleInfo(code: code, name: name, isCore: false, monthlyPrice: 0);

  final moduleField = find.byType(DropdownButtonFormField<String?>).first;
  final featureField = find.byType(DropdownButtonFormField<String?>).last;

  /// Open a menu and scroll until [label] is on screen, or until there
  /// is no more menu to scroll.
  ///
  /// Two dozen modules and sixteen features, and a dropdown builds only
  /// what its viewport holds — so an entry that is merely further down
  /// and one that is not in the list at all both answer `find.text`
  /// with nothing. Scrolling is what tells them apart, and the caller
  /// asserts which of the two it got.
  ///
  /// `scrollUntilVisible` throws when it runs out of list. That is the
  /// absent case, which is a legitimate answer here rather than an
  /// error, so it is caught and left to the assertion that follows.
  Future<void> hunt(WidgetTester tester, Finder field, String label) async {
    await tester.tap(field);
    await tester.pumpAndSettle();
    try {
      await tester.scrollUntilVisible(
        find.text(label),
        60,
        scrollable: find.byType(Scrollable).last,
        maxScrolls: 60,
      );
    } catch (_) {
      // Not in the menu. `expect` says so better than a StateError.
    }
    await tester.pumpAndSettle();
  }

  /// Whether a menu offers [label] at all.
  ///
  /// Closes the menu on the way out, so the next question starts at the
  /// top of the list rather than wherever this one stopped scrolling —
  /// and so that two questions in a row are two openings rather than an
  /// open followed by a tap on its own barrier.
  Future<bool> offers(WidgetTester tester, Finder field, String label) async {
    await hunt(tester, field, label);
    final found = find.text(label).evaluate().isNotEmpty;
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    return found;
  }

  testWidgets('the module list is every module with somewhere to go',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(moduleField);
    await tester.pumpAndSettle();

    // 24 of them today, and the assertion is that it is not one or two:
    // the complaint that started this was a list that looked empty.
    final modules = <String>{for (final d in assignableDestinations()) d.module};
    expect(modules.length, greaterThan(10));
    expect(find.text('The whole product'), findsWidgets);
  });

  testWidgets('and shows their names rather than their codes',
      (tester) async {
    await tester.pumpWidget(wrap(
      catalogue: [mod('pos', 'Point of Sale'), mod('mbrs', 'Statements')],
    ));
    await tester.pumpAndSettle();

    expect(await offers(tester, moduleField, 'Point of Sale'), isTrue);
    expect(await offers(tester, moduleField, 'Statements'), isTrue);
    expect(await offers(tester, moduleField, 'pos'), isFalse);
    expect(await offers(tester, moduleField, 'mbrs'), isFalse);
  });

  testWidgets('a module with no name yet still appears, by its code',
      (tester) async {
    // The catalogue is fetched. A list that is empty until it lands is
    // worse than one that is briefly ugly.
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(await offers(tester, moduleField, 'pos'), isTrue);
  });

  testWidgets('the feature list is the features of the chosen module',
      (tester) async {
    await tester.pumpWidget(wrap(
      module: 'pos',
      catalogue: [mod('pos', 'Point of Sale')],
    ));
    await tester.pumpAndSettle();

    // The example from the request: Module → Point of Sale,
    // Feature → Till.
    expect(await offers(tester, featureField, 'Till'), isTrue);
    expect(await offers(tester, featureField, 'Kitchen'), isTrue);
    expect(await offers(tester, featureField, 'Kiosk'), isTrue);
  });

  testWidgets('and nothing from another module', (tester) async {
    await tester.pumpWidget(wrap(
      module: 'hr',
      catalogue: [mod('hr', 'People')],
    ));
    await tester.pumpAndSettle();

    expect(await offers(tester, featureField, 'Till'), isFalse);
    expect(await offers(tester, featureField, 'Leave'), isTrue);
  });

  testWidgets('and it names the module it belongs to', (tester) async {
    await tester.pumpWidget(wrap(
      module: 'pos',
      catalogue: [mod('pos', 'Point of Sale')],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Feature'), findsOneWidget);
    expect(find.text('Any feature of Point of Sale'), findsWidgets);
  });

  testWidgets('there is no feature picker until a module is chosen',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Feature'), findsNothing);
    expect(find.text('Module'), findsOneWidget);
  });

  testWidgets('choosing a feature reports it with its module',
      (tester) async {
    final calls = <(String?, String?)>[];
    await tester.pumpWidget(wrap(
      module: 'pos',
      catalogue: [mod('pos', 'Point of Sale')],
      onChanged: (m, p) => calls.add((m, p)),
    ));
    await tester.pumpAndSettle();

    await hunt(tester, featureField, 'Till');
    await tester.tap(find.text('Till').last);
    await tester.pumpAndSettle();

    expect(calls, [('pos', '/till')]);
  });

  testWidgets('and changing the module drops the feature under it',
      (tester) async {
    // A path left pointing into a module the name no longer serves is a
    // restriction nobody can reason about.
    final calls = <(String?, String?)>[];
    await tester.pumpWidget(wrap(
      module: 'pos',
      path: '/till',
      catalogue: [mod('pos', 'Point of Sale'), mod('sales', 'Sales')],
      onChanged: (m, p) => calls.add((m, p)),
    ));
    await tester.pumpAndSettle();

    await hunt(tester, moduleField, 'Sales');
    await tester.tap(find.text('Sales').last);
    await tester.pumpAndSettle();

    expect(calls, [('sales', null)]);
  });
}
