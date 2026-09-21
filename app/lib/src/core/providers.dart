import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/ai_repository.dart';
import '../data/corp_models.dart';
import '../data/corp_repository.dart';
import '../data/firms_repository.dart';
import '../data/models.dart';
import '../data/custom_fields_repository.dart';
import '../data/ocr_repository.dart';
import '../data/repository.dart';
import '../features/admin/app_release.dart';
import '../features/einvoice/received_einvoice.dart';
import 'env.dart';
import 'push.dart';

final supabaseProvider = Provider<SupabaseClient>(
  (_) => Supabase.instance.client,
);

/// Whether `Supabase.initialize` has run in this process.
///
/// There is no public predicate for it — `Supabase.instance` throws
/// when it has not — so this asks by trying. For anything that wants to
/// open a socket before it knows whether there is a session: a widget
/// test renders real screens against overridden providers and never
/// initialises Supabase, and a screen that reached for the client
/// anyway would fail in the test and nowhere else.
final supabaseReadyProvider = Provider<bool>((ref) {
  try {
    Supabase.instance;
    return true;
  } catch (_) {
    return false;
  }
});

/// Emits on sign-in, sign-out and token refresh; the router listens to it.
final authStateProvider = StreamProvider<AuthState>(
  (ref) => ref.watch(supabaseProvider).auth.onAuthStateChange,
);

/// Who is signed in, ignoring anything that happens to their token.
///
/// A record of the user's id and the moment their record last changed.
/// It is the KEY [currentUserProvider] is derived from, and it exists
/// because the obvious version of that provider --
///
///     ref.watch(authStateProvider);
///     return auth.currentUser;
///
/// -- re-derives on EVERY auth event, `tokenRefreshed` included, and
/// returns a fresh `User` object each time. Twelve files watch
/// `currentUserProvider`, the org context and the module surface among
/// them, so one token refresh reloaded the whole shell: every
/// `AsyncValue` went back to its loading branch, every screen was
/// disposed and rebuilt, and whatever was on it lost its unsaved form
/// state and its scroll position.
///
/// That was already happening once an hour, a minute before the JWT
/// expires, and it was survivable. WHAT MADE IT A LOOP was `listFactors`
/// -- see `settings/two_factor_card.dart`. It refreshes the session as a
/// side effect of reading, it was called from `initState`, and the
/// rebuild it caused re-created the card that called it. Round and
/// round: 17 token refreshes measured in one visit to Settings, all
/// HTTP 200, against a JWT with 57 minutes left on it.
///
/// AND IT ENDED IN A SIGN-OUT, which is why this is not a performance
/// note. `/auth/v1/token` is rate-limited per IP -- 150 in five minutes,
/// bursting to 30 -- and when the loop drained that bucket the refresh
/// came back 429. GoTrue treats any non-network `AuthException` on a
/// refresh as fatal: it drops the session and emits `signedOut`, and
/// the router puts the person on the sign-in page. Nothing in this
/// application was signing anybody out. It was asking too often.
///
/// Both halves are fixed; either alone stops the loop, and they fix
/// different things. This half is the one that also stops the hourly
/// reload.
///
/// ## Why a Notifier and not `select`
///
/// `authStateProvider.select((s) => s.value?.session?.user.id)` is the
/// short version and it loses the other thing a consumer needs: a
/// `userUpdated` event after somebody changes their email address must
/// reach the screens that print it. Folding the update stamp into the
/// selector does not work either, because a selector cannot see what it
/// returned last -- so the stamp appears on the `userUpdated` event and
/// is gone again on the next `tokenRefreshed`, which is a second change
/// and a second full reload.
///
/// Holding it in state is what makes the value MONOTONIC: it moves when
/// the person changes or their record changes, and at no other time.
class UserIdentityNotifier extends Notifier<({String? id, DateTime? updated})> {
  @override
  ({String? id, DateTime? updated}) build() {
    ref.listen(authStateProvider, (_, next) {
      final auth = next.value;
      if (auth == null) return;
      final user = auth.session?.user;
      final was = state;
      final next_ = (
        id: user?.id,
        // Kept from before unless this event is the one that says the
        // record moved. A refresh carries a `User` too and its
        // `updatedAt` is not a promise of anything.
        updated: auth.event == AuthChangeEvent.userUpdated
            ? (user?.updatedAt == null
                  ? DateTime.now()
                  : DateTime.tryParse(user!.updatedAt!) ?? DateTime.now())
            : was.updated,
      );
      // Records compare by value, so this is the whole of the filter:
      // a token refresh produces a record equal to the one held and
      // nothing downstream is told anything.
      if (next_ != was) state = next_;
    });
    // Nothing read from Supabase to seed this, deliberately.
    // `onAuthStateChange` emits `initialSession` as soon as it is
    // listened to, so a restored session arrives through the same
    // listener a moment later and the seed would only be a second copy
    // of it. Not reading is what lets this be tested against a plain
    // stream, and it removes a throw: `supabaseProvider` asserts if
    // Supabase has not been initialised, and a provider that cannot be
    // built without it is a provider that takes a screen down.
    //
    // `currentUserProvider` returns `auth.currentUser` either way, so
    // no consumer sees a wrong value in the meantime -- only, at worst,
    // one extra rebuild when `initialSession` lands, which is the same
    // rebuild it has always had.
    return (id: null, updated: null);
  }
}

final userIdentityProvider =
    NotifierProvider<UserIdentityNotifier, ({String? id, DateTime? updated})>(
      UserIdentityNotifier.new,
    );

/// The signed-in user.
///
/// Watches [userIdentityProvider] rather than the auth event stream, so
/// a token refresh does not reach anything downstream of it. Read the
/// full sentence there before changing this back.
final currentUserProvider = Provider<User?>((ref) {
  ref.watch(userIdentityProvider);
  return ref.read(supabaseProvider).auth.currentUser;
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
  final org = ref.watch(currentOrgProvider).valueOrNull;
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
//
// `valueOrNull`, not `.value`. `?? 'viewer'` is least privilege and is
// the right answer while the role is loading AND if the load failed --
// but `AsyncError.value` THROWS, so on a failure the fallback never ran
// and the exception came out of whatever was watching. What watches
// these is everything: `canAdminProvider` is read by the navigation
// rail, so a role that failed to load took the whole shell down rather
// than showing somebody a viewer's menu for a second.

/// Whether the current member may post to the ledger. An accounts clerk
/// deliberately sits outside this: they prepare, someone else posts.
final canPostProvider = Provider<bool>((ref) {
  final role = ref.watch(memberRoleProvider).valueOrNull ?? 'viewer';
  return const ['owner', 'admin', 'accountant'].contains(role);
});

final canWriteProvider = Provider<bool>((ref) {
  final role = ref.watch(memberRoleProvider).valueOrNull ?? 'viewer';
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
  final role = ref.watch(memberRoleProvider).valueOrNull ?? 'viewer';
  return const ['owner', 'admin'].contains(role);
});

/// Owner and nobody else. Separate from [canAdminProvider] because two
/// things in this product are an owner's alone and an admin's not:
/// handing the company over, and closing it. `close_organization`
/// refuses an admin in the database; this is so the button is absent
/// rather than present and refusing.
final isOwnerProvider = Provider<bool>((ref) {
  return (ref.watch(memberRoleProvider).valueOrNull ?? 'viewer') == 'owner';
});

/// Who may see the journals and audit trail. Auditors get read access to
/// everything; sales and purchasing staff do not.
final canReadLedgerProvider = Provider<bool>((ref) {
  final role = ref.watch(memberRoleProvider).valueOrNull ?? 'viewer';
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

/// The list you keep beside the books. `autoDispose` so it is re-read
/// whenever the dashboard or the list screen is opened, which is the
/// only way an item ticked on one of them shows as ticked on the other.
final todosProvider = FutureProvider.autoDispose.family<List<Todo>, bool>((
  ref,
  done,
) {
  return requireRepo(ref).todos(done: done);
});

/// Where this person lands and what they want on the dashboard.
///
/// NOT autoDispose: the router reads it on every redirect, and a
/// provider that disposed between them would refetch on each navigation
/// and land somebody on the default while it did.
final userPreferencesProvider = FutureProvider<UserPreferences>((ref) async {
  final repo = ref.watch(repoProvider);
  if (repo == null) return const UserPreferences();
  return repo.userPreferences();
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

/// Which acquirers this company has set up to collect from its own
/// customers. Never the keys — see `Repo.orgPaymentGateways`.
final orgPaymentGatewaysProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) {
  return requireRepo(ref).orgPaymentGateways();
});

final bankAccountsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return requireRepo(ref).bankAccounts();
});

/// The feed on one bank account, or null where there is none.
///
/// `0567`. Never the credential: `bank_feed_status` answers with
/// `has_api_key` and never the key, for the reason the acquirer status
/// does — a screen that could redisplay a secret is a screen that could
/// leak it.
final bankFeedProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, bankAccountId) {
  return requireRepo(ref).bankFeedStatus(bankAccountId);
});

