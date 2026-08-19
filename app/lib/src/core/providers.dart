import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/corp_models.dart';
import '../data/corp_repository.dart';
import '../data/models.dart';
import '../data/ocr_repository.dart';
import '../data/repository.dart';
import 'env.dart';
import 'push.dart';

final supabaseProvider = Provider<SupabaseClient>(
  (_) => Supabase.instance.client,
);

/// Emits on sign-in, sign-out and token refresh; the router listens to it.
final authStateProvider = StreamProvider<AuthState>(
  (ref) => ref.watch(supabaseProvider).auth.onAuthStateChange,
);

final currentUserProvider = Provider<User?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(supabaseProvider).auth.currentUser;
});

/// Whether this session belongs to one of the shared demo logins.
///
/// Read from app_metadata, which only the service role can write, so an
/// account cannot talk its way out of the flag. This is for wording and
/// for hiding buttons that cannot work — the rule itself is a trigger on
/// auth.users (0076), because the password change is an ordinary call to
/// GoTrue that never passes through this app.
final isDemoAccountProvider = Provider<bool>((ref) {
  final user = ref.watch(currentUserProvider);
  return user?.appMetadata['demo'] == true;
});

/// True from the moment a reset link is redeemed until a new password has
/// actually been set.
///
/// Redeeming the link leaves the user *signed in* — which is the trap in
/// the naive version of this flow: they land on the dashboard, nothing
/// asks them for a new password, and the old one still works. So the
/// router holds them on the reset screen until [done] is called.
class PasswordRecoveryNotifier extends Notifier<bool> {
  @override
  bool build() {
    ref.listen(authStateProvider, (_, next) {
      switch (next.value?.event) {
        case AuthChangeEvent.passwordRecovery:
          state = true;
        case AuthChangeEvent.signedOut:
          state = false;
        case _:
          break;
      }
    });
    return false;
  }

  void done() => state = false;
}

final passwordRecoveryProvider =
    NotifierProvider<PasswordRecoveryNotifier, bool>(
      PasswordRecoveryNotifier.new,
    );

/// Organizations the signed-in user belongs to.
final organizationsProvider = FutureProvider<List<Organization>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return const [];

  final data = await ref.watch(supabaseProvider).rpc('my_organizations');
  return (data as List? ?? const [])
      .map((e) => Organization.fromJson(Map<String, dynamic>.from(e as Map)))
      .toList();
});

/// The org the user is currently working in. Defaults to their last used
/// org, falling back to the first one they belong to.
class CurrentOrgNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String orgId) {
    state = orgId;
    // Remember the choice so the next session lands in the same books.
    final user = ref.read(currentUserProvider);
    if (user != null) {
      ref
          .read(supabaseProvider)
          .from('profiles')
          .update({'last_org_id': orgId})
          .eq('id', user.id)
          .then(
            (_) {},
            onError: (_) {
              /* non-critical */
            },
          );
    }
  }

  void clear() => state = null;
}

final currentOrgIdProvider = NotifierProvider<CurrentOrgNotifier, String?>(
  CurrentOrgNotifier.new,
);

/// Re-reads the organization after something about it has changed.
///
/// **Always this, never `ref.invalidate(currentOrgProvider)`.**
///
/// `currentOrgProvider` does not fetch an organization. It *picks* one
/// out of `organizationsProvider`, which holds the rows. Invalidating
/// the picker alone re-runs the choice over the same cached rows and
/// hands back the identical stale record — so the write succeeds, the
/// snackbar says so, and the screen does not move. That is exactly what
/// "I have to reload the page before my change shows" looks like, and it
/// applied to every company setting: the logo, the letterhead switch,
/// the name, the tax numbers.
///
/// Invalidating the source is enough on its own. Everything downstream
/// watches it — `currentOrgProvider`, and `orgLogoProvider` behind that
/// — so Riverpod recomputes the lot.
void refreshOrganization(WidgetRef ref) =>
    ref.invalidate(organizationsProvider);

/// Resolves the active org, seeding the selection on first load.
final currentOrgProvider = FutureProvider<Organization?>((ref) async {
  final orgs = await ref.watch(organizationsProvider.future);
  if (orgs.isEmpty) return null;

  final selected = ref.watch(currentOrgIdProvider);
  if (selected != null) {
    return orgs.firstWhere((o) => o.id == selected, orElse: () => orgs.first);
  }

  final user = ref.watch(currentUserProvider);
  String? lastOrgId;
  if (user != null) {
    final profile = await ref
        .watch(supabaseProvider)
        .from('profiles')
        .select('last_org_id')
        .eq('id', user.id)
        .maybeSingle();
    lastOrgId = profile?['last_org_id'] as String?;
  }

  return orgs.firstWhere((o) => o.id == lastOrgId, orElse: () => orgs.first);
});

/// Repository bound to the active org. Null until an org is resolved.
final repoProvider = Provider<Repo?>((ref) {
  final org = ref.watch(currentOrgProvider).value;
  if (org == null) return null;
  return Repo(ref.watch(supabaseProvider), org.id);
});

/// Convenience accessor that throws rather than returning null, for use
/// inside screens that are only reachable once an org exists.
/// Not an error. A not-yet.
///
/// Signing in resolves in stages — the session, then the list of
/// organizations, then which one is current, then a repository bound to
/// it — and a screen built before the last of those has nothing to read
/// from. That is the ordinary first second of every cold load, and it
/// used to reach the screen as `Bad state: No organization selected`
/// under a red icon, which is a fair description of the code and a
/// terrible one of the situation.
///
/// Given its own type so [AsyncView] can tell it apart from a failure
/// and wait, rather than putting every error behind the same delay.
class OrgNotReady implements Exception {
  const OrgNotReady();

  @override
  String toString() => 'Your company has not finished loading.';
}

Repo requireRepo(Ref ref) {
  final repo = ref.watch(repoProvider);
  if (repo == null) throw const OrgNotReady();
  return repo;
}

final memberRoleProvider = FutureProvider<String>((ref) async {
  final org = await ref.watch(currentOrgProvider.future);
  final user = ref.watch(currentUserProvider);
  if (org == null || user == null) return 'viewer';

  final row = await ref
      .watch(supabaseProvider)
      .from('org_members')
      .select('role')
      .eq('org_id', org.id)
      .eq('user_id', user.id)
      .maybeSingle();
  return row?['role']?.toString() ?? 'viewer';
});

// These mirror app.can_post / can_write / can_read_ledger in the
// database. They only decide what the UI offers; RLS is what actually
// enforces it, so a stale copy here cannot become a security hole.

/// Whether the current member may post to the ledger. An accounts clerk
/// deliberately sits outside this: they prepare, someone else posts.
final canPostProvider = Provider<bool>((ref) {
  final role = ref.watch(memberRoleProvider).value ?? 'viewer';
  return const ['owner', 'admin', 'accountant'].contains(role);
});

