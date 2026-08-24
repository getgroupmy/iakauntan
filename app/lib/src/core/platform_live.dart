/// What the platform console changes, arriving without a reload.
///
/// The console edits things that belong to no single company: what each
/// module is called and what heading it sits under, whether the side
/// menu is grouped, the landing page and the logo on it. Every one of
/// those is fetched once when a session starts and cached for as long as
/// it lasts, which meant renaming a module renamed it in the console's
/// own list and nowhere else — not in the admin's own side menu, not in
/// anybody's dashboard tabs, and not for a single customer until they
/// signed out and back in.
///
/// Two paths, because there are two audiences and only one of them is
/// worth a round trip through a socket:
///
///  * the person who pressed Save. [invalidatePlatformTable] is called
///    by the console straight after the write, so their own screens
///    catch up at once rather than waiting for the change to come back
///    to them over the wire.
///  * everybody else. [platformLiveProvider] subscribes to the same
///    tables and invalidates the same providers when one moves.
///
/// Both read [_watchers], so the two cannot drift. That is the whole
/// reason it is a map rather than two lists of `ref.invalidate` calls:
/// the failure it prevents is somebody adding a provider to one path,
/// and a table that refreshes when you edit it yourself but not when a
/// colleague does is worse than one that never refreshes, because the
/// first person to notice will not believe the second.
///
/// **Security is the database's, not this file's.** Realtime evaluates
/// each table's RLS policies per subscriber before delivering a row, so
/// listening here shows exactly what a `select` already showed. The one
/// place that is load-bearing is `platform_settings`: 0298 lets an
/// ordinary member read `nav_grouping` and a platform admin read
/// everything, so an admin editing a different key sends that member
/// nothing at all.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/landing_repository.dart';
import '../data/platform_catalog_repository.dart';
import '../features/landing/landing_content.dart';
import 'providers.dart';

/// Which providers go stale when a platform table changes.
///
/// Must stay in step with what `0302` publishes: a table listed here and
/// not published subscribes to nothing, and a table published and not
/// listed here is changes nobody reads. Neither says so at runtime,
/// which is why `app/test/platform_live_test.dart` names the set.
final Map<String, List<ProviderOrFamily>> _watchers = {
  // The module catalogue. Renaming one, moving it under a different
  // heading, re-ordering, retiring or adding one all land here.
  //
  // `moduleLabelsProvider` is the menu's headings and the dashboard's
  // tab names. `platformModulesProvider` is the same catalogue as the
  // pricing screen and the access-type editor read it.
  // `moduleSurfaceProvider` and `myModuleAccessProvider` both join the
  // catalogue for a label, so a rename has to reach them or the
  // settings card and the rail disagree about what one module is called.
  'platform_modules': [
    moduleLabelsProvider,
    platformModulesAdminProvider,
    platformModulesProvider,
    moduleSurfaceProvider,
    myModuleAccessProvider,
  ],
  // `nav_grouping` above all — the switch whose whole purpose is to
  // change every side menu on the platform. `platformSettingsProvider`
  // is the console's own list of every setting, and an ordinary member
  // never receives a row for any key but the one they may read.
  'platform_settings': [navGroupingProvider, platformSettingsProvider],
  // The landing page, and with it the brand: `landingContentProvider`
  // is what `app.dart` reads the product's name and logo from, so a
  // logo replaced in the console changes the signed-in app too.
  'landing_page': [landingPageAdminProvider, landingContentProvider],
  // Both kinds of block live in `landing_sections`, so a change to
  // either has to refresh both console lists as well as the page.
  'landing_sections': [
    landingSectionsAdminProvider,
    landingReasonsAdminProvider,
    landingBadgesAdminProvider,
    landingContentProvider,
  ],
  'landing_app_links': [landingAppLinksAdminProvider, landingContentProvider],
  'landing_stats': [landingStatsAdminProvider, landingContentProvider],
  'landing_testimonials': [
    landingTestimonialsAdminProvider,
    landingContentProvider,
  ],
  'landing_logos': [landingLogosAdminProvider, landingContentProvider],
};

/// The platform tables listened to.
Iterable<String> get platformLiveTables => _watchers.keys;

/// What goes stale when [table] changes.
List<ProviderOrFamily> platformLiveProviders(String table) =>
    _watchers[table] ?? const [];

/// Refresh everything that reads [table], now.
///
/// For the console to call after it writes. Unknown table names are
/// ignored rather than thrown on: this is called from a save handler
/// that has already succeeded, and failing the whole action because a
/// name is not in a map would undo a write in the user's mind that the
/// database has already accepted.
void invalidatePlatformTable(WidgetRef ref, String table) {
  for (final provider in platformLiveProviders(table)) {
    ref.invalidate(provider);
  }
}

/// Long enough to collect a burst, short enough to feel immediate.
///
/// Saving a landing page writes the page and its sections separately,
/// and re-ordering modules writes a row per module. Without this the
/// landing content would be refetched once per row.
const _settle = Duration(milliseconds: 300);

/// Live updates for the platform's own tables.
///
/// Watched by the shell, beside `liveUpdatesProvider`. Unlike that one
/// this needs no organization — the brand and the module catalogue are
/// read before anybody has chosen a company, and on the landing page
/// there is no company to choose. It needs a signed-in user, because
/// every policy on these tables is granted to `authenticated` and a
/// channel opened without one can only ever receive nothing.
final platformLiveProvider = Provider<PlatformLive>((ref) {
  final user = ref.watch(currentUserProvider);

  final live = PlatformLive(ref);
  ref.onDispose(live.dispose);

  // Checked before the client is reached for, so this can be read on a
  // signed-out app — and in a test — without a Supabase that has been
  // initialised.
  if (user == null) return live;

  live._connect(ref.watch(supabaseProvider));
  return live;
});

class PlatformLive {
  PlatformLive(this._ref);

  final Ref _ref;
  RealtimeChannel? _channel;
  SupabaseClient? _client;
  Timer? _timer;
  final _pending = <String>{};

  /// Whether the socket is carrying platform changes at this moment.
  var connected = false;

  void _connect(SupabaseClient client) {
    _client = client;
    // One topic for everybody. There is nothing to filter on — these
    // tables have no `org_id` and the rows are the platform's — so what
    // decides who receives a row is the policy on the table, which is
    // where that decision belongs.
    final channel = client.channel('platform');

    for (final table in _watchers.keys) {
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (_) => _touched(table),
      );
    }

    channel.subscribe((status, error) {
      connected = status == RealtimeSubscribeStatus.subscribed;
    });
    _channel = channel;
  }

  /// A table changed. Note it, and act once the burst is over.
  void _touched(String table) {
    _pending.add(table);
    _timer?.cancel();
    _timer = Timer(_settle, _flush);
  }

  void _flush() {
    final tables = _pending.toList();
    _pending.clear();

    // Collected first so a provider listed under two tables — every
    // landing table shares `landingContentProvider` — is invalidated
    // once rather than three times.
    final stale = <ProviderOrFamily>{};
    for (final table in tables) {
      stale.addAll(platformLiveProviders(table));
    }
    for (final provider in stale) {
      _ref.invalidate(provider);
    }
  }

  void dispose() {
    _timer?.cancel();
    final channel = _channel;
    if (channel != null) {
      // Removed rather than left to be collected: the socket is shared,
      // and an abandoned channel keeps receiving and keeps invalidating
      // providers for somebody who has signed out.
      _client?.removeChannel(channel);
    }
    _channel = null;
    connected = false;
  }
}
