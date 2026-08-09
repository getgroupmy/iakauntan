import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models.dart';
import '../data/repository.dart';

final supabaseProvider = Provider<SupabaseClient>((_) => Supabase.instance.client);

/// Emits on sign-in, sign-out and token refresh; the router listens to it.
final authStateProvider = StreamProvider<AuthState>(
  (ref) => ref.watch(supabaseProvider).auth.onAuthStateChange,
);

final currentUserProvider = Provider<User?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(supabaseProvider).auth.currentUser;
});

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
          .then((_) {}, onError: (_) {/* non-critical */});
    }
  }

  void clear() => state = null;
}

final currentOrgIdProvider =
    NotifierProvider<CurrentOrgNotifier, String?>(CurrentOrgNotifier.new);

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
Repo requireRepo(Ref ref) {
  final repo = ref.watch(repoProvider);
  if (repo == null) throw StateError('No organization selected');
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
    'owner', 'admin', 'accountant', 'accounts_clerk', 'sales', 'purchaser'
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
  return const ['owner', 'admin', 'accountant', 'accounts_clerk', 'auditor']
      .contains(role);
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

final itemsProvider =
    FutureProvider.autoDispose.family<List<Item>, String>((ref, search) {
  return requireRepo(ref).items(search: search);
});

final taxCodesProvider = FutureProvider<List<TaxCode>>((ref) {
  return requireRepo(ref).taxCodes();
});

final accountsProvider = FutureProvider<List<Account>>((ref) {
  return requireRepo(ref).accounts();
});

final classificationCodesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).classificationCodes();
});

typedef DocQuery = ({
  DocKind kind,
  String docType,
  String status,
  String search
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
    .family<List<BusinessDocument>, ({DocKind kind, String contactId})>(
        (ref, args) {
  return requireRepo(ref)
      .outstandingFor(kind: args.kind, contactId: args.contactId);
});

final bankAccountsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).bankAccounts();
});

final paymentModesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).paymentModes();
});

final expensesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).expenses();
});

final einvoicesProvider =
    FutureProvider.autoDispose.family<List<EinvoiceDocument>, String>((ref, status) {
  return requireRepo(ref).einvoices(status: status);
});

final pipelineStagesProvider = FutureProvider<List<PipelineStage>>((ref) {
  return requireRepo(ref).pipelineStages();
});

final opportunitiesProvider =
    FutureProvider.autoDispose<List<Opportunity>>((ref) {
  return requireRepo(ref).opportunities();
});

final arAgingProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).arAging();
});

final trialBalanceProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).trialBalance();
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
final platformRepoProvider =
    Provider<PlatformRepo>((ref) => PlatformRepo(ref.watch(supabaseProvider)));

/// Whether the signed-in user is platform staff. Drives whether the
/// admin console appears at all.
final isPlatformAdminProvider = FutureProvider<bool>((ref) async {
  if (ref.watch(currentUserProvider) == null) return false;
  try {
    return await ref.watch(platformRepoProvider).amIPlatformAdmin();
  } catch (_) {
    return false;
  }
});

final platformStatsProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) {
  return ref.watch(platformRepoProvider).stats();
});

final platformOrgsProvider =
    FutureProvider.autoDispose<List<PlatformOrg>>((ref) {
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

/// Synchronous check for widgets. Treats "still loading" as enabled so
/// navigation does not flicker on start-up.
bool moduleEnabled(WidgetRef ref, String code) {
  final modules = ref.watch(enabledModulesProvider);
  return modules.when(
    data: (set) => set.contains(code),
    loading: () => true,
    error: (_, __) => true,
  );
}

// ---------------------------------------------------------------------
// Team
// ---------------------------------------------------------------------
final teamProvider = FutureProvider.autoDispose<List<TeamMember>>((ref) {
  return requireRepo(ref).team();
});

// ---------------------------------------------------------------------
// Legal firm module
// ---------------------------------------------------------------------
final mattersProvider = FutureProvider.autoDispose
    .family<List<Matter>, ({String status, String search})>((ref, args) {
  return requireRepo(ref).matters(status: args.status, search: args.search);
});

final matterSummaryProvider =
    FutureProvider.autoDispose<List<MatterSummary>>((ref) {
  return requireRepo(ref).matterSummary();
});

final clientTransactionsProvider = FutureProvider.autoDispose
    .family<List<ClientTransaction>, String>((ref, matterId) {
  return requireRepo(ref).clientTransactions(matterId);
});

final timeEntriesProvider =
    FutureProvider.autoDispose.family<List<TimeEntry>, String>((ref, matterId) {
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