final canWriteProvider = Provider<bool>((ref) {
  final role = ref.watch(memberRoleProvider).value ?? 'viewer';
  return const [
    'owner',
    'admin',
    'accountant',
    'accounts_clerk',
    'sales',
    'purchaser',
  ].contains(role);
});

final canAdminProvider = Provider<bool>((ref) {
  final role = ref.watch(memberRoleProvider).value ?? 'viewer';
  return const ['owner', 'admin'].contains(role);
});

/// Who may see the journals and audit trail. Auditors get read access to
/// everything; sales and purchasing staff do not.
final canReadLedgerProvider = Provider<bool>((ref) {
  final role = ref.watch(memberRoleProvider).value ?? 'viewer';
  return const [
    'owner',
    'admin',
    'accountant',
    'accounts_clerk',
    'auditor',
  ].contains(role);
});

// ---------------------------------------------------------------------
// Data providers
// ---------------------------------------------------------------------
final dashboardProvider = FutureProvider.autoDispose<DashboardSummary>((ref) {
  return requireRepo(ref).dashboard();
});

final revenueTrendProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).revenueTrend();
    });

final contactsProvider = FutureProvider.autoDispose
    .family<List<Contact>, ({String type, String search})>((ref, args) {
      return requireRepo(ref).contacts(type: args.type, search: args.search);
    });

final itemsProvider = FutureProvider.autoDispose.family<List<Item>, String>((
  ref,
  search,
) {
  return requireRepo(ref).items(search: search);
});

final taxCodesProvider = FutureProvider<List<TaxCode>>((ref) {
  return requireRepo(ref).taxCodes();
});

final accountsProvider = FutureProvider<List<Account>>((ref) {
  return requireRepo(ref).accounts();
});

final fiscalYearsProvider = FutureProvider.autoDispose<List<FiscalYear>>((ref) {
  return requireRepo(ref).fiscalYears();
});

/// The ledger. Filtered by source so "show me only the payroll journals"
/// does not mean scrolling.
final journalSourceFilterProvider = StateProvider<String?>((ref) => null);

final journalsProvider = FutureProvider.autoDispose<List<JournalEntry>>((ref) {
  return requireRepo(
    ref,
  ).journals(source: ref.watch(journalSourceFilterProvider));
});

final classificationCodesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) {
  return requireRepo(ref).classificationCodes();
});

typedef DocQuery = ({
  DocKind kind,
  String docType,
  String status,
  String search,
});

final documentsProvider = FutureProvider.autoDispose
    .family<List<BusinessDocument>, DocQuery>((ref, args) {
      return requireRepo(ref).documents(
        kind: args.kind,
        docType: args.docType,
        status: args.status,
        search: args.search,
      );
    });

final documentProvider = FutureProvider.autoDispose
    .family<BusinessDocument, ({DocKind kind, String id})>((ref, args) {
      return requireRepo(ref).document(args.kind, args.id);
    });

final outstandingProvider = FutureProvider.autoDispose
    .family<List<BusinessDocument>, ({DocKind kind, String contactId})>((
      ref,
      args,
    ) {
      return requireRepo(
        ref,
      ).outstandingFor(kind: args.kind, contactId: args.contactId);
    });

final bankAccountsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).bankAccounts();
});

final bankTransfersProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).bankTransfers();
    });

final paymentModesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).paymentModes();
});

/// ISO 4217 codes, shared across tenants and effectively static — kept
/// alive rather than autoDisposed so opening an invoice does not refetch
/// the same forty rows.
final currenciesProvider = FutureProvider<List<Currency>>((ref) {
  return requireRepo(ref).currencies();
});

/// Where a customer stands against their credit limit. Family keyed by
/// contact so switching customers on a document refetches.
final customerCreditProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, contactId) {
      return requireRepo(ref).customerCreditStatus(contactId);
    });

final recurringJournalsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).recurringJournals();
    });

final withholdingTypesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) {
  return requireRepo(ref).withholdingTypes();
});

final withholdingReportProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).withholdingReport();
    });

final recurringDocumentsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).recurringDocuments();
    });

final priceLevelsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).priceLevels();
});

final projectsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).projects();
});

/// Only the people still selling. A dropdown listing everyone who ever
/// worked here grows without bound and makes the current team harder to
/// find; the report still shows leavers, because their sales happened.
/// What LHDN credentials each environment has, without the secrets.
final einvoiceStatusProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) {
  return requireRepo(ref).einvoiceCredentialStatus();
});

final salespeopleProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).salespeople(activeOnly: true);
});

final warehousesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).warehouses();
});

final stockOnHandProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String?>((ref, warehouseId) {
      return requireRepo(ref).stockOnHand(warehouseId: warehouseId);
    });

/// One item's movements, optionally narrowed to a period or a single
/// warehouse. The dates are nullable on purpose: a card with no start
/// date opens on the first movement rather than on a brought-forward
/// line, and that is the common way to read one.
final stockCardProvider = FutureProvider.autoDispose
    .family<
      List<Map<String, dynamic>>,
      ({String itemId, DateTime? from, DateTime? to, String? warehouseId})
    >((ref, args) {
      return requireRepo(ref).stockCard(
        itemId: args.itemId,
        from: args.from,
        to: args.to,
        warehouseId: args.warehouseId,
      );
    });

final stockAdjustmentsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).stockAdjustments();
    });

/// Why this account cannot be closed yet, if it cannot.
final accountDeletionBlockersProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).accountDeletionBlockers();
    });

/// The reconciliation register for one account, or all of them.
final bankReconciliationsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String?>((ref, bankAccountId) {
      return requireRepo(ref).bankReconciliations(bankAccountId: bankAccountId);
    });

final fixedAssetsProvider = FutureProvider.autoDispose
    .family<List<FixedAsset>, bool>((ref, includeDisposed) {
      return requireRepo(ref).fixedAssets(includeDisposed: includeDisposed);
    });

final depreciationPreviewProvider = FutureProvider.autoDispose
    .family<List<DepreciationLine>, DateTime>((ref, asAt) {
      return requireRepo(ref).depreciationPreview(asAt);
    });

/// One asset's charges, in the order they were posted.
final depreciationHistoryProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, assetId) {
      return requireRepo(ref).depreciationHistory(assetId);
    });

/// The fixed asset note. Both dates are nullable: no start date means
/// since the company began, which is the position rather than a period.
final assetMovementsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({DateTime? from, DateTime? to})>((
      ref,
      args,
    ) {
      return requireRepo(ref).assetMovements(from: args.from, to: args.to);
    });

/// What revaluing the open foreign balances at [asAt] would do. Kept
/// autoDispose because the answer moves with every rate and every
/// settlement.
final fxRevaluationPreviewProvider = FutureProvider.autoDispose
    .family<List<FxRevaluation>, DateTime>((ref, asAt) {
      return requireRepo(ref).fxRevaluationPreview(asAt);
    });

final expensesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) {
    return requireRepo(ref).expenses();
  },
);

final einvoicesProvider = FutureProvider.autoDispose
    .family<List<EinvoiceDocument>, String>((ref, status) {
      return requireRepo(ref).einvoices(status: status);
    });

final pipelineStagesProvider = FutureProvider<List<PipelineStage>>((ref) {
  return requireRepo(ref).pipelineStages();
});

final opportunitiesProvider = FutureProvider.autoDispose<List<Opportunity>>((
  ref,
) {
  return requireRepo(ref).opportunities();
});

/// Today's receivables, aged. The dashboard card and the Reports tab
/// read the same function so the two cannot drift; the tab passes an
/// as-at date and this one does not.
final arAgingProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((
  ref,
) {
  return requireRepo(ref).agedBalances(receivable: true);
});

/// Keyed by side and as-at date, so changing either restates the report
/// rather than leaving the last one on screen while it reloads.
final agedBalancesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({bool receivable, DateTime asAt})>((
      ref,
      args,
    ) {
      return requireRepo(
        ref,
      ).agedBalances(receivable: args.receivable, asAt: args.asAt);
    });

final trialBalanceProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).trialBalance();
    });

/// The combined trial balance across the group, for a period.
///
/// Family by range rather than a single provider: the group screen has
/// its own date picker and a report for the wrong dates is worse than a
/// spinner.
final groupTrialBalanceProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({DateTime from, DateTime to})>((
      ref,
      range,
    ) {
      return requireRepo(ref).groupTrialBalance(from: range.from, to: range.to);
    });

/// What a consolidation would have to eliminate.
final groupConsolidatedProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({DateTime from, DateTime to})>((
      ref,
      range,
    ) {
      return requireRepo(ref).groupConsolidated(from: range.from, to: range.to);
    });

final groupEliminationCheckProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({DateTime from, DateTime to})>((
      ref,
      range,
    ) {
      return requireRepo(
        ref,
      ).groupEliminationCheck(from: range.from, to: range.to);
    });

final groupIntercompanyProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({DateTime from, DateTime to})>((
      ref,
      range,
    ) {
      return requireRepo(ref).groupIntercompany(from: range.from, to: range.to);
    });

final activitiesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).activities();
    });

/// Invalidates everything that could change after a document is posted.
void refreshLedgerData(WidgetRef ref) {
  ref.invalidate(dashboardProvider);
  ref.invalidate(revenueTrendProvider);
  ref.invalidate(arAgingProvider);
  ref.invalidate(trialBalanceProvider);
  ref.invalidate(documentsProvider);
  ref.invalidate(einvoicesProvider);
  ref.invalidate(bankAccountsProvider);
  ref.invalidate(expensesProvider);
}

// ---------------------------------------------------------------------
// Platform administration
// ---------------------------------------------------------------------
final platformRepoProvider = Provider<PlatformRepo>(
  (ref) => PlatformRepo(ref.watch(supabaseProvider)),
);

/// Whether the signed-in user is platform staff. Drives whether the
/// admin console appears, and where the router sends somebody who
/// belongs to no organization.
///
/// Allowed to fail rather than answering false. It used to catch
/// everything and report "not an admin", which reads like a safe
/// default and is not one. The operator belongs to no company by
/// design, so the router's no-organization branch is the one they land
/// in — and with a false here that branch pins them to the
/// company-setup form. One failed RPC, a token refreshing mid-flight,
/// a request that timed out, and the person who runs the platform is
/// looking at "Set up your company" with nothing on screen saying why.
///
/// A question that could not be asked is not a question answered no.
///
/// Nobody gains access from this. The console's real guard is the
/// SECURITY DEFINER function behind this call, and every platform RPC
/// checks again server-side. What the error state buys is the router
/// holding still instead of guessing, and the console offering "try
/// again" instead of "not a platform administrator".
final isPlatformAdminProvider = FutureProvider<bool>((ref) async {
  if (ref.watch(currentUserProvider) == null) return false;
  return ref.watch(platformRepoProvider).amIPlatformAdmin();
});

final platformStatsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((
  ref,
) {
  return ref.watch(platformRepoProvider).stats();
});

final platformOrgsProvider = FutureProvider.autoDispose<List<PlatformOrg>>((
  ref,
) {
  return ref.watch(platformRepoProvider).organizations();
});

final platformModulesProvider = FutureProvider<List<ModuleInfo>>((ref) {
  return ref.watch(platformRepoProvider).modules();
});

final platformSettingsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return ref.watch(platformRepoProvider).settings();
    });

// ---------------------------------------------------------------------
// Module entitlements for the active tenant
// ---------------------------------------------------------------------
final enabledModulesProvider = FutureProvider<Set<String>>((ref) async {
  final repo = ref.watch(repoProvider);
  if (repo == null) return <String>{};
  return repo.enabledModules();
});

/// What the person signed in may do in each module: `none`, `read` or
/// `write`. Everything is `write` until their company defines an access
/// type and assigns it, which is how every member stands today.
final myModuleAccessProvider = FutureProvider<Map<String, String>>((ref) async {
  final repo = ref.watch(repoProvider);
  if (repo == null) return const {};
  return repo.myModuleAccess();
});

/// Synchronous check for widgets. Treats "still loading" as enabled so
/// navigation does not flicker on start-up.
///
/// Two different questions, and both have to be yes: the company must
/// have bought the module, and this person must be allowed into it.
/// Hiding is a courtesy — the restrictive policies 0127 added are the
/// control, and they do not care what the client believes.
bool moduleEnabled(WidgetRef ref, String code) {
  final modules = ref.watch(enabledModulesProvider);
  final entitled = modules.when(
    data: (set) => set.contains(code),
    loading: () => true,
    error: (_, __) => true,
  );
  if (!entitled) return false;

  return ref
      .watch(myModuleAccessProvider)
      .when(
        data: (access) => (access[code] ?? 'write') != 'none',
        loading: () => true,
        error: (_, __) => true,
      );
}

/// Whether this person may change anything in a module, as opposed to
/// only looking at it.
bool moduleWritable(WidgetRef ref, String code) => ref
    .watch(myModuleAccessProvider)
    .when(
      data: (access) => (access[code] ?? 'write') == 'write',
      loading: () => true,
      error: (_, __) => true,
    );

// ---------------------------------------------------------------------
// Team
// ---------------------------------------------------------------------
final teamProvider = FutureProvider.autoDispose<List<TeamMember>>((ref) {
  return requireRepo(ref).team();
});

/// The places this company trades from. Empty for a company that has
/// never opened a second one, which is most of them.
final branchesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) {
    return requireRepo(ref).branches();
  },
);

/// The other companies in this one's group that the person asking is
/// already a member of — never one more than that.
final groupCompaniesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).groupCompanies();
    });

