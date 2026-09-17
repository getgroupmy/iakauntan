/// Other people's work, arriving without being asked for.
///
/// Two people keeping one ledger could not see each other. A colleague
/// raised an invoice and it was not on your screen until you left it and
/// came back; a partner changed the company's tax number and your copy
/// stayed yesterday's until you reloaded. Nothing was wrong in the
/// database — the screen had no way to learn it was out of date.
///
/// This subscribes to ONE table — `public.live_changes`, which `0547`
/// appends to from a statement trigger on every table carrying an
/// `org_id`. A row on it is a company and a table name and nothing
/// else; the app reads the name and re-reads what shows that table.
///
/// It does not merge anything by hand: a change arrives, the providers
/// that show that table are invalidated, and they fetch. Merging a
/// payload into a cached list would mean two code paths that can
/// disagree about what a row means, and the fetch is one round trip on a
/// table somebody is already looking at.
///
/// One subscription rather than two hundred and seventy-three is the
/// point of the feed. `0117` subscribed per table, which capped what
/// could be live at the dozen tables somebody had thought to list — and
/// left the storeman receiving a transfer, the manager approving leave
/// and the waiter voiding a line all invisible to the screen next to
/// them.
///
/// **Security is the database's, not this file's.** Realtime applies RLS
/// when deciding who receives a row, and `live_changes` carries a policy
/// that also holds back the tables `0117` refused to publish: a clerk is
/// not told that payroll moved. The `org_id` filter here saves
/// bandwidth; it is not what stops you seeing another company's work.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'providers.dart';

/// Which providers go stale when a named table changes.
///
/// This is now an OPTIMISATION, not the mechanism. A table that is not
/// on it still refreshes the screen — see [_refreshEverythingFetched] —
/// but by refetching everything on screen rather than the four lists
/// that actually moved. Naming the hot tables keeps the common case
/// cheap; naming all two hundred and seventy-three would be a list
/// nobody could keep true, which is the trap `0117` fell into.
///
/// Families are invalidated whole — one entry covers every argument the
/// screen might have asked with, which is the point: a colleague's
/// invoice belongs to a filter you may not have open.
///
/// The right-hand side is deliberately generous. Re-reading a list
/// nobody is watching costs nothing, because an `autoDispose` provider
/// with no listeners is not there to invalidate; being stingy here is
/// how a dashboard total quietly disagrees with the list under it.
final Map<String, List<ProviderOrFamily>> _watchers = {
  'organizations': [organizationsProvider],
  'sales_documents': [
    documentsProvider,
    documentProvider,
    outstandingProvider,
    dashboardProvider,
    revenueTrendProvider,
    arAgingProvider,
    agedBalancesProvider,
    einvoicesProvider,
    einvoiceStatusProvider,
    recurringDocumentsProvider,
  ],
  'purchase_documents': [
    documentsProvider,
    documentProvider,
    outstandingProvider,
    dashboardProvider,
    agedBalancesProvider,
    recurringDocumentsProvider,
  ],
  'receipts': [
    settlementsProvider,
    settlementProvider,
    documentProvider,
    documentsProvider,
    outstandingProvider,
    dashboardProvider,
    arAgingProvider,
    agedBalancesProvider,
  ],
  'purchase_payments': [
    settlementsProvider,
    settlementProvider,
    documentProvider,
    documentsProvider,
    outstandingProvider,
    dashboardProvider,
    agedBalancesProvider,
  ],
  'contacts': [
    contactsProvider,
    customerCreditProvider,
    arAgingProvider,
    agedBalancesProvider,
  ],
  'items': [itemsProvider, stockOnHandProvider, itemPricesProvider],
  'expenses': [expensesProvider, dashboardProvider],
  'gl_entries': [
    journalsProvider,
    trialBalanceProvider,
    dashboardProvider,
    activitiesProvider,
  ],
  // A claim only reaches `expense_claims` at the ends of its life —
  // submitted, then approved or rejected once the last stage clears.
  'expense_claims': [
    claimsProvider,
    claimsAwaitingMeProvider,
    claimApprovalsProvider,
  ],
  // Everything in between is here. A manager clearing stage one writes
  // a step and nothing else, so this is the table that makes a claim
  // leave one person's queue and arrive in the next person's.
  'claim_approvals': [
    claimsAwaitingMeProvider,
    claimApprovalsProvider,
    claimsProvider,
  ],
  'org_credits': [ocrStatusProvider],
  // What the navigation is built from. Without this a module bought or
  // switched on anywhere but this tab stays invisible until the person
  // reloads, and nothing tells them to — they paid and the screen did
  // not change.
  //
  // Only the entitlement. `myModuleAccessProvider` is not listed
  // because it cannot move for this table: `my_module_access` reads
  // `platform_modules` and the caller's access type, and neither is
  // touched by enabling a module. Listing it anyway would be a refetch
  // that can never return anything different, which is the kind of
  // generosity that makes a map hard to trust.
  //
  // 0234 added a second reason this table moves: a company putting a
  // module away writes `is_hidden` here. Everything assembled from the
  // module surface has to follow — the rail, the settings card that did
  // the writing, and the dashboard, which loses or gains a card by it.
  'org_modules': [
    enabledModulesProvider,
    moduleSurfaceProvider,
    moduleDashboardProvider,
  ],
};

/// The tables with an entry of their own. Every other table refreshes
/// too — this is the list of the ones that refresh narrowly.
Iterable<String> get liveUpdateTables => _watchers.keys;