/// Every pull against this company's feeds, newest first.
final bankFeedRunsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, bankAccountId) {
  return requireRepo(ref).bankFeedRuns(bankAccountId);
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

/// The other records of the same company, and which roles are open.
///
/// Family-keyed and autoDispose so the sheet asks afresh each time it
/// opens: a record created from another screen changes the answer.
final contactRecordsProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, contactId) {
      return requireRepo(ref).contactRecords(contactId);
    });

/// Whether this account may add another company.
///
/// Multi-Company is a module (0486): the first company is free and the
/// rest are bought. Watched rather than assumed, so a screen offers
/// the door only when it opens.
final canAddCompanyProvider = FutureProvider.autoDispose<bool>((ref) async {
  final repo = ref.watch(repoProvider);
  if (repo == null) return false;
  return repo.canAddCompany();
});

/// What this company's paid add-ons have cost it so far this month.
///
/// autoDispose, and invalidated whenever a module is switched on or
/// off: the figure is the running total, and a stale one shown beside
/// a module somebody just added is worse than no figure at all. The
/// server refuses anybody but an owner or admin, so the card that
/// draws this is drawn only for them.
final moduleChargesProvider =
    FutureProvider.autoDispose<SubscriptionMonth>((ref) async {
      final repo = ref.watch(repoProvider);
      if (repo == null) return const SubscriptionMonth(month: null, lines: [], subtotal: 0);
      return SubscriptionMonth.fromMap(await repo.moduleCharges());
    });


/// The portal links issued to one customer — whether one is live, and
/// whether they have opened it. autoDispose: issuing or revoking one is
/// exactly when the answer changes.
final customerPortalLinksProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contactId) async {
      final repo = ref.watch(repoProvider);
      if (repo == null) return const [];
      return repo.customerPortalLinks(contactId);
    });

/// Both sides of one contact's account — what they owe and what they
/// have in hand. autoDispose: knocking anything off is exactly when the
/// answer changes.
final openItemsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contactId) async {
      final repo = ref.watch(repoProvider);
      if (repo == null) return const [];
      return repo.openItems(contactId);
    });

/// The tax-details links issued to one contact — whether one is live,
/// whether they have opened it, and whether they have answered.
/// autoDispose for [customerPortalLinksProvider]'s reason: issuing or
/// revoking one is exactly when the answer changes.
final taxDetailLinksProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, contactId) async {
      final repo = ref.watch(repoProvider);
      if (repo == null) return const [];
      return repo.taxDetailLinks(contactId);
    });

/// What customers have said about their own tax details that disagrees
/// with what is on file. autoDispose: accepting or dismissing one is
/// exactly when the answer changes.
final pendingTaxSubmissionsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final repo = ref.watch(repoProvider);
      if (repo == null) return const [];
      return repo.pendingTaxSubmissions();
    });

/// The records on file twice, for the screen that offers to link
/// them. autoDispose so it is asked afresh: a group linked a moment
/// ago is not a group any more.
final contactDuplicatesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).contactDuplicates();
    });

/// What the assistant is able to read for this company.
///
/// Read from the server rather than listed in the app: a screen that
/// promises a report the assistant cannot reach is worse than one that
/// promises nothing.
final aiToolsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).aiTools();
    });

final aiConversationsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).aiConversations();
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

/// Where a custom field may be attached, and what a lookup may point
/// at. A platform catalogue that changes only by migration, so it is
/// read once and kept.
final customFieldEntitiesProvider =
    FutureProvider<List<CustomFieldEntity>>((ref) {
  return requireRepo(ref).customFieldEntities();
});

/// This company's custom fields for one kind of record, archived ones
/// included — the setup screen shows both and a form filters.
final customFieldsProvider = FutureProvider.autoDispose
    .family<List<CustomFieldDef>, String>((ref, entity) {
  return requireRepo(ref).customFields(entity);
});

/// What a lookup field may be filled in with. Read through the same
/// function the guard's rule is written beside, so the picker cannot
/// offer a record the database will refuse.
final customFieldLookupProvider = FutureProvider.autoDispose
    .family<List<LookupOption>, ({String target, String search})>((ref, args) {
  return requireRepo(ref).customFieldLookupOptions(
    args.target,
    search: args.search.isEmpty ? null : args.search,
  );
});

/// Every project with its budget and what has been spent against it.
/// Links issued for one ticket, newest first.
///
/// "Did they ever open it?" is the question somebody asks a week later,
/// and the open count is the only evidence the link reached anybody.
final ticketShareLinksProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, ticketId) => requireRepo(ref).ticketShareLinks(ticketId),
    );

final projectBudgetProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, bool>(
      (ref, includeClosed) =>
          requireRepo(ref).projectBudgets(includeClosed: includeClosed),
    );

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

/// What the next invoice, bill, journal and so on will be called: every
/// series of the modules the company has, as it is set. Read from the
/// server, which composes the sample the way the draw does.
final documentNumberingProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).documentNumbering();
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

/// Posted bill lines coded to a fixed asset account with nothing in
/// the register against them — the reconciliation an auditor opens
/// with, which the data could not answer before `0382`.
final uncapitalisedPurchasesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).uncapitalisedPurchases();
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
/// The Form C working for one computation.
final taxComputationProvider = FutureProvider.autoDispose
    .family<TaxComputation, String>((ref, id) {
      return requireRepo(ref).taxComputation(id);
    });

/// Every add-back and deduction in it.
final taxComputationLinesProvider = FutureProvider.autoDispose
    .family<List<TaxComputationLine>, String>((ref, id) {
      return requireRepo(ref).taxComputationLines(id);
    });

/// The row's own figures, which the computation cannot derive.
final taxComputationRowProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, id) {
      return requireRepo(ref).taxComputationRow(id);
    });

/// What LHDN is waiting for, and when.
///
/// Not keyed on anything: the window is the same for everybody and the
/// answer changes only with the date, so a second parameter would be a
/// second cache entry for the same list.
final taxFilingCalendarProvider =
    FutureProvider.autoDispose<List<TaxFiling>>((ref) {
      return requireRepo(ref).taxUpcomingFilings();
    });

/// What has already been recorded against an obligation.
final taxFilingHistoryProvider =
    FutureProvider.autoDispose<List<TaxFilingRecord>>((ref) {
      return requireRepo(ref).taxFilingHistory();
    });

/// Where the instalment year stands: scheduled, paid, overdue, late.
final taxInstalmentSummaryProvider = FutureProvider.autoDispose
    .family<TaxInstalmentSummary, String>((ref, id) {
      return requireRepo(ref).taxInstalmentSummary(id);
    });

/// How a first basis period differs, where the estimate says it is one.
final taxFirstPeriodProvider = FutureProvider.autoDispose
    .family<TaxFirstPeriod, String>((ref, id) {
      return requireRepo(ref).taxEstimateFirstPeriod(id);
    });

