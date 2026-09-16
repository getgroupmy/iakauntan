import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/contacts/contact_editor.dart';

/// The credit limit, and the one value it must never reach by accident.
///
/// Zero is not a small limit on this field. It is the OFF position, and
/// three separate places agree on that: the helper text under the field
/// says "Zero means no limit", `0086_credit_control.sql` reads it that
/// way, and `0467_cash_is_not_credit.sql` says it outright --
///
///     if coalesce(v_limit, 0) <= 0 then return new;
///
/// -- which is the credit check declining to run at all.
///
/// The field used to be read with `double.tryParse(text) ?? 0` and had
/// no validator. So a limit typed as "10,000", which is how the figure
/// is written on every document this app produces, did not become
/// 10,000 and did not become an error. It became NO LIMIT, on the
/// customer somebody had opened the screen specifically to cap, and the
/// only trace was the field reading "0.00" on some later visit.
///
/// The direction is what makes it worth a test file. A credit control
/// that fails shut is an annoyance somebody reports within the hour; one
/// that fails open is found when an invoice cannot be collected.
void main() {
  Contact existing({double creditLimit = 0}) => Contact(
    id: 'c1',
    code: 'C-0001',
    name: 'Rantaian Maju Sdn Bhd',
    contactType: 'customer',
    creditLimit: creditLimit,
  );

  late _FakeRepo repo;

  Widget wrap() => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(repo),
      currentOrgProvider.overrideWith(
        (ref) async => Organization(
          id: 'o1',
          name: 'Rantaian Maju Sdn Bhd',
          slug: 'rantaian',
        ),
      ),
      memberRoleProvider.overrideWith((ref) async => 'owner'),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: ContactEditor(contactId: 'c1')),
    ),
  );

  Future<void> open(WidgetTester tester, {double creditLimit = 0}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 2400);
    addTearDown(tester.view.reset);
    repo = _FakeRepo(existing(creditLimit: creditLimit));
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  Finder field() => find.ancestor(
    of: find.text('Credit limit'),
    matching: find.byType(TextFormField),
  );

  /// Type into the credit limit and press Save.
  Future<void> enterAndSave(WidgetTester tester, String text) async {
    await tester.enterText(field(), text);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  group('a figure the field can read', () {
    test('the fixture is a customer with no limit', () {
      // So every assertion below about a limit arriving is about the
      // typing rather than about what was already there.
      expect(existing().creditLimit, 0);
    });

    testWidgets('a plain number saves as itself', (tester) async {
      await open(tester);
      await enterAndSave(tester, '10000');

      expect(repo.saved?.creditLimit, 10000);
      // And the save REPORTED success. Asserted once, here, because
      // everything else in this file reads `repo.saved` -- which is set
      // partway through `_save`, so a later step throwing would leave
      // every other assertion true and the screen showing an error.
      expect(find.text('Contact saved'), findsOneWidget);
    });

    testWidgets('and one written with a comma saves as the same number',
        (tester) async {
      // The report. Ten thousand ringgit, written the way ten thousand
      // ringgit is written.
      await open(tester);
      await enterAndSave(tester, '10,000');

      expect(repo.saved, isNotNull, reason: 'the form should have saved');
      expect(repo.saved!.creditLimit, 10000);
      // Said twice on purpose: the defect was not a wrong number, it
      // was THIS number, and it is the one the database treats as off.
      expect(repo.saved!.creditLimit, isNot(0));
    });

    testWidgets('and the sen survive', (tester) async {
      // Not a round number, and deliberately so. Every other figure in
      // this file is a multiple of a thousand, and a mutant that
      // rounded the saved limit to the nearest thousand passed all of
      // them.
      await open(tester);
      await enterAndSave(tester, '12,345.67');

      expect(repo.saved?.creditLimit, 12345.67);
    });

    testWidgets('with the currency the field itself prints in front of it',
        (tester) async {
      await open(tester);
      await enterAndSave(tester, 'RM 25,000.00');

      expect(repo.saved?.creditLimit, 25000);
    });
  });

  group('a figure it cannot read', () {
    testWidgets('does not save, and says so', (tester) async {
      await open(tester);
      await enterAndSave(tester, 'ten thousand');

      // Refused, not substituted. The whole point: the old code would
      // have saved this customer with no credit limit at all.
      expect(repo.saved, isNull);
      expect(
        find.text('Enter an amount, or leave it empty for none.'),
        findsOneWidget,
      );
    });

    testWidgets('and neither does a negative one', (tester) async {
      await open(tester);
      await enterAndSave(tester, '-500');

      expect(repo.saved, isNull);
      expect(find.text('A credit limit cannot be below zero.'), findsOneWidget);
    });

    testWidgets('a comma that is not a thousands separator is refused too',
        (tester) async {
      // Not read as 115. Half the world writes 11,5 for eleven and a
      // half, and this field has no way to know which half typed it.
      await open(tester);
      await enterAndSave(tester, '11,5');

      expect(repo.saved, isNull);
    });
  });

  group('and zero still means what the helper text says', () {
    testWidgets('typing it saves it', (tester) async {
      await open(tester, creditLimit: 5000);
      await enterAndSave(tester, '0');

      // Taking a limit OFF has to stay possible, which is why the
      // validator allows zero and only refuses text that is not a
      // figure at all.
      expect(repo.saved?.creditLimit, 0);
    });

    testWidgets('and so does clearing the field', (tester) async {
      await open(tester, creditLimit: 5000);
      await enterAndSave(tester, '');

      expect(repo.saved, isNotNull);
      expect(repo.saved!.creditLimit, 0);
    });

    testWidgets('the helper text says which way round it is', (tester) async {
      await open(tester);

      expect(find.text('Zero means no limit'), findsOneWidget);
    });
  });
}

class _FakeRepo implements Repo {
  _FakeRepo(this.contactRow);

  final Contact contactRow;
  Contact? saved;

  @override
  Future<Contact> contact(String id) async => contactRow;

  @override
  Future<Contact> saveContact(Contact contact, {String? id}) async {
    saved = contact;
    return contact;
  }

  /// The group link, which the save makes straight after the contact.
  ///
  /// Answered HERE rather than by overriding `linkGroupContact`, and
  /// the difference is not cosmetic: that method is on the
  /// `RepoGroupContacts` EXTENSION, not on `Repo`. A Dart extension
  /// method binds to the static type, so a `@override` of it on this
  /// fake is not an override at all -- the analyzer says so -- and the
  /// real extension body runs regardless, reaching `callRpc` on this
  /// object. Left unanswered it throws, `runWithFeedback` catches it,
  /// and the form reports a failed save that in fact succeeded. Every
  /// assertion in this file reads `saved`, which is set before that
  /// point, so the tests would have passed while the screen under them
  /// was showing an error.
  @override
  Future<dynamic> callRpc(String fn, {Map<String, dynamic>? params}) async =>
      null;

  // Everything below is scenery. The editor is a form of thirty fields
  // and this file is about one of them, so the rest answer with nothing
  // rather than being set up.
  @override
  Future<List<Map<String, dynamic>>> groupCompanies() async => const [];

  @override
  Future<List<Map<String, dynamic>>> priceLevels() async => const [];

  @override
  Future<List<Map<String, dynamic>>> states() async => const [];

  @override
  Future<List<Account>> accounts({bool postableOnly = false}) async => const [];

  @override
  Future<String> nextContactCode(String contactType) async => 'C-0002';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'the contact editor called Repo.${invocation.memberName}, '
    'which this fake does not answer',
  );
}
