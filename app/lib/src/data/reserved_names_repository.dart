import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/providers.dart';
import 'repository.dart';

/// The two names a company can reserve on the platform's domain: a
/// subdomain to sign in at, and an address to send and receive from.
///
/// Deliberately not an extension on [Repo], for the same reason
/// [PlatformCatalog] is not: half of what follows is read by a platform
/// operator who belongs to no company at all, and `repoProvider` is
/// null for them. What a company asks for takes an org id as an
/// argument rather than reading one off a repository bound to it.
/// The name as it will be stored.
///
/// The same fold `app.normalize_host_label` does, so what the form
/// shows and what the unique index compares are the same string.
String normalizeName(String raw) => raw.trim().toLowerCase();

/// Null when a name may be asked for, otherwise the sentence to show
/// whoever typed it.
///
/// A copy of `app.check_host_label`, and deliberately only a copy: the
/// database is the authority and refuses the same names for the same
/// reasons whatever this says. What it buys is a person being told
/// their name is no good while they are still typing it, rather than
/// after a round trip that ends in a red bar.
///
/// [reserved] is the `reserved_names` table as it was read. Filtering
/// by scope happens here rather than in the query so one read serves
/// both forms.
String? checkName(
  String raw, {
  required String scope,
  required List<Map<String, dynamic>> reserved,
}) {
  final name = normalizeName(raw);

  // Three at least and 63 at most, letters digits and hyphens, starting
  // and ending with a letter or a digit.
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$').hasMatch(name)) {
    return 'Use 3 to 63 letters, digits and hyphens, starting and '
        'ending with a letter or a digit.';
  }

  // How a punycode name announces itself.
  if (name.length >= 4 && name.substring(2, 4) == '--') {
    return 'That prefix is reserved for internationalised names.';
  }

  for (final row in reserved) {
    if (row['name'] != name) continue;
    final rowScope = '${row['scope']}';
    if (rowScope == 'both' || rowScope == scope) {
      return 'That name is reserved: ${row['reason']}.';
    }
  }
  return null;
}

/// The label to ask about for a host in the browser's address bar, or
/// null when there is nothing worth asking.
///
/// Pure, and separate from the request, because the interesting cases
/// are all about *not* making one: a native build has no host at all, a
/// bare `iakauntan.com` has no company in front of it, and an address
/// typed as an IP is somebody testing. Each of those used to be a round
/// trip that could only ever come back empty.
String? workspaceLabel(String host) {
  final bare = host.split(':').first.trim().toLowerCase();
  if (bare.isEmpty) return null;

  // An IPv4 address is not a name and has no first label.
  if (RegExp(r'^[0-9.]+$').hasMatch(bare)) return null;

  final labels = bare.split('.');
  // `localhost`, and anything else with nothing in front of it.
  if (labels.length < 3) return null;

  final first = labels.first;
  // The platform's own hosts. Asking about these is asking whether the
  // platform is one of its own tenants.
  const ours = {'www', 'app', 'api', 'staging', 'dev'};
  if (first.isEmpty || ours.contains(first)) return null;

  return first;
}

class ReservedNames {
  const ReservedNames(this.client);

  final SupabaseClient client;