/// The CP204 estimate row itself.
final taxEstimateProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, id) {
      return requireRepo(ref).taxEstimate(id);
    });

final taxEstimateScheduleProvider = FutureProvider.autoDispose
    .family<List<TaxInstalment>, String>((ref, id) {
      return requireRepo(ref).taxEstimateSchedule(id);
    });

/// Keyed on the estimate AND the computation, because the exposure is
/// a different answer with one than without — and for most of the year
/// there is not one.
final taxEstimateExposureProvider = FutureProvider.autoDispose
    .family<TaxEstimateExposure, ({String estimate, String? computation})>((
      ref,
      args,
    ) {
      return requireRepo(ref).taxEstimateExposure(
        args.estimate,
        computationId: args.computation,
      );
    });

/// The Form B working.
final individualTaxProvider = FutureProvider.autoDispose
    .family<IndividualTaxComputation, String>((ref, id) {
      return requireRepo(ref).individualTaxComputation(id);
    });

/// What each partner carries into their own Form B.
final partnershipAllocationProvider = FutureProvider.autoDispose
    .family<List<PartnerAllocation>, String>((ref, id) {
      return requireRepo(ref).partnershipAllocation(id);
    });

/// The head of a Form P.
final partnershipSummaryProvider = FutureProvider.autoDispose
    .family<PartnershipSummary, String>((ref, id) {
      return requireRepo(ref).partnershipSummary(id);
    });

final taxOtherIncomeProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, id) {
      return requireRepo(ref).taxOtherIncome(id);
    });

final taxReliefClaimsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, id) {
      return requireRepo(ref).taxReliefClaims(id);
    });

final taxPartnersProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, id) {
      return requireRepo(ref).taxPartners(id);
    });

/// The reliefs catalogue PCB uses, for the Form B picker.
final individualReliefsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTime>((ref, on) {
      return requireRepo(ref).individualReliefs(on);
    });

/// The typed adjustments on a computation, with their ids.
final taxAdjustmentsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, id) {
      return requireRepo(ref).taxAdjustments(id);
    });

/// Accounts whose tax treatment is for the other side of the ledger.
final taxMisfiledAccountsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).taxMisfiledAccounts();
    });

/// What a chart of accounts can say about an account.
///
/// Not autoDispose: ten rows that move with a Budget, read by the
/// account editor every time it opens.
final taxTreatmentsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).taxTreatments();
    });

/// The Schedule 3 classes an asset can be put in.
///
/// Not autoDispose: the list is eight rows that change with a Budget,
/// and refetching it every time somebody opens the asset editor is a
/// round trip for a list that has not moved since the app started.
final capitalAllowanceClassesProvider =
    FutureProvider<List<CapitalAllowanceClass>>((ref) {
      return requireRepo(ref).capitalAllowanceClasses();
    });

/// The capital allowance schedule for a year of assessment.
///
/// Keyed on the year, so flipping between two years keeps both and
/// nothing is refetched going back. `autoDispose` because a schedule
/// nobody is looking at is a schedule worth recomputing when they are.
final capitalAllowancesProvider = FutureProvider.autoDispose
    .family<List<CapitalAllowanceLine>, int>((ref, year) {
      return requireRepo(ref).capitalAllowances(year);
    });

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

/// Deferred revenue not yet released, one row per period end.
///
/// No date family, unlike the FX preview beside it. The function
/// returns everything unposted and the card splits it on whichever date
/// is chosen, so dragging the date around is not a round trip each
/// time — and what is still to come stays on screen next to what is
/// about to post.
final revenueDueProvider = FutureProvider.autoDispose<List<RevenueDue>>((ref) {
  return requireRepo(ref).revenueScheduleDue();
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

/// The MyInvois documents suppliers have sent us.
///
/// `0650`'s table. The inbound half of e-Invoice, and the only one of
/// the two that is read rather than written.
final receivedEinvoicesProvider = FutureProvider.autoDispose
    .family<List<ReceivedEinvoice>, String>((ref, status) {
      return requireRepo(ref).receivedEinvoices(status: status);
    });

/// Open deals whose figure has drifted from the quotation attached to
/// them. What the forecast is wrong by, and nothing could ask before.
final pipelineQuoteMismatchProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).pipelineQuoteMismatch();
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

/// Whether this person carries the report button on every screen.
///
/// Not autoDispose. The shell watches it for the whole session, and a
/// provider that disposed between rebuilds would ask the server again
/// every time the person changed screens -- which is the one thing a
/// button on every screen must not do.
///
/// False while it is loading and false on an error, both deliberately.
/// The failure mode of guessing true is a button that opens a dialog
/// for somebody who will then be refused; the failure mode of guessing
/// false is a button that appears a moment late.
final isBetaTesterProvider = FutureProvider<bool>((ref) async {
  if (ref.watch(currentUserProvider) == null) return false;
  return ref.watch(platformRepoProvider).amIABetaTester();
});

final betaTestersProvider = FutureProvider.autoDispose<List<BetaTester>>((ref) {
  return ref.watch(platformRepoProvider).betaTesters();
});

/// People matching what has been typed into the console's picker.
///
/// `autoDispose` and keyed on the query, so a search that has been
/// typed past is not kept alive; `family` rather than a controller so
/// the screen has no state to get out of step with the box.
final platformUserSearchProvider = FutureProvider.autoDispose
    .family<List<PlatformUser>, String>((ref, query) {
  final needle = query.trim();
  // The server refuses under two characters as well. This saves the
  // round trip on every single keystroke of the first letter.
  if (needle.length < 2) return Future.value(const <PlatformUser>[]);
  return ref.watch(platformRepoProvider).searchUsers(needle);
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

/// The last few iOS releases, from GitHub.
///
/// `autoDispose` because it is a list of workflow runs and goes stale
/// the moment one starts; the card refreshes it rather than holding
/// yesterday's answer for the length of a session.
final appReleasesProvider = FutureProvider.autoDispose
    .family<AppReleases, ReleasePlatform>((ref, platform) {
  return ref.watch(platformRepoProvider).appReleases(platform);
});

/// The files on one feedback report, fetched when a row is expanded.
///
/// `family` on the report id, and autoDispose so a triage session
/// through forty reports does not hold forty lists open.
final feedbackFilesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, reportId) {
  return ref.watch(platformRepoProvider).feedbackFiles(reportId);
});

/// The bank rules, in the order they are tried. 0625.
final bankRulesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).bankRules();
    });

/// How many unclaimed statement lines each rule would take, and how
/// many nothing describes. Keyed by bank account, null meaning all.
final bankRuleCoverageProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String?>((ref, bankAccountId) {
      return requireRepo(ref).bankRuleCoverage(bankAccountId: bankAccountId);
    });

final bankLinesUnexplainedProvider =
    FutureProvider.autoDispose.family<int, String?>((ref, bankAccountId) {
      return requireRepo(ref).bankLinesUnexplained(
        bankAccountId: bankAccountId,
      );
    });

/// What has been closed, for the console. 0619.
final platformClosuresProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({String? kind, bool includeRestored})>(
      (ref, args) => ref.watch(platformRepoProvider).closedAccounts(
        kind: args.kind,
        includeRestored: args.includeRestored,
      ),
    );

final platformSettingsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return ref.watch(platformRepoProvider).settings();
    });

// ---------------------------------------------------------------------
// Module entitlements for the active tenant
// ---------------------------------------------------------------------
/// True from the moment a sign-in succeeds until the door checks that
/// may undo it have finished.
///
/// `0346` asks two questions after the password is accepted — is this
/// account on this company's team, and can it open what this address
/// opens — and either answer can sign the session straight back out.
/// Both need a session to ask, so they cannot be asked first.
///
/// Meanwhile the session itself is what the router watches. Without
/// this the order is: password accepted, router moves them into the
/// app, checks come back, session revoked, router moves them out
/// again, and only then does the dialog get a screen to appear on.
/// The person watches themselves get in and thrown out before being
/// told why, which reads as a fault rather than as a decision.
///
/// So the router holds while this is true. Nobody is moved on the
/// strength of a session that is still being vetted.
final vettingProvider = StateProvider<bool>((ref) => false);

