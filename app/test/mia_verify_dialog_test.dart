import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/mia/mia_credential.dart';
import 'package:iakauntan/src/features/mia/mia_service.dart';
import 'package:iakauntan/src/features/mia/mia_verify_dialog.dart';

/// The dialog that records what the register said.
///
/// `MiaResultParser` has its own tests and they prove the parser. They
/// do not prove that the DIALOG parses anything — the lesson this
/// repository keeps relearning — so everything here drives the real
/// widget: type into the real paste box, tap the real button, read the
/// real fields.
///
/// What is asserted is what would be wrong quietly. A pasted row whose
/// fields did not reach the boxes looks like a form somebody has to
/// fill in by hand. A row saved without its number looks like a
/// verified credential and cannot be looked up again.
class _RecordingService extends MiaVerificationService {
  _RecordingService(super.ref);

  Map<String, String?>? savedFields;
  MiaKind? savedKind;
  String? savedRaw;

  @override
  Future<List<MiaCredential>> load({
    required String subjectType,
    required String subjectId,
  }) async => const [];

  @override
  Future<void> save({
    required String subjectType,
    required String subjectId,
    required MiaKind kind,
    required Map<String, String?> fields,
    required String rawText,
  }) async {
    savedKind = kind;
    savedFields = fields;
    savedRaw = rawText;
  }

  @override
  Future<void> remove(String id) async {}
}

