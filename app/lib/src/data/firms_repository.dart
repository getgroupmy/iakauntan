import 'package:supabase_flutter/supabase_flutter.dart';

import 'repository.dart';

/// A practice, and the companies whose books it keeps.
///
/// Not on [Repo], and deliberately: everything on `Repo` is scoped to one
/// organization, and a firm is not inside one. A practice sits above the
/// companies on its list — it is not owned by any of them — so its calls
/// take a firm id or nothing at all, and the client is all this needs.
///
/// The handover pair is the exception and lives here anyway, because
/// `transfer_company` is the operation that moves a company *out* of a
/// firm's hands. Keeping it beside the portfolio is how it reads.
class FirmsRepo {
  FirmsRepo(this.client);

  final SupabaseClient client;

  /// The practices this person belongs to. Empty for almost everybody:
  /// a company that keeps its own books never touches any of this.
  Future<List<Map<String, dynamic>>> myFirms() async =>
      Repo.rows(await client.rpc('my_firms'));

  Future<String> createFirm(
    String name, {
    String? registrationNo,
    String? email,
    String? phone,
  }) async {
    final data = await client.rpc(
      'create_firm',
      params: {
        'p_name': name,
        'p_registration_no': registrationNo,
        'p_email': email,
        'p_phone': phone,
      },
    );
    return data as String;
  }

  /// Everyone at the practice, oldest first, with the name to show them
  /// under. An invited person has no profile yet, so the address they
  /// were invited at is what there is.
  ///
  /// Through `firm_team` rather than a select on the table, because
  /// `profiles_select` is `id = auth.uid() or shares_org_with(id)` --
  /// two people at one practice cannot read each other's names until
  /// they happen to share a client, so the join has to be made
  /// somewhere that is allowed to make it. See 0453.
  Future<List<Map<String, dynamic>>> members(String firmId) async =>
      Repo.rows(await client.rpc('firm_team', params: {'p_firm_id': firmId}));

  Future<void> invite(String firmId, String email, String role) => client.rpc(
    'invite_firm_member',
    params: {'p_firm_id': firmId, 'p_email': email, 'p_role': role},
  );

  /// The client list, with enough on each row to decide what to open
  /// first: how many unposted documents are waiting and when anybody
  /// last touched the company.
  Future<List<Map<String, dynamic>>> portfolio(String firmId) async =>
      Repo.rows(
        await client.rpc('firm_portfolio', params: {'p_firm_id': firmId}),
      );

  /// Appoints the practice. Run by somebody who administers the company
  /// *and* belongs to the firm — handing your books to a practice that
  /// has never heard of you is not an appointment.
  Future<int> attach(String orgId, String firmId, String role) async {
    final data = await client.rpc(
      'attach_company_to_firm',
      params: {'p_org_id': orgId, 'p_firm_id': firmId, 'p_role': role},
    );
    return (data as num).toInt();
  }

  /// Ends the appointment. Removes exactly the rows the firm brought and
  /// none the company invited itself.
  Future<int> detach(String orgId) async {
    final data = await client.rpc(
      'detach_company_from_firm',
      params: {'p_org_id': orgId},
    );
    return (data as num).toInt();
  }

  /// What has happened to the practice — partners and managers only.
  Future<List<Map<String, dynamic>>> trail(String firmId, {int limit = 200}) =>
      client
          .rpc('firm_audit_trail', params: {
            'p_firm_id': firmId,
            'p_limit': limit,
          })
          .then(Repo.rows);

  // ------------------------------------------------------------------
  // Handing a company over
  // ------------------------------------------------------------------

  /// Owner only. The recipient becomes owner in their own right, the
  /// caller steps down to admin, and any firm's borrowed access ends.
  /// The recipient must already have an account: a company whose owner
  /// is an unaccepted invitation has no owner.
  Future<void> transferCompany(String orgId, String toEmail, {String? note}) =>
      client.rpc(
        'transfer_company',
        params: {'p_org_id': orgId, 'p_to_email': toEmail, 'p_note': note},
      );

  Future<List<Map<String, dynamic>>> transferHistory(String orgId) async =>
      Repo.rows(
        await client.rpc(
          'company_transfer_history',
          params: {'p_org_id': orgId},
        ),
      );

  /// The way out when the owner is unreachable. Platform staff only, and
  /// the reason is not optional — an escape hatch with no record is
  /// indistinguishable from a back door.
  Future<void> forceTransfer(String orgId, String toEmail, String reason) =>
      client.rpc(
        'platform_force_transfer',
        params: {
          'p_org_id': orgId,
          'p_to_email': toEmail,
          'p_reason': reason,
        },
      );
}

/// Taking the whole company out of this system.
///
/// Two calls and a walk: the manifest says what there is, and each page
/// hands back a slice of one table with the cursor for the next. Kept
/// on [FirmsRepo] because it is the same question the rest of this file
/// answers — whose company is this, and can it leave.
extension CompanyExport on FirmsRepo {
  /// Every table holding this company's data, largest first, with a
  /// row count. Tables with nothing in them are left out: 258 tables
  /// carry `org_id` and a small company uses a few dozen.
  Future<List<Map<String, dynamic>>> exportManifest(String orgId) async =>
      Repo.rows(
        await client.rpc(
          'company_export_manifest',
          params: {'p_org_id': orgId},
        ),
      );

  /// One page. [after] is the `next` from the page before, or null to
  /// start; the returned `next` is null when there is nothing after.
  Future<Map<String, dynamic>> exportPage(
    String orgId,
    String table, {
    String? after,
    int limit = 1000,
  }) async {
    final data = await client.rpc(
      'company_export_page',
      params: {
        'p_org_id': orgId,
        'p_table': table,
        'p_after': after,
        'p_limit': limit,
      },
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Walks every page of one table. Bounded so a cursor that stops
  /// advancing — which would mean a bug on the server, not a large
  /// company — cannot spin here forever.
  Future<List<dynamic>> exportTable(String orgId, String table) async {
    final out = <dynamic>[];
    String? after;
    for (var hop = 0; hop < 10000; hop++) {
      final page = await exportPage(orgId, table, after: after);
      out.addAll(page['rows'] as List? ?? const []);
      after = page['next'] as String?;
      if (after == null) return out;
    }
    return out;
  }
}