final enabledModulesProvider = FutureProvider<Set<String>>((ref) async {
  final repo = ref.watch(repoProvider);
  if (repo == null) return <String>{};
  return repo.enabledModules();
});

/// Every module with what this company may see of it. The settings
/// screen's list, and the only place `entitled` and `hidden` are shown
/// side by side.
final moduleSurfaceProvider = FutureProvider.autoDispose<List<ModuleSurface>>((
  ref,
) async {
  final repo = ref.watch(repoProvider);
  if (repo == null) return const [];
  return repo.moduleSurface();
});

/// Figures for the modules this company actually uses, keyed by module
/// code. Empty for a company whose dashboard is the accounting one.
final moduleDashboardProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
      final repo = ref.watch(repoProvider);
      if (repo == null) return const {};
      return repo.moduleDashboard();
    });

/// What the person signed in may do in each module: `none`, `read` or
/// `write`. Everything is `write` until their company defines an access
/// type and assigns it, which is how every member stands today.
final myModuleAccessProvider = FutureProvider<Map<String, String>>((ref) async {
  final repo = ref.watch(repoProvider);
  if (repo == null) return const {};
  return repo.myModuleAccess();
});

/// What the entitlement list and the access map add up to, given plain
/// values rather than an `AsyncValue`.
///
/// Extracted because three callers state the same rule in three
/// different ways — `.when(loading: () => true)`, `.valueOrNull` with a
/// null check, and an awaited read — and their own comments say they
/// agree ("The answer is the same and so is the permissiveness while it
/// loads"). Nothing made them. Reading a `WidgetRef` back needs a
/// widget, so none of the three could be called by a unit test either.
///
/// **Null is "not known yet", and it reads as yes.** That is the
/// permissiveness the comments describe, and it is deliberate: a screen
/// that hid a button because an entitlement had not arrived would hide
/// it from the person who does hold it. Hiding is a courtesy in every
/// one of these — `0127`'s restrictive policies are the control, and
/// they do not care what the client believes.
///
/// An access map that has arrived and does not mention the module is a
/// different thing again, and also yes: that is what the database
/// answers for a member with no access type at all.
bool moduleAllowed({
  required Set<String>? entitled,
  required Map<String, String>? access,
  required String code,
}) {
  if (entitled != null && !entitled.contains(code)) return false;
  return (access?[code] ?? 'write') != 'none';
}

/// Whether this person may change anything in a module, as opposed to
/// only looking at it.
///
/// Deliberately does not ask about the entitlement. Two callers want
/// this question on its own — a permission is not sold and never
/// appears in the entitlement list, so asking would deny every one of
/// them to everybody.
bool moduleWriteAllowed({
  required Map<String, String>? access,
  required String code,
}) => (access?[code] ?? 'write') == 'write';

/// Synchronous check for widgets. Treats "still loading" as enabled so
/// navigation does not flicker on start-up.
///
/// Two different questions, and both have to be yes: the company must
/// have bought the module, and this person must be allowed into it.
/// Hiding is a courtesy — the restrictive policies 0127 added are the
/// control, and they do not care what the client believes.
bool moduleEnabled(WidgetRef ref, String code) => moduleAllowed(
  entitled: ref.watch(enabledModulesProvider).valueOrNull,
  access: ref.watch(myModuleAccessProvider).valueOrNull,
  code: code,
);

/// The same question, asked from somewhere that is not a build method.
///
/// [moduleEnabled] watches, and watching outside `build` throws. An
/// event handler — a bottom sheet being assembled after a tap, a dialog
/// deciding which buttons to show — has to read instead. The answer is
/// the same and so is the permissiveness while it loads: a screen that
/// hid a button because an entitlement had not arrived yet would be
/// hiding it from the person who does hold it.
///
/// Hiding remains a courtesy either way. The server refuses on its own
/// account, and 0231 gates every loyalty and membership function on the
/// module rather than on the till.
bool moduleEnabledNow(WidgetRef ref, String code) => moduleAllowed(
  entitled: ref.read(enabledModulesProvider).valueOrNull,
  access: ref.read(myModuleAccessProvider).valueOrNull,
  code: code,
);

/// Whether this person holds a named permission inside a module — an
/// action a company can hand out separately, like voiding a sent line.
///
/// Deliberately *not* [moduleEnabledNow]. That asks two questions and
/// the first one is whether the company bought the module; a permission
/// is not sold and never appears in the entitlement list, so asking
/// would deny every one of them to everybody.
///
/// Missing means held, which is what the database answers for a member
/// with no access type and what keeps the till usable while the answer
/// is still in flight. Hiding is a courtesy either way: the refusal in
/// `void_pos_sale_line` is the control.
Future<bool> permissionHeld(WidgetRef ref, String code) async {
  // Awaited, not read. A provider nothing on the screen watches has no
  // value yet, and a read would answer "held" from the fallback — which
  // is the wrong answer to give quietly, because the database will then
  // refuse and the person will have been walked into it.
  final access = await ref.read(myModuleAccessProvider.future);
  return moduleWriteAllowed(access: access, code: code);
}

/// The actions a company can hand out inside the modules it holds.
/// Read once for the screen that hands them out.
final accessPermissionsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final repo = ref.watch(repoProvider);
  if (repo == null) return const [];
  return repo.accessPermissions();
});

/// Whether this person may change anything in a module, as opposed to
/// only looking at it.
bool moduleWritable(WidgetRef ref, String code) => moduleWriteAllowed(
  access: ref.watch(myModuleAccessProvider).valueOrNull,
  code: code,
);

// ---------------------------------------------------------------------
// Team
// ---------------------------------------------------------------------
final teamProvider = FutureProvider.autoDispose<List<TeamMember>>((ref) {
  return requireRepo(ref).team();
});

// ---------------------------------------------------------------------
// The practice
//
// Above the organization rather than inside it, so none of these is
// scoped by `currentOrgIdProvider` and none goes through `Repo`. Almost
// everybody gets an empty list from `myFirmsProvider` and never sees any
// of this: a company that keeps its own books is not a practice.
// ---------------------------------------------------------------------
final firmsRepoProvider = Provider<FirmsRepo>(
  (ref) => FirmsRepo(ref.watch(supabaseProvider)),
);

final myFirmsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  if (!ref.watch(supabaseReadyProvider)) return Future.value(const []);
  if (ref.watch(currentUserProvider) == null) return Future.value(const []);
  return ref.watch(firmsRepoProvider).myFirms();
});

/// Which practice the firm screen is showing. Null until the list has
/// arrived, and set to the only one when there is only one.
final currentFirmIdProvider = StateProvider<String?>((ref) => null);

final firmPortfolioProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, firmId) {
      return ref.watch(firmsRepoProvider).portfolio(firmId);
    });

final firmTeamProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, firmId) {
      return ref.watch(firmsRepoProvider).members(firmId);
    });

/// Partners and managers only; a member of staff gets a permission
/// error rather than an empty list, which is why the screen guards it.
final firmTrailProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, firmId) {
      return ref.watch(firmsRepoProvider).trail(firmId);
    });

// ---------------------------------------------------------------------
// Telling us it is broken
// ---------------------------------------------------------------------

/// What this person has reported, plus what was reported from inside
/// their company if they administer it.
final myFeedbackProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).myFeedback();
    });

/// Every company's reports. Platform staff only; the server refuses
/// anybody else outright rather than handing back an empty list.
final platformFeedbackProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String?>((ref, status) {
      return ref.watch(platformRepoProvider).feedback(status: status);
    });

// ---------------------------------------------------------------------
// One payment across several companies
// ---------------------------------------------------------------------

