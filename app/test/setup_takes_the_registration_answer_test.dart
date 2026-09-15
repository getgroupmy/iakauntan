import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/business_types_repository.dart';
import 'package:iakauntan/src/data/my_profile_repository.dart';
import 'package:iakauntan/src/data/places_repository.dart';
import 'package:iakauntan/src/features/onboarding/create_org_screen.dart';
import 'package:iakauntan/src/features/onboarding/onboarding_copy.dart';

/// What setup does with the answer registration already has.
///
/// `onboarding_copy_test.dart` proves the RULES: that
/// `stepAfterUse(UseKind.accountant)` is the module list rather than the
/// business-type question, and that `accountantModules` contains
/// `multi_company`. This file proves the WIRING, which is a different
/// thing and the one that was untested: that a practice which answered
/// at registration actually arrives at the module list with
/// Multi-Company already ticked, having never seen either question.
///
/// That path runs in a post-frame callback off a profile row, and every
/// step of it is a place where nothing would be said if it stopped
/// working. `useKindFrom` returning null for a stored string, a renamed
/// `signup_` column, a profile that arrives after the first frame -- any
/// of them lands an accounting practice on "what kind of business are
/// you?" with nothing ticked, and the first anybody hears of it is a
/// customer who was charged for a module they never got, or who got a
/// question they were told they would not be asked.
void main() {
  Widget wrap(Map<String, dynamic>? profile) => ProviderScope(
    overrides: [
      myProfileProvider.overrideWith((ref) async => profile),
      refStatesProvider.overrideWith(
        (ref) async => const [
          {'code': '10', 'name': 'Selangor'},
        ],
      ),
      countriesProvider.overrideWith(
        (ref) async => const [
          {'code': 'MYS', 'alpha2': 'MY', 'name': 'Malaysia'},
        ],
      ),
      onboardingModulesProvider.overrideWith(
        (ref) async => const [
          {
            'code': 'multi_company',
            'name': 'Multi-Company',
            'description': 'Keep more than one set of books.',
            'monthly_price': 30,
            'nav_group': 'practice',
          },
          {
            'code': 'pos',
            'name': 'Point of Sale',
            'description': 'A till.',
            'monthly_price': 20,
            'nav_group': 'sales',
          },
        ],
      ),
    ],
    child: const MaterialApp(home: CreateOrgScreen()),
  );

  Future<void> open(WidgetTester tester, Map<String, dynamic>? profile) async {
    await tester.pumpWidget(wrap(profile));
    await tester.pumpAndSettle();
  }

  bool tickedIn(WidgetTester tester, String code) => tester
      .widget<CheckboxListTile>(find.byKey(ValueKey('module-$code')))
      .value!;

  testWidgets('a practice lands on the modules, not on "what kind of business"',
      (tester) async {
    await open(tester, {'use_kind': 'accountant', 'country_code': 'MYS'});

    // The question they were told they would not be asked.
    expect(find.text(businessTypeQuestion), findsNothing);
    expect(find.text(modulesQuestion), findsOneWidget);
  });

  testWidgets('with Multi-Company already ticked', (tester) async {
    await open(tester, {'use_kind': 'accountant', 'country_code': 'MYS'});

    expect(tickedIn(tester, 'multi_company'), isTrue);
    // Only that one: ticking the module the answer is about must not
    // become ticking the list.
    expect(tickedIn(tester, 'pos'), isFalse);
  });

  testWidgets('and showing it, with its price, rather than hiding it', (
    tester,
  ) async {
    await open(tester, {'use_kind': 'accountant', 'country_code': 'MYS'});

    // A paid module nobody saw arrive is a charge somebody disputes.
    // It is ticked and visible, and they can untick it.
    expect(find.byKey(const ValueKey('module-multi_company')), findsOneWidget);
    expect(find.textContaining('Multi-Company'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('module-multi_company')));
    await tester.pumpAndSettle();
    expect(tickedIn(tester, 'multi_company'), isFalse);
  });

  testWidgets('a business still gets asked what kind it is', (tester) async {
    await open(tester, {'use_kind': 'business', 'country_code': 'MYS'});

    // The control. Without it, a test that passed because the screen
    // always shows the modules would look identical to one that passed
    // because the answer was read.
    expect(find.text(businessTypeQuestion), findsOneWidget);
    expect(find.text(modulesQuestion), findsNothing);
  });

  testWidgets('an account made before the question is asked as before', (
    tester,
  ) async {
    await open(tester, {'country_code': 'MYS'});

    // No `use_kind` at all: an older account, or one made by an
    // invitation. Setup asks the first question itself rather than
    // guessing, and guessing "business" would file a practice wrong.
    expect(find.text(useQuestion(SetupAudience.own)), findsOneWidget);
  });

  testWidgets('and a profile that has not arrived yet does not decide anything',
      (tester) async {
    await open(tester, null);

    // Null for the moment between signing in and the row arriving, and
    // `_tookProfileAnswer` must not be spent on it -- a screen that
    // took "no answer" as an answer would ask a practice the two
    // questions the whole feature exists to skip.
    expect(find.text(useQuestion(SetupAudience.own)), findsOneWidget);
  });
}
