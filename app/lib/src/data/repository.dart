import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/format.dart';
import '../features/documents/transfer.dart';
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

  Future<List<FiscalYear>> fiscalYears() async {
    final data = await client
        .from('fiscal_years')
        .select('*, fiscal_periods(*)')
        .eq('org_id', orgId)
        .order('start_date', ascending: false);
    return _rows(data).map(FiscalYear.fromJson).toList();
  }

  /// Creates the year after the last one. Passing a start date is only
  /// for the first year, or for a company changing its year end.
  Future<void> createFiscalYear({DateTime? startDate}) =>
      client.rpc('create_fiscal_year', params: {
        'p_org_id': orgId,
        if (startDate != null) 'p_start_date': Fmt.iso(startDate),
      });

  Future<void> setPeriodStatus(String periodId, String status) =>
      client.rpc('set_fiscal_period_status',
          params: {'p_period_id': periodId, 'p_status': status});

  /// The ledger itself. Everything in the system posts through
  /// create_gl_entry, so this is the one place an invoice, a payroll run
  /// and a hand-written correction can be compared side by side.
  Future<List<JournalEntry>> journals({
    DateTime? from,
    DateTime? to,
    String? source,
    int limit = 100,
  }) async {
    var q = client
        .from('gl_entries')
        .select('*, gl_lines(*, accounts(code, name))')
        .eq('org_id', orgId);
    if (from != null) q = q.gte('entry_date', Fmt.iso(from));
    if (to != null) q = q.lte('entry_date', Fmt.iso(to));
    if (source != null) q = q.eq('source', source);
    final rows = await q.order('entry_date', ascending: false).limit(limit);
    return _rows(rows).map(JournalEntry.fromJson).toList();
  }

  /// Posts the mirror image and voids the original. Nothing is deleted:
  /// a ledger you can erase is not a ledger.
  Future<void> reverseJournal(String entryId, DateTime on) =>
      client.rpc('reverse_gl_entry',
          params: {'p_entry_id': entryId, 'p_date': Fmt.iso(on)});

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
  // Foreign exchange
  // ------------------------------------------------------------------
  Future<List<Currency>> currencies() async {
    final data = await client
        .from('ref_currencies')
        .select()
        .eq('is_active', true)
        .order('code');
    return _rows(data).map(Currency.fromJson).toList();
  }

  /// The rate the database would apply to a document in [currency] dated
  /// [onDate], or null when there is none on file.
  ///
  /// Null rather than 1. `app.exchange_rate_for` raises P0002 instead of
  /// defaulting, for the reason set out in migration 0078 — defaulting
  /// turns a USD 10,000 invoice into RM 10,000 and every check in the
  /// system still passes. The absence is translated here into something
  /// the form can act on, and nothing else about it is softened: a null
  /// stops the save.
  Future<double?> exchangeRateFor(String currency, DateTime onDate) async {
    try {
      final data = await client.rpc('exchange_rate_for', params: {
        'p_org_id': orgId,
        'p_currency': currency,
        'p_on_date': Fmt.iso(onDate),
      });
      return Fmt.toDouble(data);
    } on PostgrestException catch (e) {
      if (e.code == 'P0002') return null;
      rethrow;
    }
  }

  // ------------------------------------------------------------------
  // Bank reconciliation
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> bankStatementLines(
    String bankAccountId, {
    bool onlyOpen = false,
  }) async {
    var q = client
        .from('bank_transactions')
        .select()
        .eq('org_id', orgId)
        .eq('bank_account_id', bankAccountId);
    if (onlyOpen) q = q.isFilter('reconciliation_id', null);
    return _rows(await q.order('transaction_date'));
  }

  /// Imports statement lines, skipping any already on the account.
  /// Returns {'imported': n, 'skipped': n}.
  Future<Map<String, dynamic>> importBankTransactions(
    String bankAccountId,
    List<Map<String, dynamic>> rows,
  ) async {
    final data = await client.rpc('import_bank_transactions', params: {
      'p_bank_account_id': bankAccountId,
      'p_rows': rows,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  Future<List<Map<String, dynamic>>> suggestBankMatches(
          String transactionId) async =>
      _rows(await client.rpc('suggest_bank_matches',
          params: {'p_transaction_id': transactionId}));

  Future<void> matchBankTransaction({
    required String transactionId,
    required String sourceTable,
    required String sourceId,
  }) =>
      client.rpc('match_bank_transaction', params: {
        'p_transaction_id': transactionId,
        'p_source_table': sourceTable,
        'p_source_id': sourceId,
      });

  Future<void> unmatchBankTransaction(String transactionId) =>
      client.rpc('unmatch_bank_transaction',
          params: {'p_transaction_id': transactionId});

  /// Book balance, unpresented items, and what is left over.
  Future<Map<String, dynamic>> bankReconciliationStatus({
    required String bankAccountId,
    required DateTime asAt,
    required double statementBalance,
  }) async {
    final data = await client.rpc('bank_reconciliation_status', params: {
      'p_bank_account_id': bankAccountId,
      'p_as_at': Fmt.iso(asAt),
      'p_statement_balance': statementBalance,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  Future<String> completeBankReconciliation({
    required String bankAccountId,
    required DateTime statementDate,
    required double statementBalance,
  }) async {
    final data = await client.rpc('complete_bank_reconciliation', params: {
      'p_bank_account_id': bankAccountId,
      'p_statement_date': Fmt.iso(statementDate),
      'p_statement_balance': statementBalance,
    });
    return data as String;
  }

  // ------------------------------------------------------------------
  // Fixed assets
  // ------------------------------------------------------------------
  Future<List<FixedAsset>> fixedAssets({bool includeDisposed = false}) async {
    var q = client
        .from('fixed_assets')
        .select()
        .eq('org_id', orgId)
        .isFilter('deleted_at', null);
    if (!includeDisposed) q = q.neq('status', 'disposed');
    final data = await q.order('asset_no');
    return _rows(data).map(FixedAsset.fromJson).toList();
  }

  Future<FixedAsset> saveFixedAsset(FixedAsset asset, {String? id}) async {
    final payload = asset.toJson()..['org_id'] = orgId;
    final data = id == null
        ? await client.from('fixed_assets').insert(payload).select().single()
        : await client
            .from('fixed_assets')
            .update(payload)
            .eq('id', id)
            .select()
            .single();
    return FixedAsset.fromJson(data);
  }

  /// What a run would charge, per asset, before anything is posted.
  Future<List<DepreciationLine>> depreciationPreview(DateTime asAt) async {
    final data = await client.rpc('depreciation_preview', params: {
      'p_org_id': orgId,
      'p_as_at': Fmt.iso(asAt),
    });
    return _rows(data).map(DepreciationLine.fromJson).toList();
  }

  /// Posts the charge. Null when every asset is already up to date —
  /// which is what running it twice looks like.
  Future<String?> runDepreciation(DateTime asAt) async {
    final data = await client.rpc('run_depreciation', params: {
      'p_org_id': orgId,
      'p_as_at': Fmt.iso(asAt),
    });
    return data as String?;
  }

  /// Takes the asset off the books and recognises the gain or loss,
  /// after bringing its depreciation up to the disposal date.
  Future<String> disposeFixedAsset({
    required String assetId,
    required DateTime on,
    double proceeds = 0,
    String? bankAccountId,
  }) async {
    final data = await client.rpc('dispose_fixed_asset', params: {
      'p_asset_id': assetId,
      'p_date': Fmt.iso(on),
      'p_proceeds': proceeds,
      if (bankAccountId != null) 'p_bank_account_id': bankAccountId,
    });
    return data as String;
  }

  /// What the open foreign balances would be restated to, one row per
  /// currency. Raises if a currency has no rate on file at that date,
  /// rather than reporting a confident zero for one it cannot price.
  Future<List<FxRevaluation>> fxRevaluationPreview(DateTime asAt) async {
    final data = await client.rpc('fx_revaluation_preview', params: {
      'p_org_id': orgId,
      'p_as_at': Fmt.iso(asAt),
    });
    return _rows(data).map(FxRevaluation.fromJson).toList();
  }

  /// Posts the restatement, returning the journal id — or null when
  /// there was nothing to restate.
  Future<String?> revalueForeignBalances(DateTime asAt) async {
    final data = await client.rpc('revalue_foreign_balances', params: {
      'p_org_id': orgId,
      'p_as_at': Fmt.iso(asAt),
    });
    return data as String?;
  }

  /// Records a rate so the next document does not have to be told again.
  ///
  /// Upserted on the natural key, because two rates for one pair on one
  /// day is not a history — it is a tie the resolver would break by
  /// insertion order, which is no answer at all.
  Future<void> saveExchangeRate({
    required String from,
    required String to,
    required double rate,
    required DateTime date,
  }) =>
      client.from('exchange_rates').upsert({
        'org_id': orgId,
        'from_currency': from,
        'to_currency': to,
        'rate': rate,
        'rate_date': Fmt.iso(date),
        'source': 'manual',
      }, onConflict: 'org_id,from_currency,to_currency,rate_date');

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

  /// What is still available to take forward from this document into a
  /// [targetType], line by line.
  Future<List<TransferLine>> transferOutstanding(
    String documentId,
    String targetType,
  ) async {
    final data = await client.rpc('transfer_outstanding', params: {
      'p_source_id': documentId,
      'p_target_type': targetType,
    });
    return _rows(data).map(TransferLine.fromJson).toList();
  }

  /// Creates the next document in the cycle and returns its id.
  ///
  /// Omit [lines] to take everything outstanding. The database decides
  /// what is permitted and how much remains — this only carries the
  /// request — so a stale screen is refused rather than acted on.
  Future<String> transferDocument({
    required String sourceId,
    required String targetType,
    List<({String lineId, double quantity})>? lines,
  }) async {
    final data = await client.rpc('transfer_document', params: {
      'p_source_id': sourceId,
      'p_target_type': targetType,
      if (lines != null)
        'p_lines': [
          for (final l in lines)
            {'line_id': l.lineId, 'quantity': l.quantity},
        ],
    });
    return data as String;
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
    String currency = 'MYR',
    double exchangeRate = 1,
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
          // Both are in the currency of the documents being settled;
          // post_receipt multiplies them by the rate. A receipt in a
          // currency other than its invoices is refused by
          // app.realised_fx_on_settlement, so the dialog never sends one.
          'currency': currency,
          'exchange_rate': exchangeRate,
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
    // No bare `contacts(...)` here. An expense points at contacts twice —
    // contact_id for whoever was paid, billed_to_id for the client it is
    // rebilled to — so PostgREST cannot guess which one is meant and
    // refuses the whole request with PGRST201 rather than choosing. The
    // screen never read the name anyway. If it should show the payee, ask
    // for it by constraint: `contacts!expenses_contact_id_fkey(name)`.
    final data = await client
        .from('expenses')
        .select('*, accounts(code, name)')
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

  /// The same shaping, reachable from extensions in other files. Dart
  /// extensions cannot see a private member across a file boundary, and
  /// duplicating the cast is how two of them end up disagreeing about
  /// what PostgREST returns.
  static List<Map<String, dynamic>> rows(dynamic data) => _rows(data);
}

/// The company's own mark, for the top of everything it sends out.
extension RepoOrgLogo on Repo {
  /// One object per company at a fixed path, replaced in place.
  ///
  /// Fixed rather than timestamped so the bucket does not accumulate
  /// every logo a company has ever had, and because the storage policy
  /// keys off the first path segment: `<org>/logo` is what makes this
  /// company's mark unwritable by anyone else.
  String get _logoPath => '$orgId/logo';

  Future<String> uploadOrgLogo(Uint8List bytes, String contentType) async {
    await client.storage.from('logos').uploadBinary(
          _logoPath,
          bytes,
          fileOptions: FileOptions(upsert: true, contentType: contentType),
        );

    // The path never changes, so a browser that has seen the old logo
    // would keep showing it. The version parameter is only for display —
    // the PDF reads the bytes straight from storage and never sees it.
    final url = client.storage.from('logos').getPublicUrl(_logoPath);
    final versioned = '$url?v=${DateTime.now().millisecondsSinceEpoch}';
    await client
        .from('organizations')
        .update({'logo_url': versioned}).eq('id', orgId);
    return versioned;
  }

  Future<void> removeOrgLogo() async {
    await client.storage.from('logos').remove([_logoPath]);
    await client.from('organizations').update({'logo_url': null}).eq('id', orgId);
  }

  /// The raw bytes, for embedding in a PDF.
  ///
  /// Returns null rather than throwing when there is no logo, or when the
  /// object has gone missing behind a stale `logo_url`: a company without
  /// a mark still has to be able to print an invoice.
  Future<Uint8List?> orgLogoBytes() async {
    try {
      return await client.storage.from('logos').download(_logoPath);
    } catch (_) {
      return null;
    }
  }

  /// Whether the generated PDFs should leave room for a header already
  /// printed on the paper. RLS lets only an administrator through, which
  /// is the same bar as replacing the logo.
  Future<void> setPreprintedLetterhead(bool value) => client
      .from('organizations')
      .update({'uses_preprinted_letterhead': value}).eq('id', orgId);
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

/// HRMS data access. Kept in its own extension so the HR surface can be
/// read as one piece rather than scattered through the finance methods.
extension RepoHr on Repo {
  // ------------------------------------------------------------------
  // People
  // ------------------------------------------------------------------

  /// The whole company, name and role only. Backed by a function so the
  /// pay columns on the employee row never travel to the client.
  Future<List<Employee>> directory() async {
    final data = await client.rpc('employee_directory', params: {'p_org_id': orgId});
    return Repo._rows(data).map(Employee.fromJson).toList();
  }

  /// Full employee records, which RLS narrows to what the caller may see:
  /// everyone for HR, your reporting line for a manager, yourself
  /// otherwise.
  Future<List<Employee>> employees({String? search, String? status}) async {
    var q = client
        .from('employees')
        // `departments!` names the relationship explicitly. An employee
        // belongs to a department and a department has a head employee,
        // so PostgREST sees two ways to join the two tables and refuses
        // the request rather than guessing. The JSON key stays
        // `departments`, so nothing downstream changes.
        .select('*, departments!employees_department_id_fkey(name), positions(title)')
        .eq('org_id', orgId);
    if (status != null && status != 'all') q = q.eq('employment_status', status);
    if (search != null && search.trim().isNotEmpty) {
      final s = '%${search.trim()}%';
      q = q.or('full_name.ilike.$s,employee_no.ilike.$s');
    }
    return Repo._rows(await q.order('employee_no')).map(Employee.fromJson).toList();
  }

  Future<Employee?> employee(String id) async {
    final row = await client
        .from('employees')
        // `departments!` names the relationship explicitly. An employee
        // belongs to a department and a department has a head employee,
        // so PostgREST sees two ways to join the two tables and refuses
        // the request rather than guessing. The JSON key stays
        // `departments`, so nothing downstream changes.
        .select('*, departments!employees_department_id_fkey(name), positions(title)')
        .eq('id', id)
        .maybeSingle();
    return row == null ? null : Employee.fromJson(Map<String, dynamic>.from(row));
  }

  /// The caller's own employee record, or null when their login is not
  /// linked to one.
  Future<Employee?> myEmployee() async {
    final uid = client.auth.currentUser?.id;
    if (uid == null) return null;
    final row = await client
        .from('employees')
        // `departments!` names the relationship explicitly. An employee
        // belongs to a department and a department has a head employee,
        // so PostgREST sees two ways to join the two tables and refuses
        // the request rather than guessing. The JSON key stays
        // `departments`, so nothing downstream changes.
        .select('*, departments!employees_department_id_fkey(name), positions(title)')
        .eq('org_id', orgId)
        .eq('user_id', uid)
        .maybeSingle();
    return row == null ? null : Employee.fromJson(Map<String, dynamic>.from(row));
  }

  Future<String> saveEmployee(Map<String, dynamic> values, {String? id}) async {
    if (id != null) {
      await client.from('employees').update(values).eq('id', id);
      return id;
    }
    final no = await client
        .rpc('next_document_number', params: {'p_org_id': orgId, 'p_doc_type': 'employee'});
    final row = await client
        .from('employees')
        .insert({...values, 'org_id': orgId, 'employee_no': no})
        .select('id')
        .single();
    return row['id'] as String;
  }

  // ------------------------------------------------------------------
  // The tax year an employee brings with them
  //
  // PCB projects the year, so what was already earned and deducted
  // elsewhere has to be known or the projection is a fraction of the
  // truth. All of this is read by app.calc_pcb.
  // ------------------------------------------------------------------
  Future<YtdOpening?> ytdOpening(String employeeId, int taxYear) async {
    final row = await client
        .from('employee_ytd_opening')
        .select()
        .eq('employee_id', employeeId)
        .eq('tax_year', taxYear)
        .maybeSingle();
    return row == null
        ? null
        : YtdOpening.fromJson(Map<String, dynamic>.from(row));
  }

  Future<void> saveYtdOpening(String employeeId, YtdOpening opening) =>
      client.from('employee_ytd_opening').upsert({
        'org_id': orgId,
        'employee_id': employeeId,
        'tax_year': opening.taxYear,
        'gross_pay': opening.grossPay,
        'epf_employee': opening.epfEmployee,
        'pcb_paid': opening.pcbPaid,
        'zakat_paid': opening.zakatPaid,
        'benefits_in_kind': opening.benefitsInKind,
        'notes': opening.notes,
      }, onConflict: 'employee_id,tax_year');

  Future<List<DeclaredRelief>> declaredReliefs(
          String employeeId, int taxYear) async =>
      Repo._rows(await client
              .from('employee_tax_reliefs')
              .select()
              .eq('employee_id', employeeId)
              .eq('tax_year', taxYear)
              .order('relief_code'))
          .map(DeclaredRelief.fromJson)
          .toList();

  /// The reliefs an employee may declare — everything the company cannot
  /// work out for itself from the record it already holds.
  Future<List<ReliefType>> reliefTypes(DateTime on) async {
    final schedule = await client
        .from('statutory_schedules')
        .select('id')
        .eq('schedule_type', 'pcb')
        .lte('effective_from', Fmt.iso(on))
        .order('effective_from', ascending: false)
        .limit(1)
        .maybeSingle();
    if (schedule == null) return const [];
    return Repo._rows(await client
            .from('tax_reliefs')
            .select('code, name, max_amount')
            .eq('schedule_id', schedule['id'] as String)
            .eq('applies_to', 'manual')
            .order('sort_order'))
        .map(ReliefType.fromJson)
        .toList();
  }

  Future<void> saveDeclaredRelief(String employeeId, DeclaredRelief relief) =>
      client.from('employee_tax_reliefs').upsert({
        'org_id': orgId,
        'employee_id': employeeId,
        'tax_year': relief.taxYear,
        'relief_code': relief.reliefCode,
        'amount': relief.amount,
        'notes': relief.notes,
      }, onConflict: 'employee_id,tax_year,relief_code');

  Future<void> deleteDeclaredRelief(String id) =>
      client.from('employee_tax_reliefs').delete().eq('id', id);

  Future<List<Map<String, dynamic>>> departments() async => Repo._rows(
      await client.from('departments').select().eq('org_id', orgId).order('name'));

  Future<List<Map<String, dynamic>>> positions() async => Repo._rows(
      await client.from('positions').select().eq('org_id', orgId).order('title'));

  // ------------------------------------------------------------------
  // Attendance
  // ------------------------------------------------------------------
  Future<List<AttendanceRecord>> attendance({
    String? employeeId,
    DateTime? from,
    DateTime? to,
  }) async {
    var q = client
        .from('attendance_records')
        .select('*, employees(full_name)')
        .eq('org_id', orgId);
    if (employeeId != null) q = q.eq('employee_id', employeeId);
    if (from != null) q = q.gte('work_date', Fmt.iso(from));
    if (to != null) q = q.lte('work_date', Fmt.iso(to));
    return Repo._rows(await q.order('work_date', ascending: false).limit(200))
        .map(AttendanceRecord.fromJson)
        .toList();
  }

  Future<void> clockIn({double? lat, double? lng, String? address}) =>
      client.rpc('clock_in', params: {
        'p_org_id': orgId,
        'p_method': lat == null ? 'web' : 'mobile_gps',
        if (lat != null) 'p_lat': lat,
        if (lng != null) 'p_lng': lng,
        if (address != null) 'p_address': address,
      });

  Future<Map<String, dynamic>> clockOut({double? lat, double? lng}) async {
    final data = await client.rpc('clock_out', params: {
      'p_org_id': orgId,
      'p_method': lat == null ? 'web' : 'mobile_gps',
      if (lat != null) 'p_lat': lat,
      if (lng != null) 'p_lng': lng,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  // ------------------------------------------------------------------
  // Leave
  // ------------------------------------------------------------------
  Future<List<LeaveType>> leaveTypes() async => Repo._rows(await client
          .from('leave_types')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('sort_order'))
      .map(LeaveType.fromJson)
      .toList();

  Future<List<LeaveBalance>> leaveBalances(String employeeId, int year) async =>
      Repo._rows(await client
              .from('leave_balances')
              .select('*, leave_types(name)')
              .eq('employee_id', employeeId)
              .eq('leave_year', year))
          .map(LeaveBalance.fromJson)
          .toList();

  Future<List<LeaveRequest>> leaveRequests({String? status, String? employeeId}) async {
    var q = client
        .from('leave_requests')
        .select('*, employees(full_name), leave_types(name)')
        .eq('org_id', orgId);
    if (status != null && status != 'all') q = q.eq('status', status);
    if (employeeId != null) q = q.eq('employee_id', employeeId);
    return Repo._rows(await q.order('start_date', ascending: false).limit(200))
        .map(LeaveRequest.fromJson)
        .toList();
  }

  Future<void> submitLeave({
    required String leaveTypeId,
    required DateTime start,
    required DateTime end,
    required double days,
    String? reason,
  }) =>
      client.rpc('submit_leave_request', params: {
        'p_org_id': orgId,
        'p_leave_type_id': leaveTypeId,
        'p_start_date': Fmt.iso(start),
        'p_end_date': Fmt.iso(end),
        'p_total_days': days,
        if (reason != null) 'p_reason': reason,
      });

  Future<void> decideLeave(String id, bool approve, {String? note}) =>
      client.rpc('decide_leave_request', params: {
        'p_request_id': id,
        'p_approve': approve,
        if (note != null) 'p_note': note,
      });

  // ------------------------------------------------------------------
  // Claims
  // ------------------------------------------------------------------
  Future<List<ExpenseClaim>> claims({String? status, String? employeeId}) async {
    var q = client
        .from('expense_claims')
        .select('*, employees(full_name)')
        .eq('org_id', orgId);
    if (status != null && status != 'all') q = q.eq('status', status);
    if (employeeId != null) q = q.eq('employee_id', employeeId);
    return Repo._rows(await q.order('claim_date', ascending: false).limit(200))
        .map(ExpenseClaim.fromJson)
        .toList();
  }

  Future<void> decideClaim(String id, bool approve,
          {String? note, double? approvedAmount}) =>
      client.rpc('decide_expense_claim', params: {
        'p_claim_id': id,
        'p_approve': approve,
        if (note != null) 'p_note': note,
        if (approvedAmount != null) 'p_approved_amount': approvedAmount,
      });

  Future<List<Map<String, dynamic>>> claimTypes() async => Repo._rows(await client
      .from('claim_types')
      .select()
      .eq('org_id', orgId)
      .eq('is_active', true)
      .order('sort_order'));

  Future<String> createClaim({
    required String employeeId,
    required String title,
    required List<Map<String, dynamic>> lines,
  }) async {
    final no = await client.rpc('next_document_number',
        params: {'p_org_id': orgId, 'p_doc_type': 'expense_claim'});
    final total = lines.fold<double>(
        0, (sum, l) => sum + Fmt.toDouble(l['amount']));
    final row = await client
        .from('expense_claims')
        .insert({
          'org_id': orgId,
          'claim_no': no,
          'employee_id': employeeId,
          'title': title,
          'total_amount': total,
          'status': 'submitted',
          'submitted_at': DateTime.now().toIso8601String(),
        })
        .select('id')
        .single();
    final id = row['id'] as String;
    await client.from('expense_claim_lines').insert([
      for (var i = 0; i < lines.length; i++)
        {...lines[i], 'org_id': orgId, 'claim_id': id, 'line_no': i + 1}
    ]);
    return id;
  }

  // ------------------------------------------------------------------
  // Payroll
  // ------------------------------------------------------------------
  Future<List<PayrollRun>> payrollRuns() async => Repo._rows(await client
          .from('payroll_runs')
          .select('*, pay_periods(code, pay_date)')
          .eq('org_id', orgId)
          .order('created_at', ascending: false))
      .map(PayrollRun.fromJson)
      .toList();

  Future<List<Payslip>> payslips({String? runId, String? employeeId}) async {
    var q = client
        .from('payslips')
        .select('*, payroll_runs(run_no, pay_periods(code))')
        .eq('org_id', orgId);
    if (runId != null) q = q.eq('run_id', runId);
    if (employeeId != null) q = q.eq('employee_id', employeeId);
    return Repo._rows(await q.order('employee_no'))
        .map(Payslip.fromJson)
        .toList();
  }

  Future<Payslip?> payslip(String id) async {
    final row = await client
        .from('payslips')
        .select('*, payslip_lines(*), payroll_runs(run_no, pay_periods(code))')
        .eq('id', id)
        .maybeSingle();
    return row == null ? null : Payslip.fromJson(Map<String, dynamic>.from(row));
  }

  /// Creates the period if it does not exist, then a run against it.
  Future<String> startPayrollRun(int year, int month) async {
    final periodId = await client.rpc('ensure_pay_period',
        params: {'p_org_id': orgId, 'p_year': year, 'p_month': month});
    final runId = await client.rpc('create_payroll_run', params: {
      'p_org_id': orgId,
      'p_period_id': periodId,
      'p_description': '${Fmt.monthName(month)} $year payroll',
    });
    return runId as String;
  }

  Future<void> calculatePayroll(String runId) =>
      client.rpc('calculate_payroll_run', params: {'p_run_id': runId});

  Future<void> postPayroll(String runId) =>
      client.rpc('post_payroll_run', params: {'p_run_id': runId});

  /// The bank instruction for a posted run. Lines that cannot be paid
  /// come back flagged rather than missing.
  Future<List<PaymentLine>> paymentInstruction(String runId) async {
    final data = await client
        .rpc('payroll_payment_instruction', params: {'p_run_id': runId});
    return Repo._rows(data).map(PaymentLine.fromJson).toList();
  }

  /// Records that the bank took the file. Separate from producing it,
  /// because only a person can know whether the transfer actually went.
  Future<void> markPayrollPaid(String runId) =>
      client.rpc('mark_payroll_paid', params: {'p_run_id': runId});

  // ------------------------------------------------------------------
  // Talent
  // ------------------------------------------------------------------
  Future<List<JobRequisition>> requisitions() async => Repo._rows(await client
          .from('job_requisitions')
          .select('*, departments(name), applicants(count)')
          .eq('org_id', orgId)
          .order('created_at', ascending: false))
      .map(JobRequisition.fromJson)
      .toList();

  Future<List<Applicant>> applicants({String? requisitionId}) async {
    var q = client
        .from('applicants')
        .select('*, job_requisitions(title)')
        .eq('org_id', orgId);
    if (requisitionId != null) q = q.eq('requisition_id', requisitionId);
    return Repo._rows(await q.order('applied_at', ascending: false))
        .map(Applicant.fromJson)
        .toList();
  }

  /// Moves an applicant along and keeps the move as history, so
  /// time-to-hire can be measured later.
  Future<void> moveApplicant(String id, String from, String to) async {
    await client.from('applicants').update({'status': to}).eq('id', id);
    await client.from('applicant_stage_history').insert({
      'org_id': orgId,
      'applicant_id': id,
      'from_status': from,
      'to_status': to,
    });
  }

  Future<List<Appraisal>> appraisals() async => Repo._rows(await client
          .from('appraisals')
          .select('*, employees!appraisals_employee_id_fkey(full_name), '
              'appraisal_cycles(name)')
          .eq('org_id', orgId)
          .order('created_at', ascending: false))
      .map(Appraisal.fromJson)
      .toList();
}

/// Auditor access to payslips: requested, approved by a company admin,
/// and time-boxed so it lapses without anyone having to remember.
extension RepoPayslipAccess on Repo {
  Future<bool> myPayslipAccess() async {
    final data =
        await client.rpc('my_payslip_access', params: {'p_org_id': orgId});
    return data == true;
  }

  Future<List<PayslipAccessRequest>> payslipAccessRequests() async {
    final rows = await client
        .from('payslip_access_requests')
        .select('*, requester:profiles!payslip_access_requests_requested_by_fkey'
            '(full_name, email), '
            'decider:profiles!payslip_access_requests_decided_by_fkey'
            '(full_name, email)')
        .eq('org_id', orgId)
        .order('requested_at', ascending: false);
    return Repo._rows(rows).map(PayslipAccessRequest.fromJson).toList();
  }

  Future<void> requestPayslipAccess({
    required String reason,
    DateTime? from,
    DateTime? to,
  }) =>
      client.rpc('request_payslip_access', params: {
        'p_org_id': orgId,
        'p_reason': reason,
        if (from != null) 'p_period_from': Fmt.iso(from),
        if (to != null) 'p_period_to': Fmt.iso(to),
      });

  Future<void> decidePayslipAccess(String id, bool approve,
          {String? note, int days = 30}) =>
      client.rpc('decide_payslip_access', params: {
        'p_request_id': id,
        'p_approve': approve,
        if (note != null) 'p_note': note,
        'p_days': days,
      });

  Future<void> revokePayslipAccess(String id, {String? note}) =>
      client.rpc('revoke_payslip_access',
          params: {'p_request_id': id, if (note != null) 'p_note': note});

  /// Payslips a granted reader may see. Goes through a function rather
  /// than the table because the function writes the read into the log —
  /// there is no unlogged way in.
  Future<List<Payslip>> auditPayslips({String? runId}) async {
    final data = await client.rpc('audit_list_payslips', params: {
      'p_org_id': orgId,
      if (runId != null) 'p_run_id': runId,
    });
    return (data as List)
        .map((e) => Payslip.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<Payslip?> auditPayslip(String id) async {
    final data =
        await client.rpc('audit_view_payslip', params: {'p_payslip_id': id});
    return data == null
        ? null
        : Payslip.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Who has opened which payslip, and under whose grant.
  Future<List<PayslipAccessLogEntry>> payslipAccessLog({int limit = 100}) async {
    final rows = await client
        .from('payslip_access_log')
        .select('*, actor:profiles!payslip_access_log_actor_id_fkey'
            '(full_name, email)')
        .eq('org_id', orgId)
        .order('viewed_at', ascending: false)
        .limit(limit);
    return Repo._rows(rows).map(PayslipAccessLogEntry.fromJson).toList();
  }

  /// Who changed what. The function refuses anyone who is not an owner
  /// or admin, because the diffs carry salaries and bank details.
  Future<List<AuditEntry>> auditTrail({
    String? table,
    String? recordId,
    int limit = 100,
  }) async {
    final rows = await client.rpc('audit_trail', params: {
      'p_org_id': orgId,
      'p_table': table,
      'p_record_id': recordId,
      'p_limit': limit,
    });
    return Repo._rows(rows).map(AuditEntry.fromJson).toList();
  }
}

/// HR configuration. Every one of these was SQL-only, which meant a new
/// tenant could not set itself up.
extension RepoHrSetup on Repo {
  Future<Map<String, dynamic>?> payrollSettings() async {
    final row = await client
        .from('payroll_settings')
        .select()
        .eq('org_id', orgId)
        .maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  Future<void> savePayrollSettings(Map<String, dynamic> values) =>
      client.from('payroll_settings').upsert({...values, 'org_id': orgId});

  /// One save path for every simple configuration list, since they all
  /// behave the same way: insert when new, update when not.
  Future<void> saveSetupRow(
    String table,
    Map<String, dynamic> values, {
    String? id,
  }) async {
    if (id != null) {
      await client.from(table).update(values).eq('id', id);
    } else {
      await client.from(table).insert({...values, 'org_id': orgId});
    }
  }

  Future<List<Map<String, dynamic>>> setupRows(String table,
          {String orderBy = 'name'}) async =>
      Repo._rows(
          await client.from(table).select().eq('org_id', orgId).order(orderBy));
}