/// What is open across every company the signed-in person may post in.
/// Not scoped to the company that happens to be selected — that is the
/// point of the screen it feeds.
final openAcrossCompaniesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, kind) {
      return requireRepo(ref).openAcrossCompanies(kind: kind);
    });

// ---------------------------------------------------------------------
// Statutory remittances
// ---------------------------------------------------------------------

/// Every posted payroll month, split by the body owed. Empty for a
/// company that has never posted one.
final statutoryRemittancesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).statutoryRemittances();
    });

/// The ones still to send, soonest first. Watched by the payroll screen
/// so an overdue contribution announces itself rather than waiting to
/// be looked for.
final statutoryDueProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).statutoryDue(withinDays: 45);
    });

// ---------------------------------------------------------------------
// SST taxable periods
// ---------------------------------------------------------------------

/// Every taxable period since registration. Empty for a company that is
/// not SST-registered, which is most of them.
final sstTaxablePeriodsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).sstTaxablePeriods();
    });

/// The returns that have not gone in. Watched by the card, so a
/// deadline appears without anybody going looking for it.
final sstDueProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((
  ref,
) {
  return requireRepo(ref).sstDue(withinDays: 120);
});

/// What makes up one period's figure, split by tax type and the basis
/// each part is due on. Keyed by the period end as an ISO date, because
/// that is what identifies a taxable period.
final sstReturnLinesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, periodEnd) {
      return requireRepo(ref).sstReturnLines(DateTime.parse(periodEnd));
    });

/// The practice keeping *this* company's books, if any, with the role
/// its people hold here. Null for the great majority of companies.
///
/// `firms_select` lets a client's own members read the firm row their
/// company names, which is what makes the embed legal.
final ourPracticeProvider = FutureProvider.autoDispose<Map<String, dynamic>?>((
  ref,
) async {
  final orgId = ref.watch(currentOrgIdProvider);
  if (orgId == null) return null;
  final row = await ref
      .watch(supabaseProvider)
      .from('organizations')
      .select('firm_id, firm_member_role, firms(name, email, phone)')
      .eq('id', orgId)
      .maybeSingle();
  if (row == null || row['firm_id'] == null) return null;
  return Map<String, dynamic>.from(row);
});

/// Who has held this company before. Owners and admins only.
final companyTransferHistoryProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      final orgId = ref.watch(currentOrgIdProvider);
      if (orgId == null) return Future.value(const []);
      return ref.watch(firmsRepoProvider).transferHistory(orgId);
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

/// Sales orders past the delivery date they were given.
///
/// Watched by the sales order list so the button appears only when there
/// is something behind it — a permanent "Late (0)" is a door onto an
/// empty room.
final lateOrdersProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).lateOrders();
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

/// Subscribe this device and put it on the register.
///
/// `ask` decides whether the permission prompt may appear. Safari
/// requires that prompt to come from a user gesture, and neither a
/// browser nor iOS will ask a second time once refused, so the app only
/// ever asks from a button — see [pushRegistrarProvider] for what
/// happens on start. Takes the repository rather than a ref, because
/// `Ref` and `WidgetRef` have no common supertype and this is called
/// from both a provider and a button. Whoever calls it refreshes
/// [pushStatusProvider].
///
/// A list, not one registration, and that is the whole reason this
/// reads the way it does: an iPhone hands back an alert token and a
/// PushKit token, from two Apple services, and both have to go on the
/// register under their own transport or a call cannot ring. See 0658.
Future<PushStatus> enablePush(Repo? repo, {bool ask = true}) async {
  if (repo == null) return PushStatus.unsupported;

  final registrations = await subscribeToPush(Env.webPushPublicKey, ask: ask);
  if (registrations.isEmpty) return pushStatus(Env.webPushPublicKey);

  for (final device in registrations) {
    await repo.registerDevice(
      token: device.token,
      platform: device.platform,
      label: device.label,
      p256dh: device.p256dh,
      auth: device.auth,
      transport: device.transport,
      deviceId: device.deviceId,
    );
  }
  // Not unconditionally `on`. An iPhone whose owner refused the prompt
  // still hands back a PushKit token — calls ring, messages do not —
  // and calling that "on" would be a lie on the settings screen.
  return pushStatus(Env.webPushPublicKey);
}

/// Re-register on every start, without ever prompting.
///
/// No token is stable: a browser may rotate its endpoint at any time
/// and Apple may reissue a device token, and the register would then
/// hold one nobody can send to while the person sees notifications as
/// switched on. Re-registering is cheap — 0143 keys on the token, so an
/// unchanged one updates a single row — and it is the only thing that
/// catches a rotation.
///
/// Silent by construction: `ask: false` means a device that has never
/// been asked stays unasked, and one that refused is not nagged.
final pushRegistrarProvider = FutureProvider<void>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return;
  if (await pushStatus(Env.webPushPublicKey) != PushStatus.on) return;
  await enablePush(ref.read(repoProvider), ask: false);
});

/// Take this device off the register, on the way out.
///
/// Every token it holds, because an iPhone holds two and leaving the
/// PushKit one behind would leave it ringing for calls after somebody
/// switched notifications off.
///
/// Best effort by nature — an app that is force-quit never gets here —
/// which is why the sender also drops tokens the push service rejects.
Future<void> disablePush(Repo? repo) async {
  for (final token in await currentPushTokens()) {
    await repo?.unregisterDevice(token);
  }
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

/// The matters open for one client, for the receipt and payment screens
/// to offer when a firm holds the legal module (0549).
///
/// Open ones only: money is not received on account for a matter that
/// closed, and a picker offering fifty closed matters is a picker
/// nobody uses.
final clientMattersProvider = FutureProvider.autoDispose
    .family<List<Matter>, String>((ref, contactId) async {
      final all = await requireRepo(ref).matters(status: 'open');
      return [for (final m in all) if (m.clientId == contactId) m];
    });

/// What one matter holds in the client account, now.
final matterClientBalanceProvider = FutureProvider.autoDispose
    .family<double, String>((ref, matterId) {
      return requireRepo(ref).matterClientBalance(matterId);
    });

/// Client money coming in, and client money going out (0549).
///
/// Two providers rather than one family on a bool, because the two
/// screens show different things and a family keyed on a flag reads as
/// though they were the same list filtered.
final clientReceiptsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).clientAccountLedger(types: const ['receipt']);
    });

/// Payments out and refunds together: both are money leaving a matter,
/// and a firm closing one wants to see the disbursements and the
/// balance returned on the same page.
final clientPayoutsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref)
          .clientAccountLedger(types: const ['payment', 'refund']);
    });

/// What each matter holds, for the pickers on both screens.
final matterClientBalancesProvider =
    FutureProvider.autoDispose<Map<String, double>>((ref) {
      return requireRepo(ref).matterClientBalances();
    });

/// Fixed-fee matters that have gone past what was agreed.
final mattersOverAgreedFeeProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).mattersOverAgreedFee();
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
  final role = ref.watch(memberRoleProvider).valueOrNull ?? 'viewer';
  return const ['owner', 'admin', 'hr_manager'].contains(role);
});