/// Invoices from group companies waiting to be turned into bills here.
final intercompanyInboxProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).intercompanyInbox();
    });

/// How far the move onto this system has got — six imports in the order
/// they have to be done, and the balance of 3900 as the verdict.
final migrationProgressProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).migrationProgress();
    });

// ---------------------------------------------------------------------
// Push notifications
// ---------------------------------------------------------------------

/// Whether this device can be reached when the app is closed, and
/// whether it currently is.
final pushStatusProvider = FutureProvider.autoDispose<PushStatus>((ref) {
  // Permission belongs to the browser and the registration belongs to
  // the person, so signing in as somebody else has to re-ask.
  ref.watch(currentUserProvider);
  return pushStatus(Env.webPushPublicKey);
});

/// Subscribe this browser and put it on the register.
///
/// `ask` decides whether the permission prompt may appear. Safari
/// requires that prompt to come from a user gesture and a browser that
/// has refused once will not be asked again, so the app only ever asks
/// from a button — see `keepPushRegistered` for what happens on start.
/// Takes the repository rather than a ref, because `Ref` and `WidgetRef`
/// have no common supertype and this is called from both a provider and
/// a button. Whoever calls it refreshes [pushStatusProvider].
Future<PushStatus> enablePush(Repo? repo, {bool ask = true}) async {
  if (repo == null) return PushStatus.unsupported;

  final subscription = await subscribeToPush(Env.webPushPublicKey, ask: ask);
  if (subscription == null) return pushStatus(Env.webPushPublicKey);

  await repo.registerDevice(
    token: subscription.endpoint,
    platform: 'web',
    label: 'This browser',
    p256dh: subscription.p256dh,
    auth: subscription.auth,
  );
  return PushStatus.on;
}

/// Re-register on every start, without ever prompting.
///
/// The endpoint is not stable: a browser may rotate it at any time, and
/// the register would then hold one nobody can send to while the person
/// sees notifications as switched on. Re-registering is cheap — 0143
/// keys on the token, so an unchanged endpoint updates one row — and it
/// is the only thing that catches a rotation.
///
/// Silent by construction: `ask: false` means a browser that has never
/// been asked stays unasked, and one that refused is not nagged.
final pushRegistrarProvider = FutureProvider<void>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return;
  if (await pushStatus(Env.webPushPublicKey) != PushStatus.on) return;
  await enablePush(ref.read(repoProvider), ask: false);
});

/// Take this browser off the register, on the way out.
///
/// Best effort by nature — an app that is force-quit never gets here —
/// which is why the sender also drops endpoints the push service
/// rejects.
Future<void> disablePush(Repo? repo) async {
  final endpoint = await currentPushEndpoint();
  if (endpoint != null) await repo?.unregisterDevice(endpoint);
  await unsubscribeFromPush();
}

// ---------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------

/// The conversation list, carrying unread counts, the other person's
/// presence and how far they have read.
final chatConversationsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).chatConversations();
    });

/// Who you may start a conversation with.
final chatDirectoryProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).chatDirectory();
    });

/// Who is in a conversation, with their company named. A room that
/// crosses a boundary is exactly where "who can hear this?" has to be
/// answerable without leaving it.
/// The call happening in a conversation right now, if any.
final chatActiveCallProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, conversationId) {
      return requireRepo(ref).chatActiveCall(conversationId);
    });

/// Every phone that should be ringing for this person. Watched by the
/// shell so a call arrives wherever they are in the app.
final chatIncomingCallsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).chatIncomingCalls();
    });

final chatMembersProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, conversationId) {
      return requireRepo(ref).chatMembers(conversationId);
    });

final chatThreadProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, conversationId) {
      return requireRepo(ref).chatThread(conversationId);
    });

final chatTypingProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, conversationId) {
      return requireRepo(ref).chatWhoIsTyping(conversationId);
    });

/// Everybody in the company and whether the administrator has switched
/// them on. Administrators only — the function refuses anybody else.
final chatAccessListProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).chatAccessList();
    });

/// Links to other companies, in both directions, pending ones first.
final chatLinksProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).chatLinks();
    });

/// How many messages are waiting, for the badge on the rail. Derived
/// from the list rather than counted separately, so the two can never
/// disagree.
final chatUnreadProvider = Provider.autoDispose<int>((ref) {
  return ref
      .watch(chatConversationsProvider)
      .maybeWhen(
        data: (rows) => rows.fold<int>(
          0,
          (sum, r) => sum + ((r['unread'] as num?)?.toInt() ?? 0),
        ),
        orElse: () => 0,
      );
});

// ---------------------------------------------------------------------
// Manufacturing
// ---------------------------------------------------------------------

/// What things are made of.
final bomsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((
  ref,
) {
  return requireRepo(ref).billsOfMaterials();
});

/// Where the work happens, and what an hour of it costs.
final workCentresProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).workCentres();
    });

/// Orders to make something. [openOnly] is the shop floor's view — the
/// ones still to be made — rather than everything ever made.
final manufacturingOrdersProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, bool>((ref, openOnly) {
      return requireRepo(ref).manufacturingOrders(openOnly: openOnly);
    });

final manufacturingOrderProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, id) {
      return requireRepo(ref).manufacturingOrder(id);
    });

/// What is missing before the line can start.
final manufacturingShortagesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, id) {
      return requireRepo(ref).manufacturingShortages(id);
    });

/// Whether anything has reached the ledger yet. Asked before offering to
/// change the base currency, which cannot be corrected afterwards.
final hasPostingsProvider = FutureProvider.autoDispose<bool>((ref) {
  return requireRepo(ref).hasPostings();
});

/// The access types a company has defined for itself.
final accessTypesProvider = FutureProvider.autoDispose<List<AccessType>>((ref) {
  return requireRepo(ref).accessTypes();
});

// ---------------------------------------------------------------------
// Legal firm module
// ---------------------------------------------------------------------
final mattersProvider = FutureProvider.autoDispose
    .family<List<Matter>, ({String status, String search})>((ref, args) {
      return requireRepo(ref).matters(status: args.status, search: args.search);
    });

final matterSummaryProvider = FutureProvider.autoDispose<List<MatterSummary>>((
  ref,
) {
  return requireRepo(ref).matterSummary();
});

final clientTransactionsProvider = FutureProvider.autoDispose
    .family<List<ClientTransaction>, String>((ref, matterId) {
      return requireRepo(ref).clientTransactions(matterId);
    });

final timeEntriesProvider = FutureProvider.autoDispose
    .family<List<TimeEntry>, String>((ref, matterId) {
      return requireRepo(ref).timeEntries(matterId);
    });

final disbursementsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, matterId) {
      return requireRepo(ref).disbursements(matterId);
    });

