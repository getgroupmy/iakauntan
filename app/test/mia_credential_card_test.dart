import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/mia/mia_credential.dart';
import 'package:iakauntan/src/features/mia/mia_credential_card.dart';
import 'package:iakauntan/src/features/mia/mia_service.dart';

/// What the MIA card shows, driven as the widget rather than as its
/// parts.
///
/// The card carries three claims that are wrong in a quiet direction:
/// a practising certificate the register never mentioned must not read
/// "No"; a check made more than a year ago must say so, because a
/// certificate is renewed annually and a year-old answer describes last
/// year's register; and the caveat about what MIA membership is not
/// must be beside every one of them. All three fail silently — the
/// screen looks right and says something untrue.
void main() {
  MiaCredential cred({
    MiaKind kind = MiaKind.member,
    String? memberNo = '12345',
    String? memberName = 'TAN AH KOW',
    String? memberType = 'CA',
    bool? pcHolder,
    String? firmNo,
    String? firmName,
    String? firmType,
    DateTime? verifiedAt,
    String? verifiedByName = 'Kabeer',
  }) => MiaCredential(
    id: 'c-${kind.name}',
    subjectType: 'corp_officer',
    subjectId: 'o1',
    kind: kind,
    verifiedVia: MiaVerifiedVia.manual,
    verifiedAt: verifiedAt ?? DateTime(2026, 9, 1),
    memberNo: kind == MiaKind.member ? memberNo : null,
    memberName: kind == MiaKind.member ? memberName : null,
    memberType: kind == MiaKind.member ? memberType : null,
    pcHolder: pcHolder,
    firmNo: firmNo,
    firmName: firmName,
    firmType: firmType,
    state: 'Selangor',
    verifiedByName: verifiedByName,
  );

  Future<void> show(
    WidgetTester tester,
    List<MiaCredential> rows, {
    bool canWrite = true,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    // A browser viewport, not a screen size. Tall enough that the
    // caveat at the foot of the card is laid out rather than clipped
    // off the bottom, which would make every assertion below about a
    // widget that is present read as if it were absent.
    tester.view.physicalSize = const Size(1280, 1400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          miaCredentialsProvider.overrideWith((ref, arg) async => rows),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: MiaCredentialCard(
                subjectType: 'corp_officer',
                subjectId: 'o1',
                subjectName: 'TAN AH KOW',
                canWrite: canWrite,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a practising certificate nobody asked about is not a No', (
    tester,
  ) async {
    await show(tester, [cred(pcHolder: null)]);

    expect(find.text('Not recorded'), findsOneWidget);
    expect(find.text('No'), findsNothing);
  });

  testWidgets('and one the register answered is shown as it answered', (
    tester,
  ) async {
    // The control for the assertion above. Without it "Not recorded"
    // could be what the card always prints, and the first test would
    // pass against a card that never reads `pcHolder` at all.
    await show(tester, [cred(pcHolder: false)]);

    expect(find.text('No'), findsOneWidget);
    expect(find.text('Not recorded'), findsNothing);
  });

  testWidgets('a check older than a year asks to be made again', (
    tester,
  ) async {
    await show(tester, [cred(verifiedAt: DateTime(2025, 1, 4))]);

    expect(find.byKey(const ValueKey('mia-stale')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mia-reverify-member')),
      findsOneWidget,
    );
  });

  testWidgets('a recent one does not', (tester) async {
    await show(tester, [cred(verifiedAt: DateTime(2026, 8, 30))]);

    expect(find.byKey(const ValueKey('mia-stale')), findsNothing);
  });

  testWidgets('what a credential is not is said beside it', (tester) async {
    await show(tester, [cred()]);

    final caveat = tester.widget<Text>(
      find.byKey(const ValueKey('mia-caveat')),
    );
    expect(caveat.data, contains('approved company auditor'));
    expect(caveat.data, contains('tax agent'));
  });

  testWidgets('who looked it up is on the card', (tester) async {
    await show(tester, [cred(verifiedAt: DateTime(2026, 9, 1))]);

    final line = tester.widget<Text>(
      find.byKey(const ValueKey('mia-checked-member')),
    );
    expect(line.data, contains('Kabeer'));
  });

  testWidgets('both credentials show at once', (tester) async {
    // An engagement partner is a member AND signs for a registered
    // firm. Two rows about one appointment is the case the unique key
    // in 0603 is shaped for, so the card has to draw both.
    await show(tester, [
      cred(),
      cred(
        kind: MiaKind.firm,
        firmNo: 'AF 0759',
        firmName: 'ABC & CO PLT',
        firmType: 'A',
      ),
    ]);

    // Number AND name, for both. `registeredName` reads a different
    // column per kind, and reading the member column for a firm gives
    // an em dash beside a real firm number — a row that looks recorded
    // and names nobody.
    expect(find.textContaining('12345 · TAN AH KOW'), findsOneWidget);
    expect(find.textContaining('AF 0759 · ABC & CO PLT'), findsOneWidget);
    expect(find.text('Audit'), findsOneWidget);
  });

  testWidgets('a reader who cannot write sees nothing when there is '
      'nothing', (tester) async {
    // An empty card headed "Malaysian Institute of Accountants" under
    // every officer of every company is an invitation to record
    // something that mostly does not apply.
    await show(tester, const [], canWrite: false);

    expect(find.byKey(const ValueKey('mia-card')), findsNothing);
  });

  testWidgets('a card still loading does not claim nothing was recorded', (
    tester,
  ) async {
    // The answer that has not arrived is not an answer of none. Pumped
    // once rather than settled, which is the only way to see the frame
    // the user actually gets.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 1400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          miaCredentialsProvider.overrideWith((ref, arg) async {
            // Never completes within the frames this test pumps.
            return Completer<List<MiaCredential>>().future;
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: MiaCredentialCard(
              subjectType: 'corp_officer',
              subjectId: 'o1',
              subjectName: 'TAN AH KOW',
              canWrite: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('Nothing recorded'), findsNothing);
  });

  testWidgets('but somebody who can write is offered the check', (
    tester,
  ) async {
    await show(tester, const []);

    expect(find.byKey(const ValueKey('mia-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('mia-verify')), findsOneWidget);
    expect(find.text('Check'), findsOneWidget);
  });

  testWidgets('and a reader who cannot write is not', (tester) async {
    await show(tester, [cred()], canWrite: false);

    expect(find.byKey(const ValueKey('mia-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('mia-verify')), findsNothing);
    expect(find.byKey(const ValueKey('mia-remove-member')), findsNothing);
  });
}
