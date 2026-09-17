import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/corp_models.dart';
import 'package:iakauntan/src/features/mia/mia_credential.dart';
import 'package:iakauntan/src/features/mia/mia_service.dart';
import 'package:iakauntan/src/features/secretarial/entity_screen.dart';
import 'package:iakauntan/src/features/secretarial/officer_sheet.dart';

/// Which corporate appointment is asked about MIA, and where the card
/// appears.
///
/// The rule is one line and it is a scoping rule: ask about the auditor
/// and nobody else. Getting it wrong in the generous direction puts a
/// card headed "Malaysian Institute of Accountants" under every
/// director of every company — an invitation to record something that
/// does not apply, which is how a register fills with confident wrong
/// answers.
///
/// Both halves are driven through the real sheet, because a pure
/// function that returns the right answer proves nothing about a screen
/// that never calls it.
void main() {
  CorpOfficer officer({
    String id = 'o1',
    String role = 'auditor',
    String name = 'TAN AH KOW',
  }) => CorpOfficer(
    id: id,
    personId: 'p1',
    role: role,
    appointedOn: DateTime(2026, 1, 2),
    name: name,
  );

  group('the rule itself', () {
    test('the auditor is asked', () {
      expect(roleNeedsMia('auditor'), isTrue);
    });

    test('a director is not', () {
      expect(roleNeedsMia('director'), isFalse);
    });

    test('nor is the secretary, who already has a licence field', () {
      // MIA is one of the prescribed bodies under s.20G, so this is a
      // judgement rather than an obvious no: the licence number, body
      // and expiry on the same form already record it, and two places
      // to record one fact is how the two come to disagree.
      expect(roleNeedsMia('secretary'), isFalse);
      expect(roleNeedsLicence('secretary'), isTrue);
    });

    test('and no other role is', () {
      // The control. Without it a `roleNeedsMia` that returned true for
      // everything would pass the first assertion.
      for (final role in officerRoles.keys) {
        expect(roleNeedsMia(role), role == 'auditor', reason: role);
      }
    });
  });

  group('the appointment sheet', () {
    Future<void> show(
      WidgetTester tester, {
      CorpOfficer? existing,
      List<MiaCredential> credentials = const [],
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 2400);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            canWriteProvider.overrideWithValue(true),
            corpPersonsProvider.overrideWith((ref) async => const []),
            corpPrincipalsProvider.overrideWith(
              (ref, entityId) async => const [],
            ),
            corpOfficersProvider.overrideWith(
              (ref, entityId) async => const [],
            ),
            miaCredentialsProvider.overrideWith((ref, arg) async => credentials),
            repoProvider.overrideWithValue(null),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showOfficerSheet(
                    context,
                    entityId: 'e1',
                    officer: existing,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> chooseRole(WidgetTester tester, String role) async {
      await tester.tap(find.byKey(const ValueKey('officer-role')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(officerRoleName(role)).last);
      await tester.pumpAndSettle();
    }

    testWidgets('an existing auditor gets the card', (tester) async {
      await show(tester, existing: officer());

      expect(find.byKey(const ValueKey('mia-card')), findsOneWidget);
    });

    testWidgets('an existing director does not', (tester) async {
      await show(tester, existing: officer(role: 'director'));

      expect(find.byKey(const ValueKey('mia-card')), findsNothing);
      expect(find.byKey(const ValueKey('officer-mia-later')), findsNothing);
    });

    testWidgets('changing the role to auditor brings it', (tester) async {
      // The sheet reads the role being EDITED, not the one on file. A
      // card keyed off the saved role would appear only after a save
      // and a reopen.
      await show(tester, existing: officer(role: 'director'));
      expect(find.byKey(const ValueKey('mia-card')), findsNothing);

      await chooseRole(tester, 'auditor');
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mia-card')), findsOneWidget);
    });

    testWidgets('an auditor not yet appointed is asked to wait', (
      tester,
    ) async {
      // There is no id to hang a credential on until the appointment
      // exists, and there must not be one: a credential filed against
      // an auditor who was never appointed is a record of a check that
      // has no subject.
      await show(tester);
      await chooseRole(tester, 'auditor');

      expect(find.byKey(const ValueKey('officer-mia-later')), findsOneWidget);
      expect(find.byKey(const ValueKey('mia-card')), findsNothing);
    });

    testWidgets('what was recorded shows on the appointment', (tester) async {
      await show(
        tester,
        existing: officer(),
        credentials: [
          MiaCredential(
            id: 'c1',
            subjectType: 'corp_officer',
            subjectId: 'o1',
            kind: MiaKind.firm,
            verifiedVia: MiaVerifiedVia.manual,
            verifiedAt: DateTime(2026, 9, 1),
            firmNo: 'AF 0759',
            firmName: 'ABC & CO PLT',
            firmType: 'A',
          ),
        ],
      );

      expect(find.textContaining('AF 0759'), findsOneWidget);
    });
  });

  group('the register', () {
    MiaCredential cred({
      String firmNo = 'AF 0759',
      DateTime? verifiedAt,
    }) => MiaCredential(
      id: 'c1',
      subjectType: 'corp_officer',
      subjectId: 'o1',
      kind: MiaKind.firm,
      verifiedVia: MiaVerifiedVia.manual,
      verifiedAt: verifiedAt ?? DateTime(2026, 9, 1),
      firmNo: firmNo,
      firmName: 'ABC & CO PLT',
    );

    Future<void> show(
      WidgetTester tester, {
      required List<CorpOfficer> officers,
      List<MiaCredential> credentials = const [],
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 1200);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            canWriteProvider.overrideWithValue(true),
            corpOfficersProvider.overrideWith((ref, entityId) async => officers),
            miaCredentialsProvider.overrideWith((ref, arg) async => credentials),
            repoProvider.overrideWithValue(null),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: OfficersTab(entityId: 'e1')),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('an auditor with a credential shows its number', (
      tester,
    ) async {
      await show(tester, officers: [officer()], credentials: [cred()]);

      final line = tester.widget<Text>(
        find.byKey(const ValueKey('officer-mia-line')),
      );
      expect(line.data, contains('AF 0759'));
    });

    testWidgets('an auditor with none says nothing', (tester) async {
      // Not "not checked". A line under every auditor of every company
      // saying what has not been done is a nag rather than a fact, and
      // the card inside the appointment is where one is added.
      await show(tester, officers: [officer()]);

      expect(find.byKey(const ValueKey('officer-mia-line')), findsNothing);
    });

    testWidgets('a director with one still says nothing', (tester) async {
      // The credential provider is keyed on the officer, so a register
      // that drew the line for every role would draw it here too.
      await show(
        tester,
        officers: [officer(role: 'director')],
        credentials: [cred()],
      );

      expect(find.byKey(const ValueKey('officer-mia-line')), findsNothing);
    });

    testWidgets('a year-old check says so on the register', (tester) async {
      await show(
        tester,
        officers: [officer()],
        credentials: [cred(verifiedAt: DateTime(2025, 1, 4))],
      );

      final line = tester.widget<Text>(
        find.byKey(const ValueKey('officer-mia-line')),
      );
      expect(line.data, contains('over a year ago'));
    });

    testWidgets('and a recent one does not', (tester) async {
      await show(tester, officers: [officer()], credentials: [cred()]);

      final line = tester.widget<Text>(
        find.byKey(const ValueKey('officer-mia-line')),
      );
      expect(line.data, isNot(contains('over a year ago')));
    });
  });
}