/// Refresh everything a matter screen shows after money moves.
void refreshMatter(WidgetRef ref, String matterId) {
  ref.invalidate(clientTransactionsProvider(matterId));
  ref.invalidate(timeEntriesProvider(matterId));
  ref.invalidate(disbursementsProvider(matterId));
  ref.invalidate(matterSummaryProvider);
  ref.invalidate(bankAccountsProvider);
}

// ---------------------------------------------------------------------
// HRMS
//
// These mirror app.can_manage_hr / can_run_payroll. As with the finance
// tiers, they only decide what the UI offers — RLS decides what actually
// comes back.
// ---------------------------------------------------------------------
final canManageHrProvider = Provider<bool>((ref) {
  final role = ref.watch(memberRoleProvider).value ?? 'viewer';
  return const ['owner', 'admin', 'hr_manager'].contains(role);
});

/// Payroll touches the ledger, so it needs a finance role as well as HR.
final canRunPayrollProvider = Provider<bool>((ref) {
  final role = ref.watch(memberRoleProvider).value ?? 'viewer';
  return const ['owner', 'admin', 'hr_manager', 'accountant'].contains(role);
});

final directoryProvider = FutureProvider.autoDispose<List<Employee>>((ref) {
  return requireRepo(ref).directory();
});

final employeesProvider = FutureProvider.autoDispose
    .family<List<Employee>, String?>((ref, status) {
      return requireRepo(ref).employees(status: status);
    });

final employeeProvider = FutureProvider.autoDispose.family<Employee?, String>((
  ref,
  id,
) {
  return requireRepo(ref).employee(id);
});

/// What an employee brought with them into the current tax year, and the
/// reliefs they have declared. Keyed by employee because the tax year is
/// always the current one — a past year is history, not something the
/// projection can still act on.
final ytdOpeningProvider = FutureProvider.autoDispose
    .family<YtdOpening?, String>((ref, employeeId) {
      return requireRepo(ref).ytdOpening(employeeId, DateTime.now().year);
    });

final declaredReliefsProvider = FutureProvider.autoDispose
    .family<List<DeclaredRelief>, String>((ref, employeeId) {
      return requireRepo(ref).declaredReliefs(employeeId, DateTime.now().year);
    });

final reliefTypesProvider = FutureProvider<List<ReliefType>>((ref) {
  return requireRepo(ref).reliefTypes(DateTime.now());
});

/// The caller's own employee record. Everything on the self-service
/// screen hangs off this, and it is null when the login is not linked.
final myEmployeeProvider = FutureProvider<Employee?>((ref) {
  final repo = ref.watch(repoProvider);
  if (repo == null) return Future.value(null);
  return repo.myEmployee();
});

final myAttendanceTodayProvider = FutureProvider.autoDispose<AttendanceRecord?>(
  (ref) async {
    final me = await ref.watch(myEmployeeProvider.future);
    if (me == null) return null;
    final today = DateTime.now();
    final rows = await requireRepo(ref).attendance(
      employeeId: me.id,
      from: DateTime(today.year, today.month, today.day),
      to: DateTime(today.year, today.month, today.day),
    );
    return rows.isEmpty ? null : rows.first;
  },
);

final attendanceProvider = FutureProvider.autoDispose
    .family<List<AttendanceRecord>, String?>((ref, employeeId) {
      final now = DateTime.now();
      return requireRepo(ref).attendance(
        employeeId: employeeId,
        from: DateTime(now.year, now.month, 1),
      );
    });

final leaveTypesProvider = FutureProvider<List<LeaveType>>((ref) {
  return requireRepo(ref).leaveTypes();
});

final myLeaveBalancesProvider = FutureProvider.autoDispose<List<LeaveBalance>>((
  ref,
) async {
  final me = await ref.watch(myEmployeeProvider.future);
  if (me == null) return const [];
  return requireRepo(ref).leaveBalances(me.id, DateTime.now().year);
});

final leaveRequestsProvider = FutureProvider.autoDispose
    .family<List<LeaveRequest>, String>((ref, status) {
      return requireRepo(ref).leaveRequests(status: status);
    });

final claimsProvider = FutureProvider.autoDispose
    .family<List<ExpenseClaim>, String>((ref, status) {
      return requireRepo(ref).claims(status: status);
    });

/// The claims this person is the one holding up.
final claimsAwaitingMeProvider = FutureProvider.autoDispose<List<ExpenseClaim>>(
  (ref) {
    return requireRepo(ref).claimsAwaitingMe();
  },
);

/// The approval chain on one claim.
final claimApprovalsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, claimId) {
      return requireRepo(ref).claimApprovals(claimId);
    });

final claimTypesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).claimTypes();
});

/// Where the approval chain becomes the full chain. Null until a company
/// sets one, which the database reads as zero.
final claimApprovalThresholdProvider = FutureProvider.autoDispose<double?>((
  ref,
) {
  return requireRepo(ref).claimApprovalThreshold();
});

final payrollRunsProvider = FutureProvider.autoDispose<List<PayrollRun>>((ref) {
  return requireRepo(ref).payrollRuns();
});

final payslipsForRunProvider = FutureProvider.autoDispose
    .family<List<Payslip>, String>((ref, runId) {
      // Payroll reads the table directly; a granted reader goes through the
      // function that logs the read.
      final repo = requireRepo(ref);
      return ref.watch(canRunPayrollProvider)
          ? repo.payslips(runId: runId)
          : repo.auditPayslips(runId: runId);
    });

final myPayslipsProvider = FutureProvider.autoDispose<List<Payslip>>((
  ref,
) async {
  final me = await ref.watch(myEmployeeProvider.future);
  if (me == null) return const [];
  return requireRepo(ref).payslips(employeeId: me.id);
});

final payslipProvider = FutureProvider.autoDispose.family<Payslip?, String>((
  ref,
  id,
) async {
  final repo = requireRepo(ref);
  if (ref.watch(canRunPayrollProvider)) return repo.payslip(id);
  // An employee opening their own payslip still reads the table; only a
  // granted outsider is routed through the logged function.
  final mine = await repo.payslip(id).catchError((_) => null);
  if (mine != null) return mine;
  return repo.auditPayslip(id);
});

/// The bank instruction for a posted run. Only payroll may ask; the
/// function refuses anyone else, so the screen guards on the same right.
final paymentInstructionProvider = FutureProvider.autoDispose
    .family<List<PaymentLine>, String>((ref, runId) {
      return requireRepo(ref).paymentInstruction(runId);
    });

// ---------------------------------------------------------------------
// Corporate secretarial
// ---------------------------------------------------------------------
final corpEntitiesProvider = FutureProvider.autoDispose<List<CorpEntity>>((
  ref,
) {
  return requireRepo(ref).corpEntities();
});

final corpEntityProvider = FutureProvider.autoDispose
    .family<CorpEntity?, String>((ref, id) {
      return requireRepo(ref).corpEntity(id);
    });

