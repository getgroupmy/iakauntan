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
  test('the tables subscribed to are the ones the database publishes', () {
    // Kept in step with `0117_live_updates.sql`,
    // `0124_a_claim_moves_while_you_watch.sql` and
    // `0204_an_entitlement_arrives_without_a_reload.sql` by hand, so it
    // is written down twice on purpose: if they ever disagree, one side
    // listens for something nobody sends and the feature quietly does
    // nothing.
    expect(
      liveUpdateTables.toSet(),
      {
        'organizations',
        'sales_documents',
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

  test('the organization is filtered by its own key, not by org_id', () {
    // `organizations` has no `org_id` column. Filtering on one would
    // match no rows and deliver nothing — the settings screen would go
    // back to needing a reload, and nothing would say why.
    expect(liveUpdateColumn('organizations'), 'id');
    for (final table in liveUpdateTables) {
      if (table == 'organizations') continue;
      expect(liveUpdateColumn(table), 'org_id', reason: table);
    }
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

  test('nothing private is subscribed to', () {
    // The database refuses to publish these; this is the other half,
    // so a table added to the publication by hand still would not be
    // listened to without a deliberate change here.
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

  test('with nobody signed in, nothing is listening', () {
    final container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(null),
    ]);
    addTearDown(container.dispose);

    final live = container.read(liveUpdatesProvider);
    expect(live.connected, isFalse);
  });
}
