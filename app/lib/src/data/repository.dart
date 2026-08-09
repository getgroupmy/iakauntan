import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/format.dart';
import 'models.dart';

/// All data access for one organization. Every query is additionally
/// filtered by org_id even though RLS already enforces it — belt and
/// braces, and it keeps the generated SQL selective.
class Repo {
  Repo(this.client, this.orgId);

  final SupabaseClient client;
  final String orgId;

  // ------------------------------------------------------------------
  // Dashboard and reports
  // ------------------------------------------------------------------
  Future<DashboardSummary> dashboard({DateTime? from, DateTime? to}) async {
    final data = await client.rpc('dashboard_summary', params: {
      'p_org_id': orgId,
      if (from != null) 'p_from': Fmt.iso(from),
      if (to != null) 'p_to': Fmt.iso(to),
    });
    return DashboardSummary(Map<String, dynamic>.from(data as Map));
  }

  Future<List<Map<String, dynamic>>> revenueTrend({int months = 12}) async {
    final data = await client.rpc('report_revenue_trend',
        params: {'p_org_id': orgId, 'p_months': months});
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> trialBalance({
    DateTime? from,
    DateTime? to,
  }) async {
    final data = await client.rpc('report_trial_balance', params: {
      'p_org_id': orgId,
      if (from != null) 'p_from': Fmt.iso(from),
      'p_to': Fmt.iso(to ?? DateTime.now()),
    });
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> profitLoss({
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await client.rpc('report_profit_loss', params: {
      'p_org_id': orgId,
      'p_from': Fmt.iso(from),
      'p_to': Fmt.iso(to),
    });
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> balanceSheet({DateTime? asAt}) async {
    final data = await client.rpc('report_balance_sheet', params: {
      'p_org_id': orgId,
      'p_as_at': Fmt.iso(asAt ?? DateTime.now()),
    });
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> sstSummary({
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await client.rpc('report_sst_summary', params: {
      'p_org_id': orgId,
      'p_from': Fmt.iso(from),
      'p_to': Fmt.iso(to),
    });
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> arAging() async {
    final data = await client
        .from('v_ar_aging')
        .select()
        .eq('org_id', orgId)
        .order('days_overdue', ascending: false);
    return _rows(data);
  }

  // ------------------------------------------------------------------
  // Contacts
  // ------------------------------------------------------------------
  Future<List<Contact>> contacts({String? type, String? search}) async {
    var query = client.from('contacts').select().eq('org_id', orgId).isFilter(
          'deleted_at',
          null,
        );

    if (type != null && type != 'all') {
      query = query.inFilter('contact_type', [type, 'both']);
    }
    if (search != null && search.trim().isNotEmpty) {
      final q = search.trim();
      query = query.or('name.ilike.%$q%,code.ilike.%$q%,email.ilike.%$q%');
    }

    final data = await query.order('name').limit(200);
    return _rows(data).map(Contact.fromJson).toList();
  }

  Future<Contact> contact(String id) async {
    final data =
        await client.from('contacts').select().eq('id', id).single();
    return Contact.fromJson(data);
  }

  Future<Contact> saveContact(Contact contact, {String? id}) async {
    final payload = contact.toJson()..['org_id'] = orgId;
    final data = id == null
        ? await client.from('contacts').insert(payload).select().single()
        : await client
            .from('contacts')
            .update(payload)
            .eq('id', id)
            .select()
            .single();
    return Contact.fromJson(data);
  }

  // ------------------------------------------------------------------
  // Items
  // ------------------------------------------------------------------
  Future<List<Item>> items({String? search, bool onlyLowStock = false}) async {
    var query =
        client.from('items').select().eq('org_id', orgId).isFilter('deleted_at', null);

    if (search != null && search.trim().isNotEmpty) {
      final q = search.trim();
      query = query.or('name.ilike.%$q%,code.ilike.%$q%,barcode.ilike.%$q%');
    }

    final data = await query.order('code').limit(300);
    final items = _rows(data).map(Item.fromJson).toList();
    return onlyLowStock ? items.where((i) => i.isLowStock).toList() : items;
  }

  Future<Item> saveItem(Item item, {String? id}) async {
    final payload = item.toJson()..['org_id'] = orgId;
    final data = id == null
        ? await client.from('items').insert(payload).select().single()
        : await client
            .from('items')
            .update(payload)
            .eq('id', id)
            .select()
            .single();
    return Item.fromJson(data);
  }

  // ------------------------------------------------------------------
  // Master data
  // ------------------------------------------------------------------
  Future<List<TaxCode>> taxCodes() async {
    final data = await client
        .from('tax_codes')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('code');
    return _rows(data).map(TaxCode.fromJson).toList();
  }

  Future<List<Account>> accounts({bool postableOnly = false}) async {
    var query = client
        .from('accounts')
        .select()
        .eq('org_id', orgId)
        .isFilter('deleted_at', null);
    if (postableOnly) query = query.eq('is_group', false);
    final data = await query.order('code');
    return _rows(data).map(Account.fromJson).toList();
  }

  Future<List<Map<String, dynamic>>> paymentTerms() async {
    final data = await client
        .from('payment_terms')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('days');
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> classificationCodes() async {
    final data = await client
        .from('ref_classification_codes')
        .select()
        .eq('is_active', true)
        .order('code');
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> uomCodes() async {
    final data = await client
        .from('ref_uom_codes')
        .select()
        .eq('is_active', true)
        .order('code');
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> states() async {
    final data = await client.from('ref_states').select().order('code');
    return _rows(data);
  }

  // ------------------------------------------------------------------
  // Sales and purchase documents
  //
  // Both cycles use the same table shape, so one set of methods serves
  // them and the screens only pass a DocKind.
  // ------------------------------------------------------------------
  Future<List<BusinessDocument>> documents({
    required DocKind kind,
    required String docType,
    String? status,
    String? search,
    int limit = 100,
  }) async {
    var query = client
        .from(kind.table)
        .select('*, contacts(name, code)')
        .eq('org_id', orgId)
        .eq('doc_type', docType)
        .isFilter('deleted_at', null);

    if (status != null && status != 'all') {
      query = status == 'outstanding'
          ? query.gt('balance_amount', 0)
          : query.eq('status', status);
    }
    if (search != null && search.trim().isNotEmpty) {
      final q = search.trim();
      query = kind.isSales
          ? query.ilike('doc_no', '%$q%')
          : query.or('doc_no.ilike.%$q%,supplier_doc_no.ilike.%$q%');
    }

    final data = await query.order('doc_date', ascending: false).limit(limit);
    return _rows(data).map(BusinessDocument.fromJson).toList();
  }

  Future<BusinessDocument> document(DocKind kind, String id) async {
    final data = await client
        .from(kind.table)
        .select('*, contacts(name, code), ${kind.lineTable}(*)')
        .eq('id', id)
        .single();
    return BusinessDocument.fromJson(data);
  }

  Future<String> nextDocumentNumber(String docType) async {
    final data = await client.rpc('next_document_number',
        params: {'p_org_id': orgId, 'p_doc_type': docType});
    return data as String;
  }

  /// Creates or replaces a document and its lines. Lines are deleted and
  /// re-inserted so the header totals are recomputed by the database
  /// triggers rather than trusted from the client.
  Future<String> saveDocument({
    required DocKind kind,
    String? id,
    required String docType,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  }) async {
    String documentId;

    if (id == null) {
      final payload = {
        ...header,
        'org_id': orgId,
        'doc_type': docType,
        'doc_no': header['doc_no'] ?? await nextDocumentNumber(docType),
      };
      final row =
          await client.from(kind.table).insert(payload).select().single();
      documentId = row['id'] as String;
    } else {
      documentId = id;
      await client.from(kind.table).update(header).eq('id', id);
      await client.from(kind.lineTable).delete().eq('document_id', id);
    }

    if (lines.isNotEmpty) {
      await client.from(kind.lineTable).insert([
        for (var i = 0; i < lines.length; i++)
          {
            ...lines[i],
            'org_id': orgId,
            'document_id': documentId,
            'line_no': i + 1,
          }
      ]);
    }

    return documentId;
  }

  Future<void> deleteDocument(DocKind kind, String id) =>
      client.from(kind.table).update({
        'deleted_at': DateTime.now().toIso8601String(),
      }).eq('id', id);

  Future<String> postDocument(DocKind kind, String id) async {
    final data = await client.rpc(kind.postRpc, params: {'p_id': id});
    return data as String;
  }

  Future<void> voidSalesDocument(String id, String reason) => client.rpc(
        'void_sales_document',
        params: {'p_id': id, 'p_reason': reason},
      );

  // ------------------------------------------------------------------
  // Settlement
  // ------------------------------------------------------------------

  /// Records a customer receipt or a supplier payment, allocates it
  /// against open documents and posts it. The two flows differ only in
  /// which table and column names are used, so they share one method.
  Future<void> recordSettlement({
    required DocKind kind,
    required String contactId,
    required double amount,
    required DateTime date,
    required List<({String documentId, double amount})> allocations,
    String? bankAccountId,
    String? paymentModeCode,
    String? reference,
    double bankCharges = 0,
  }) async {
    final isReceipt = kind.isSales;
    final table = isReceipt ? 'receipts' : 'purchase_payments';
    final numberField = isReceipt ? 'receipt_no' : 'payment_no';
    final dateField = isReceipt ? 'receipt_date' : 'payment_date';
    final docType = isReceipt ? 'receipt' : 'payment';

    final row = await client
        .from(table)
        .insert({
          'org_id': orgId,
          numberField: await nextDocumentNumber(docType),
          dateField: Fmt.iso(date),
          'contact_id': contactId,
          'amount': amount,
          'unapplied_amount': amount,
          'bank_charges': bankCharges,
          'bank_account_id': bankAccountId,
          'payment_mode_code': paymentModeCode,
          'reference': reference,
        })
        .select()
        .single();

    final settlementId = row['id'] as String;

    if (allocations.isNotEmpty) {
      await client.from('payment_allocations').insert([
        for (final a in allocations)
          {
            'org_id': orgId,
            if (isReceipt) 'receipt_id': settlementId else 'payment_id': settlementId,
            if (isReceipt) 'invoice_id': a.documentId else 'bill_id': a.documentId,
            'amount': a.amount,
          }
      ]);
    }

    await client.rpc(
      isReceipt ? 'post_receipt' : 'post_purchase_payment',
      params: {'p_id': settlementId},
    );
  }

  /// Open documents for a contact, used by the settlement dialog.
  Future<List<BusinessDocument>> outstandingFor({
    required DocKind kind,
    required String contactId,
  }) async {
    final data = await client
        .from(kind.table)
        .select('*, contacts(name, code)')
        .eq('org_id', orgId)
        .eq('contact_id', contactId)
        .eq('doc_type', kind.isSales ? 'invoice' : 'bill')
        .gt('balance_amount', 0)
        .isFilter('deleted_at', null)
        .order('doc_date');
    return _rows(data).map(BusinessDocument.fromJson).toList();
  }

  Future<List<Map<String, dynamic>>> bankAccounts() async {
    final data = await client
        .from('bank_accounts')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('name');
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> paymentModes() async {
    final data = await client
        .from('ref_payment_modes')
        .select()
        .eq('is_active', true)
        .order('code');
    return _rows(data);
  }

  // ------------------------------------------------------------------
  // Expenses
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> expenses({int limit = 100}) async {
    final data = await client
        .from('expenses')
        .select('*, accounts(code, name), contacts(name)')
        .eq('org_id', orgId)
        .isFilter('deleted_at', null)
        .order('expense_date', ascending: false)
        .limit(limit);
    return _rows(data);
  }

  /// Creates an expense and posts it in one step — expenses are always
  /// money already spent, so there is no useful draft state.
  Future<void> recordExpense({
    required String accountId,
    required double amount,
    required DateTime date,
    String? description,
    String? contactId,
    String? bankAccountId,
    String? paymentModeCode,
    String? taxCodeId,
    double taxAmount = 0,
    String? reference,
  }) async {
    final row = await client
        .from('expenses')
        .insert({
          'org_id': orgId,
          'expense_no': await nextDocumentNumber('expense'),
          'expense_date': Fmt.iso(date),
          'account_id': accountId,
          'contact_id': contactId,
          'bank_account_id': bankAccountId,
          'payment_mode_code': paymentModeCode,
          'description': description,
          'reference': reference,
          'amount': amount,
          'tax_code_id': taxCodeId,
          'tax_amount': taxAmount,
          'total_amount': amount + taxAmount,
        })
        .select()
        .single();

    await client.rpc('post_expense', params: {'p_id': row['id']});
  }

  // ------------------------------------------------------------------
  // e-Invoice
  // ------------------------------------------------------------------
  Future<List<EinvoiceDocument>> einvoices({String? status}) async {
    var query = client.from('einvoice_documents').select().eq('org_id', orgId);
    if (status != null && status != 'all') {
      query = status == 'attention'
          ? query.inFilter('status', ['invalid', 'failed'])
          : query.eq('status', status);
    }
    final data = await query.order('issue_date', ascending: false).limit(200);
    return _rows(data).map(EinvoiceDocument.fromJson).toList();
  }

  Future<Map<String, dynamic>> callMyInvois(
    String action,
    Map<String, dynamic> payload,
  ) async {
    final res = await client.functions.invoke('myinvois', body: {
      'action': action,
      'org_id': orgId,
      ...payload,
    });

    final data = res.data;
    if (data is Map && data['error'] != null) {
      throw MyInvoisException(data['error'].toString(), data['details']);
    }
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> submitEinvoice({
    String? salesDocumentId,
    List<String>? einvoiceIds,
  }) =>
      callMyInvois('submit', {
        if (salesDocumentId != null) 'sales_document_id': salesDocumentId,
        if (einvoiceIds != null) 'einvoice_ids': einvoiceIds,
      });

  Future<Map<String, dynamic>> refreshEinvoiceStatus({List<String>? ids}) =>
      callMyInvois('status', {if (ids != null) 'einvoice_ids': ids});

  Future<Map<String, dynamic>> cancelEinvoice(String id, String reason) =>
      callMyInvois('cancel', {'einvoice_id': id, 'reason': reason});

  Future<Map<String, dynamic>> validateTin({
    required String tin,
    required String idType,
    required String idValue,
    String? contactId,
  }) =>
      callMyInvois('validate-tin', {
        'tin': tin,
        'id_type': idType,
        'id_value': idValue,
        if (contactId != null) 'contact_id': contactId,
      });

  // ------------------------------------------------------------------
  // CRM
  // ------------------------------------------------------------------
  Future<List<PipelineStage>> pipelineStages() async {
    final data = await client
        .from('pipeline_stages')
        .select()
        .eq('org_id', orgId)
        .order('sort_order');
    return _rows(data).map(PipelineStage.fromJson).toList();
  }

  Future<List<Opportunity>> opportunities({String? status = 'open'}) async {
    var query = client
        .from('opportunities')
        .select('*, contacts(name)')
        .eq('org_id', orgId)
        .isFilter('deleted_at', null);
    if (status != null && status != 'all') query = query.eq('status', status);
    final data = await query.order('created_at', ascending: false).limit(300);
    return _rows(data).map(Opportunity.fromJson).toList();
  }

  Future<void> moveOpportunity(String id, String stageId) => client
      .from('opportunities')
      .update({'stage_id': stageId}).eq('id', id);

  Future<void> saveOpportunity(Map<String, dynamic> values, {String? id}) async {
    final payload = {...values, 'org_id': orgId};
    if (id == null) {
      payload['opportunity_no'] = await nextDocumentNumber('opportunity');
      await client.from('opportunities').insert(payload);
    } else {
      await client.from('opportunities').update(values).eq('id', id);
    }
  }

  Future<List<Map<String, dynamic>>> activities({bool onlyPending = true}) async {
    var query = client
        .from('activities')
        .select('*, contacts(name), opportunities(name)')
        .eq('org_id', orgId);
    if (onlyPending) query = query.eq('status', 'pending');
    final data = await query.order('due_date').limit(100);
    return _rows(data);
  }

  static List<Map<String, dynamic>> _rows(dynamic data) =>
      (data as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
}

class MyInvoisException implements Exception {
  MyInvoisException(this.message, [this.details]);
  final String message;
  final dynamic details;
  @override
  String toString() => message;
}

/// Platform-level data access. Not tenant scoped: every call lands on a
/// SECURITY DEFINER function that re-checks platform admin rights, so a
/// normal user calling these simply gets an error.
class PlatformRepo {
  PlatformRepo(this.client);

  final SupabaseClient client;

  Future<bool> amIPlatformAdmin() async {
    final data = await client.rpc('am_i_platform_admin');
    return data == true;
  }

  Future<Map<String, dynamic>> stats() async {
    final data = await client.rpc('platform_stats');
    return Map<String, dynamic>.from(data as Map);
  }

  Future<List<PlatformOrg>> organizations() async {
    final data = await client.rpc('platform_organizations');
    return Repo._rows(data).map(PlatformOrg.fromJson).toList();
  }

  Future<List<ModuleInfo>> modules() async {
    final data = await client
        .from('platform_modules')
        .select()
        .eq('is_active', true)
        .order('sort_order');
    return Repo._rows(data).map(ModuleInfo.fromJson).toList();
  }

  Future<void> setModule(String orgId, String code, bool enabled) =>
      client.rpc('platform_set_module', params: {
        'p_org_id': orgId,
        'p_module_code': code,
        'p_enabled': enabled,
      });

  Future<void> setOrgStatus(String orgId, String status) =>
      client.rpc('platform_set_org_status',
          params: {'p_org_id': orgId, 'p_status': status});

  Future<List<Map<String, dynamic>>> settings() async {
    final data =
        await client.from('platform_settings').select().order('key');
    return Repo._rows(data);
  }

  Future<void> updateSetting(String key, Map<String, dynamic> value) =>
      client.rpc('platform_update_setting',
          params: {'p_key': key, 'p_value': value});
}

/// Tenant-scoped extras: team management, module entitlements and the
/// legal firm module.
extension RepoExtras on Repo {
  // ------------------------------------------------------------------
  // Modules the tenant is entitled to
  // ------------------------------------------------------------------
  Future<Set<String>> enabledModules() async {
    final rows = await client
        .from('org_modules')
        .select('module_code, is_enabled, expires_at')
        .eq('org_id', orgId);

    final enabled = <String>{};
    for (final r in Repo._rows(rows)) {
      if (r['is_enabled'] != true) continue;
      final expires = Fmt.parseDate(r['expires_at']);
      if (expires != null && expires.isBefore(DateTime.now())) continue;
      enabled.add(r['module_code'].toString());
    }

    // Core modules are always available.
    final core = await client
        .from('platform_modules')
        .select('code')
        .eq('is_core', true);
    for (final r in Repo._rows(core)) {
      enabled.add(r['code'].toString());
    }
    return enabled;
  }

  // ------------------------------------------------------------------
  // Team
  // ------------------------------------------------------------------
  Future<List<TeamMember>> team() async {
    final data = await client.rpc('org_team', params: {'p_org_id': orgId});
    return Repo._rows(data).map(TeamMember.fromJson).toList();
  }

  Future<void> inviteMember(String email, String role) =>
      client.rpc('invite_member', params: {
        'p_org_id': orgId,
        'p_email': email,
        'p_role': role,
      });

  Future<void> changeMemberRole(String memberId, String role) =>
      client.from('org_members').update({'role': role}).eq('id', memberId);

  Future<void> removeMember(String memberId) =>
      client.from('org_members').delete().eq('id', memberId);

  Future<String> acceptInvitation(String token) async {
    final data = await client.rpc('accept_invitation', params: {'p_token': token});
    return data as String;
  }

  // ------------------------------------------------------------------
  // Legal firm module
  // ------------------------------------------------------------------
  Future<void> setupLegalModule() =>
      client.rpc('setup_legal_module', params: {'p_org_id': orgId});

  Future<List<Matter>> matters({String? status, String? search}) async {
    var query = client
        .from('matters')
        .select('*, contacts(name)')
        .eq('org_id', orgId)
        .isFilter('deleted_at', null);

    if (status != null && status != 'all') query = query.eq('status', status);
    if (search != null && search.trim().isNotEmpty) {
      final q = search.trim();
      query = query.or('name.ilike.%$q%,matter_no.ilike.%$q%');
    }

    final data = await query.order('matter_no', ascending: false).limit(200);
    return Repo._rows(data).map(Matter.fromJson).toList();
  }

  Future<List<MatterSummary>> matterSummary() async {
    final data =
        await client.rpc('report_matter_summary', params: {'p_org_id': orgId});
    return Repo._rows(data).map(MatterSummary.fromJson).toList();
  }

  Future<String> createMatter(Map<String, dynamic> values) async {
    final row = await client
        .from('matters')
        .insert({
          ...values,
          'org_id': orgId,
          'matter_no': await nextDocumentNumber('matter'),
        })
        .select()
        .single();
    return row['id'] as String;
  }

  Future<List<ClientTransaction>> clientTransactions(String matterId) async {
    final data = await client
        .from('client_account_transactions')
        .select()
        .eq('org_id', orgId)
        .eq('matter_id', matterId)
        .order('transaction_date')
        .order('created_at');
    return Repo._rows(data).map(ClientTransaction.fromJson).toList();
  }

  /// Records a client-money movement and posts it. `amount` is signed:
  /// positive is money received into the client account.
  Future<void> recordClientTransaction({
    required String matterId,
    required String transactionType,
    required double amount,
    required DateTime date,
    String? description,
    String? payee,
    String? reference,
    String? paymentModeCode,
  }) async {
    final bank = await client
        .from('bank_accounts')
        .select('id')
        .eq('org_id', orgId)
        .eq('is_client_account', true)
        .maybeSingle();

    if (bank == null) {
      throw Exception(
          'No client account configured. Open Settings and run the legal setup first.');
    }

    final row = await client
        .from('client_account_transactions')
        .insert({
          'org_id': orgId,
          'matter_id': matterId,
          'transaction_no': await nextDocumentNumber('client_txn'),
          'transaction_date': Fmt.iso(date),
          'transaction_type': transactionType,
          'bank_account_id': bank['id'],
          'amount': amount,
          'description': description,
          'payee': payee,
          'reference': reference,
          'payment_mode_code': paymentModeCode,
        })
        .select()
        .single();

    await client.rpc('post_client_transaction', params: {'p_id': row['id']});
  }

  Future<List<TimeEntry>> timeEntries(String matterId) async {
    final data = await client
        .from('time_entries')
        .select()
        .eq('org_id', orgId)
        .eq('matter_id', matterId)
        .order('entry_date', ascending: false);
    return Repo._rows(data).map(TimeEntry.fromJson).toList();
  }

  Future<void> addTimeEntry({
    required String matterId,
    required String description,
    required int minutes,
    required double hourlyRate,
    required DateTime date,
    String? activityCode,
    bool billable = true,
  }) =>
      client.from('time_entries').insert({
        'org_id': orgId,
        'matter_id': matterId,
        'user_id': client.auth.currentUser?.id,
        'entry_date': Fmt.iso(date),
        'description': description,
        'activity_code': activityCode,
        'minutes': minutes,
        'hourly_rate': hourlyRate,
        'is_billable': billable,
      });

  Future<List<Map<String, dynamic>>> disbursements(String matterId) async {
    final data = await client
        .from('disbursements')
        .select()
        .eq('org_id', orgId)
        .eq('matter_id', matterId)
        .order('disbursement_date', ascending: false);
    return Repo._rows(data);
  }

  Future<void> addDisbursement({
    required String matterId,
    required String description,
    required double amount,
    required DateTime date,
    String paidFrom = 'office',
  }) =>
      client.from('disbursements').insert({
        'org_id': orgId,
        'matter_id': matterId,
        'disbursement_date': Fmt.iso(date),
        'description': description,
        'amount': amount,
        'paid_from': paidFrom,
      });
}