final corpOfficersProvider = FutureProvider.autoDispose
    .family<List<CorpOfficer>, String>((ref, id) {
      return requireRepo(ref).corpOfficers(id);
    });

final corpMembersProvider = FutureProvider.autoDispose
    .family<List<CorpMember>, String>((ref, id) {
      return requireRepo(ref).corpRegisterOfMembers(id);
    });

final corpShareEventsProvider = FutureProvider.autoDispose
    .family<List<CorpShareEvent>, String>((ref, id) {
      return requireRepo(ref).corpShareEvents(id);
    });

final corpBeneficialOwnersProvider = FutureProvider.autoDispose
    .family<List<CorpBeneficialOwner>, String>((ref, id) {
      return requireRepo(ref).corpBeneficialOwners(id);
    });

final corpChargesProvider = FutureProvider.autoDispose
    .family<List<CorpCharge>, String>((ref, id) {
      return requireRepo(ref).corpCharges(id);
    });

final corpDocumentsProvider = FutureProvider.autoDispose
    .family<List<CorpDocument>, String>((ref, id) {
      return requireRepo(ref).corpDocuments(id);
    });

/// Every obligation falling due, computed from each entity's own dates.
final corpFilingsProvider = FutureProvider.autoDispose<List<CorpFiling>>((ref) {
  return requireRepo(ref).corpUpcomingFilings(withinDays: 180);
});

final corpTemplatesProvider = FutureProvider<List<CorpTemplate>>((ref) {
  return requireRepo(ref).corpTemplates();
});

final corpSignaturesProvider = FutureProvider.autoDispose
    .family<List<CorpSignature>, String>((ref, id) {
      return requireRepo(ref).corpSignatures(id);
    });

final corpPersonsProvider = FutureProvider.autoDispose<List<CorpPerson>>((ref) {
  return requireRepo(ref).corpPersons();
});

final requisitionsProvider = FutureProvider.autoDispose<List<JobRequisition>>((
  ref,
) {
  return requireRepo(ref).requisitions();
});

final applicantsProvider = FutureProvider.autoDispose<List<Applicant>>((ref) {
  return requireRepo(ref).applicants();
});

final appraisalsProvider = FutureProvider.autoDispose<List<Appraisal>>((ref) {
  return requireRepo(ref).appraisals();
});

/// Whether the caller holds a live, admin-approved grant to read payslips.
final myPayslipAccessProvider = FutureProvider.autoDispose<bool>((ref) {
  final repo = ref.watch(repoProvider);
  if (repo == null) return Future.value(false);
  return repo.myPayslipAccess();
});

final payslipAccessRequestsProvider =
    FutureProvider.autoDispose<List<PayslipAccessRequest>>((ref) {
      return requireRepo(ref).payslipAccessRequests();
    });

/// True for an auditor: no payroll rights, but may ask for them.
final canRequestPayslipAccessProvider = Provider<bool>((ref) {
  return (ref.watch(memberRoleProvider).value ?? '') == 'auditor';
});

final payslipAccessLogProvider =
    FutureProvider.autoDispose<List<PayslipAccessLogEntry>>((ref) {
      return requireRepo(ref).payslipAccessLog();
    });

/// The change history. Owners and admins only — the RPC refuses anyone
/// else, so the screen guards on the same right rather than showing an
/// error where a card should be.
final auditTrailProvider = FutureProvider.autoDispose<List<AuditEntry>>((ref) {
  return requireRepo(ref).auditTrail();
});

final departmentsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).departments();
});

final positionsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).positions();
});

final payrollSettingsProvider =
    FutureProvider.autoDispose<Map<String, dynamic>?>((ref) {
      return requireRepo(ref).payrollSettings();
    });

/// One provider for every simple configuration list, keyed by table.
final setupRowsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({String table, String orderBy})>((
      ref,
      arg,
    ) {
      return requireRepo(ref).setupRows(arg.table, orderBy: arg.orderBy);
    });

/// The thirteen states and three federal territories. Most Malaysian
/// public holidays are observed in some of them and not others.
final statesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).states();
});

final publicHolidaysProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, int>((ref, year) {
      return requireRepo(ref).publicHolidays(year);
    });

final leaveBandsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, leaveTypeId) {
      return requireRepo(ref).leaveBands(leaveTypeId);
    });

/// The statutory rate tables — EPF, SOCSO, EIS, PCB.
///
/// Not autoDispose: they are the same for every organization in the
/// database and change a few times a decade.
///
/// Off [platformRepoProvider] rather than the org-bound repository, for
/// the same reason: the rows have no `org_id`. Going through
/// `requireRepo` made an organization a precondition for reading data
/// that has nothing to do with one — and the platform console, where
/// the only person who may *edit* these works, is exactly where
/// somebody may belong to no company. It surfaced as "your company has
/// not finished loading, check your connection", which sends the reader
/// to look at their network.
final statutorySchedulesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) {
  return ref.watch(platformRepoProvider).statutorySchedules();
});

final itemPricesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, itemId) {
      return requireRepo(ref).itemPrices(itemId);
    });

final contactPersonsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contactId) {
      return requireRepo(ref).contactPersons(contactId);
    });

final contactAddressesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contactId) {
      return requireRepo(ref).contactAddresses(contactId);
    });

final emailSettingsProvider = FutureProvider.autoDispose<Map<String, dynamic>?>(
  (ref) {
    return requireRepo(ref).emailSettings();
  },
);

final emailOutboxProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, status) {
      return requireRepo(ref).emailOutbox(status: status);
    });

final documentShareLinksProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, documentId) {
      return requireRepo(ref).documentShareLinks(documentId);
    });

/// Money in (`true`) or money out (`false`).
final settlementsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, bool>((ref, isSales) {
      return requireRepo(ref).settlements(isSales: isSales);
    });

/// One settlement and its allocations. Keyed by id and direction,
/// because a receipt and a supplier payment are different tables.
final settlementProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, ({String id, bool isSales})>((ref, key) {
      return requireRepo(ref).settlement(key.id, isSales: key.isSales);
    });

/// Messages, share links and downloads for one document, newest first.
final documentActivityProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, documentId) {
      return requireRepo(ref).documentActivity(documentId);
    });

final appraisalGoalsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, appraisalId) {
      return requireRepo(ref).appraisalGoals(appraisalId);
    });

final leadsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, status) {
      return requireRepo(ref).leads(status: status);
    });

final pipelinesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).pipelines();
});

final interviewsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, applicantId) {
      return requireRepo(ref).interviews(applicantId);
    });

final onboardingChecklistsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, bool>((ref, openOnly) {
      return requireRepo(ref).onboardingChecklists(openOnly: openOnly);
    });

final onboardingTasksProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, checklistId) {
      return requireRepo(ref).onboardingTasks(checklistId);
    });

final templateItemsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, templateId) {
      return requireRepo(ref).onboardingTemplateItems(templateId);
    });

/// Dependants, documents and shifts all hang off one employee and are
/// read the same way, so they share a provider keyed by table.
final employeeRowsProvider = FutureProvider.autoDispose
    .family<
      List<Map<String, dynamic>>,
      ({String table, String employeeId, String select, String orderBy})
    >((ref, arg) {
      return requireRepo(ref).employeeRows(
        arg.table,
        arg.employeeId,
        select: arg.select,
        orderBy: arg.orderBy,
      );
    });

/// The company logo as raw bytes, for embedding in a PDF.
///
/// Separate from `currentOrgProvider.logoUrl`, which is a URL for the
/// browser to fetch: a PDF needs the bytes themselves, and reading them
/// through the storage client sidesteps both CORS and the cache that
/// makes a replaced logo look unchanged.
final orgLogoProvider = FutureProvider<Uint8List?>((ref) async {
  final repo = ref.watch(repoProvider);
  final org = ref.watch(currentOrgProvider).valueOrNull;
  if (repo == null || org?.logoUrl == null) return null;
  return repo.orgLogoBytes();
});

/// Whether this organization reads its own paperwork, and what is left
/// to pay for it.
///
/// Not autoDispose: half a dozen screens ask, the answer changes only
/// when somebody edits a setting or spends a scan, and both of those
/// invalidate it.
final ocrStatusProvider = FutureProvider<OcrSettings>((ref) {
  return requireRepo(ref).ocrStatus();
});

final creditLedgerProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).creditLedger();
    });

final creditInvoicesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).creditInvoices();
    });

/// Every tenant's scanning balance, emptiest first, and the invoices
/// raised for what they bought. Platform staff only — the RPCs behind
/// these re-check that.
final platformCreditProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return ref.watch(platformRepoProvider).creditSummary();
    });

final platformInvoicesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return ref.watch(platformRepoProvider).creditInvoices();
    });

// ---------------------------------------------------------------------
// Property
//
// The spine is shared, so `propertySitesProvider` takes the tenure it
// wants rather than there being two of it. Passing null asks for the
// whole portfolio, which is what a managing agent holding both modules
// is looking at.
// ---------------------------------------------------------------------

final propertySitesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String?>((ref, tenure) {
      return requireRepo(ref).propertySites(tenure: tenure);
    });

final propertySiteProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, id) {
      return requireRepo(ref).propertySite(id);
    });

final propertyUnitsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, siteId) {
      return requireRepo(ref).propertyUnits(siteId);
    });

/// Null where the site has no scheme record yet — a strata site can be
/// entered before anybody has filled in who runs it.
final strataSchemeProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, siteId) {
      return requireRepo(ref).strataScheme(siteId);
    });

final strataChargeRunsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, schemeId) {
      return requireRepo(ref).strataChargeRuns(schemeId);
    });

/// What is owed and the late payment charge that has accrued on it.
final strataArrearsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, schemeId) {
      return requireRepo(ref).strataArrears(schemeId);
    });

final tenanciesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String?>((ref, siteId) {
      return requireRepo(ref).tenancies(siteId: siteId);
    });

/// Quit rent and assessment falling due, across every site. The dashboard
/// question, not a per-site one: a managing agent loses a bill by not
/// looking at a site, so this never asks which site to look at.
final propertyStatutoryDueProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).propertyStatutoryDue();
    });

final propertyStatutoryChargesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, siteId) {
      return requireRepo(ref).propertyStatutoryCharges(siteId);
    });

// ---------------------------------------------------------------------
// Timesheets
// ---------------------------------------------------------------------

/// A person's own week, which is what the screen opens on. Everyone
/// else's is a report, not a list to scroll.
final myTimeEntriesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({DateTime from, DateTime to})>((
      ref,
      period,
    ) {
      return requireRepo(
        ref,
      ).timeLog(from: period.from, to: period.to, mine: true);
    });

/// What has been recorded against a project and not yet invoiced — the
/// list the person about to press "bill" is looking at.
final unbilledTimeProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, projectId) {
      return requireRepo(ref).timeLog(projectId: projectId, unbilledOnly: true);
    });

final timesheetReportProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({DateTime from, DateTime to})>((
      ref,
      period,
    ) {
      return requireRepo(ref).timesheetReport(period.from, period.to);
    });

final billingRatesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).billingRates();
    });

// ---------------------------------------------------------------------
// Debt collection
// ---------------------------------------------------------------------

/// Who owes what, and where the chasing got to. Already ordered by the
/// database — broken promises, then never chased, then oldest — so the
/// screen does not re-sort it and cannot disagree with the report.
final collectionsWorklistProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).collectionsWorklist();
    });

/// Everything ever said to one customer, newest first.
final collectionHistoryProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contactId) {
      return requireRepo(ref).collectionHistory(contactId);
    });

// ---------------------------------------------------------------------
// Approvals
// ---------------------------------------------------------------------

/// What is waiting on this person's signature. Deliberately not
/// autoDispose: the shell reads it for the badge on every screen, and a
/// provider that disposes between navigations would refetch the inbox
/// each time somebody moves.
final myApprovalsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).myApprovals();
});

final approvalRulesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).approvalRules();
    });

/// Where one document stands. Keyed on both halves because a sales and a
/// purchase document can share an id only by accident, but the kind is
/// what the function switches on and a cache keyed on the id alone would
/// eventually answer the wrong question.
final approvalStateProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, ({String kind, String id})>((ref, args) {
      return requireRepo(ref).approvalState(args.kind, args.id);
    });

// ---------------------------------------------------------------------
// Financial statements and MBRS
// ---------------------------------------------------------------------

final fsFilingsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).fsFilings();
    });

final fsFilingProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, id) {
      return requireRepo(ref).fsFiling(id);
    });

/// The statements as they stand. Read live on a draft and off the frozen
/// figures once frozen — `fs_export` decides which, so the screen cannot
/// show one and export the other.
final fsExportProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, filingId) {
      return requireRepo(ref).fsExport(filingId);
    });

final fsBalanceCheckProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, filingId) {
      return requireRepo(ref).fsBalanceCheck(filingId);
    });

final fsDeadlinesProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, filingId) {
      return requireRepo(ref).fsDeadlines(filingId);
    });

/// All three grounds, whether they apply or not. The screen shows the
/// ones that do not alongside why, because "why am I not exempt" is the
/// question an accountant actually asks.
final fsExemptionProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, filingId) {
      return requireRepo(ref).fsAuditExemption(filingId);
    });

final mbrsElementsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).mbrsElements();
});

// ---------------------------------------------------------------------
// Service desk
//
// The queue's filters travel as one record rather than four families,
// because they are read together and invalidated together: changing the
// team while a status filter is on has to refetch once, not twice.
// ---------------------------------------------------------------------
@immutable
class TicketQuery {
  const TicketQuery({
    this.status = 'open',
    this.teamId,
    this.priority,
    this.onlyMine = false,
    this.onlyBreached = false,
  });