  // -------------------------------------------------------------------
  // A company's own
  // -------------------------------------------------------------------
  Future<Map<String, dynamic>?> subdomainFor(String orgId) async {
    final rows = Repo.rows(
      await client
          .from('org_subdomains')
          .select('id, subdomain, status, requested_at, decided_at, note')
          .eq('org_id', orgId)
          .limit(1),
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> mailboxesFor(String orgId) async =>
      Repo.rows(
        await client
            .from('org_mailboxes')
            .select('id, local_part, status, requested_at, decided_at, note')
            .eq('org_id', orgId)
            .order('requested_at'),
      );

  Future<void> requestSubdomain(String orgId, String name) => client
      .rpc('request_subdomain', params: {
        'p_org_id': orgId,
        'p_subdomain': name,
      });

  Future<void> requestMailbox(String orgId, String localPart) => client
      .rpc('request_mailbox', params: {
        'p_org_id': orgId,
        'p_local_part': localPart,
      });

  // -------------------------------------------------------------------
  // What an operator decides
  // -------------------------------------------------------------------
  /// Everything still waiting, both kinds.
  Future<List<Map<String, dynamic>>> pending() async {
    final rows = await all();
    return [for (final r in rows) if (r['status'] == 'requested') r];
  }

  /// What has been decided, newest first.
  Future<List<Map<String, dynamic>>> decided() async {
    final rows = await all();
    return [for (final r in rows) if (r['status'] != 'requested') r];
  }

  /// Every reservation an operator may act on, with the company on it.
  ///
  /// Through an RPC rather than PostgREST's `organizations(name)` embed,
  /// which is what the two lists used to do. `organizations` carries one
  /// SELECT policy — `app.is_org_member(id)` — and a platform operator
  /// is not a member of the companies they administer, so the embed came
  /// back null and every row on the screen read "Unknown company". The
  /// rows themselves were never the problem: `org_subdomains` lets an
  /// operator read them, so the list looked complete and was anonymous.
  Future<List<Map<String, dynamic>>> all() async =>
      Repo.rows(await client.rpc('platform_reservations'));

  /// Move a name to another company, or correct how it is spelled.
  ///
  /// Both are optional and null leaves that half alone, so the console
  /// can send whatever its form holds without deciding which of the two
  /// the operator meant to change.
  /// Hold a name, with or without a company behind it.
  ///
  /// `0342`. An operator reserving a name is the decision — there is
  /// nobody to approve it afterwards — so the row is created approved.
  ///
  /// [purpose] is `0344`'s: `company`, `reserved` or `admin`. Null lets
  /// the database read it off the company, which is what every caller
  /// written before that migration meant — a company on it made it
  /// theirs, and nothing on it made it held.
  Future<void> reserve({
    required String name,
    String? orgId,
    String? moduleCode,
    String? landingPath,
    String? note,
    String? purpose,
  }) =>
      client.rpc('platform_reserve_subdomain', params: {
        'p_name': name,
        'p_org_id': orgId,
        'p_module_code': moduleCode,
        'p_landing_path': landingPath,
        'p_note': note,
        'p_purpose': purpose,
      });

  /// Move a name, rename it, point it, or let go of it.
  ///
  /// An omitted argument leaves that field alone. The two `0342` added
  /// are cleared with an empty string rather than a null, because a
  /// null already means "do not touch" — and [release] does the same
  /// job for the company, which has no empty form to send.
  Future<void> update({
    required String kind,
    required String id,
    String? orgId,
    String? name,
    String? moduleCode,
    String? landingPath,
    bool release = false,
    String? purpose,
  }) =>
      client.rpc('platform_update_reservation', params: {
        'p_kind': kind,
        'p_id': id,
        'p_org_id': orgId,
        'p_name': name,
        'p_module_code': moduleCode,
        'p_landing_path': landingPath,
        'p_release': release,
        'p_purpose': purpose,
      });

  Future<void> decide({
    required String kind,
    required String id,
    required bool approve,
    String? note,
  }) =>
      client.rpc(
        kind == 'subdomain' ? 'decide_subdomain' : 'decide_mailbox',
        params: {'p_id': id, 'p_approve': approve, 'p_note': note},
      );

  /// The names nobody may have, so the request form can say why before
  /// anybody submits one.
  Future<List<Map<String, dynamic>>> reserved() async => Repo.rows(
        await client
            .from('reserved_names')
            .select('name, scope, reason')
            .order('name'),
      );
}

final reservedNamesProvider = Provider<ReservedNames>(
  (ref) => ReservedNames(ref.watch(supabaseProvider)),
);

/// This company's subdomain, requested or granted, or null for neither.
final orgSubdomainProvider =
    FutureProvider.autoDispose<Map<String, dynamic>?>((ref) async {
  final orgId = ref.watch(currentOrgIdProvider);
  if (orgId == null) return null;
  return ref.watch(reservedNamesProvider).subdomainFor(orgId);
});

final orgMailboxesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final orgId = ref.watch(currentOrgIdProvider);
  if (orgId == null) return const [];
  return ref.watch(reservedNamesProvider).mailboxesFor(orgId);
});

final pendingReservationsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) => ref.watch(reservedNamesProvider).pending(),
);

final decidedReservationsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) => ref.watch(reservedNamesProvider).decided(),
);

/// What the address in the browser's bar turned out to be.
///
/// Three outcomes, and the third is the one this enum exists for.
/// Before `0331` an unknown name and the bare domain were both "null",
/// so `nosuchcompany.iakauntan.com` drew the platform's own front page
/// — which tells a visitor the address is fine and the company is not
/// there, when the truth is the other way round.
enum WorkspaceHost {
  /// Not a company's address at all: a native build, the bare domain,
  /// `localhost`, or one of the platform's own labels. Draw the
  /// ordinary app.
  platform,

  /// A company holds this name. Draw its door.
  found,

  /// The address is shaped like a company's and nobody holds it. Draw
  /// the page that says so.
  unknown,
}

/// Whose door this is, and the company if it is anybody's.
typedef WorkspaceLookup = ({WorkspaceHost host, Map<String, dynamic>? workspace});

/// Whose door this is, for the address in the browser's bar.
///
/// Read before anybody has signed in, which is the whole point: the
/// sign-in page at `sinar.iakauntan.com` should say Sinar on it.
///
/// A lookup that *fails* is deliberately `platform` rather than
/// `unknown`. A company whose name is perfectly good must not be told
/// it does not exist because a request timed out — the platform's own
/// page is a survivable wrong answer and that one is not.
final workspaceLookupProvider = FutureProvider<WorkspaceLookup>((ref) async {
  final label = workspaceLabel(Uri.base.host);
  if (label == null) return (host: WorkspaceHost.platform, workspace: null);

  try {
    final rows = Repo.rows(
      await ref
          .watch(supabaseProvider)
          .rpc('workspace_by_host', params: {'p_host': Uri.base.host}),
    );
    return rows.isEmpty
        ? (host: WorkspaceHost.unknown, workspace: null)
        : (host: WorkspaceHost.found, workspace: rows.first);
  } catch (_) {
    // A sign-in page that cannot reach the server still has to draw,
    // and it must not draw an accusation.
    return (host: WorkspaceHost.platform, workspace: null);
  }
});

/// The company at this address, or null for every other case.
///
/// Kept because that is what the two places drawing a logo and a name
/// actually want, and neither of them cares which kind of "no" it got.
final workspaceHostProvider =
    FutureProvider<Map<String, dynamic>?>((ref) async {
  return (await ref.watch(workspaceLookupProvider.future)).workspace;
});

/// Mail that arrived at this company's addresses, newest first.
final inboxProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final orgId = ref.watch(currentOrgIdProvider);
  if (orgId == null) return const [];
  return Repo.rows(
    await ref
        .watch(supabaseProvider)
        .from('inbound_emails')
        .select('id, from_email, from_name, to_email, subject, body_text, '
            'received_at, read_at')
        .eq('org_id', orgId)
        .order('received_at', ascending: false)
        .limit(200),
  );
});