/// Payroll touches the ledger, so it needs a finance role as well as HR.
final canRunPayrollProvider = Provider<bool>((ref) {
  final role = ref.watch(memberRoleProvider).valueOrNull ?? 'viewer';
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

/// Keyed on the tax year, because that is what the ceiling is keyed on:
/// `0408` judges a declaration against the PCB schedule in force at the
/// end of the year it is declared for, and a list fetched for a
/// different year would offer reliefs the database then refuses.
final reliefTypesProvider = FutureProvider.family<List<ReliefType>, int>((
  ref,
  taxYear,
) {
  return requireRepo(ref).reliefTypes(taxYear);
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

/// Every document running out inside the window.
///
/// `0025` built an index for this list and it was never written, so a
/// lapsing work permit could only be found by opening each employee in
/// turn — and employing on an expired pass is the company's offence,
/// not the employee's.
final expiringDocumentsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, int>(
      (ref, days) => requireRepo(ref).expiringDocuments(withinDays: days),
    );

/// Everyone away over the coming days, and how to reach them.
///
/// `contact_while_away` was a column nothing wrote and nothing read
/// until `0395`; this is the reader. The window runs from today, so
/// the family key is how many days ahead to look and not a date pair —
/// a report about who is away has no use for a window in the past.
final whoIsAwayProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, int>((ref, days) {
      final today = DateTime.now();
      return requireRepo(ref).whoIsAway(
        from: today,
        to: today.add(Duration(days: days)),
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

/// Who at a company may be stood in for. Asked of the database, which
/// is the same list `0380`'s guard will accept.
final corpPrincipalsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, entityId) {
      return requireRepo(ref).corpPrincipalsForAlternate(entityId);
    });

final corpMembersProvider = FutureProvider.autoDispose
    .family<List<CorpMember>, String>((ref, id) {
      return requireRepo(ref).corpRegisterOfMembers(id);
    });

final corpShareClassesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, id) {
      return requireRepo(ref).corpShareClasses(id);
    });

final corpShareEventsProvider = FutureProvider.autoDispose
    .family<List<CorpShareEvent>, String>((ref, id) {
      return requireRepo(ref).corpShareEvents(id);
    });

final corpBeneficialOwnersProvider = FutureProvider.autoDispose
    .family<List<CorpBeneficialOwner>, String>((ref, id) {
      return requireRepo(ref).corpBeneficialOwners(id);
    });

/// The resolutions a company has passed. 0062.
final corpResolutionsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, id) {
      return requireRepo(ref).corpResolutions(id);
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

/// Who introduced the people the company hired. HR only; the database
/// answers an employee with nothing.
final referralHiresProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).referralHires();
    });

final appraisalsProvider = FutureProvider.autoDispose<List<Appraisal>>((ref) {
  return requireRepo(ref).appraisals();
});

final appraisalCyclesProvider =
    FutureProvider.autoDispose<List<AppraisalCycle>>((ref) {
      return requireRepo(ref).appraisalCycles();
    });

/// Whose half is whose, straight from `my_appraisal_parts`. The screen
/// draws its buttons from this rather than working the rule out again —
/// see `features/hr/appraisal_part.dart`.
final myAppraisalPartsProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) {
      return requireRepo(ref).myAppraisalParts();
    });

/// Who has not written their half, and by how long. HR only; an employee
/// asking gets nothing, which is the database's answer and not a filter
/// applied here.
final appraisalsDueProvider = FutureProvider.autoDispose<List<AppraisalDue>>((
  ref,
) {
  return requireRepo(ref).appraisalsDue();
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
  return (ref.watch(memberRoleProvider).valueOrNull ?? '') == 'auditor';
});

final payslipAccessLogProvider =
    FutureProvider.autoDispose<List<PayslipAccessLogEntry>>((ref) {
      return requireRepo(ref).payslipAccessLog();
    });

/// The change history. Owners and admins only — the RPC refuses anyone
/// else, so the screen guards on the same right rather than showing an
/// error where a card should be.
/// The security log, filtered by kind. Null is everything.
final securityLogProvider = FutureProvider.autoDispose
    .family<List<SecurityEvent>, String?>((ref, kind) {
      return requireRepo(ref).securityLog(kind: kind);
    });

/// Sign-ins, exports, reads, refusals and changes over a window.
final securitySummaryProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) {
      return requireRepo(ref).securitySummary();
    });

/// What the change history is being narrowed to.
///
/// Held as a value rather than as three providers so that changing two
/// filters at once is one read rather than two — which matters here more
/// than usual, because reading the trail WRITES a `sensitive_read` and
/// a screen that re-reads per filter buries the events somebody is
/// looking for.
@immutable
class AuditFilter {
  const AuditFilter({this.actorId, this.from, this.to});

  final String? actorId;
  final DateTime? from;
  final DateTime? to;

  bool get isEmpty => actorId == null && from == null && to == null;

  AuditFilter copyWith({
    Object? actorId = _same,
    Object? from = _same,
    Object? to = _same,
  }) => AuditFilter(
    actorId: actorId == _same ? this.actorId : actorId as String?,
    from: from == _same ? this.from : from as DateTime?,
    to: to == _same ? this.to : to as DateTime?,
  );

  // A sentinel, because `null` is a value each of these can take and
  // `copyWith(actorId: null)` has to mean "clear it" rather than "leave
  // it".
  static const _same = Object();

  @override
  bool operator ==(Object other) =>
      other is AuditFilter &&
      other.actorId == actorId &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(actorId, from, to);
}

final auditFilterProvider = StateProvider.autoDispose<AuditFilter>(
  (ref) => const AuditFilter(),
);

final auditTrailProvider = FutureProvider.autoDispose<List<AuditEntry>>((ref) {
  final filter = ref.watch(auditFilterProvider);
  return requireRepo(ref).auditTrail(
    actorId: filter.actorId,
    from: filter.from,
    to: filter.to,
  );
});

/// A company's report layouts, by report kind. 0637.
final reportLayoutsProvider = FutureProvider.autoDispose
    .family<List<ReportLayout>, String>((ref, kind) {
      return requireRepo(ref).reportLayouts(kind);
    });

/// A company's own payment methods. 0635.
final paymentMethodsProvider =
    FutureProvider.autoDispose<List<PaymentMethod>>((ref) {
      return requireRepo(ref).paymentMethods();
    });

/// Who appears in the change history, for the filter's dropdown.
final auditTrailActorsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).auditTrailActors();
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

/// The platform's own audit trail and security log — the rows with no
/// organization. `platformRepoProvider` for the same reason the line
/// above uses it: the person reading these may belong to no company.
///
/// `autoDispose`, and deliberately so. Reading the trail is recorded as
/// a sensitive read, so a provider kept alive across the console would
/// turn one visit into a stream of identical events every time the tab
/// was rebuilt.
final platformAuditTrailProvider = FutureProvider.autoDispose
    .family<List<AuditEntry>, String?>((ref, table) {
      return ref.watch(platformRepoProvider).platformAuditTrail(table: table);
    });

final platformSecurityLogProvider =
    FutureProvider.autoDispose<List<SecurityEvent>>((ref) {
      return ref.watch(platformRepoProvider).platformSecurityLog();
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

/// What is waiting for the person signed in, in this company.
final myNotificationsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, bool>((ref, includeRead) {
      return requireRepo(ref).myNotifications(includeRead: includeRead);
    });

/// Just the number, for the bell. Separate from the list because the
/// bell is on every screen and the list is only on the one that is
/// open.
final unreadNotificationsProvider =
    FutureProvider.autoDispose<int>((ref) {
      return requireRepo(ref).unreadNotifications();
    });

/// What one expense was divided into. Empty for the ordinary expense,
/// which is on one account and has no lines at all.
final expenseSplitProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, expenseId) {
      return requireRepo(ref).expenseSplit(expenseId);
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

/// What the platform has billed *this* company -- module subscriptions
/// since 0489, scanning credit since 0111, both in `platform_invoices`.
///
/// `RepoOcr.creditInvoices` filters on `org_id` itself, which matters
/// more than it used to: the read policy also lets a platform
/// administrator see every tenant's invoices, so an unscoped select
/// would put all of them on their own company's settings card.
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

/// The same deadlines for the whole list, keyed by filing id.
///
/// Six months rather than the function's default sixty days: CA 2016
/// s.258 gives six months from the year end to circulate and thirty days
/// after that to lodge, so a window shorter than the statutory one would
/// hide the filing on the day somebody most wants to start it.
final fsDeadlinesDueProvider =
    FutureProvider.autoDispose<Map<String, Map<String, dynamic>>>((ref) async {
      final rows = await requireRepo(ref).fsDeadlinesDue(withinDays: 180);
      return {
        for (final r in rows)
          if (r['filing_id'] != null) r['filing_id'].toString(): r,
      };
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

/// The deviations from the default MBRS mapping, and only those. An
/// empty list means a standard chart mapped the standard way, not an
/// unmapped one.
final fsAccountMapProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return requireRepo(ref).fsAccountMap();
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

/// Every team, retired ones included. The console's list.
final ticketTeamsAllProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).ticketTeamsAll(),
    );

/// Who is on one, leads first.
final ticketTeamRosterProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, teamId) => requireRepo(ref).ticketTeamRoster(teamId),
    );

final ticketTeamsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
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

final posRegistersProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posRegisters(),
    );

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

/// The week somebody works. 0217.
///
/// Empty means booked at no time, not booked at any time: the check is
/// an `exists` over this table.
final posProviderHoursProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, providerId) => requireRepo(ref).posProviderHours(providerId),
    );

/// And when they are away. 0217.
final posProviderTimeOffProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, providerId) => requireRepo(ref).posProviderTimeOff(providerId),
    );

/// What is being made and what is ready, for the screen customers
/// watch. Keyed on the outlet: the board belongs to the shop, not to
/// the kiosk that happens to be showing it.
final posOutletChannelsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, outletId) => requireRepo(ref).posOutletChannels(outletId),
    );

/// The last thirty days, split by how the order arrived. A fixed window
/// rather than a picker: the question this answers on a settings screen
/// is "is this channel worth keeping on", and that is a recent
/// question.
final posChannelMixProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posSalesByChannel(
        from: DateTime.now().subtract(const Duration(days: 30)),
      ),
    );

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

/// The questions a company asks, for the screen that edits them.
/// Retired ones are in the list — see `pos_modifier_groups_admin`.
final posModifierGroupsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posModifierGroups(),
    );

final posModifierOptionsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, groupId) => requireRepo(ref).posModifierOptions(groupId),
    );

/// What was chosen on the lines of a sale. Keyed on the sale rather
/// than the line so the basket makes one round trip instead of one per
/// line.
final posSaleLineModifiersProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, saleId) => requireRepo(ref).posSaleLineModifiers(saleId),
    );

// ---------------------------------------------------------------------
// Memberships
// ---------------------------------------------------------------------

/// The offers this company sells.
final posMembershipsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posMemberships(),
    );

/// Who is on what, filtered by status. `'all'` is a real choice rather
/// than the absence of one: a cancelled membership is the row somebody
/// goes looking for when a customer says they were still being charged.
final membershipSubscriptionsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, status) => requireRepo(ref).membershipSubscriptions(status: status),
    );

/// What is left this period, for one subscription.
final membershipBalanceProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>(
      (ref, subscriptionId) =>
          requireRepo(ref).membershipBalance(subscriptionId),
    );

/// Active memberships with no renewal schedule behind them. Watched by
/// the screen rather than fetched on demand, because the point of the
/// list is that somebody sees it without going to look.
final membershipBillingGapsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).membershipBillingGaps(),
    );

/// What the till owes LHDN and has not filed.
///
/// Watched by the e-Invoice screen rather than fetched on demand: the
/// deadline is seven days after month end and passes whether or not
/// anybody went looking.
final posEinvoiceOutstandingProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posEinvoiceOutstanding(),
    );

/// The axes a style has been split along, and the variants under it.
final itemVariantMatrixProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, parentId) => requireRepo(ref).itemVariantMatrix(parentId),
    );

final itemVariantsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, parentId) => requireRepo(ref).itemVariants(parentId),
    );

/// What one customer holds on the loyalty programme.
final loyaltyAccountBalanceProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>(
      (ref, contactId) => requireRepo(ref).loyaltyAccountBalance(contactId),
    );

/// What went off the bills over a range, grouped by reason.
final posVoidSummaryProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({DateTime from, DateTime to})>(
      (ref, range) => requireRepo(ref).posVoidSummary(range.from, range.to),
    );

/// When each group of dishes is offered, and whether it is on now. 0258.
final posMenuSchedulesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posMenuSchedules(),
    );

/// What an outlet has run out of today. 0258.
final posStoppedItemsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, outletId) => requireRepo(ref).posStoppedItems(outletId),
    );

/// Everyone still standing in the line at an outlet today. 0257.
///
/// Minutes waited and the count ahead come back from the server, so two
/// devices with different clocks cannot show two different queues.
final posQueueProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, outletId) => requireRepo(ref).posQueue(outletId),
    );

/// What the line did on one day, per outlet. 0257.
final posQueueDayProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTime>(
      (ref, date) => requireRepo(ref).posQueueDay(date),
    );

/// Every promotion a company has written, with what each gave away. 0256.
final posPromotionsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posPromotions(),
    );

/// What the shop's own rules have taken off this bill, and any voucher
/// on it — including one qualifying for nothing, with the reason. 0256.
final posSalePromotionsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, saleId) => requireRepo(ref).posSalePromotions(saleId),
    );

/// Who took money off which bills, over a range of days. 0255.
///
/// The other half of the void report and read on the same screen: one
/// answers where the food went, the other where the price went.
final posDiscountSummaryProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({DateTime from, DateTime to})>(
      (ref, range) => requireRepo(ref).posDiscountSummary(range.from, range.to),
    );

/// The company's active loyalty scheme, or nothing if it runs none.
final loyaltyProgramProvider =
    FutureProvider.autoDispose<Map<String, dynamic>?>(
      (ref) => requireRepo(ref).loyaltyProgram(),
    );

/// The bands a loyalty scheme gives its members. 0253.
final loyaltyTiersProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).loyaltyTiers(),
    );

/// Which tier one member is in. Keyed on the account rather than the
/// contact, because the till already has the account.
final loyaltyMemberTierProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>(
      (ref, accountId) => requireRepo(ref).loyaltyMemberTier(accountId),
    );

/// Every outlet's day on one board. Keyed on the date because the
/// question "and yesterday?" is one tap away and should not refetch
/// today.
final posDayBoardProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTime>(
      (ref, date) => requireRepo(ref).posDayBoard(date),
    );

/// The bills written off, one row each rather than grouped. See
/// `pos_voided_bills` (0248) on why this is a different question from
/// the line summary above.
final posVoidedBillsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({DateTime from, DateTime to})>(
      (ref, range) => requireRepo(ref).posVoidedBills(range.from, range.to),
    );

/// Every OCR reader the platform offers, active or retired.
final ocrProviderCatalogProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => ref.watch(platformRepoProvider).ocrProviderCatalog(),
    );

/// Every AI provider, with whether a key is on file. Platform staff
/// only — the function behind it refuses anybody else, and it has no
/// column that could carry a key. 0536.
final aiProviderCatalogueProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => ref.watch(platformRepoProvider).aiProviderCatalogue(),
    );

/// The provider catalogue as a company sees it: names and addresses,
/// nothing private. 0536.
final aiProvidersProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => ref.watch(platformRepoProvider).aiProviders(),
    );

/// Every model on offer. A table rather than a constant, so a model
/// that shipped on Tuesday is a row somebody added. 0536.
final aiModelsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => ref.watch(platformRepoProvider).aiModels(),
    );

/// Whether this company's assistant is on, what it will call, and
/// whether that call can be made. 0536.
final aiStatusProvider = FutureProvider.autoDispose<Map<String, dynamic>>((
  ref,
) async {
  final org = ref.watch(currentOrgIdProvider);
  if (org == null) return <String, dynamic>{};
  return requireRepo(ref).aiStatus(org);
});

/// Every run at an outlet that has not landed yet. 0259.
final posDeliveryBoardProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, outletId) => requireRepo(ref).posDeliveryBoard(outletId),
    );

/// Where one bill is going, what the ride costs and who has it. 0259.
///
/// An empty map when the bill is not a delivery, which is what the till
/// reads to decide whether to offer the address sheet or the summary.
final posDeliveryForProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>(
      (ref, saleId) => requireRepo(ref).posDeliveryFor(saleId),
    );

