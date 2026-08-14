/// Other people's work, arriving without being asked for.
///
/// Two people keeping one ledger could not see each other. A colleague
/// raised an invoice and it was not on your screen until you left it and
/// came back; a partner changed the company's tax number and your copy
/// stayed yesterday's until you reloaded. Nothing was wrong in the
/// database — the screen had no way to learn it was out of date.
///
/// This subscribes to the organization's rows and re-reads what changed.
/// It does not merge anything by hand: a change arrives, the providers
/// that show that table are invalidated, and they fetch. Merging a
/// payload into a cached list would mean two code paths that can
/// disagree about what a row means, and the fetch is one round trip on a
/// table somebody is already looking at.
///
/// **Security is the database's, not this file's.** Realtime applies RLS
/// when deciding who receives a row, and every table below carries
/// org-membership policies. The `org_id` filter here saves bandwidth; it
/// is not what stops you seeing another company's invoices.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'providers.dart';

/// Which providers go stale when a table changes.
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
};

/// The tables listened to. Must match what `0117_live_updates.sql` and
/// `0124_a_claim_moves_while_you_watch.sql` publish between them: a name
/// that is in one and not the other subscribes to nothing, or is sent
/// changes nobody reads, and neither says so.
Iterable<String> get liveUpdateTables => _watchers.keys;

/// What goes stale when [table] changes.
List<ProviderOrFamily> liveUpdateProviders(String table) =>
    _watchers[table] ?? const [];

/// The column that says which organization a row belongs to.
///
/// `organizations` is the exception and has to be: the organization's own
/// row is identified by its primary key, and filtering it on a column
/// that does not exist would silently deliver nothing.
String liveUpdateColumn(String table) =>
    table == 'organizations' ? 'id' : 'org_id';

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

    for (final table in _watchers.keys) {
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: liveUpdateColumn(table),
          value: orgId,
        ),
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

    // Collected first so a provider listed under two tables is
    // invalidated once, not twice.
    final stale = <ProviderOrFamily>{};
    for (final table in tables) {
      stale.addAll(liveUpdateProviders(table));
    }
    for (final provider in stale) {
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
