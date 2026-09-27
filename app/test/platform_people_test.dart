import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/admin/organization_admin_dialogs.dart';
import 'package:iakauntan/src/features/admin/platform_console_screen.dart';
import 'package:iakauntan/src/features/admin/support_access_admin.dart';
import 'package:iakauntan/src/features/admin/users_admin.dart';

/// The console's three new pages and the banner that goes with them.
/// `0719`, `0720`, `0721`.
///
/// What is asserted here is the SCREEN half: which call a button makes,
/// with what, and what somebody is told when it refuses. The rules —
/// that a support session expires, that the last owner cannot be
/// removed, that a reason is required, that suspending yourself is
/// refused — are in `supabase/tests/support_access.sql`,
/// `platform_org_access.sql` and `platform_users.sql`, because a rule
/// enforced only in Dart is not enforced.
void main() {
  Widget wrap(Widget child, {required _FakePlatform platform}) => ProviderScope(
        overrides: [
          platformRepoProvider.overrideWithValue(platform),
          isPlatformAdminProvider.overrideWith((_) async => true),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: child),
        ),
      );

  group('the register of people', () {
    testWidgets('lists them, with what each one is', (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(wrap(const UsersAdminTab(), platform: platform));
      await tester.pumpAndSettle();

      expect(find.text('Aisyah Rahman'), findsOneWidget);
      // Somebody with no name is shown by the address they sign in with
      // rather than by a blank row.
      expect(find.text('nameless@example.com'), findsOneWidget);
      // The two tags are the two things that change what an account is.
      expect(find.text('Platform'), findsOneWidget);
      expect(find.text('Suspended'), findsOneWidget);
    });

    testWidgets('says "never signed in" rather than a dash', (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(wrap(const UsersAdminTab(), platform: platform));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('never signed in'),
        findsOneWidget,
        reason: 'somebody who never arrived is not somebody seen long ago',
      );
    });

    testWidgets('asks again only when the search is submitted', (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(wrap(const UsersAdminTab(), platform: platform));
      await tester.pumpAndSettle();
      expect(platform.queries, ['']);

      // Typing is not asking. The list is every user on the platform and
      // a round trip per keystroke would be six of them for a surname.
      await tester.enterText(find.byKey(const ValueKey('users-search')), 'ais');
      await tester.pumpAndSettle();
      expect(platform.queries, ['']);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(platform.queries, ['', 'ais']);
    });

    testWidgets('an empty list reads differently when something was searched',
        (tester) async {
      final platform = _FakePlatform(people: const []);
      await tester.pumpWidget(wrap(const UsersAdminTab(), platform: platform));
      await tester.pumpAndSettle();
      expect(find.text('Nobody here yet'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('users-search')), 'zz');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Nobody matches that'), findsOneWidget);
    });
  });

  group('adding a person', () {
    testWidgets('will not send until there is an address and ten characters',
        (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(wrap(const UsersAdminTab(), platform: platform));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('users-add')));
      await tester.pumpAndSettle();

      Widget button() => tester.widget(find.byKey(const ValueKey('new-user-save')));
      expect((button() as FilledButton).onPressed, isNull);

      // A long password and no address: the other half of the guard, and
      // the half a mutant removes without this assertion noticing.
      await tester.enterText(
          find.byKey(const ValueKey('new-user-password')), 'long enough one');
      await tester.pumpAndSettle();
      expect((button() as FilledButton).onPressed, isNull,
          reason: 'a password is not an account');
      await tester.enterText(
          find.byKey(const ValueKey('new-user-password')), '');
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const ValueKey('new-user-email')), 'new@example.com');
      await tester.pumpAndSettle();
      expect((button() as FilledButton).onPressed, isNull,
          reason: 'an address alone is not a password');

      // Nine characters is one short of what the edge function accepts,
      // and a form that sends it makes the refusal arrive from the
      // server instead of from the box.
      await tester.enterText(
          find.byKey(const ValueKey('new-user-password')), '123456789');
      await tester.pumpAndSettle();
      expect((button() as FilledButton).onPressed, isNull);

      await tester.enterText(
          find.byKey(const ValueKey('new-user-password')), '1234567890');
      await tester.pumpAndSettle();
      expect((button() as FilledButton).onPressed, isNotNull);
    });

    testWidgets('sends what was typed, and the password nowhere else',
        (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(wrap(const UsersAdminTab(), platform: platform));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('users-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('new-user-email')), ' new@example.com ');
      await tester.enterText(
          find.byKey(const ValueKey('new-user-name')), 'New Person');
      await tester.enterText(
          find.byKey(const ValueKey('new-user-password')), 'correct horse');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-user-save')));
      await tester.pumpAndSettle();

      expect(platform.created, {
        'email': 'new@example.com',
        'password': 'correct horse',
        'full_name': 'New Person',
      });
      // And the list is asked again, or the person just added is not there.
      expect(platform.queries, ['', '']);
    });

    testWidgets('a refusal is shown in the dialog, not behind it',
        (tester) async {
      final platform = _FakePlatform(
        onCreate: () => throw const _Refused(
            'A user with this email address has already been registered'),
      );
      await tester.pumpWidget(wrap(const UsersAdminTab(), platform: platform));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('users-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('new-user-email')), 'taken@example.com');
      await tester.enterText(
          find.byKey(const ValueKey('new-user-password')), '1234567890');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-user-save')));
      await tester.pumpAndSettle();

      // The dialog is still open, with the sentence under the box it is
      // about — a message that outlives its form is a message nobody
      // connects to anything.
      expect(find.byKey(const ValueKey('new-user-problem')), findsOneWidget);
      expect(
        find.textContaining('already been registered'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('new-user-email')), findsOneWidget);
    });
  });

  group('one person', () {
    Future<_FakePlatform> open(WidgetTester tester,
        {bool suspended = false}) async {
      final platform = _FakePlatform(people: [
        {
          'user_id': 'u1',
          'full_name': 'Aisyah Rahman',
          'email': 'aisyah@example.com',
          'phone': '0123456789',
          'company_count': 2,
          'suspended': suspended,
          'is_platform_admin': false,
          'last_sign_in_at': '2026-09-01T02:00:00Z',
        },
      ]);
      await tester.pumpWidget(wrap(const UsersAdminTab(), platform: platform));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('user-u1')));
      await tester.pumpAndSettle();
      return platform;
    }

    testWidgets('shows which companies they can open, and as what',
        (tester) async {
      await open(tester);
      expect(find.text('Sinar Teknologi'), findsOneWidget);
      expect(find.textContaining('owner'), findsOneWidget);
      // A demo company is marked, because taking somebody out of one is
      // not the same decision as taking them out of their real books.
      expect(find.textContaining('demo'), findsOneWidget);
    });

    testWidgets('saves the name and phone through the SQL call',
        (tester) async {
      final platform = await open(tester);
      await tester.enterText(
          find.byKey(const ValueKey('person-name')), 'Aisyah binti Rahman');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('person-save')));
      await tester.pumpAndSettle();

      expect(platform.updatedUser, {
        'user_id': 'u1',
        'full_name': 'Aisyah binti Rahman',
        'phone': '0123456789',
      });
    });

    testWidgets('takes a company away', (tester) async {
      final platform = await open(tester);
      await tester
          .tap(find.byKey(const ValueKey('person-org-remove-o1')));
      await tester.pumpAndSettle();

      expect(platform.removed, {'org_id': 'o1', 'user_id': 'u1'});
    });

    testWidgets('sets a password, and only one at least ten long',
        (tester) async {
      final platform = await open(tester);
      await tester.tap(find.byKey(const ValueKey('person-password')));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const ValueKey('set-password-field')), 'short');
      await tester.pumpAndSettle();
      expect(
        (tester.widget(find.byKey(const ValueKey('set-password-save')))
                as FilledButton)
            .onPressed,
        isNull,
      );

      await tester.enterText(
          find.byKey(const ValueKey('set-password-field')), 'long enough one');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('set-password-save')));
      await tester.pumpAndSettle();

      expect(platform.passwordSet,
          {'user_id': 'u1', 'password': 'long enough one'});
    });

    testWidgets('asks before suspending somebody', (tester) async {
      final platform = await open(tester);
      await tester.tap(find.byKey(const ValueKey('person-suspend')));
      await tester.pumpAndSettle();

      // Nothing has happened yet: it is a question first.
      expect(platform.suspended, isNull);
      expect(find.text('Suspend this person?'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Suspend'));
      await tester.pumpAndSettle();
      expect(platform.suspended, {'user_id': 'u1', 'suspended': true});
    });

    testWidgets('letting somebody back in is not a question', (tester) async {
      // Asking "are you sure you want to undo the harm" is a confirmation
      // for nothing, and the row already says Suspended.
      final platform = await open(tester, suspended: true);
      expect(find.text('Let back in'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('person-suspend')));
      await tester.pumpAndSettle();
      expect(platform.suspended, {'user_id': 'u1', 'suspended': false});
    });
  });

  group('who can open a company', () {
    testWidgets('lists them and takes one away', (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(wrap(
        const OrgMembersPanel(orgId: 'o1', orgName: 'Sinar Teknologi'),
        platform: platform,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Aisyah Rahman'), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('org-member-remove-u1')));
      await tester.pumpAndSettle();
      expect(platform.removed, {'org_id': 'o1', 'user_id': 'u1'});
    });

    testWidgets('gives somebody access as the role that was chosen',
        (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(wrap(
        const OrgMembersPanel(orgId: 'o1', orgName: 'Sinar Teknologi'),
        platform: platform,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('org-member-add-o1')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('assign-email')), 'new@example.com');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('assign-role')));
      await tester.pumpAndSettle();
      // The role that reads everything and changes nothing, which is the
      // one an auditor gets and the reason the enum has ten entries
      // rather than three.
      await tester.tap(find.text('Auditor').last);
      await tester.pumpAndSettle();

      // The picker carries a NAME; what it means is the line under it.
      // The explanation used to be inside the dropdown item and
      // overflowed it by 49 pixels, which Flutter paints as stripes over
      // the words that did not fit.
      expect(find.text('Reads the ledger and changes nothing'),
          findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('assign-save')));
      await tester.pumpAndSettle();

      expect(platform.assigned, {
        'org_id': 'o1',
        'email': 'new@example.com',
        'role': 'auditor',
      });
    });

    testWidgets('and shows the refusal where the form is', (tester) async {
      final platform = _FakePlatform(
        onAssign: () => throw const _Refused(
            'A company must keep an owner. Make somebody else an owner '
            'first.'),
      );
      await tester.pumpWidget(wrap(
        const AssignAccessDialog(orgId: 'o1', orgName: 'Sinar Teknologi'),
        platform: platform,
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const ValueKey('assign-email')), 'a@example.com');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('assign-save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('assign-problem')), findsOneWidget);
      expect(find.textContaining('must keep an owner'), findsOneWidget);
    });
  });

  group('making a company for somebody', () {
    testWidgets('needs an owner who is already here, and a name',
        (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(
          wrap(const NewOrganizationDialog(), platform: platform));
      await tester.pumpAndSettle();

      FilledButton save() =>
          tester.widget(find.byKey(const ValueKey('new-org-save')));
      expect(save().onPressed, isNull);

      // A name and nobody to own it. The database refuses a company with
      // no owner, and a form that sends one turns a rule into an error
      // message arriving a second later.
      await tester.enterText(
          find.byKey(const ValueKey('new-org-name')), 'Baru Sdn Bhd');
      await tester.pumpAndSettle();
      expect(save().onPressed, isNull, reason: 'a company needs an owner');

      // And the other way round: an owner and no name.
      await tester.enterText(find.byKey(const ValueKey('new-org-name')), '');
      await tester.enterText(
          find.byKey(const ValueKey('new-org-owner')), 'owner@example.com');
      await tester.pumpAndSettle();
      expect(save().onPressed, isNull, reason: 'a company needs a name');

      // Whitespace is not a name either.
      await tester.enterText(find.byKey(const ValueKey('new-org-name')), '  ');
      await tester.pumpAndSettle();
      expect(save().onPressed, isNull);

      await tester.enterText(
          find.byKey(const ValueKey('new-org-name')), 'Baru Sdn Bhd');
      await tester.pumpAndSettle();
      expect(save().onPressed, isNotNull);

      await tester.tap(find.byKey(const ValueKey('new-org-save')));
      await tester.pumpAndSettle();
      expect(platform.createdOrg, {
        'owner_email': 'owner@example.com',
        'name': 'Baru Sdn Bhd',
        'registration_no': '',
      });
    });

    testWidgets('and a refusal stays where the form is', (tester) async {
      // "Nobody here has that e-mail address. Add the person first." is
      // about the box at the top of this dialog. A snackbar behind a
      // dialog somebody is still looking at is a message nobody connects
      // to anything.
      final platform = _FakePlatform(
        onCreateOrg: () => throw const _Refused(
            'Nobody here has that e-mail address. Add the person first.'),
      );
      await tester.pumpWidget(
          wrap(const NewOrganizationDialog(), platform: platform));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const ValueKey('new-org-owner')), 'nobody@example.com');
      await tester.enterText(
          find.byKey(const ValueKey('new-org-name')), 'Baru Sdn Bhd');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-org-save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('new-org-problem')), findsOneWidget);
      expect(find.textContaining('Add the person first'), findsOneWidget);
      // And the dialog is still open, with what was typed still in it.
      expect(find.byKey(const ValueKey('new-org-owner')), findsOneWidget);
    });

    testWidgets('says the administrator will not be a member', (tester) async {
      // The whole point of `0719`'s delete: an operator who made a
      // hundred companies for customers would otherwise hold standing
      // access to all hundred.
      await tester.pumpWidget(
          wrap(const NewOrganizationDialog(), platform: _FakePlatform()));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('You will not be a member of it'),
        findsOneWidget,
      );
    });

    testWidgets('editing says a blank box is left alone', (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(wrap(
        const EditOrganizationDialog(
            orgId: 'o1', name: 'Sinar Teknologi', registrationNo: '123456-X'),
        platform: platform,
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('left blank is left alone'), findsOneWidget);
      // And the boxes arrive filled, so somebody editing a phone number
      // does not have to retype the name.
      expect(find.text('Sinar Teknologi'), findsOneWidget);
      expect(find.text('123456-X'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('edit-org-phone')), '03-1234 5678');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('edit-org-save')));
      await tester.pumpAndSettle();

      expect(platform.updatedOrg?['org_id'], 'o1');
      expect(platform.updatedOrg?['phone'], '03-1234 5678');
      expect(platform.updatedOrg?['name'], 'Sinar Teknologi');
    });
  });

  group('opening a support session', () {
    testWidgets('will not start without a reason', (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(wrap(
        const GrantSupportDialog(orgId: 'o1', orgName: 'Sinar Teknologi'),
        platform: platform,
      ));
      await tester.pumpAndSettle();

      FilledButton start() =>
          tester.widget(find.byKey(const ValueKey('support-start')));
      expect(start().onPressed, isNull);

      // Whitespace is not a reason. The database refuses it too, and a
      // button that sends it turns a rule into an error message.
      await tester.enterText(
          find.byKey(const ValueKey('support-reason')), '   ');
      await tester.pumpAndSettle();
      expect(start().onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('support-reason')),
          'Ticket 412: their bank reconciliation is out');
      await tester.pumpAndSettle();
      expect(start().onPressed, isNotNull);
    });

    testWidgets('sends the length that was chosen, not the default',
        (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(wrap(
        const GrantSupportDialog(orgId: 'o1', orgName: 'Sinar Teknologi'),
        platform: platform,
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const ValueKey('support-reason')), 'Ticket 412');
      await tester.tap(find.byKey(const ValueKey('support-minutes-15')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('support-start')));
      await tester.pumpAndSettle();

      expect(platform.granted,
          {'org_id': 'o1', 'reason': 'Ticket 412', 'minutes': 15});
    });

    testWidgets('says out loud that it is read-only and ends on its own',
        (tester) async {
      await tester.pumpWidget(wrap(
        const GrantSupportDialog(orgId: 'o1', orgName: 'Sinar Teknologi'),
        platform: _FakePlatform(),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('read everything and change'),
          findsOneWidget);
      expect(find.textContaining('ends on its own'), findsOneWidget);
    });
  });

  group('the record of support sessions', () {
    final now = DateTime.utc(2026, 9, 27, 12);

    test('a session ends three ways and the list agrees on all three', () {
      Map<String, dynamic> s({String? ended, required String expires}) => {
            'ended_at': ended,
            'expires_at': expires,
          };

      expect(isSessionOpen(s(expires: '2026-09-27T13:00:00Z'), now), isTrue);
      expect(isSessionOpen(s(expires: '2026-09-27T11:00:00Z'), now), isFalse,
          reason: 'expired is not open, whatever nobody pressed');
      expect(
        isSessionOpen(
            s(ended: '2026-09-27T11:30:00Z', expires: '2026-09-27T13:00:00Z'),
            now),
        isFalse,
        reason: 'ended by hand, before its time',
      );
      // A row with no expiry at all is not a session that never ends.
      expect(isSessionOpen(s(expires: 'not a date'), now), isFalse);
    });

    test('and says which of the three it was', () {
      expect(
        sessionState({'expires_at': '2026-09-27T12:30:00Z'}, now),
        '30 min left',
      );
      expect(
        sessionState({'expires_at': '2026-09-27T20:00:00Z'}, now),
        startsWith('until '),
      );
      expect(sessionState({'expires_at': '2026-09-27T11:00:00Z'}, now),
          'expired');
      expect(
        sessionState({
          'ended_at': '2026-09-27T11:00:00Z',
          'expires_at': '2026-09-27T13:00:00Z',
        }, now),
        'ended',
      );
    });

    testWidgets('shows the reason in full, and only offers to end a live one',
        (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(
          wrap(const SupportAccessAdminTab(), platform: platform));
      await tester.pumpAndSettle();

      // Never truncated: the reason is the whole difference between
      // support and a back door, and one nobody can read afterwards is
      // one nobody gave.
      expect(
        find.text('Ticket 412: their bank reconciliation is out'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('support-end-s1')), findsOneWidget);
      expect(find.byKey(const ValueKey('support-end-s2')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('support-end-s1')));
      await tester.pumpAndSettle();
      expect(platform.ended, 's1');
    });
  });

  group('the banner', () {
    final now = DateTime.utc(2026, 9, 27, 12);

    test('names the company when there is one of them', () {
      final text = supportBannerText([
        {
          'org_name': 'Sinar Teknologi',
          'expires_at': '2026-09-27T12:30:00Z',
        },
      ], now);
      expect(text, contains('Sinar Teknologi'));
      expect(text, contains('30 min left'));
    });

    test('and counts them when there are more', () {
      // Three companies do not fit on a phone, and the page behind the
      // button has them in full.
      final text = supportBannerText([
        {'org_name': 'A', 'expires_at': '2026-09-27T13:00:00Z'},
        {'org_name': 'B', 'expires_at': '2026-09-27T13:00:00Z'},
      ], now);
      expect(text, contains('2 companies'));
      expect(text, isNot(contains('A')));
    });

    testWidgets('one session offers the way out of it', (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(wrap(
        SupportAccessBanner(sessions: [
          {
            'id': 's1',
            'org_name': 'Sinar Teknologi',
            'expires_at': DateTime.now()
                .add(const Duration(minutes: 30))
                .toIso8601String(),
          },
        ]),
        platform: platform,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('support-banner-leave')));
      await tester.pumpAndSettle();
      expect(platform.ended, 's1');

      // EQUIVALENT MUTANT, not a gap: ending `sessions.last` instead of
      // the one session survives this file, because the button only
      // exists where the list has one entry and first IS last. The
      // mutant above it — several sessions all offering one Leave button
      // — is the one that can be observed, and it is killed.
    });

    testWidgets('several do not, because it would have to guess which',
        (tester) async {
      final platform = _FakePlatform();
      await tester.pumpWidget(wrap(
        SupportAccessBanner(sessions: [
          {'id': 's1', 'org_name': 'A', 'expires_at': '2026-12-01T00:00:00Z'},
          {'id': 's2', 'org_name': 'B', 'expires_at': '2026-12-01T00:00:00Z'},
        ]),
        platform: platform,
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('support-banner-leave')), findsNothing);
      expect(find.byKey(const ValueKey('support-banner-open')), findsOneWidget);
      expect(platform.ended, isNull);
    });
  });

  group('both pages are reachable', () {
    // A console page nothing routes to is a page nobody finds, and that
    // failure is silent: the file compiles, the tests pass, and the menu
    // has no row for it.
    test('the register of people is a section of its own', () {
      final section = platformConsoleSections
          .firstWhere((s) => s.page is UsersAdminTab);
      expect(section.group, 'Platform');
      expect(section.label, 'Users');
      expect(section.path, '/admin/users');
    });

    test('and so is the support-access record', () {
      final section = platformConsoleSections
          .firstWhere((s) => s.page is SupportAccessAdminTab);
      expect(section.group, 'Platform');
      expect(section.label, 'Support access');
      expect(section.path, '/admin/support-access');
    });
  });
}

