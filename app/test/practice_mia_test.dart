import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/firms/practice_screen.dart';
import 'package:iakauntan/src/features/mia/mia_credential.dart';
import 'package:iakauntan/src/features/mia/mia_service.dart';

/// The practice's own MIA registration, and who may change it.
///
/// `practice_screen.dart` is 700 lines and had no test at all. The rule
/// added to it is a permission rule, and a permission rule that is too
/// generous is invisible: the button appears, somebody presses it, and
/// the database refuses with an error nobody can act on.
///
/// `app.can_manage_firm` is the authority — partner or manager, active.
/// What is asserted here is that the SCREEN asks the same question, so
/// the control offered is one the server will accept.
void main() {
  Map<String, dynamic> staff({
    String userId = 'me',
    String role = 'staff',
    String status = 'active',
  }) => {
    'member_id': 'm-$userId-$role',
    'user_id': userId,
    'role': role,
    'status': status,
    'full_name': 'Somebody',
    'email': 'somebody@example.test',
  };

  group('the rule itself', () {
    test('a partner may', () {
      expect(canManagePractice([staff(role: 'partner')], 'me'), isTrue);
    });

    test('a manager may', () {
      expect(canManagePractice([staff(role: 'manager')], 'me'), isTrue);
    });

    test('a member of staff may not', () {
      expect(canManagePractice([staff()], 'me'), isFalse);
    });

    test('an invited partner who has not accepted may not', () {
      // `app.can_manage_firm` requires `status = 'active'`. An
      // invitation is a row on the table and not yet a membership.
      expect(
        canManagePractice(
          [staff(role: 'partner', status: 'invited')],
          'me',
        ),
        isFalse,
      );
    });

    test('somebody else being a partner does not make me one', () {
      expect(
        canManagePractice([staff(userId: 'them', role: 'partner')], 'me'),
        isFalse,
      );
    });

    test('and nobody signed in may not', () {
      expect(canManagePractice([staff(role: 'partner')], null), isFalse);
    });
  });

  group('the screen', () {
    MiaCredential firmCred() => MiaCredential(
      id: 'c1',
      subjectType: 'firm',
      subjectId: 'f1',
      kind: MiaKind.firm,
      verifiedVia: MiaVerifiedVia.manual,
      verifiedAt: DateTime(2026, 9, 1),
      firmNo: 'AF 0759',
      firmName: 'ABC & CO PLT',
      firmType: 'A',
    );

    Future<void> show(
      WidgetTester tester, {
      String role = 'partner',
      List<MiaCredential> credentials = const [],
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 2000);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            myFirmsProvider.overrideWith(
              (ref) async => [
                {'id': 'f1', 'name': 'ABC & Co PLT'},
              ],
            ),
            firmTeamProvider.overrideWith(
              (ref, firmId) async => [staff(role: role)],
            ),
            firmPortfolioProvider.overrideWith((ref, firmId) async => const []),
            firmTrailProvider.overrideWith((ref, firmId) async => const []),
            miaCredentialsProvider.overrideWith((ref, arg) async => credentials),
            currentUserProvider.overrideWithValue(
              User(
                id: 'me',
                appMetadata: const {},
                userMetadata: const {},
                aud: 'authenticated',
                createdAt: DateTime(2026).toIso8601String(),
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const PracticeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a partner is offered the check', (tester) async {
      await show(tester);

      expect(find.byKey(const ValueKey('mia-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('mia-verify')), findsOneWidget);
    });

    testWidgets('a member of staff is not', (tester) async {
      await show(tester, role: 'staff');

      // Nothing recorded and nothing they may record: the card is not
      // drawn at all rather than drawn empty and inert.
      expect(find.byKey(const ValueKey('mia-card')), findsNothing);
    });

    testWidgets('and the check it opens is about the firm only', (
      tester,
    ) async {
      // A practice is a firm. The partners' own member numbers belong
      // to the partners, and a Member/Firm toggle here would offer to
      // file a person's credential against a company — which the
      // unique key in 0603 would then hold as the practice's own.
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('mia-verify')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mia-field-firm_no')), findsOneWidget);
      expect(find.byKey(const ValueKey('mia-kind')), findsNothing);
      expect(find.byKey(const ValueKey('mia-field-member_no')), findsNothing);
    });

    testWidgets('but staff see what was recorded', (tester) async {
      await show(tester, role: 'staff', credentials: [firmCred()]);

      expect(find.byKey(const ValueKey('mia-card')), findsOneWidget);
      expect(find.textContaining('AF 0759'), findsOneWidget);
      expect(find.byKey(const ValueKey('mia-verify')), findsNothing);
      expect(find.byKey(const ValueKey('mia-remove-firm')), findsNothing);
    });
  });
}
