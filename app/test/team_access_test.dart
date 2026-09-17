import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/team/team_screen.dart';

/// Who may change whose access, and whether the row says so.
///
/// `team_screen.dart` is 831 lines and had no test. The rule it turns
/// on is three conditions long and each prevents something different,
/// which is the sort of thing that is wrong for a year before anybody
/// notices — because being able to do something you should not is not a
/// thing the person doing it reports.
///
/// The server refuses all three as well and is the authority. What is
/// asserted here is that the SCREEN agrees with it, so a control is not
/// offered whose only possible outcome is an error message.
void main() {
  TeamMember member({
    String id = 'm1',
    String role = 'accounts_clerk',
    String? userId = 'u1',
    String name = 'Aminah binti Hassan',
    String status = 'active',
  }) => TeamMember(
    memberId: id,
    role: role,
    status: status,
    userId: userId,
    email: 'aminah@example.test',
    fullName: name,
  );

  group('the rule itself', () {
    test('an admin may edit an ordinary member', () {
      expect(
        memberIsEditable(canAdmin: true, isSelf: false, role: 'accounts_clerk'),
        isTrue,
      );
    });

    test('somebody who is not an admin may edit nobody', () {
      // Including a row they would otherwise be allowed to touch, which
      // is what makes this the first condition rather than an extra one.
      expect(
        memberIsEditable(canAdmin: false, isSelf: false, role: 'viewer'),
        isFalse,
      );
    });

    test('an admin may not edit their own row', () {
      // An admin who demotes themselves by accident has locked the
      // company out of its own administration, and there may be nobody
      // left who can undo it.
      expect(
        memberIsEditable(canAdmin: true, isSelf: true, role: 'admin'),
        isFalse,
      );
    });

    test('and nobody edits the owner from a list', () {
      // Ownership is transferred deliberately. It is not a line in a
      // dropdown.
      expect(
        memberIsEditable(canAdmin: true, isSelf: false, role: 'owner'),
        isFalse,
      );
    });

    test('every combination, so no condition is carrying the others', () {
      // Eight cases. Only one is true, and naming which makes a rule
      // that quietly became `canAdmin` alone fail here.
      final allowed = <String>[];
      for (final canAdmin in [true, false]) {
        for (final isSelf in [true, false]) {
          for (final role in ['owner', 'admin']) {
            if (memberIsEditable(
              canAdmin: canAdmin,
              isSelf: isSelf,
              role: role,
            )) {
              allowed.add('$canAdmin/$isSelf/$role');
            }
          }
        }
      }

      expect(allowed, ['true/false/admin']);
    });
  });

  group('what may be assigned', () {
    test('owner is not on the list', () {
      // An admin promoting somebody to owner is a privilege escalation
      // out of a dropdown. `assignableRoles` is the one place that
      // decides it, for the invite dialog and the row alike.
      expect(assignableRoles.map((e) => e.key), isNot(contains('owner')));
    });

    test('but the ordinary roles are', () {
      // The control. Without it the assertion above passes against an
      // empty list, and a company could not give anybody any access at
      // all.
      final keys = assignableRoles.map((e) => e.key);
      expect(keys, contains('admin'));
      expect(keys, contains('accounts_clerk'));
      expect(keys, contains('viewer'));
      expect(keys.length, greaterThan(4));
    });
  });

  group('the row on the screen', () {
    Widget wrap(
      List<TeamMember> members, {
      bool canAdmin = true,
      String? meId = 'someone-else',
    }) => ProviderScope(
      overrides: [
        teamProvider.overrideWith((ref) async => members),
        canAdminProvider.overrideWithValue(canAdmin),
        currentUserProvider.overrideWithValue(
          meId == null
              ? null
              : User(
                  id: meId,
                  appMetadata: const {},
                  userMetadata: const {},
                  aud: 'authenticated',
                  createdAt: DateTime(2026).toIso8601String(),
                ),
        ),
        repoProvider.overrideWithValue(null),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const TeamScreen()),
    );

    /// Scoped to the member list rather than the whole screen: the role
    /// reference card at the foot of it names every role too.
    Finder inRow(Finder f) =>
        find.descendant(of: find.byType(ListTile), matching: f);

    Future<void> show(
      WidgetTester tester,
      List<TeamMember> members, {
      bool canAdmin = true,
      String? meId = 'someone-else',
      double width = 1280,
    }) async {
      tester.view.devicePixelRatio = 1.0;
      // Browser viewports, not screen sizes.
      tester.view.physicalSize = Size(width, 720);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        wrap(members, canAdmin: canAdmin, meId: meId),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('an admin sees the controls on somebody else', (tester) async {
      await show(tester, [member()]);

      expect(find.byType(DropdownButton<String>), findsOneWidget);
      expect(find.byTooltip('Remove from company'), findsOneWidget);
      expect(find.byTooltip('Access type'), findsOneWidget);
    });

    testWidgets('and none of them on their own row', (tester) async {
      await show(tester, [member(userId: 'me')], meId: 'me');

      expect(find.byType(DropdownButton<String>), findsNothing);
      expect(find.byTooltip('Remove from company'), findsNothing);
      // The role is still SHOWN, just not editable — the row has to say
      // what this person is. Scoped to the row: `_RoleReference` at the
      // foot of the screen lists every label as well, so an unscoped
      // finder matches the glossary rather than the person.
      expect(inRow(find.text('Accounts Clerk')), findsOneWidget);
      // `StatusChip` puts its label through `Fmt.label`, which
      // capitalises it.
      expect(find.text('You'), findsOneWidget);
    });

    testWidgets('the owner gets no dropdown either', (tester) async {
      await show(tester, [member(role: 'owner', userId: 'u9')]);

      expect(find.byType(DropdownButton<String>), findsNothing);
      expect(inRow(find.text('Owner')), findsOneWidget);
    });

    testWidgets('and somebody who is not an admin sees no controls at all',
        (tester) async {
      await show(tester, [member()], canAdmin: false);

      expect(find.byType(DropdownButton<String>), findsNothing);
      expect(find.byTooltip('Remove from company'), findsNothing);
      expect(find.text('Invite'), findsNothing);
      // But can still see who is in the company, which is the point of
      // withholding the controls rather than the screen.
      expect(find.text('Aminah binti Hassan'), findsOneWidget);
    });

    testWidgets('a pending invitation is marked as one', (tester) async {
      // `TeamMember.isPending` reads `status == 'invited'`, which is
      // what `invite_member` writes. 'pending' is the word on the chip,
      // not the word in the column.
      await show(tester, [member(status: 'invited', userId: null)]);

      expect(find.text('Pending'), findsOneWidget);
    });

    for (final width in [360.0, 412.0, 600.0, 900.0]) {
      testWidgets('the row fits at ${width.toInt()} with every control on it',
          (tester) async {
        // A `DropdownButton` sizes itself to its WIDEST item — "Company
        // Admin" here — and a `ListTile` gives its trailing whatever it
        // asks for and the title what is left. That combination has
        // already shipped once in this app as a name rendered one
        // letter per line.
        //
        // Rendering IS the assertion: a RenderFlex overflow is a test
        // failure. What the name check adds is that the title was not
        // squeezed to nothing to achieve it.
        await show(
          tester,
          [member(name: 'Aminah binti Hassan')],
          width: width,
        );

        final title = tester.getSize(find.text('Aminah binti Hassan'));
        expect(title.width, greaterThan(60),
            reason: 'the name has room at $width');
      });
    }
  });
}
