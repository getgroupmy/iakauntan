import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/live_updates.dart';
import 'package:iakauntan/src/core/providers.dart';

/// The wiring behind other people's changes appearing.
///
/// Almost everything here fails *silently* when it is wrong: a table
/// named slightly differently subscribes to nothing, a missing provider
/// leaves one screen stale while its neighbours update, and neither
/// shows up as an error. So the map is asserted rather than trusted.
void main() {
  test('the tables with a narrow answer are these, and only these', () {
    // Not the tables that are LIVE any more — `0547` made that every
    // table with an `org_id`. These are the ones whose refresh is
    // narrowed to the handful of lists that actually moved, instead of
    // refetching the screen. Pinned so that adding one is a decision:
    // a wrong entry here is worse than no entry, because no entry still
    // refreshes and a wrong one refreshes the wrong thing.
    expect(
      liveUpdateTables.toSet(),
      {
        'organizations',
        'sales_documents',
        // 0650. A supplier's document lands while nobody is looking,
        // and the list it lands in is the only screen that has to
        // move -- which is what earns it a narrow entry rather than a
        // whole-screen refetch.
        'received_einvoices',
        'purchase_documents',
        'receipts',
        'purchase_payments',
        'contacts',
        'items',
        'expenses',
        'gl_entries',
        'expense_claims',
        'claim_approvals',
        'org_credits',
        'org_modules',
      },
    );
  });

  test('a module switched on appears without a reload', () {
    // The navigation is built from `enabledModulesProvider`, which is
    // read once per sign-in. Before this it was invalidated only by the
    // platform console in the same tab, so a module granted by another
    // admin, from another device, or by support stayed invisible until
    // the person happened to reload — and nothing told them to.
    expect(
      liveUpdateProviders('org_modules'),
      contains(enabledModulesProvider),
    );
  });

  test('a module put away leaves the dashboard with it', () {
    // 0234 gave `org_modules` a second reason to move: `is_hidden`, which
    // an admin writes from Settings. The rail follows through
    // `enabledModulesProvider`, but the dashboard is assembled from its
    // own call — so an admin switching the service desk off would have
    // left the ticket cards sitting there until somebody reloaded.
    expect(
      liveUpdateProviders('org_modules'),
      allOf(contains(moduleSurfaceProvider), contains(moduleDashboardProvider)),
    );
  });

  test('the access map is left alone by an entitlement change', () {
    // `my_module_access` reads `platform_modules` and the caller's
    // access type. Neither moves when a module is switched on, so
    // invalidating it here would be a refetch that can never come back
    // different — and a map with entries that do nothing is a map
    // nobody can reason about.
    expect(
      liveUpdateProviders('org_modules'),
      isNot(contains(myModuleAccessProvider)),
    );
  });

  test('a claim cleared by somebody else moves without a reload', () {
    // The chain is the table that matters and the easy one to leave
    // out. Clearing an intermediate step writes to `claim_approvals`
    // and leaves `expense_claims` untouched — still `submitted`, same
    // row — so subscribing to the claim alone would deliver the ending
    // of a claim's life and none of the middle, which is precisely what
    // the queue is made of.
    expect(liveUpdateProviders('claim_approvals'),
        contains(claimsAwaitingMeProvider));
    expect(liveUpdateProviders('claim_approvals'),
        contains(claimApprovalsProvider));

    // And the ends of its life, which is what the claim row records.
    expect(liveUpdateProviders('expense_claims'),
        contains(claimsAwaitingMeProvider));
    expect(liveUpdateProviders('expense_claims'), contains(claimsProvider));
  });

  test('there is one subscription, and it is to the feed', () {
    // `0547`. The app no longer names a table per subscription — the
    // trigger does, and the name arrives in the row. This is the whole
    // of the coupling between the two sides now, so it is written down.
    expect(liveChangeFeed, 'live_changes');
  });

  test('every table re-reads something', () {
    for (final table in liveUpdateTables) {
      expect(liveUpdateProviders(table), isNotEmpty,
          reason: '$table is subscribed to and then ignored');
    }
  });

  test('a new invoice refreshes the list, the dashboard and the ageing', () {
    final stale = liveUpdateProviders('sales_documents');
    expect(stale, contains(documentsProvider));
    expect(stale, contains(dashboardProvider));
    expect(stale, contains(arAgingProvider));
  });

  test("a colleague's payment refreshes what it settles, not just itself", () {
    // The receipt is one row, but it changes the document's outstanding
    // balance and the ageing with it. Refreshing only the receipts list
    // is how a paid invoice keeps showing as due.
    for (final table in ['receipts', 'purchase_payments']) {
      final stale = liveUpdateProviders(table);
      expect(stale, contains(settlementsProvider), reason: table);
      expect(stale, contains(documentProvider), reason: table);
      expect(stale, contains(outstandingProvider), reason: table);
    }
  });

  test('a company setting refreshes the source, not the picker', () {
    // The same trap as the manual refresh: `currentOrgProvider` picks
    // from `organizationsProvider`, so invalidating the picker would
    // re-choose from cached rows and show the old value.
    final stale = liveUpdateProviders('organizations');
    expect(stale, contains(organizationsProvider));
    expect(stale, isNot(contains(currentOrgProvider)));
  });

  test('nothing private has a narrow answer here', () {
    // These are held back in the database, by the policy on
    // `live_changes` that `0547` wrote and
    // `supabase/tests/live_change_feed.sql` asserts: a clerk is not
    // told that payroll moved. This is the other half — no entry here
    // either, so a name that somehow arrived would refresh the screen
    // and not point at a payroll list.
    const private = [
      'einvoice_credentials',
      'org_ocr_credentials',
      'payslips',
      'payroll_runs',
      'platform_settings',
      'profiles',
    ];
    for (final table in private) {
      expect(liveUpdateTables, isNot(contains(table)), reason: table);
    }
  });

  test('the auth stream is never thrown away with the rest', () {
    // The broad refresh reaches everything holding an AsyncValue, and
    // the auth stream holds one. Re-subscribing to it would flicker a
    // signed-in person's session every time a colleague saved
    // anything, so it is the one exception — and it is the exception by
    // name, in one place, rather than by a check scattered about.
    expect(liveUpdateNeverInvalidated, contains(authStateProvider));
  });

  test('a table with no entry of its own still refreshes something', () {
    // The point of `0547`. `stock_transfers` is not on the narrow list
    // and never will be worth putting there — but a storeman receiving
    // one must not leave the warehouse screen on the next desk showing
    // it in transit. Empty here means "refetch the screen", not
    // "nothing happens", which is only true because `_flush` reads it
    // that way.
    expect(liveUpdateProviders('stock_transfers'), isEmpty);
    expect(liveUpdateProviders('leave_requests'), isEmpty);
    expect(liveUpdateProviders('pos_sales'), isEmpty);
  });

  group('what a change actually refreshes', () {
    // A provider that counts how often it was asked, standing in for
    // every list on a screen.
    var fetched = 0;
    late AutoDisposeFutureProvider<int> aList;
    late StateProvider<String> whatSomebodyTyped;

    setUp(() {
      fetched = 0;
      aList = FutureProvider.autoDispose<int>((ref) async => ++fetched);
      whatSomebodyTyped = StateProvider<String>((ref) => 'untouched');
    });

    Future<(ProviderContainer, LiveUpdates)> harness() async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final probe = Provider<LiveUpdates>(LiveUpdates.new);
      // Listened to, not read once: an autoDispose provider with no
      // listener is not in the container at all, and "everything alive"
      // would then be nothing.
      container.listen(aList, (_, __) {});
      container.listen(whatSomebodyTyped, (_, __) {});
      await container.read(aList.future);
      return (container, container.read(probe));
    }

    test('a table with a narrow answer refreshes what that answer names',
        () async {
      final (container, live) = await harness();
      expect(fetched, 1);

      live.noteChange('sales_documents');
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // Not this list: `sales_documents` has a narrow answer, and this
      // list is not on it. That is the optimisation working.
      expect(fetched, 1);
      container.dispose();
    });

    test('a table with none refetches everything that was fetched',
        () async {
      final (container, live) = await harness();
      expect(fetched, 1);

      live.noteChange('stock_transfers');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await container.read(aList.future);

      expect(fetched, 2,
          reason: 'a storeman receiving a transfer has to reach the '
              'warehouse screen on the next desk');
      container.dispose();
    });

    test('and leaves what somebody typed alone', () async {
      final (container, live) = await harness();
      container.read(whatSomebodyTyped.notifier).state = 'half a name';

      live.noteChange('stock_transfers');
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // The rule is about the shape of a provider, not a list of names:
      // an AsyncValue was fetched and can be fetched again; a State is
      // a choice, and resetting it would throw away work nobody asked
      // to lose.
      expect(container.read(whatSomebodyTyped), 'half a name');
      container.dispose();
    });

    test('and waits for the burst to settle before it does', () async {
      final (container, live) = await harness();

      // Posting a document writes the document, its lines and a journal
      // entry, and each arrives separately. Refetching on the first
      // would be three round trips for one action a colleague took, and
      // a list that flickers twice on the way to the right answer.
      live.noteChange('stock_transfers');
      live.noteChange('stock_movements');
      live.noteChange('stock_levels');

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await container.read(aList.future);
      expect(fetched, 1, reason: 'the burst is not over yet');

      await Future<void>.delayed(const Duration(milliseconds: 400));
      await container.read(aList.future);
      expect(fetched, 2, reason: 'and then it refetches once');
      container.dispose();
    });
  });

  test('with nobody signed in, nothing is listening', () {
    final container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);

    final live = container.read(liveUpdatesProvider);
    expect(live.connected, isFalse);
  });
}
