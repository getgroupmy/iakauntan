import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/landing_repository.dart';
import 'package:iakauntan/src/features/admin/landing_cms.dart';

/// The Order box on the landing console, which used to accept anything
/// and quietly do nothing.
///
/// Every one of the five dialogs on that page reads its order with
/// `int.tryParse` and sends the result to a function whose SQL is
/// `sort_order = coalesce(p_sort_order, s.sort_order)`. So an
/// unreadable box was not an error anywhere along the way: null out,
/// "leave it as it was" in, and "Saved" on the screen. An administrator
/// retyping an order to move a block, who typed a letter O for a
/// nought, was told it saved and the page was exactly as before.
///
/// `keyboardType: TextInputType.number` is not a defence. It is a hint
/// to a phone keyboard and does nothing at all in a browser, which is
/// where this screen is used.
///
/// Blank is NOT the same case and must go on working: the helper text
/// says "Leave blank to put it last", and the insert turns a null order
/// into `max(sort_order) + 10`.
class _RecordingAdmin extends LandingAdmin {
  _RecordingAdmin(super.client);

  final List<Map<String, dynamic>> saved = [];

  @override
  Future<List<Map<String, dynamic>>> landingSections({String kind = 'feature'}) async => [
        {
          'id': 'sec-1',
          'title': 'Everything in one place',
          'body': 'Books, payroll and e-Invoice.',
          'icon': 'check',
          'sort_order': 20,
          'is_active': true,
        },
      ];

  @override
  Future<String> saveLandingSection({
    String? id,
    String? title,
    String? body,
    String? icon,
    int? sortOrder,
    bool? isActive,
    String? kind,
  }) async {
    saved.add({
      'id': id,
      'title': title,
      'sort_order': sortOrder,
      'kind': kind,
    });
    return id ?? 'new-id';
  }
}

void main() {
  late _RecordingAdmin admin;

  // Build the client BEFORE any widget test runs. A top-level `final`
  // is lazy, so touching it for the first time inside `testWidgets`
  // creates GoTrue's auto-refresh timer inside that test's fake-async
  // zone — and a timer still pending when the tree is disposed fails
  // the test for a reason that has nothing to do with what it asserts.
  // It failed exactly one test, the first, which is the confusing shape
  // of this particular trap.
  setUpAll(() => _unusedClient);

  Future<void> openTheBlock(WidgetTester tester) async {
    admin = _RecordingAdmin(_unusedClient);
    tester.view.devicePixelRatio = 1.0;
    // A browser viewport. This screen is a platform administrator at a
    // desk, which is also why the number keyboard buys nothing.
    tester.view.physicalSize = const Size(1280, 1000);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [landingAdminProvider.overrideWithValue(admin)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SingleChildScrollView(child: LandingSectionsCard()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everything in one place'));
    await tester.pumpAndSettle();
  }

  Future<void> typeOrderAndSave(WidgetTester tester, String order) async {
    await tester.enterText(find.byKey(const ValueKey('landing-order')), order);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
  }

  group('the rule on its own', () {
    test('a whole number is fine', () {
      expect(landingSortProblem('20'), isNull);
      expect(landingSortProblem('  20  '), isNull);
      expect(landingSortProblem('0'), isNull);
    });

    test('blank is an instruction, not a mistake', () {
      // "Leave blank to put it last" is what the box says, and a null
      // order becomes max(sort_order) + 10 on the way in.
      expect(landingSortProblem(''), isNull);
      expect(landingSortProblem('   '), isNull);
    });

    test('a letter O for a nought is refused', () {
      expect(landingSortProblem('1O'), isNotNull);
      expect(landingSortProblem('2O'), contains('whole number'));
    });

    test('and so is anything else that is not a whole number', () {
      expect(landingSortProblem('10.5'), isNotNull);
      expect(landingSortProblem('10.0'), isNotNull);
      expect(landingSortProblem('twenty'), isNotNull);
      expect(landingSortProblem('1,000'), isNotNull);
    });

    test('a negative order is allowed', () {
      // Not a mistake to catch here. The column takes it and a
      // deliberate negative is how somebody pins a block above
      // everything already numbered.
      expect(landingSortProblem('-10'), isNull);
    });
  });

  group('the dialog', () {
    testWidgets('refuses an order nobody can read, and does not save', (
      tester,
    ) async {
      await openTheBlock(tester);
      await typeOrderAndSave(tester, '1O');

      expect(admin.saved, isEmpty);
      expect(find.textContaining('whole number'), findsOneWidget);
    });

    testWidgets('saves a real order', (tester) async {
      // The control. Without it a dialog that refused everything would
      // pass the assertion above and nothing could ever be reordered.
      await openTheBlock(tester);
      await typeOrderAndSave(tester, '15');

      expect(admin.saved.single['sort_order'], 15);
      expect(admin.saved.single['id'], 'sec-1');
    });

    testWidgets('and still saves a blank one', (tester) async {
      // The case the refusal must not break: blank means "put it last",
      // and it reaches the database as null so the insert can pick.
      await openTheBlock(tester);
      await typeOrderAndSave(tester, '');

      expect(admin.saved.single['sort_order'], isNull);
      expect(admin.saved.single['title'], 'Everything in one place');
    });

    testWidgets('the block stays in the band it was in', (tester) async {
      // `kind` goes on every save including an edit, so a block cannot
      // be moved between the two bands by accident.
      await openTheBlock(tester);
      await typeOrderAndSave(tester, '15');

      expect(admin.saved.single['kind'], 'feature');
    });
  });
}

/// A client no test calls through.
///
/// `LandingAdmin` takes a concrete `SupabaseClient`, which cannot be
/// faked, and every method the dialog reaches is overridden above — so
/// this is only ever the unused constructor argument.
///
/// Built ONCE, at the top level, and deliberately not inside a test
/// body: `SupabaseClient`'s constructor starts GoTrue's auto-refresh
/// timer, and a timer created during a widget test is still pending
/// when the tree is disposed, which fails the test for a reason that
/// has nothing to do with what it asserts.
final _unusedClient = SupabaseClient('https://example.invalid', 'not-a-key');