/// A refusal shaped like the ones these calls really make: a sentence
/// written for a person, which [errorText] passes through.
class _Refused implements Exception {
  const _Refused(this.message);
  final String message;
  @override
  String toString() => message;
}

class _FakePlatform implements PlatformRepo {
  _FakePlatform({
    this.people,
    this.onCreate,
    this.onAssign,
    this.onCreateOrg,
  });

  final List<Map<String, dynamic>>? people;
  final void Function()? onCreate;
  final void Function()? onAssign;
  final void Function()? onCreateOrg;

  /// Every query the list has been asked for, in order. The assertion is
  /// as much about the LENGTH as the contents: a round trip per keystroke
  /// is what this page must not do.
  final List<String> queries = [];

  Map<String, Object?>? created;
  Map<String, Object?>? createdOrg;
  Map<String, Object?>? updatedUser;
  Map<String, Object?>? updatedOrg;
  Map<String, Object?>? removed;
  Map<String, Object?>? assigned;
  Map<String, Object?>? granted;
  Map<String, Object?>? passwordSet;
  Map<String, Object?>? suspended;
  String? ended;

  @override
  Future<List<Map<String, dynamic>>> platformUsers({
    String? query,
    int limit = 50,
  }) async {
    queries.add(query ?? '');
    return people ??
        const [
          {
            'user_id': 'u1',
            'full_name': 'Aisyah Rahman',
            'email': 'aisyah@example.com',
            'phone': '0123456789',
            'company_count': 2,
            'suspended': false,
            'is_platform_admin': true,
            'last_sign_in_at': '2026-09-26T02:00:00Z',
          },
          {
            'user_id': 'u2',
            'full_name': '',
            'email': 'nameless@example.com',
            'company_count': 0,
            'suspended': true,
            'is_platform_admin': false,
            'last_sign_in_at': null,
          },
        ];
  }

