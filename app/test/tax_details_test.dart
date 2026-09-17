import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/contacts/tax_details.dart';
import 'package:iakauntan/src/features/contacts/tax_details_page.dart';

/// Asking a customer for their own TIN. `0626`.
///
/// Three things are asserted here and none of them is layout.
///
///   * **the form refuses a half-answer.** LHDN validates a TIN
///     *against* an identification number, so a TIN with nothing to
///     match it against is not an answer — and the customer finds that
///     out months later, through an invoice that was rejected.
///   * **the page tells the truth about what happened.** A submission
///     that filled three blanks and a submission that disagreed with
///     something on file are different outcomes, and saying "thank you"
///     to both is a lie in one of them: somebody whose correction is
///     waiting for a human has not finished, and telling them they have
///     means they will not chase it.
///   * **a disagreement is shown with both sides.** "They say
///     C1234567890" is not answerable without "you hold C9999999999",
///     and a card that showed only the new value is a card that gets
///     accepted without being read.
void main() {
  Map<String, dynamic> invite({
    Map<String, dynamic> contact = const {},
    bool alreadySubmitted = false,
  }) => {
    'state': 'open',
    'company': {'name': 'Kedai Buku Sdn Bhd'},
    'contact': {'name': 'Pembeli Sdn Bhd', ...contact},
    'already_submitted': alreadySubmitted,
    'states': [
      {'code': '10', 'name': 'Selangor'},
      {'code': '14', 'name': 'Wilayah Persekutuan Kuala Lumpur'},
    ],
  };

  Future<void> pump(
    WidgetTester tester, {
    Map<String, dynamic>? contact,
    bool alreadySubmitted = false,
  }) async {
    final map = invite(
      contact: contact ?? const {},
      alreadySubmitted: alreadySubmitted,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TaxDetailsForm(
              token: 'tok',
              invite: TaxDetailsInvite.fromMap(map),
              states: [
                for (final s in map['states'] as List)
                  Map<String, dynamic>.from(s as Map),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  TaxDetailsFormState state(WidgetTester tester) =>
      tester.state<TaxDetailsFormState>(find.byType(TaxDetailsForm));

  group('what the form refuses before LHDN has to', () {
    testWidgets('an empty form has nothing to send', (tester) async {
      await pump(tester);
      expect(state(tester).problem, contains('nothing to send'));
    });

    testWidgets('a TIN on its own is not an answer', (tester) async {
      await pump(tester);
      await tester.enterText(
        find.byKey(const ValueKey('tax-details-tin')),
        'C1234567890',
      );
      await tester.pump();
      expect(state(tester).problem, contains('checks a TIN against'));
    });

    testWidgets('and neither is the number on its own', (tester) async {
      await pump(tester);
      await tester.enterText(
        find.byKey(const ValueKey('tax-details-id-value')),
        '201901000001',
      );
      await tester.pump();
      expect(state(tester).problem, contains('give the TIN as well'));
    });

    testWidgets('the pair is an answer', (tester) async {
      await pump(tester);
      await tester.enterText(
        find.byKey(const ValueKey('tax-details-tin')),
        'C1234567890',
      );
      await tester.enterText(
        find.byKey(const ValueKey('tax-details-id-value')),
        '201901000001',
      );
      await tester.pump();
      expect(state(tester).problem, isNull);
    });

    testWidgets('the Send button is dead while anything is wrong', (
      tester,
    ) async {
      await pump(tester);
      FilledButton button() => tester.widget<FilledButton>(
        find.byKey(const ValueKey('tax-details-send')),
      );
      expect(button().onPressed, isNull);

      await tester.enterText(
        find.byKey(const ValueKey('tax-details-tin')),
        'C1234567890',
      );
      await tester.enterText(
        find.byKey(const ValueKey('tax-details-id-value')),
        '201901000001',
      );
      await tester.pump();
      expect(button().onPressed, isNotNull);
    });
  });

  group('the form starts from what the company already holds', () {
    testWidgets('so a customer corrects rather than retypes', (tester) async {
      await pump(
        tester,
        contact: const {
          'tin': 'C1234567890',
          'id_value': '201901000001',
          'city': 'Shah Alam',
          'state_code': '10',
        },
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('tax-details-tin')))
            .controller!
            .text,
        'C1234567890',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('tax-details-city')))
            .controller!
            .text,
        'Shah Alam',
      );
      // The state too, and it is the one that is easy to lose: it is a
      // dropdown rather than a controller, so pre-filling it is a
      // separate line of code. Left out, a customer correcting their
      // postcode sends a form with no state on it — and the state is
      // the field MyInvois refuses an address without.
      expect(find.text('Selangor'), findsOneWidget);
      // And a pre-filled form has nothing wrong with it, so the customer
      // who only wants to correct one line is not told off first.
      expect(state(tester).problem, isNull);
    });

    testWidgets('and is told when they have answered before', (tester) async {
      await pump(tester, alreadySubmitted: true);
      expect(find.byKey(const ValueKey('tax-details-again')), findsOneWidget);
      await pump(tester);
      expect(find.byKey(const ValueKey('tax-details-again')), findsNothing);
    });

    testWidgets('the state list comes from the server, not from here', (
      tester,
    ) async {
      await pump(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('tax-details-state')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tax-details-state')));
      await tester.pumpAndSettle();
      // What the fixture sent, and only that. A screen holding its own
      // copy of LHDN's codes would offer all sixteen here.
      expect(find.text('Selangor'), findsWidgets);
      expect(
        find.text('Wilayah Persekutuan Kuala Lumpur'),
        findsWidgets,
      );
      expect(find.text('Sabah'), findsNothing);
    });

    testWidgets('and the page says there is no money on it', (tester) async {
      await pump(tester);
      // The words, not the key. A key survives the sentence being
      // rewritten into something that no longer says it, which is
      // exactly what the mutation sweep did to this assertion as first
      // written.
      final line = tester.widget<Text>(
        find.byKey(const ValueKey('tax-details-assurance')),
      );
      expect(line.data, contains('amount owing'));
      expect(line.data, contains('Kedai Buku Sdn Bhd'));
    });
  });

  group('what it says afterwards', () {
    test('a clean answer is finished', () {
      expect(
        taxDetailsThanks(companyName: 'Kedai Buku', awaitingReview: false),
        contains('Nothing else is needed'),
      );
    });

    test('a disagreement is not, and says so', () {
      final m = taxDetailsThanks(
        companyName: 'Kedai Buku',
        awaitingReview: true,
      );
      expect(m, contains('differs from what'));
      expect(m, contains('look at it before it is changed'));
    });

    test('every dead state names itself rather than saying "invalid"', () {
      for (final s in const ['expired', 'revoked', 'withdrawn', 'nonsense']) {
        final m = taxDetailsStateMessage(s);
        expect(m.title, isNotEmpty);
        // Every one of them tells the customer the same thing to DO,
        // because there is nothing else they can do.
        expect(m.body.toLowerCase(), contains('email'));
      }
      expect(taxDetailsStateMessage('expired').title, contains('expired'));
      expect(taxDetailsStateMessage('revoked').title, contains('replaced'));
    });
  });

  group('where the link has got to', () {
    TaxDetailLinkState from(Map<String, dynamic> row) =>
        TaxDetailLinkState.fromRows([row]);

    test('no link at all', () {
      expect(
        taxDetailsLinkStatusLine(TaxDetailLinkState.fromRows(const [])),
        contains('No link is open'),
      );
    });

    test('a revoked one is not a link', () {
      expect(
        from({
          'revoked_at': '2026-01-01T00:00:00Z',
          'expires_at': '2099-01-01T00:00:00Z',
        }).live,
        isFalse,
      );
    });

    test('nor an expired one', () {
      expect(from({'expires_at': '2020-01-01T00:00:00Z'}).live, isFalse);
    });

    // The state worth chasing, and the one a "is a link open?" line
    // cannot show: somebody read the email, opened the page, and
    // stopped.
    test('opened and not answered says both', () {
      final line = taxDetailsLinkStatusLine(
        from({
          'expires_at': '2099-01-01T00:00:00Z',
          'open_count': 3,
          'last_opened_at': '2026-09-01T00:00:00Z',
          'submission_count': 0,
        }),
      );
      expect(line, contains('opened'));
      expect(line, contains('not answered'));
    });

    test('answered says so and stops mentioning opening', () {
      final line = taxDetailsLinkStatusLine(
        from({
          'expires_at': '2099-01-01T00:00:00Z',
          'open_count': 3,
          'submission_count': 1,
        }),
      );
      expect(line, contains('answered'));
      expect(line, isNot(contains('not answered')));
    });

    test('unopened says that rather than nothing', () {
      expect(
        taxDetailsLinkStatusLine(
          from({'expires_at': '2099-01-01T00:00:00Z', 'open_count': 0}),
        ),
        contains('not been opened'),
      );
    });
  });

  group('the prompt before sending one', () {
    test('says what the customer will see and what they will not', () {
      final p = taxDetailsIssuePrompt(
        replacing: false,
        sendingTo: 'ap@buyer.test',
      );
      expect(p, contains('correct them'));
      expect(p, contains('amount owing'));
      expect(p, contains('ap@buyer.test'));
      expect(p, isNot(contains('stops working')));
    });

    test('and says when it kills the link already out there', () {
      expect(
        taxDetailsIssuePrompt(replacing: true),
        contains('stops working'),
      );
    });

    test('a contact with no address is not a refusal', () {
      expect(
        taxDetailsIssuePrompt(replacing: false),
        contains('shown here for you to pass on'),
      );
    });
  });

  group('deciding about what came back', () {
    TaxSubmission sub(List<Map<String, dynamic>> conflicts, {
      List<String> applied = const [],
      String? name,
    }) => TaxSubmission.fromMap({
      'submission_id': 's1',
      'contact_id': 'c1',
      'contact_name': 'Pembeli Sdn Bhd',
      'submitted_at': '2026-09-15T00:00:00Z',
      'submitted_by_name': name,
      'applied_fields': applied,
      'conflicts': conflicts,
    });

    test('a disagreement carries both sides and a readable field name', () {
      final s = sub([
        {
          'field': 'sst_registration_no',
          'theirs': 'W10-9999-31000009',
          'ours': 'W10-1808-31000001',
        },
      ]);
      final line = taxConflictLine(s.conflicts.single);
      expect(line, contains('SST number'));
      expect(line, contains('W10-9999-31000009'));
      expect(line, contains('W10-1808-31000001'));
      // The column name is not a sentence anybody can act on.
      expect(line, isNot(contains('sst_registration_no')));
    });

    test('what was filled in without asking is said out loud', () {
      expect(taxAppliedNote(sub(const [])), isNull);
      expect(
        taxAppliedNote(sub(const [], applied: ['tin'])),
        'TIN was blank and has been filled in from this form.',
      );
      final many = taxAppliedNote(
        sub(const [], applied: ['id_value', 'tin', 'city']),
      );
      // In the order the form asks, not the order the server returned.
      expect(many, startsWith('TIN, ID number and Town or city'));
    });

    test('who said it falls back rather than showing a blank', () {
      expect(sub(const []).byName, isNull);
      expect(
        taxSubmissionWho(sub(const [])),
        startsWith('Somebody at Pembeli Sdn Bhd'),
      );
      expect(taxSubmissionWho(sub(const [], name: 'Siti')), startsWith('Siti'));
    });
  });

  group('every field the form asks about has a name a person can read', () {
    test('and none of them leaks a column name', () {
      for (final f in taxDetailFields) {
        expect(taxFieldLabel(f), isNot(contains('_')));
      }
    });
  });
}