  final String? status;
  final String? teamId;
  final String? priority;
  final bool onlyMine;
  final bool onlyBreached;

  TicketQuery copyWith({
    String? Function()? status,
    String? Function()? teamId,
    String? Function()? priority,
    bool? onlyMine,
    bool? onlyBreached,
  }) => TicketQuery(
    status: status == null ? this.status : status(),
    teamId: teamId == null ? this.teamId : teamId(),
    priority: priority == null ? this.priority : priority(),
    onlyMine: onlyMine ?? this.onlyMine,
    onlyBreached: onlyBreached ?? this.onlyBreached,
  );

  @override
  bool operator ==(Object other) =>
      other is TicketQuery &&
      other.status == status &&
      other.teamId == teamId &&
      other.priority == priority &&
      other.onlyMine == onlyMine &&
      other.onlyBreached == onlyBreached;

  @override
  int get hashCode =>
      Object.hash(status, teamId, priority, onlyMine, onlyBreached);
}

final ticketsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, TicketQuery>((ref, q) {
      return requireRepo(ref).tickets(
        status: q.status,
        teamId: q.teamId,
        priority: q.priority,
        onlyMine: q.onlyMine,
        onlyBreached: q.onlyBreached,
      );
    });

final ticketProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, id) {
      return requireRepo(ref).ticket(id);
    });

final ticketCommentsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, id) {
      return requireRepo(ref).ticketComments(id);
    });

final ticketEventsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, id) {
      return requireRepo(ref).ticketEvents(id);
    });

final ticketTeamsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) => requireRepo(ref).ticketTeams(),
);

final ticketCategoriesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).ticketCategories(),
    );

final cannedResponsesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).cannedResponses(),
    );

// ---------------------------------------------------------------------
// Inventory forecasting
// ---------------------------------------------------------------------

final forecastSettingsProvider =
    FutureProvider.autoDispose<Map<String, dynamic>?>(
      (ref) => requireRepo(ref).forecastSettings(),
    );

/// Keyed on the location, with null meaning the company as a whole.
///
/// A family rather than a single provider because the company-level
/// answer and a branch's are different answers to different questions,
/// and one cache holding whichever was asked for last is how a branch's
/// figures end up under the main store's heading.
final latestForecastRunProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String?>(
      (ref, warehouseId) =>
          requireRepo(ref).latestForecastRun(warehouseId: warehouseId),
    );

final forecastSuggestionsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String?>(
      (ref, warehouseId) =>
          requireRepo(ref).forecastSuggestions(warehouseId: warehouseId),
    );

final forecastLinesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, runId) => requireRepo(ref).forecastLines(runId),
    );

/// One item's parameters at one location. The record is keyed on both,
/// so asking with the wrong half returns the company-wide row and
/// silently saves over it.
typedef ItemParamsKey = ({String itemId, String? warehouseId});

final itemForecastParamsProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, ItemParamsKey>(
      (ref, key) => requireRepo(
        ref,
      ).itemForecastParams(key.itemId, warehouseId: key.warehouseId),
    );

// ---------------------------------------------------------------------
// Point of sale
// ---------------------------------------------------------------------

final posOutletsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posOutlets(),
    );

final posRegistersProvider = FutureProvider.autoDispose<
  List<Map<String, dynamic>>
>((ref) => requireRepo(ref).posRegisters());

/// The open shift on a register, or null. Everything the till can do
/// hangs off this being a row, which is why it is a provider rather
/// than something the screen reads once and remembers: a drawer closed
/// on another device has to reach this one.
final currentPosShiftProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>(
      (ref, registerId) => requireRepo(ref).currentPosShift(registerId),
    );

final posTenderTypesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posTenderTypes(),
    );

final posSaleProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>(
      (ref, saleId) => requireRepo(ref).posSale(saleId),
    );

final posSaleLinesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, saleId) => requireRepo(ref).posSaleLines(saleId),
    );

final parkedPosSalesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, registerId) => requireRepo(ref).parkedPosSales(registerId),
    );

/// Every open bill in the outlet, keyed by outlet rather than register
/// — which is the whole difference from [parkedPosSalesProvider].
final posOpenOrdersProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, outletId) => requireRepo(ref).posOpenOrders(outletId),
    );

/// The room. Keyed on the outlet rather than the register, because the
/// tables belong to the shop and not to the device looking at them —
/// two waiters on two tablets are looking at the same floor.
final posFloorPlanProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, outletId) => requireRepo(ref).posFloorPlan(outletId),
    );

final posKitchenStationsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, outletId) => requireRepo(ref).posKitchenStations(outletId),
    );

/// What is on the pass at one station. Deliberately not cached beyond
/// the screen that watches it: a kitchen board showing a ticket that
/// was bumped two minutes ago is worse than one showing nothing.
final kitchenDisplayProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, stationId) => requireRepo(ref).kitchenDisplay(stationId),
    );

/// A day in the diary, keyed on the outlet and the date together so
/// paging back and forth does not refetch what is already held.
final posDaySheetProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({String outletId, DateTime day})>(
      (ref, args) => requireRepo(ref).posDaySheet(args.outletId, args.day),
    );

final posServicesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posServices(),
    );

final posServiceProvidersProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, outletId) => requireRepo(ref).posServiceProviders(outletId),
    );

/// What is being made and what is ready, for the screen customers
/// watch. Keyed on the outlet: the board belongs to the shop, not to
/// the kiosk that happens to be showing it.
/// Where every dish goes, and why. Keyed by outlet because the same
/// menu in two shops routes two different ways.
final posStationRoutingProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, outletId) => requireRepo(ref).posStationRouting(outletId),
    );

final kioskOrderBoardProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, outletId) => requireRepo(ref).kioskOrderBoard(outletId),
    );

/// What an outlet can sell. Read once per outlet and held, because a
/// menu changes when somebody edits it rather than while a queue is
/// waiting — refetching it on every tap would be spending a round trip
/// to learn nothing.
/// The member panel on the tender sheet. Keyed by sale, because what it
/// shows is as much about the bill (what is being redeemed against it,
/// what paying it would earn) as about the customer.
final posSaleMemberProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>(
      (ref, saleId) => requireRepo(ref).posSaleMember(saleId),
    );

final posMenuProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, outletId) => requireRepo(ref).posMenu(outletId),
    );

final itemModifierOptionsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, itemId) => requireRepo(ref).itemModifierOptions(itemId),
    );

/// What was chosen on the lines of a sale. Keyed on the sale rather
/// than the line so the basket makes one round trip instead of one per
/// line.
final posSaleLineModifiersProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, saleId) => requireRepo(ref).posSaleLineModifiers(saleId),
    );