/// What goes stale when [table] changes. Empty means "no narrow answer
/// for this one", which is a refetch of everything on screen, not
/// nothing.
List<ProviderOrFamily> liveUpdateProviders(String table) =>
    _watchers[table] ?? const [];

/// The one table subscribed to. `0547`.
const liveChangeFeed = 'live_changes';

/// What must not be thrown away when everything else is.
///
/// The broad refresh reaches every provider holding an [AsyncValue] —
/// everything that was fetched from the server, and nothing that
/// somebody chose or typed. `authStateProvider` is the exception it
/// cannot tell apart: it holds an [AsyncValue] like a fetched list, but
/// invalidating it re-subscribes to the auth stream, and a signed-in
/// person would watch their session flicker every time a colleague
/// saved anything.
final Set<ProviderOrFamily> liveUpdateNeverInvalidated = {authStateProvider};

/// Long enough to collect a burst, short enough to feel immediate.
///
/// Posting a document writes the document, its lines and a journal
/// entry, and each arrives separately. Without this the dashboard would
/// refetch three times for one action a colleague took.
const _settle = Duration(milliseconds: 300);

/// Live updates for the organization currently open.
///
/// Watched by the shell, so it lives as long as somebody is signed in
/// and is torn down and rebuilt when they switch organization — which is
/// the correct behaviour rather than a happy accident: the subscription
/// is filtered by organization, so it has to be rebuilt to follow.
final liveUpdatesProvider = Provider<LiveUpdates>((ref) {
  final org = ref.watch(currentOrgProvider).valueOrNull;
  final user = ref.watch(currentUserProvider);

  final live = LiveUpdates(ref);
  ref.onDispose(live.dispose);

  // Signed out, or no organization chosen yet. Nothing to listen to, and
  // subscribing anyway would open a channel that can only ever receive
  // things this user may not see.
  //
  // Checked before the client is reached for, so this provider can be
  // read on a signed-out app — and in a test — without requiring a
  // Supabase that has been initialised.
  if (org == null || user == null) return live;

  live._connect(ref.watch(supabaseProvider), org.id);
  return live;
});

class LiveUpdates {
  LiveUpdates(this._ref);

  final Ref _ref;
  RealtimeChannel? _channel;
  SupabaseClient? _client;
  Timer? _timer;
  final _pending = <String>{};

  /// Whether the socket is carrying changes at this moment.
  ///
  /// Not shown anywhere yet. It exists because "is this screen live or
  /// merely recent" is a real question, and a boolean nobody displays is
  /// cheaper than adding one later on a hunch.
  var connected = false;

  void _connect(SupabaseClient client, String orgId) {
    _client = client;
    final channel = client.channel('org:$orgId');

    // One subscription, to the feed. Inserts only: `live_changes` is
    // append-only, and the nightly prune's deletes are housekeeping
    // nobody needs to hear about.
    channel.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: liveChangeFeed,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'org_id',
        value: orgId,
      ),
      callback: (payload) {
        final table = payload.newRecord['table_name'];
        if (table is String && table.isNotEmpty) noteChange(table);
      },
    );

    channel.subscribe((status, error) {
      connected = status == RealtimeSubscribeStatus.subscribed;
    });
    _channel = channel;
  }

  /// A table changed. Note it, and act once the burst is over.
  ///
  /// The seam between the socket and everything below it, and public so
  /// a test can push a table name through the same door a colleague's
  /// write comes in by. There is no other way in: what this does after
  /// the burst settles is the whole behaviour, and asserting it against
  /// a mocked socket would be asserting the mock.
  void noteChange(String table) {
    _pending.add(table);
    _timer?.cancel();
    _timer = Timer(_settle, _flush);
  }

  void _flush() {
    final tables = _pending.toList();
    _pending.clear();

    // Collected first so a provider listed under two tables is
    // invalidated once, not twice.
    final stale = <ProviderOrFamily>{};
    for (final table in tables) {
      final narrow = liveUpdateProviders(table);
      if (narrow.isEmpty) {
        // A table with no entry of its own. Rather than let the screen
        // go on being wrong — which is the whole complaint — refetch
        // everything that was fetched, and stop looking at the rest of
        // the burst: the broad refresh already covers it.
        _refreshEverythingFetched();
        return;
      }
      stale.addAll(narrow);
    }
    for (final provider in stale) {
      _ref.invalidate(provider);
    }
  }

  /// Refetch everything on screen that came from the server.
  ///
  /// The rule is deliberately about the SHAPE of a provider and not
  /// about a list of names: anything holding an [AsyncValue] was fetched
  /// and can be fetched again, and anything else — the client, the
  /// signed-in user, the organization somebody picked, a form's own
  /// state — is a choice, not a copy, and resetting it would throw away
  /// work nobody asked to lose.
  ///
  /// It reaches only providers that are ALIVE. An `autoDispose` list
  /// with no listeners is not in the container to be invalidated, so
  /// "everything" is bounded by what is actually on screen, which on a
  /// typical page is a handful.
  void _refreshEverythingFetched() {
    for (final element in _ref.container.getAllProviderElements().toList()) {
      final provider = element.origin;
      if (provider is! ProviderBase<AsyncValue<Object?>>) continue;
      if (liveUpdateNeverInvalidated.contains(provider)) continue;
      _ref.invalidate(provider);
    }
  }

  void dispose() {
    _timer?.cancel();
    final channel = _channel;
    if (channel != null) {
      // Removed rather than left to be garbage collected: the socket is
      // shared, and an abandoned channel keeps receiving and keeps
      // invalidating providers for an organization nobody is in.
      _client?.removeChannel(channel);
    }
    _channel = null;
    connected = false;
  }
}
