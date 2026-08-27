import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/platform_live.dart';
import 'package:iakauntan/src/data/site_pages_repository.dart';
import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/data/landing_repository.dart';
import 'package:iakauntan/src/data/platform_catalog_repository.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';

/// The wiring behind a console change reaching the product.
///
/// Every failure this guards against is silent. A table named slightly
/// differently subscribes to nothing; a provider missing from a list
/// leaves one screen showing yesterday's name while the screen beside it
/// shows today's; and the console invalidating its own list but not the
/// menu's looks, from the admin's chair, exactly like the rename not
/// having saved. None of them raises anything, so they are asserted.
void main() {
  test('the tables subscribed to are the ones the database publishes', () {
    // Kept in step with `0302` by hand, so it is written down twice on
    // purpose: if the two disagree, one side listens for something
    // nobody sends and the feature quietly does nothing.
    expect(platformLiveTables.toSet(), {
      'platform_modules',
      'platform_settings',
      'landing_page',
      'landing_sections',
      'landing_app_links',
      'landing_stats',
      'landing_testimonials',
      'landing_logos',
      // 0341. The five pages around the product — the wording on the
      // two auth screens, and Terms, Privacy and Contact.
      'site_pages',
    });
  });

  test('payment_gateways is deliberately not among them', () {
    // Its read policy is `using (is_active)`, so switching a gateway off
    // is the update whose new row fails the policy for every ordinary
    // subscriber — the change most worth delivering is the one that
    // would not be. 0302 says the same thing at length. Asserted so
    // adding it is a decision rather than a reflex.
    expect(platformLiveTables, isNot(contains('payment_gateways')));
  });

  // ---- a module renamed in the console ----

  test('renaming a module renames it in the menu and the dashboard', () {
    // `moduleLabelsProvider` is both the rail's headings and the
    // dashboard's tab names. Before this the console invalidated its own
    // admin list and nothing else, so the admin who did the renaming saw
    // the new name in one panel and the old one in the menu beside it.
    expect(
      platformLiveProviders('platform_modules'),
      contains(moduleLabelsProvider),
    );
  });

  test('and in the pricing list and the access-type editor', () {
    // Both read `platformModulesProvider`, which is the same catalogue
    // reached by a different call.
    expect(
      platformLiveProviders('platform_modules'),
      contains(platformModulesProvider),
    );
  });

  test('and in the settings card a company puts a module away from', () {
    expect(
      platformLiveProviders('platform_modules'),
      contains(moduleSurfaceProvider),
    );
  });

  test('and the console list that did the renaming', () {
    // The positive control for the console's own screen. Every
    // assertion above is also satisfied by a map that forgot the one
    // list the person is looking at while they press Save.
    expect(
      platformLiveProviders('platform_modules'),
      contains(platformModulesAdminProvider),
    );
  });

  // ---- the switch that regroups every menu on the platform ----

  test('grouping the menu regroups it without a reload', () {
    expect(
      platformLiveProviders('platform_settings'),
      contains(navGroupingProvider),
    );
  });

  test('and the console still sees its own list of settings', () {
    expect(
      platformLiveProviders('platform_settings'),
      contains(platformSettingsProvider),
    );
  });

  // ---- the landing page, and the brand that comes with it ----

  test('every landing table refreshes the page a stranger sees', () {
    // `landingContentProvider` is the public page and, through
    // `app.dart`, the product name and logo inside the signed-in app.
    // A logo replaced in the console that did not change the app's own
    // header is the complaint that started this.
    for (final table in const [
      'landing_page',
      'landing_sections',
      'landing_app_links',
      'landing_stats',
      'landing_testimonials',
      'landing_logos',
    ]) {
      expect(
        platformLiveProviders(table),
        contains(landingContentProvider),
        reason: '$table must refresh the brand',
      );
    }
  });

  test('and each one refreshes its own editor', () {
    expect(
      platformLiveProviders('landing_page'),
      contains(landingPageAdminProvider),
    );
    expect(
      platformLiveProviders('landing_sections'),
      contains(landingSectionsAdminProvider),
    );
    expect(
      platformLiveProviders('landing_app_links'),
      contains(landingAppLinksAdminProvider),
    );
    expect(
      platformLiveProviders('landing_stats'),
      contains(landingStatsAdminProvider),
    );
    expect(
      platformLiveProviders('landing_testimonials'),
      contains(landingTestimonialsAdminProvider),
    );
    expect(
      platformLiveProviders('landing_logos'),
      contains(landingLogosAdminProvider),
    );
  });

  test('and the sign-in bullets refresh the list they are edited in', () {
    // 0336 added a fourth `kind` to `landing_sections` and 0341 put it
    // here. Left out, editing a bullet refreshed the landing page's
    // three bands and not the list the operator was looking at.
    expect(
      platformLiveProviders('landing_sections'),
      contains(landingSigninPointsAdminProvider),
    );
  });

  test('and the five pages refresh both what is read and what is edited',
      () {
    // Both, and for different reasons: `sitePagesProvider` is the
    // sign-in screen's wording and the three public pages, and
    // `sitePageDraftsProvider` is the console's own view. One without
    // the other is a tab that disagrees with the page beside it.
    expect(
      platformLiveProviders('site_pages'),
      contains(sitePagesProvider),
    );
    expect(
      platformLiveProviders('site_pages'),
      contains(sitePageDraftsProvider),
    );
  });

  test('and a block of either kind refreshes both console lists', () {
    // Features and reasons are one table split by `kind`, so a save of
    // either arrives as a change to `landing_sections`. Refreshing only
    // the list the admin happened to be looking at is how a reason
    // typed into the console appears on the public page and not in the
    // tab it was typed into.
    expect(
      platformLiveProviders('landing_sections'),
      contains(landingReasonsAdminProvider),
    );
    expect(
      platformLiveProviders('landing_sections'),
      contains(landingBadgesAdminProvider),
    );
  });

  test('and does not refresh the other two editors', () {
    // The map is allowed to be generous — a refetch nobody is watching
    // costs nothing — but not so generous that it stops describing
    // anything. Saving a section must not be indistinguishable from
    // saving the page.
    expect(
      platformLiveProviders('landing_page'),
      isNot(contains(landingSectionsAdminProvider)),
    );
    expect(
      platformLiveProviders('landing_sections'),
      isNot(contains(landingAppLinksAdminProvider)),
    );
  });

  // ---- the two paths cannot drift ----

  test('what the socket refreshes is what the console refreshes', () {
    // The reason this is a map and not two sets of `ref.invalidate`
    // calls. `invalidatePlatformTable` reads the same lists the channel
    // does, so a provider added for one audience is added for both —
    // and a table that refreshed when you edited it yourself but not
    // when a colleague did would be worse than one that never
    // refreshed, because the first person to notice would not be
    // believed.
    for (final table in platformLiveTables) {
      expect(
        platformLiveProviders(table),
        isNotEmpty,
        reason: '$table is subscribed to and refreshes nothing',
      );
    }
  });

  test('a table nobody listed refreshes nothing rather than throwing', () {
    // `invalidatePlatformTable` is called from a save handler after the
    // write has already succeeded. Throwing there would report a failure
    // for something the database has accepted.
    expect(platformLiveProviders('no_such_table'), isEmpty);
  });

  test('no provider is listed twice under one table', () {
    for (final table in platformLiveTables) {
      final list = platformLiveProviders(table);
      expect(list.toSet().length, list.length, reason: table);
    }
  });

  test('the channel is inert where there is no Supabase to open one', () {
    // A widget test renders real screens against overridden providers
    // and never calls `Supabase.initialize`. The provider has to answer
    // that before it reaches for the client — and before it reads the
    // user, which goes through the same client — or every shell test
    // fails on a socket the shell only wanted to listen to.
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    expect(container.read(platformLiveProvider).connected, isFalse);
  });

  test('a signed-out visitor is no longer a reason not to connect', () {
    // It used to be. Postgres changes are delivered per subscriber
    // under RLS and every policy on these tables is granted to
    // `authenticated`, so a channel opened without a user received
    // nothing — and the front page, the one screen read by people who
    // are not signed in, was the one screen that never updated.
    //
    // `0322` gives it something to receive that carries no rows: a
    // nudge naming the table that changed, which the page answers by
    // asking `landing_page()` again. So being signed out is a reason to
    // subscribe to less, not a reason to subscribe to nothing.
    //
    // Asserted on the map rather than on a live socket, which needs a
    // server: every landing table the nudge names has to be a table
    // this file knows what to refresh for, or the message arrives and
    // nothing happens.
    for (final table in [
      'landing_page',
      'landing_sections',
      'landing_app_links',
      'landing_stats',
      'landing_testimonials',
      'landing_logos',
      'platform_modules',
    ]) {
      expect(
        platformLiveProviders(table),
        isNotEmpty,
        reason: '$table nudges the front page and refreshes nothing',
      );
      expect(platformLiveProviders(table), contains(anything), reason: table);
    }
    // And the landing page itself is what a landing nudge refreshes.
    for (final table in [
      'landing_page',
      'landing_sections',
      'landing_app_links',
      'landing_stats',
      'landing_testimonials',
      'landing_logos',
    ]) {
      expect(
        platformLiveProviders(table),
        contains(landingContentProvider),
        reason: '$table changes and the page does not',
      );
    }
  });
}