/// How far each outlet will go and what it charges. 0259.
final posDeliveryZonesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posDeliveryZones(),
    );

/// The people who carry the orders, with how many each has out. 0259.
final posDriversProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posDrivers(),
    );

/// What each driver carried on one trading day. 0259.
/// One day of delivering, per outlet. 0280.
final posDeliveryDayProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTime>(
      (ref, date) => requireRepo(ref).posDeliveryDay(date),
    );

final posDriverRunsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, DateTime>(
      (ref, date) => requireRepo(ref).posDriverRuns(date),
    );

/// The paper for one bill, rendered on the server. 0261.
final posReceiptTextProvider = FutureProvider.autoDispose
    .family<String, String>(
      (ref, saleId) => requireRepo(ref).posReceiptText(saleId),
    );

/// What an outlet prints, defaults included. 0261.
final posReceiptSettingsProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>(
      (ref, outletId) => requireRepo(ref).posReceiptSettings(outletId),
    );

/// The last bill an outlet settled, for the settings screen's preview. 0261.
final posRecentSaleProvider = FutureProvider.autoDispose
    .family<String?, String>(
      (ref, outletId) => requireRepo(ref).posRecentSale(outletId),
    );

/// Every menu a company has published, with how many bills came in
/// through each. 0262.
final posMenuLinksProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posMenuLinks(),
    );

/// The reports a company keeps, plus this person's own. 0263.
final posReportsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posReports(),
    );

/// What a source can be cut by and what it can add up. 0263.
final posReportFieldsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, source) => requireRepo(ref).posReportFields(source),
    );

/// One built report's rows. 0263.
final posReportRunProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, id) => requireRepo(ref).runPosReport(id),
    );

/// And what its columns are called. 0263.
final posReportHeadersProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>(
      (ref, id) => requireRepo(ref).posReportHeaders(id),
    );

/// Every dish that has a recipe, with what one costs today. 0264.
final posRecipesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posRecipes(),
    );

/// What one of a dish actually draws, sub-recipes exploded. 0264.
final posRecipeRequirementProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, itemId) => requireRepo(ref).posRecipeRequirement(itemId),
    );

/// How many more of each dish an outlet can make. 0264.
final posItemAvailabilityProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, outletId) => requireRepo(ref).posItemAvailability(outletId),
    );

/// The units an item's quantities may be written in. 0264.
/// Every unit of measure the platform knows. Reference data, so it is
/// held rather than autoDisposed: the list is the same on every screen
/// that asks and does not change while somebody is looking at it.
/// Every item with the stall it belongs to, for the food court.
final itemStallsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).itemStalls(),
    );

final uomCodesProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) => requireRepo(ref).uomCodes(),
);

final itemUomOptionsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, itemId) => requireRepo(ref).itemUomOptions(itemId),
    );

/// Every bundle a company sells. 0277.
final itemBundlesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).itemBundles(),
    );

/// What one is made of, exploded through any sub-bundles.
final bundlePartsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, itemId) => requireRepo(ref).bundleParts(itemId),
    );

final bundleMarginProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>(
      (ref, itemId) => requireRepo(ref).bundleMargin(itemId),
    );

final bundleAvailabilityProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>(
      (ref, itemId) => requireRepo(ref).bundleAvailability(itemId),
    );

/// Thirteen weeks of cash, or however many were asked for. 0276.
final cashForecastProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({int weeks, bool useHistory})>(
      (ref, args) => requireRepo(
        ref,
      ).cashForecast(weeks: args.weeks, useHistory: args.useHistory),
    );

/// The week the money runs out, or null when it does not.
final cashRunsOutProvider = FutureProvider.autoDispose.family<DateTime?, int>(
  (ref, weeks) => requireRepo(ref).cashRunsOutOn(weeks: weeks),
);

final cashForecastDetailProvider = FutureProvider.autoDispose
    .family<
      List<Map<String, dynamic>>,
      ({DateTime from, DateTime to, bool useHistory})
    >(
      (ref, args) => requireRepo(ref).cashForecastDetail(
        from: args.from,
        to: args.to,
        useHistory: args.useHistory,
      ),
    );

final cashForecastItemsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).cashForecastItems(),
    );

final customerPaymentLagsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).customerPaymentLags(),
    );

/// The post-dated cheque register. 0275.
final postDatedChequesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({String? direction, String? status})>(
      (ref, args) => requireRepo(
        ref,
      ).postDatedCheques(direction: args.direction, status: args.status),
    );

/// What matures in the next month, and anything already past its date.
final pdcMaturingProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).pdcMaturing(),
    );

/// Every budget, newest year first. 0274.
final budgetsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) => requireRepo(ref).budgets(),
);

final budgetLinesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, id) => requireRepo(ref).budgetLines(id),
    );

/// What happened, what was supposed to, and the difference.
final budgetVsActualProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({String budget, int? from, int? to})>(
      (ref, args) => requireRepo(
        ref,
      ).budgetVsActual(args.budget, fromPeriod: args.from, toPeriod: args.to),
    );

/// Every deposit note, newest first. 0273.
final depositNotesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, ({String? kind, String? status})>(
      (ref, args) =>
          requireRepo(ref).depositNotes(kind: args.kind, status: args.status),
    );

/// What is still held for a party, either way.
final depositsHeldForProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, contactId) => requireRepo(ref).depositsHeldFor(contactId),
    );

final depositHistoryProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, id) => requireRepo(ref).depositHistory(id),
    );

/// Every contra note, newest first. 0272.
final contraNotesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String?>(
      (ref, status) => requireRepo(ref).contraNotes(status: status),
    );

/// What a party has outstanding on both sides.
final contraCandidatesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, contactId) => requireRepo(ref).contraCandidates(contactId),
    );

final contraLinesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, id) => requireRepo(ref).contraLines(id),
    );

/// Every landed cost run, newest first. 0271.
final landedCostRunsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String?>(
      (ref, status) => requireRepo(ref).landedCostRuns(status: status),
    );

/// What each goods line on a run would take, from the same function the
/// posting uses.
final landedCostPreviewProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, runId) => requireRepo(ref).landedCostPreview(runId),
    );

final landedCostChargesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, runId) => requireRepo(ref).landedCostCharges(runId),
    );

final landedCostTargetsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, runId) => requireRepo(ref).landedCostTargets(runId),
    );

/// Every stock transfer, newest first. 0265.
final stockTransfersProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String?>(
      (ref, status) => requireRepo(ref).stockTransfers(status: status),
    );

/// Why a supply is exempt, in LHDN's own list. 0002.
final exemptionReasonsProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) => requireRepo(ref).exemptionReasons(),
);

/// The MSIC 2008 codes SSM registers a business activity under. 0002.
final msicCodesProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) => requireRepo(ref).msicCodes(),
);

/// What a shop files its items under. 0003.
final itemCategoriesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).itemCategories(),
    );

/// The conversions a company keeps. 0265.
final itemConversionsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).itemConversions(),
    );

/// And what one of them produces. 0265.
final itemConversionOutputsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, id) => requireRepo(ref).itemConversionOutputs(id),
    );

/// Everything this shop sells by weight. 0266.
final weighedItemsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).weighedItems(),
    );

/// The label layouts its scales print. 0266.
final scaleFormatsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).scaleFormats(),
    );

/// The stalls in a food court. 0268.
final posStallsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, outletId) => requireRepo(ref).posStalls(outletId),
    );

/// And what each has been paid. 0268.
final posStallSettlementsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, outletId) => requireRepo(ref).posStallSettlements(outletId),
    );

/// What is left uncredited on an invoice. 0269.
final invoiceCreditRemainingProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, invoiceId) => requireRepo(ref).invoiceCreditRemaining(invoiceId),
    );

/// The same, for a supplier's bill. 0376.
final billCreditRemainingProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>(
      (ref, billId) => requireRepo(ref).billCreditRemaining(billId),
    );