  @override
  Future<void> platformUpdateUser({
    required String userId,
    String? fullName,
    String? phone,
  }) async {
    updatedUser = {
      'user_id': userId,
      'full_name': fullName,
      'phone': phone,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> platformUserOrganizations(
          String userId) async =>
      const [
        {
          'org_id': 'o1',
          'org_name': 'Sinar Teknologi',
          'role': 'owner',
          'is_demo': false,
        },
        {
          'org_id': 'o2',
          'org_name': 'Demo Enterprise',
          'role': 'viewer',
          'is_demo': true,
        },
      ];

  @override
  Future<List<Map<String, dynamic>>> platformOrgMembers(String orgId) async =>
      const [
        {
          'user_id': 'u1',
          'full_name': 'Aisyah Rahman',
          'email': 'aisyah@example.com',
          'role': 'owner',
        },
      ];

  @override
  Future<void> platformAssignOrgAccess({
    required String orgId,
    required String email,
    required String role,
  }) async {
    onAssign?.call();
    assigned = {'org_id': orgId, 'email': email, 'role': role};
  }

  @override
  Future<void> platformRemoveOrgAccess({
    required String orgId,
    required String userId,
  }) async {
    removed = {'org_id': orgId, 'user_id': userId};
  }

  @override
  Future<String> platformCreateOrganization({
    required String ownerEmail,
    required String name,
    String entityType = 'sdn_bhd',
    String? registrationNo,
    String? tin,
    String? stateCode,
    String? city,
    String? phone,
    String? email,
  }) async {
    onCreateOrg?.call();
    createdOrg = {
      'owner_email': ownerEmail,
      'name': name,
      'registration_no': registrationNo,
    };
    return 'o9';
  }

  @override
  Future<void> platformUpdateOrganization({
    required String orgId,
    String? name,
    String? legalName,
    String? registrationNo,
    String? tin,
    String? phone,
    String? email,
    String? city,
    String? stateCode,
  }) async {
    updatedOrg = {
      'org_id': orgId,
      'name': name,
      'registration_no': registrationNo,
      'phone': phone,
      'email': email,
    };
  }

  @override
  Future<String> grantSupportAccess({
    required String orgId,
    required String reason,
    int minutes = 60,
  }) async {
    granted = {'org_id': orgId, 'reason': reason, 'minutes': minutes};
    return 's9';
  }

  @override
  Future<void> endSupportAccess(String id) async {
    ended = id;
  }

  @override
  Future<List<Map<String, dynamic>>> mySupportAccess() async => const [];

  @override
  Future<List<Map<String, dynamic>>> platformSupportAccess({
    int limit = 100,
  }) async =>
      const [
        {
          'id': 's1',
          'org_name': 'Sinar Teknologi',
          'admin_name': 'Support',
          'reason': 'Ticket 412: their bank reconciliation is out',
          'granted_at': '2026-09-27T11:00:00Z',
          // Far enough out that the row is open whenever this runs.
          'expires_at': '2099-01-01T00:00:00Z',
        },
        {
          'id': 's2',
          'org_name': 'Demo Enterprise',
          'admin_name': 'Support',
          'reason': 'Ticket 399: payroll question',
          'granted_at': '2026-09-20T11:00:00Z',
          'expires_at': '2026-09-20T12:00:00Z',
          'ended_at': '2026-09-20T11:20:00Z',
        },
      ];

  @override
  Future<String> platformCreateUser({
    required String email,
    required String password,
    String? fullName,
  }) async {
    onCreate?.call();
    created = {'email': email, 'password': password, 'full_name': fullName};
    return 'u9';
  }

  @override
  Future<void> platformSetPassword({
    required String userId,
    required String password,
  }) async {
    passwordSet = {'user_id': userId, 'password': password};
  }

  @override
  Future<void> platformSetSuspended({
    required String userId,
    required bool suspended,
  }) async {
    this.suspended = {'user_id': userId, 'suspended': suspended};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'the console pages called PlatformRepo.${invocation.memberName}, '
        'which this fake does not answer',
      );
}