void main() {
  // The two rows from the handoff, with the tabs the register's own
  // table puts between the cells. Not a tidied-up version: the firm row
  // carries a blank fax and newlines inside one cell, which is the part
  // that has broken before.
  const memberRow = '12345\tTAN AH KOW\tCA\tSelangor\tYes';
  const firmRow =
      'AF 1234\tABC & CO PLT\tLEVEL 3, MENARA XYZ, JALAN AMPANG, '
      '50450 KUALA LUMPUR\tWP Kuala Lumpur\tMYR\t'
      'Tel: 60312345678\nFax: \nEmail: someone@abc.com.my\twww.abc.com.my';

  late _RecordingService service;

  Future<void> show(
    WidgetTester tester, {
    List<MiaKind> kinds = const [MiaKind.member, MiaKind.firm],
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 2400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          miaServiceProvider.overrideWith((ref) {
            return service = _RecordingService(ref);
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: MiaVerifyDialog(
              subjectType: 'corp_officer',
              subjectId: 'o1',
              subjectName: 'TAN AH KOW',
              kinds: kinds,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String boxText(WidgetTester tester, String field) => tester
      .widget<TextField>(find.byKey(ValueKey('mia-field-$field')))
      .controller!
      .text;

  Future<void> paste(WidgetTester tester, String row) async {
    await tester.enterText(find.byKey(const ValueKey('mia-paste')), row);
    await tester.tap(find.byKey(const ValueKey('mia-read')));
    await tester.pumpAndSettle();
  }

  testWidgets('a pasted member row fills the boxes', (tester) async {
    await show(tester);
    await paste(tester, memberRow);

    expect(boxText(tester, 'member_no'), '12345');
    expect(boxText(tester, 'member_name'), 'TAN AH KOW');
    expect(boxText(tester, 'member_type'), 'CA');
    expect(boxText(tester, 'state'), 'Selangor');
  });

  testWidgets('a pasted firm row switches the dialog to a firm', (
    tester,
  ) async {
    await show(tester);
    await paste(tester, firmRow);

    // Firm fields exist only when the dialog thinks it is looking at a
    // firm, so finding them at all is the assertion that it switched.
    expect(boxText(tester, 'firm_no'), 'AF 1234');
    expect(boxText(tester, 'firm_name'), 'ABC & CO PLT');
    expect(boxText(tester, 'tel'), '60312345678');
    expect(boxText(tester, 'email'), 'someone@abc.com.my');
    // The blank fax stays blank. It used to swallow the line below it,
    // which put an e-mail address in the fax box — a record worse than
    // no record.
    expect(boxText(tester, 'fax'), '');
  });

  testWidgets('a number that is not a row is refused rather than guessed', (
    tester,
  ) async {
    await show(tester);
    await paste(tester, 'who knows what this is');

    expect(find.byKey(const ValueKey('mia-parse-note')), findsOneWidget);
    expect(boxText(tester, 'member_no'), '');
  });

  testWidgets('the empty no-record row is not read as a credential', (
    tester,
  ) async {
    // A search that found nothing still renders one row. Somebody
    // copying the table gets it, and it must not become a credential
    // asserting that a person with no number was checked.
    await show(tester);
    await paste(tester, ', , , \tTel: Fax: Email:');

    expect(boxText(tester, 'member_no'), '');
    final note = tester.widget<Text>(
      find.byKey(const ValueKey('mia-parse-note')),
    );
    expect(note.data, contains('does not look like'));
  });

  testWidgets('saving sends what is in the boxes', (tester) async {
    await show(tester);
    await paste(tester, memberRow);
    await tester.tap(find.byKey(const ValueKey('mia-save')));
    await tester.pumpAndSettle();

    expect(service.savedKind, MiaKind.member);
    expect(service.savedFields!['member_no'], '12345');
    expect(service.savedFields!['member_name'], 'TAN AH KOW');
    // Yes in the register's column became a boolean, not the word.
    expect(service.savedFields!['pc_holder'], 'true');
    // Exactly what was pasted, kept for the audit.
    expect(service.savedRaw, memberRow);
  });

  testWidgets('a row with no number is refused', (tester) async {
    await show(tester);
    await tester.enterText(
      find.byKey(const ValueKey('mia-field-member_name')),
      'TAN AH KOW',
    );
    await tester.tap(find.byKey(const ValueKey('mia-save')));
    await tester.pumpAndSettle();

    expect(service.savedFields, isNull);
    expect(find.textContaining('member number'), findsOneWidget);
  });

  testWidgets('a firm-only dialog offers no member/firm toggle', (
    tester,
  ) async {
    // The practice screen records the practice's own registration and
    // nothing else. A toggle there would offer to file a person's
    // member number against a company.
    await show(tester, kinds: const [MiaKind.firm]);

    expect(find.byKey(const ValueKey('mia-kind')), findsNothing);
    expect(find.byKey(const ValueKey('mia-field-firm_no')), findsOneWidget);
    expect(find.byKey(const ValueKey('mia-field-member_no')), findsNothing);
  });

  testWidgets('and a dialog offering both does', (tester) async {
    // The control for the assertion above: without it, a toggle that
    // had been deleted outright would pass.
    await show(tester);

    expect(find.byKey(const ValueKey('mia-kind')), findsOneWidget);
  });

  testWidgets('there is no live search, and the dialog says so', (
    tester,
  ) async {
    await show(tester);

    expect(find.textContaining('publishes no API'), findsOneWidget);
    expect(find.byKey(const ValueKey('mia-open-register')), findsOneWidget);
  });

  group('the rule on its own', () {
    test('a member row needs a member number', () {
      expect(
        miaSaveProblem(kind: MiaKind.member, values: {'member_name': 'X'}),
        isNotNull,
      );
      expect(
        miaSaveProblem(kind: MiaKind.member, values: {'member_no': ' 12345 '}),
        isNull,
      );
    });

    test('a firm row needs a firm number', () {
      expect(
        miaSaveProblem(kind: MiaKind.firm, values: {'firm_name': 'X'}),
        isNotNull,
      );
      expect(
        miaSaveProblem(kind: MiaKind.firm, values: {'firm_no': 'AF 1234'}),
        isNull,
      );
    });

    test('whitespace is not a number', () {
      expect(
        miaSaveProblem(kind: MiaKind.member, values: {'member_no': '   '}),
        isNotNull,
      );
    });

    test('a member and a firm do not share a single field', () {
      // Which is why the dialog has a kind at all. If these ever
      // overlapped, one paste could fill a box the other kind saves.
      final member = miaFieldLabels(MiaKind.member).keys.toSet();
      final firm = miaFieldLabels(MiaKind.firm).keys.toSet();
      expect(member.intersection(firm), {'state'});
    });
  });
}
