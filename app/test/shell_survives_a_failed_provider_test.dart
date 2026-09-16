import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

/// The shell has to survive a provider that FAILED, not merely one that
/// has not answered yet.
///
/// `AsyncError.value` throws — riverpod's own doc comment says so — so
/// `ref.watch(p).value ?? const []` never runs its fallback when the
/// load failed. Everywhere else in this app that costs one screen. Here
/// it costs the navigation: `_visible` builds the rail, so a failed
/// `organizationsProvider` left nothing on screen but grey, on every
/// route at once, with no rail to navigate away with and no way back
/// but reloading the page.
///
/// A network that drops for a second is enough to produce it, which is
/// why this is asserted rather than reasoned about. Each test puts ONE
/// provider into an error state and asks for the shell.
void main() {
  /// A provider that has failed, not one that is loading.
  Future<T> fails<T>() => Future<T>.error(StateError('the network went'));

  Widget harness({
    bool platformAdminFails = false,
    bool organizationsFail = false,
    bool firmsFail = false,
    bool currentOrgFails = false,
    bool memberRoleFails = false,
    bool modulesFail = false,
    Size size = const Size(1400, 900),
  }) =>
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWithValue(null),
          authStateProvider
              .overrideWith((_) => const Stream<AuthState>.empty()),
          isPlatformAdminProvider.overrideWith(
            (_) => platformAdminFails ? fails<bool>() : Future.value(true),
          ),
          organizationsProvider.overrideWith(
            (_) => organizationsFail ? fails() : Future.value(const []),
          ),
          myFirmsProvider.overrideWith(
            (_) => firmsFail ? fails() : Future.value(const []),
          ),
          currentOrgProvider.overrideWith(
            (_) => currentOrgFails ? fails() : Future.value(null),
          ),
          memberRoleProvider.overrideWith(
            (_) => memberRoleFails ? fails<String>() : Future.value(''),
          ),
          enabledModulesProvider.overrideWith(
            (_) => modulesFail ? fails() : Future.value(const <String>{}),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const AppShell(
            location: '/admin',
            child: Scaffold(body: Text('the screen')),
          ),
        ),
      );

  Future<void> show(WidgetTester tester, Widget w, {Size? size}) async {
    tester.view.devicePixelRatio = 1.0;
    // A browser viewport, not a screen size.
    tester.view.physicalSize = size ?? const Size(1400, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pumpAndSettle();
  }

  /// What a thrown build looks like from a test: the exception escapes
  /// into `takeException`, and the screen under the shell is gone.
  void expectShellStandsUp(WidgetTester tester) {
    expect(
      tester.takeException(),
      isNull,
      reason: 'the shell threw out of build — there is no navigation left',
    );
    expect(find.text('the screen'), findsOneWidget);
  }

  testWidgets('a failed company list does not take the shell down', (
    tester,
  ) async {
    await show(tester, harness(organizationsFail: true));
    expectShellStandsUp(tester);
  });

  testWidgets('nor a failed platform-admin answer', (tester) async {
    await show(tester, harness(platformAdminFails: true));
    expectShellStandsUp(tester);
  });

  testWidgets('nor a failed practice list', (tester) async {
    await show(tester, harness(firmsFail: true));
    expectShellStandsUp(tester);
  });

  testWidgets('nor a failed current company', (tester) async {
    await show(tester, harness(currentOrgFails: true));
    expectShellStandsUp(tester);
  });

  testWidgets('nor a failed role', (tester) async {
    await show(tester, harness(memberRoleFails: true));
    expectShellStandsUp(tester);
  });

  testWidgets('nor a failed module list', (tester) async {
    await show(tester, harness(modulesFail: true));
    expectShellStandsUp(tester);
  });

  testWidgets('all of them at once', (tester) async {
    // The case a dropped connection actually produces: everything the
    // shell reads fails together, not one thing at a time.
    await show(
      tester,
      harness(
        platformAdminFails: true,
        organizationsFail: true,
        firmsFail: true,
        currentOrgFails: true,
        memberRoleFails: true,
        modulesFail: true,
      ),
    );
    expectShellStandsUp(tester);
  });

  testWidgets('and on a phone, where the rail is a bar', (tester) async {
    // A different widget builds the destinations at this width, and it
    // reads the same providers.
    await show(
      tester,
      harness(organizationsFail: true, firmsFail: true),
      size: const Size(500, 900),
    );
    expectShellStandsUp(tester);
  });

  group('what a failed role is taken to mean', () {
    /// The permission gates read directly, because "the shell did not
    /// throw" says nothing about WHICH menu it drew. A failure that
    /// fell back to owner would be an admin rail in front of somebody
    /// whose role could not be read — quieter than a crash and worse.
    /// A container whose role and company have ALREADY FAILED.
    ///
    /// The await is the whole of it. Reading a provider whose future is
    /// still in flight is the LOADING state, where `.value` returns
    /// null quite happily — so a test that read straight after building
    /// the container would assert the wrong state and pass against the
    /// bug. Found by a surviving mutant that put `.value` back and was
    /// not noticed.
    Future<ProviderContainer> failedRole() async {
      final c = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWithValue(null),
          authStateProvider
              .overrideWith((_) => const Stream<AuthState>.empty()),
          memberRoleProvider.overrideWith((_) => fails<String>()),
          currentOrgProvider.overrideWith((_) => fails()),
        ],
      );
      addTearDown(c.dispose);
      await expectLater(c.read(memberRoleProvider.future), throwsStateError);
      await expectLater(c.read(currentOrgProvider.future), throwsStateError);
      return c;
    }

    test('a role that failed to load is a viewer, not an owner', () async {
      final c = await failedRole();

      expect(c.read(canAdminProvider), isFalse);
      expect(c.read(canPostProvider), isFalse);
      expect(c.read(canWriteProvider), isFalse);
      expect(c.read(canReadLedgerProvider), isFalse);
      expect(c.read(canManageHrProvider), isFalse);
      expect(c.read(canRunPayrollProvider), isFalse);
    });

    test('and not an auditor either', () async {
      // `?? ''` rather than `?? 'viewer'` on this one, and the empty
      // string must not read as the role that may ASK for payslips.
      final c = await failedRole();

      expect(c.read(canRequestPayslipAccessProvider), isFalse);
    });

    test('a company that failed to load leaves no repository', () async {
      // `repoProvider` reads `currentOrgProvider` and hands back null
      // when there is no company. A failure has to be the same answer:
      // every screen already handles a null repository, and none of
      // them handles an exception thrown while reading one.
      final c = await failedRole();

      expect(c.read(repoProvider), isNull);
    });

    test('the control: a role that loaded is what it says', () {
      // Without this, providers that always returned false would pass
      // every assertion above and nobody could do anything.
      final c = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWithValue(null),
          authStateProvider
              .overrideWith((_) => const Stream<AuthState>.empty()),
          memberRoleProvider.overrideWith((_) async => 'owner'),
          currentOrgProvider.overrideWith((_) async => null),
        ],
      );
      addTearDown(c.dispose);
      // Warm it: the gates read `valueOrNull`, which is null until the
      // future completes, so an unawaited read is the loading state
      // rather than the answer.
      return c.read(memberRoleProvider.future).then((_) {
        expect(c.read(canAdminProvider), isTrue);
        expect(c.read(canPostProvider), isTrue);
      });
    });
  });

  testWidgets('the control: everything answers and the shell is there', (
    tester,
  ) async {
    // Without this the assertions above could pass against a harness
    // that never built a shell at all.
    await show(tester, harness());
    expectShellStandsUp(tester);
    expect(find.byType(AppShell), findsOneWidget);
  });
}
