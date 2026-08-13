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

  /// The same P&L, restricted to one project or department. Passing
  /// neither gives the whole company, so this can serve both.
  Future<List<Map<String, dynamic>>> profitLossByDimension({
    required DateTime from,
    required DateTime to,
    String? projectCode,
    String? departmentCode,
  }) async {
    final data = await client.rpc('report_profit_loss_by_dimension', params: {
      'p_org_id': orgId,
      'p_from': Fmt.iso(from),
      'p_to': Fmt.iso(to),
      if (projectCode != null) 'p_project_code': projectCode,
      if (departmentCode != null) 'p_department_code': departmentCode,
    });
    return _rows(data);
  }

  /// Which project and department codes actually appear in the ledger.
  Future<List<Map<String, dynamic>>> ledgerDimensions() async =>
      _rows(await client.rpc('ledger_dimensions', params: {'p_org_id': orgId}));

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

  /// The aged listing of one side of the subledger, as at a date.
  ///
  /// Not the same question as "what is still open today": with an as-at
  /// date the balance is rebuilt from the settlements that had happened
  /// by then, so a March listing run in June still shows the invoices
  /// that were paid in April. Passing no date asks about today, which is
  /// what the dashboard wants.
  Future<List<Map<String, dynamic>>> agedBalances({
    required bool receivable,
    DateTime? asAt,
  }) async {
    final data = await client.rpc(
      receivable ? 'report_ar_aging' : 'report_ap_aging',
      params: {
        'p_org_id': orgId,
        if (asAt != null) 'p_as_at': Fmt.iso(asAt),
      },
    );
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

  /// A journal somebody wrote by hand.
  ///
  /// Everything else in this system reaches the ledger behind a
  /// document; this is the one entry that is its own document.
  ///
  /// Not `create_gl_entry`, which takes the journal's source as an
  /// argument — the client has no business asserting where a ledger
  /// entry came from. `post_manual_journal` fixes the source and checks
  /// the accounts, the balance and the period, so nothing here is
  /// trusted.
  Future<String> createJournal({
    required DateTime date,
    required String description,
    String? reference,
    required List<Map<String, dynamic>> lines,
  }) async {
    final data = await client.rpc('post_manual_journal', params: {
      'p_org_id': orgId,
      'p_entry_date': Fmt.iso(date),
      'p_lines': lines,
      'p_description': description,
      if (reference != null && reference.trim().isNotEmpty)
        'p_reference': reference.trim(),
    });
    return data as String;
  }

  /// Puts an approved claim into the ledger. With a bank account it is
  /// reimbursed straight away; without one it sits in accruals until it
  /// is paid.
  Future<String> postExpenseClaim(String claimId, {String? bankAccountId}) async {
    final data = await client.rpc('post_expense_claim', params: {
      'p_claim_id': claimId,
      if (bankAccountId != null) 'p_bank_account_id': bankAccountId,
    });
    return data as String;
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
  // Recurring journals
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> recurringJournals() async =>
      _rows(await client
          .from('recurring_journals')
          .select()
          .eq('org_id', orgId)
          .order('name'));

  Future<void> saveRecurringJournal({
    String? id,
    required String name,
    required String frequency,
    required int intervalCount,
    required DateTime nextRun,
    required bool autoPost,
    required bool isActive,
    required List<Map<String, dynamic>> lines,
  }) async {
    final payload = {
      'org_id': orgId,
      'name': name,
      'frequency': frequency,
      'interval_count': intervalCount,
      'start_date': Fmt.iso(nextRun),
      'next_run_date': Fmt.iso(nextRun),
      'auto_post': autoPost,
      'is_active': isActive,
      'template': {'lines': lines},
      // Clearing the last failure on save: whatever it was, the template
      // has just been edited and the old message describes a version
      // that no longer exists.
      'last_error': null,
      'last_error_at': null,
    };

    if (id == null) {
      await client.from('recurring_journals').insert(payload);
    } else {
      await client.from('recurring_journals').update(payload).eq('id', id);
    }
  }

  /// Runs anything due for this organization now, rather than waiting
  /// for the nightly job. Returns how many ran.
  Future<int> runRecurringJournals({DateTime? on}) async {
    final data = await client.rpc('run_recurring_journals_for', params: {
      'p_org_id': orgId,
      if (on != null) 'p_on': Fmt.iso(on),
    });
    return (data as num?)?.toInt() ?? 0;
  }

  // ------------------------------------------------------------------
  // Recurring invoices and bills
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> recurringDocuments() async =>
      _rows(await client
          .from('recurring_documents')
          .select()
          .eq('org_id', orgId)
          .order('is_active', ascending: false)
          .order('next_run_date'));

  /// Copies a posted invoice or bill into a schedule. The document is
  /// snapshotted, not pointed at: editing it afterwards does not change
  /// what gets billed next month.
  Future<String> createRecurringDocument({
    required String documentId,
    required String name,
    required String frequency,
    required DateTime startDate,
    int intervalCount = 1,
    DateTime? endDate,
    int? maxOccurrences,
    bool autoPost = false,
    bool autoEmail = false,
  }) async {
    final data = await client.rpc('create_recurring_document', params: {
      'p_document_id': documentId,
      'p_name': name,
      'p_frequency': frequency,
      'p_start_date': Fmt.iso(startDate),
      'p_interval_count': intervalCount,
      if (endDate != null) 'p_end_date': Fmt.iso(endDate),
      if (maxOccurrences != null) 'p_max_occurrences': maxOccurrences,
      'p_auto_post': autoPost,
      'p_auto_email': autoEmail,
    });
    return data as String;
  }

  /// Re-snapshots the schedule from another document — last month's
  /// invoice with the new price on it.
  Future<void> updateRecurringTemplate({
    required String id,
    required String documentId,
  }) async {
    await client.rpc('update_recurring_template',
        params: {'p_id': id, 'p_document_id': documentId});
  }

  Future<void> saveRecurringDocument(
      String id, Map<String, dynamic> patch) async {
    await client.from('recurring_documents').update(patch).eq('id', id);
  }

  Future<void> deleteRecurringDocument(String id) async {
    await client.from('recurring_documents').delete().eq('id', id);
  }

  /// Raises whatever is due now rather than waiting for the nightly
  /// job. Returns how many documents it made.
  Future<int> runRecurringDocuments({DateTime? on}) async {
    final data = await client.rpc('run_recurring_documents_for', params: {
      'p_org_id': orgId,
      if (on != null) 'p_on': Fmt.iso(on),
    });
    return (data as num?)?.toInt() ?? 0;
  }

  // ------------------------------------------------------------------
  // Getting a customer or item list in
  // ------------------------------------------------------------------

  /// Validates every row and, when [commit] is true, writes them —
  /// which the database only does if none of them are wrong. Returns a
  /// verdict per row either way, so a preview and an import cannot
  /// disagree about what is acceptable.
  Future<List<Map<String, dynamic>>> importRows({
    required bool contacts,
    required List<Map<String, String>> rows,
    required bool commit,
  }) async {
    final data = await client.rpc(
      contacts ? 'import_contacts' : 'import_items',
      params: {'p_org_id': orgId, 'p_rows': rows, 'p_commit': commit},
    );
    return _rows(data);
  }

  // ------------------------------------------------------------------
  // Moving money between the company's own accounts
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> bankTransfers() async => _rows(await client
      .from('bank_transfers')
      .select('*, from_account:bank_accounts!bank_transfers_from_account_id_fkey(name), '
          'to_account:bank_accounts!bank_transfers_to_account_id_fkey(name)')
      .eq('org_id', orgId)
      .order('transfer_date', ascending: false)
      .limit(200));

  /// Records the transfer and posts it in one go. A draft transfer helps
  /// nobody: the money has either moved or it has not.
  Future<String> transferBetweenBanks({
    required String fromAccountId,
    required String toAccountId,
    required double amountSent,
    required DateTime date,
    double? amountReceived,
    double bankCharges = 0,
    String? reference,
    String? notes,
  }) async {
    final id = await client.rpc('create_bank_transfer', params: {
      'p_from_account_id': fromAccountId,
      'p_to_account_id': toAccountId,
      'p_amount_sent': amountSent,
      'p_transfer_date': Fmt.iso(date),
      if (amountReceived != null) 'p_amount_received': amountReceived,
      'p_bank_charges': bankCharges,
      if (reference != null) 'p_reference': reference,
      if (notes != null) 'p_notes': notes,
    }) as String;
    await client.rpc('post_bank_transfer', params: {'p_id': id});
    return id;
  }

  Future<void> voidBankTransfer(String id, String reason) async {
    await client
        .rpc('void_bank_transfer', params: {'p_id': id, 'p_reason': reason});
  }

  // ------------------------------------------------------------------
  // The rest of a complete set of financial statements
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> cashFlow({
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await client.rpc('report_cash_flow', params: {
      'p_org_id': orgId,
      'p_from': Fmt.iso(from),
      'p_to': Fmt.iso(to),
    });
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> changesInEquity({
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await client.rpc('report_changes_in_equity', params: {
      'p_org_id': orgId,
      'p_from': Fmt.iso(from),
      'p_to': Fmt.iso(to),
    });
    return _rows(data);
  }

  // ------------------------------------------------------------------
  // Withholding tax
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> withholdingTypes() async => _rows(
      await client
          .from('ref_withholding_types')
          .select()
          .eq('is_active', true)
          .order('sort_order'));

  /// The CP37 listing: what was deducted, on which form, and by when it
  /// has to reach LHDN.
  Future<List<Map<String, dynamic>>> withholdingReport({
    DateTime? from,
    DateTime? to,
  }) async {
    final data = await client.rpc('report_withholding', params: {
      'p_org_id': orgId,
      if (from != null) 'p_from': Fmt.iso(from),
      if (to != null) 'p_to': Fmt.iso(to),
    });
    return _rows(data);
  }

  Future<String> createWithholding({
    required String billId,
    required String whtCode,
    double? grossAmount,
    double? rate,
    DateTime? certDate,
  }) async {
    final data = await client.rpc('create_withholding', params: {
      'p_bill_id': billId,
      'p_wht_code': whtCode,
      if (grossAmount != null) 'p_gross_amount': grossAmount,
      if (rate != null) 'p_rate': rate,
      if (certDate != null) 'p_cert_date': Fmt.iso(certDate),
    });
    return data as String;
  }

  Future<void> postWithholding(String id) async {
    await client.rpc('post_withholding', params: {'p_id': id});
  }

  Future<void> remitWithholding({
    required String id,
    required DateTime paidOn,
    String? bankAccountId,
    String? reference,
  }) async {
    await client.rpc('remit_withholding', params: {
      'p_id': id,
      'p_paid_on': Fmt.iso(paidOn),
      if (bankAccountId != null) 'p_bank_account_id': bankAccountId,
      if (reference != null) 'p_reference': reference,
    });
  }

  /// What this customer pays for this item at this quantity: a price
  /// named for their level, a level-wide percentage, or the list price.
  Future<double> itemPrice({
    required String itemId,
    String? contactId,
    double quantity = 1,
  }) async {
    final data = await client.rpc('item_price', params: {
      'p_item_id': itemId,
      if (contactId != null) 'p_contact_id': contactId,
      'p_quantity': quantity,
    });
    return Fmt.toDouble(data);
  }

  Future<List<Map<String, dynamic>>> priceLevels() async => _rows(await client
      .from('price_levels')
      .select()
      .eq('org_id', orgId)
      .eq('is_active', true)
      .order('code'));

  Future<List<Map<String, dynamic>>> projects() async => _rows(await client
      .from('projects')
      .select()
      .eq('org_id', orgId)
      .eq('is_active', true)
      .order('code'));

  // ------------------------------------------------------------------
  // Stock
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> warehouses() async => _rows(await client
      .from('warehouses')
      .select()
      .eq('org_id', orgId)
      .eq('is_active', true)
      .order('code'));

  /// The warehouse a new adjustment is filed against, created if the
  /// organization has none — `warehouses` being empty is not a state the
  /// client can do anything about on its own.
  Future<String> ensureDefaultWarehouse() async {
    final data = await client
        .rpc('ensure_default_warehouse', params: {'p_org_id': orgId});
    return data as String;
  }

  /// What the books think is on the shelf, which is what a stock take
  /// sheet opens on.
  Future<List<Map<String, dynamic>>> stockOnHand({String? warehouseId}) async =>
      _rows(await client.rpc('stock_on_hand', params: {
        'p_org_id': orgId,
        if (warehouseId != null) 'p_warehouse_id': warehouseId,
      }));

  Future<List<Map<String, dynamic>>> stockAdjustments({int limit = 50}) async =>
      _rows(await client
          .from('stock_adjustments')
          .select()
          .eq('org_id', orgId)
          .order('adjustment_date', ascending: false)
          .limit(limit));

  /// Saves a counted sheet as a draft adjustment and returns its id.
  /// Lines whose count equals the system figure are left out: they are
  /// not an adjustment, and carrying them makes the sheet unreadable.
  Future<String> saveStockAdjustment({
    required String warehouseId,
    required DateTime date,
    required String reason,
    required List<({String itemId, double system, double counted})> lines,
  }) async {
    final header = await client
        .from('stock_adjustments')
        .insert({
          'org_id': orgId,
          'adjustment_no': await nextDocumentNumber('stock_adjustment'),
          'adjustment_date': Fmt.iso(date),
          'warehouse_id': warehouseId,
          'reason': reason,
          'adjustment_type': 'stock_take',
          'status': 'draft',
        })
        .select()
        .single();

    final id = header['id'] as String;
    final changed = lines.where((l) => l.counted != l.system).toList();
    if (changed.isNotEmpty) {
      await client.from('stock_adjustment_lines').insert([
        for (var i = 0; i < changed.length; i++)
          {
            'org_id': orgId,
            'adjustment_id': id,
            'line_no': i + 1,
            'item_id': changed[i].itemId,
            'system_quantity': changed[i].system,
            'counted_quantity': changed[i].counted,
          }
      ]);
    }
    return id;
  }

  Future<String> postStockAdjustment(String id) async {
    final data =
        await client.rpc('post_stock_adjustment', params: {'p_id': id});
    return data as String;
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

  /// Every currency this organization could use, with the rate that is
  /// actually in force and where it came from.
  ///
  /// `exchangeRateFor` answers one currency and says nothing about
  /// provenance, which is right for pricing a document and useless for
  /// answering "why is this the rate?". A currency with nothing on file
  /// comes back with a null rate rather than being left out — that row
  /// is the one that will refuse to post.
  Future<List<Map<String, dynamic>>> exchangeRateBoard([DateTime? onDate]) async =>
      _rows(await client.rpc('exchange_rate_board', params: {
        'p_org_id': orgId,
        'p_on_date': Fmt.iso(onDate ?? DateTime.now()),
      }));

  /// Records a rate so the next document does not have to be told again.
  ///
  /// Upserted on the natural key, because two rates for one pair on one
  /// day is not a history — it is a tie the resolver would break by
  /// insertion order, which is no answer at all.
  ///
  /// Always this organization's own row. A published rate is never
  /// written from here: `ingest_exchange_rates` is closed to signed-in
  /// users, and the insert policy refuses a row belonging to nobody.
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

  // ------------------------------------------------------------------
  // LHDN credentials
  //
  // Never the table. `einvoice_credentials` holds client secrets and
  // certificate private keys, so it has RLS with no policies and no
  // grants at all — the app could not write it even when it tried to,
  // which is why nobody could set up e-Invoice until 0107.
  // ------------------------------------------------------------------

  /// What is configured, per environment. Never returns a secret — only
  /// whether one is on file.
  Future<List<Map<String, dynamic>>> einvoiceCredentialStatus() async =>
      _rows(await client.rpc('einvoice_credential_status',
          params: {'p_org_id': orgId}));

  /// Leave [clientSecret] null to keep the stored one, which is what
  /// makes correcting a typo in the client id safe.
  Future<void> setEinvoiceCredentials({
    required String environment,
    required String clientId,
    String? clientSecret,
  }) =>
      client.rpc('set_einvoice_credentials', params: {
        'p_org_id': orgId,
        'p_environment': environment,
        'p_client_id': clientId,
        'p_client_secret': clientSecret,
      });

  Future<void> clearEinvoiceCredentials(String environment) =>
      client.rpc('clear_einvoice_credentials', params: {
        'p_org_id': orgId,
        'p_environment': environment,
      });

  // ------------------------------------------------------------------
  // Batches and serial numbers
  //
  // Identity, not cost. A tracked item still values at weighted average
  // — see 0106 — so nothing here touches a figure on the balance sheet.
  // What it does is make a recall answerable.
  // ------------------------------------------------------------------

  /// The saved lines of a document, in line order.
  ///
  /// Needed because `saveDocument` deletes and reinserts lines, so the
  /// ids an editor was holding are gone by the time it wants to attach
  /// anything to them. Line order is what survives.
  Future<List<Map<String, dynamic>>> documentLineIds({
    required DocKind kind,
    required String documentId,
  }) async =>
      _rows(await client
          .from(kind.lineTable)
          .select('id, line_no')
          .eq('document_id', documentId)
          .order('line_no'));

  /// Every lot allocation on a document, keyed by line id.
  Future<Map<String, List<Map<String, dynamic>>>> lotsForDocument({
    required DocKind kind,
    required List<String> lineIds,
  }) async {
    if (lineIds.isEmpty) return {};
    final column = kind.isSales ? 'sales_line_id' : 'purchase_line_id';
    final rows = _rows(await client
        .from('document_line_lots')
        .select()
        .inFilter(column, lineIds)
        .order('lot_ref'));
    final out = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      (out[r[column] as String] ??= []).add(r);
    }
    return out;
  }

  /// Replaces the whole breakdown for one document line.
  ///
  /// The database refuses a breakdown that does not add up to the line,
  /// so a screen can send what it has and let the message come back
  /// rather than doing the arithmetic twice and disagreeing with itself.
  Future<int> setLineLots({
    required String lineTable,
    required String lineId,
    required List<Map<String, dynamic>> lots,
  }) async {
    final data = await client.rpc('set_line_lots', params: {
      'p_line_table': lineTable,
      'p_line_id': lineId,
      'p_lots': lots,
    });
    return (data as num?)?.toInt() ?? 0;
  }

  Future<List<Map<String, dynamic>>> lineLots({
    required String lineTable,
    required String lineId,
  }) async =>
      _rows(await client.rpc('line_lots', params: {
        'p_line_table': lineTable,
        'p_line_id': lineId,
      }));

  /// What still has to be named before this document can post. Empty
  /// means it is ready.
  Future<List<Map<String, dynamic>>> documentLotProblems({
    required String documentId,
    required bool sales,
  }) async =>
      _rows(await client.rpc('document_lot_problems', params: {
        'p_document_id': documentId,
        'p_kind': sales ? 'sales' : 'purchase',
      }));

  /// First expired, first out. Advisory — a physical pick is a physical
  /// fact, and refusing the box in somebody's hand gets worked around.
  Future<List<Map<String, dynamic>>> suggestLots({
    required String itemId,
    String? warehouseId,
    required double quantity,
  }) async =>
      _rows(await client.rpc('suggest_lots', params: {
        'p_item_id': itemId,
        'p_warehouse_id': warehouseId,
        'p_quantity': quantity,
      }));

  Future<List<Map<String, dynamic>>> lotBalances({String? itemId}) async =>
      _rows(await client.rpc('report_lot_balances', params: {
        'p_org_id': orgId,
        'p_item_id': itemId,
        'p_warehouse_id': null,
      }));

  Future<List<Map<String, dynamic>>> expiringStock({int withinDays = 90}) async =>
      _rows(await client.rpc('report_expiring_stock', params: {
        'p_org_id': orgId,
        'p_within_days': withinDays,
      }));

  /// Where a batch came from and everywhere it went — the recall
  /// question, and the only thing that justifies typing batch numbers.
  Future<List<Map<String, dynamic>>> traceLot(String lotId) async =>
      _rows(await client.rpc('trace_lot', params: {
        'p_org_id': orgId,
        'p_lot_id': lotId,
      }));

  // ------------------------------------------------------------------
  // Salespeople
  //
  // Their own table rather than a pointer at a user, because the person
  // who won the order does not always have a login — and until 0105 the
  // column insisted they did, against `auth.users`, which is global and
  // so did not even keep one organization's documents from naming
  // another's people.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> salespeople({bool activeOnly = false}) async {
    var q = client.from('salespeople').select().eq('org_id', orgId);
    if (activeOnly) q = q.eq('is_active', true);
    return _rows(await q.order('name'));
  }

  Future<void> saveSalesperson(Map<String, dynamic> row) async {
    final id = row['id'] as String?;
    final payload = {...row, 'org_id': orgId}..remove('id');
    if (id == null) {
      await client.from('salespeople').insert(payload);
    } else {
      await client.from('salespeople').update(payload).eq('id', id);
    }
  }

  /// Removes the person and leaves every document they sold standing.
  ///
  /// The foreign key is `on delete set null`: blocking this would make a
  /// leaver permanent, and cascading it would delete invoices because
  /// somebody resigned. The sales move to the unattributed line, which is
  /// visible rather than lost.
  Future<void> deleteSalesperson(String id) =>
      client.from('salespeople').delete().eq('id', id);

  /// Net sales by salesperson, and what any agreed rate implies.
  ///
  /// The commission figure is a working paper. Nothing is posted, no
  /// liability is raised and nothing reaches payroll — whether
  /// commission is earned on invoice, on payment or on margin is a
  /// policy the database has no business inventing.
  Future<List<Map<String, dynamic>>> salesByPerson({
    required DateTime from,
    required DateTime to,
  }) async =>
      _rows(await client.rpc('report_sales_by_person', params: {
        'p_org_id': orgId,
        'p_from': Fmt.iso(from),
        'p_to': Fmt.iso(to),
      }));

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

  /// Where a customer stands against their credit limit, in base
  /// currency. Null limit means no limit was set.
  Future<Map<String, dynamic>> customerCreditStatus(String contactId) async {
    final data = await client
        .rpc('customer_credit_status', params: {'p_contact_id': contactId});
    return Map<String, dynamic>.from(data as Map);
  }

  /// off | warn | block — what happens when an invoice would take a
  /// customer past their limit.
  Future<void> setCreditControl(String mode) => client
      .from('organizations')
      .update({'credit_control': mode}).eq('id', orgId);

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

  /// [payWithPayroll] decides which of two settlement routes the claim
  /// takes, and it cannot be changed afterwards from here: true and the
  /// next payroll run picks it up and posts it; false and somebody has
  /// to post it from the claims screen. The column has always defaulted
  /// to true, so before this argument existed every claim went down the
  /// payroll route whether or not that was what anyone wanted.
  Future<String> createClaim({
    required String employeeId,
    required String title,
    required List<Map<String, dynamic>> lines,
    bool payWithPayroll = true,
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
          'pay_with_payroll': payWithPayroll,
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

  Future<void> deleteSetupRow(String table, String id) =>
      client.from(table).delete().eq('id', id);

  // ------------------------------------------------------------------
  // Public holidays
  //
  // Read by leave day counts and by the rest-day / public-holiday
  // classification in attendance, so an empty calendar does not fail —
  // it quietly makes every holiday an ordinary working day.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> publicHolidays(int year) async =>
      Repo._rows(await client
          .from('public_holidays')
          .select()
          .eq('org_id', orgId)
          .gte('holiday_date', '$year-01-01')
          .lte('holiday_date', '$year-12-31')
          .order('holiday_date'));

  /// Fills in the four federal holidays that fall on a fixed date. The
  /// lunar ones are gazetted each year and are not guessed.
  Future<int> addFixedHolidays(int year) async {
    final data = await client.rpc('add_fixed_public_holidays',
        params: {'p_org_id': orgId, 'p_year': year});
    return Fmt.toInt(data);
  }

  // ------------------------------------------------------------------
  // Leave entitlement bands
  //
  // Not `setupRows`: the table carries no `org_id` at all — it hangs off
  // its leave type, and RLS reaches the organization through that.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> leaveBands(String leaveTypeId) async =>
      Repo._rows(await client
          .from('leave_entitlement_bands')
          .select()
          .eq('leave_type_id', leaveTypeId)
          .order('service_years_from'));

  Future<void> saveLeaveBand(Map<String, dynamic> values, {String? id}) async {
    if (id != null) {
      await client.from('leave_entitlement_bands').update(values).eq('id', id);
    } else {
      await client.from('leave_entitlement_bands').insert(values);
    }
  }

  /// Writes the Employment Act 1955 minimums — s.60E(1) for annual
  /// leave, s.60F(1) for sick — and turns on the flag that makes them
  /// count.
  Future<int> applyStatutoryLeaveBands(String leaveTypeId, String preset) async {
    final data = await client.rpc('apply_statutory_leave_bands',
        params: {'p_leave_type_id': leaveTypeId, 'p_preset': preset});
    return Fmt.toInt(data);
  }

  // ------------------------------------------------------------------
  // Statutory rate tables
  //
  // These have no `org_id`: one table, shared by every organization in
  // the database. Anybody may read them — that is what makes "are we
  // filing on verified figures?" answerable — and only a platform
  // administrator may change them.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> statutorySchedules() async =>
      Repo._rows(await client
          .from('statutory_schedules')
          .select('*, statutory_rates(*)')
          .order('body')
          .order('effective_from', ascending: false));

  Future<String> publishStatutorySchedule({
    required String body,
    required String name,
    required String method,
    required DateTime effectiveFrom,
    required List<Map<String, dynamic>> rates,
    String? source,
    String? notes,
    double? wageRoundUpTo,
    String resultRounding = 'nearest_cent',
    bool isVerified = false,
  }) async {
    final data = await client.rpc('platform_publish_statutory_schedule', params: {
      'p_body': body,
      'p_name': name,
      'p_method': method,
      'p_effective_from': Fmt.iso(effectiveFrom),
      'p_rates': rates,
      if (source != null) 'p_source': source,
      if (notes != null) 'p_notes': notes,
      if (wageRoundUpTo != null) 'p_wage_round_up_to': wageRoundUpTo,
      'p_result_rounding': resultRounding,
      'p_is_verified': isVerified,
    });
    return data as String;
  }

  Future<void> setScheduleVerified(String scheduleId, bool verified,
          {String? source, String? notes}) =>
      client.rpc('platform_set_schedule_verified', params: {
        'p_schedule_id': scheduleId,
        'p_verified': verified,
        if (source != null) 'p_source': source,
        if (notes != null) 'p_notes': notes,
      });

  // ------------------------------------------------------------------
  // Item prices
  //
  // `item_price(item, contact, qty)` resolves a named price first and
  // falls back to the level's percentage. Named prices are what this
  // reads and writes; without them a price level can only move every
  // item by the same percentage, which is not how anybody prices a
  // catalogue.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> itemPrices(String itemId) async =>
      Repo._rows(await client
          .from('item_prices')
          .select('*, price_levels(code, name)')
          .eq('item_id', itemId)
          .order('min_quantity'));

  Future<void> saveItemPrice(Map<String, dynamic> values, {String? id}) async {
    if (id != null) {
      await client.from('item_prices').update(values).eq('id', id);
    } else {
      await client.from('item_prices').insert({...values, 'org_id': orgId});
    }
  }

  // Resolving what a customer is quoted is `Repo.itemPrice`, further
  // up, which the document editor already calls. Writing the named
  // prices it reads is what was missing.

  // ------------------------------------------------------------------
  // Contact people and delivery addresses
  //
  // `sales_documents.contact_person_id` and `.shipping_address_id` are
  // carried through the transfer path and read by the e-Invoice
  // preparation, and both tables were empty because nothing could write
  // them.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> contactPersons(String contactId) async =>
      Repo._rows(await client
          .from('contact_persons')
          .select()
          .eq('contact_id', contactId)
          .order('is_primary', ascending: false)
          .order('name'));

  Future<void> saveContactPerson(Map<String, dynamic> values,
      {String? id}) async {
    if (id != null) {
      await client.from('contact_persons').update(values).eq('id', id);
    } else {
      await client.from('contact_persons').insert({...values, 'org_id': orgId});
    }
  }

  Future<List<Map<String, dynamic>>> contactAddresses(String contactId) async =>
      Repo._rows(await client
          .from('contact_addresses')
          .select()
          .eq('contact_id', contactId)
          .order('is_default', ascending: false)
          .order('label'));

  Future<void> saveContactAddress(Map<String, dynamic> values,
      {String? id}) async {
    if (id != null) {
      await client.from('contact_addresses').update(values).eq('id', id);
    } else {
      await client
          .from('contact_addresses')
          .insert({...values, 'org_id': orgId});
    }
  }

  /// Clears the flag on every other row first. Two default addresses is
  /// the same as none: whichever one a query happens to return wins, and
  /// deliveries go to whichever that is.
  Future<void> makeAddressDefault(String contactId, String addressId) async {
    await client
        .from('contact_addresses')
        .update({'is_default': false})
        .eq('contact_id', contactId);
    await client
        .from('contact_addresses')
        .update({'is_default': true})
        .eq('id', addressId);
  }

  // ------------------------------------------------------------------
  // Leads
  //
  // The top of the funnel. Everything before somebody has decided the
  // enquiry is real enough to be an opportunity.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> leads({String? status}) async {
    var q = client
        .from('leads')
        .select('*, contacts:converted_contact_id(name)')
        .eq('org_id', orgId)
        .isFilter('deleted_at', null);
    if (status != null && status != 'all') {
      q = status == 'open'
          ? q.not('status', 'in', '("converted","lost","unqualified")')
          : q.eq('status', status);
    }
    return Repo._rows(
        await q.order('created_at', ascending: false).limit(300));
  }

  Future<void> saveLead(Map<String, dynamic> values, {String? id}) async {
    if (id != null) {
      await client.from('leads').update(values).eq('id', id);
    } else {
      await client.from('leads').insert({
        ...values,
        'org_id': orgId,
        'lead_no': await nextDocumentNumber('lead'),
      });
    }
  }

  /// Creates the customer, the contact person and usually an
  /// opportunity, and stamps the lead — in one transaction, because
  /// three writes from here can half succeed and leave the same company
  /// in the book twice.
  ///
  /// Returns the new contact and opportunity ids.
  Future<Map<String, dynamic>> convertLead(
    String leadId, {
    bool createOpportunity = true,
    String? pipelineId,
    double? amount,
    DateTime? expectedClose,
  }) async {
    final data = await client.rpc('convert_lead', params: {
      'p_lead_id': leadId,
      'p_create_opportunity': createOpportunity,
      if (pipelineId != null) 'p_pipeline_id': pipelineId,
      if (amount != null) 'p_amount': amount,
      if (expectedClose != null)
        'p_expected_close_date': Fmt.iso(expectedClose),
    });
    return Map<String, dynamic>.from(data as Map);
  }

  Future<List<Map<String, dynamic>>> pipelines() async => Repo._rows(await client
      .from('pipelines')
      .select()
      .eq('org_id', orgId)
      .eq('is_active', true)
      .order('sort_order'));

  // ------------------------------------------------------------------
  // Interviews
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> interviews(String applicantId) async =>
      Repo._rows(await client
          .from('interviews')
          .select('*, employees:interviewer_id(full_name)')
          .eq('applicant_id', applicantId)
          .order('round_no'));

  Future<void> saveInterview(Map<String, dynamic> values, {String? id}) async {
    if (id != null) {
      await client.from('interviews').update(values).eq('id', id);
    } else {
      await client.from('interviews').insert({...values, 'org_id': orgId});
    }
  }

  // ------------------------------------------------------------------
  // Onboarding
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> onboardingTemplateItems(
          String templateId) async =>
      Repo._rows(await client
          .from('onboarding_template_items')
          .select()
          .eq('template_id', templateId)
          .order('sort_order'));

  Future<void> saveTemplateItem(Map<String, dynamic> values,
      {String? id}) async {
    if (id != null) {
      await client
          .from('onboarding_template_items')
          .update(values)
          .eq('id', id);
    } else {
      await client
          .from('onboarding_template_items')
          .insert({...values, 'org_id': orgId});
    }
  }

  Future<List<Map<String, dynamic>>> onboardingChecklists(
      {bool openOnly = true}) async {
    var q = client
        .from('onboarding_checklists')
        .select('*, employees(full_name, employee_no), '
            'onboarding_tasks(id, is_done, is_mandatory)')
        .eq('org_id', orgId);
    if (openOnly) q = q.isFilter('completed_at', null);
    return Repo._rows(await q.order('start_date', ascending: false).limit(200));
  }

  Future<List<Map<String, dynamic>>> onboardingTasks(String checklistId) async =>
      Repo._rows(await client
          .from('onboarding_tasks')
          .select('*, employees:owner_employee_id(full_name)')
          .eq('checklist_id', checklistId)
          .order('sort_order'));

  /// Materialises the template's items as dated tasks. Copied rather
  /// than referenced, so editing the template later does not move the
  /// due dates of an onboarding already under way.
  Future<String> startOnboarding({
    required String employeeId,
    String? templateId,
    DateTime? startDate,
    String kind = 'onboarding',
  }) async {
    final data = await client.rpc('start_onboarding', params: {
      'p_employee_id': employeeId,
      if (templateId != null) 'p_template_id': templateId,
      if (startDate != null) 'p_start_date': Fmt.iso(startDate),
      'p_kind': kind,
    });
    return data as String;
  }

  /// Returns true when that tick finished the checklist.
  Future<bool> setOnboardingTaskDone(String taskId, bool done) async {
    final data = await client.rpc('set_onboarding_task_done',
        params: {'p_task_id': taskId, 'p_done': done});
    return data == true;
  }

  // ------------------------------------------------------------------
  // What an employee record hangs off: dependants, documents, shifts
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> employeeRows(
          String table, String employeeId,
          {String select = '*', String orderBy = 'created_at'}) async =>
      Repo._rows(await client
          .from(table)
          .select(select)
          .eq('employee_id', employeeId)
          .order(orderBy));

  Future<void> saveEmployeeRow(
      String table, Map<String, dynamic> values, {String? id}) async {
    if (id != null) {
      await client.from(table).update(values).eq('id', id);
    } else {
      await client.from(table).insert({...values, 'org_id': orgId});
    }
  }

  // ------------------------------------------------------------------
  // Sharing a document with somebody who has no login
  //
  // The token comes back exactly once and is never stored in the clear,
  // so a caller that loses it has to issue a new link rather than look
  // the old one up.
  // ------------------------------------------------------------------
  Future<String> shareDocument(String documentId,
      {int validDays = 30, String? email}) async {
    final data = await client.rpc('share_document', params: {
      'p_document_id': documentId,
      'p_valid_days': validDays,
      if (email != null && email.trim().isNotEmpty) 'p_email': email.trim(),
    });
    return data as String;
  }

  Future<int> revokeDocumentShare(String documentId) async {
    final data = await client
        .rpc('revoke_document_share', params: {'p_document_id': documentId});
    return Fmt.toInt(data);
  }

  Future<List<Map<String, dynamic>>> documentShareLinks(
          String documentId) async =>
      Repo._rows(await client
          .from('document_share_links')
          .select()
          .eq('document_id', documentId)
          .order('created_at', ascending: false));

  // ------------------------------------------------------------------
  // Outbound email
  //
  // Queued here and sent by the `send-email` edge function, which is
  // the only thing holding a provider key. Nothing in the app can send.
  // ------------------------------------------------------------------
  Future<Map<String, dynamic>?> emailSettings() async {
    final rows = await client
        .from('email_settings')
        .select()
        .eq('org_id', orgId)
        .limit(1);
    final list = Repo._rows(rows);
    return list.isEmpty ? null : list.first;
  }

  Future<void> saveEmailSettings(Map<String, dynamic> values) => client
      .from('email_settings')
      .upsert({...values, 'org_id': orgId, 'updated_at': 'now()'});

  /// Queues a document for sending and returns the outbox row's id.
  ///
  /// `dispatch` records which button was pressed and nothing more — the
  /// database never talks to a mail provider. Sending now is this call
  /// followed by [sendQueuedEmail] on the id it returns; if that second
  /// call fails the row is still queued and the schedule collects it,
  /// so send now degrades to send soon rather than to lost.
  Future<String> emailDocument(String documentId,
      {String? to,
      String templateCode = 'document_new',
      String dispatch = 'queued',
      String? attachmentPath,
      String? attachmentName}) async {
    final data = await client.rpc('email_document', params: {
      'p_document_id': documentId,
      if (to != null && to.trim().isNotEmpty) 'p_to': to.trim(),
      'p_template_code': templateCode,
      'p_dispatch': dispatch,
      if (attachmentPath != null) 'p_attachment_path': attachmentPath,
      if (attachmentName != null) 'p_attachment_name': attachmentName,
    });
    return data as String;
  }

  /// Puts a rendered PDF where a queued message can attach it, and
  /// returns the object name to hand to [emailDocument].
  ///
  /// The path is the convention 0068's storage policies enforce —
  /// {org}/{entity}/{id}/{file} — so writing here is already gated on
  /// `app.can_write`, and `email_document` re-checks that the path names
  /// this document before it will reference one.
  ///
  /// `upsert` so sending the same invoice twice replaces the file rather
  /// than failing on the second attempt or accumulating copies.
  Future<String> uploadDocumentPdf(
      String documentId, String fileName, Uint8List bytes) async {
    final path = '$orgId/sales_documents/$documentId/$fileName';
    await client.storage.from('attachments').uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(
              contentType: 'application/pdf', upsert: true),
        );
    return path;
  }

  /// Queues one message and drains that row immediately.
  ///
  /// Returns the outbox row as it stands afterwards, so the caller can
  /// say what actually happened rather than "probably sent". A failure
  /// to drain is deliberately not rethrown: the message is queued by
  /// then, and telling somebody their invoice was not sent when it is
  /// about to go out half an hour later would be wrong.
  Future<Map<String, dynamic>> emailDocumentNow(String documentId,
      {String? to,
      String templateCode = 'document_new',
      String? attachmentPath,
      String? attachmentName}) async {
    final id = await emailDocument(documentId,
        to: to,
        templateCode: templateCode,
        dispatch: 'immediate',
        attachmentPath: attachmentPath,
        attachmentName: attachmentName);
    try {
      await sendQueuedEmail(id: id);
    } catch (_) {
      // Swallowed on purpose; the row below reports the truth.
    }
    final row = await client
        .from('email_outbox')
        .select('id, status, to_email, sent_at, last_error, attempts')
        .eq('id', id)
        .maybeSingle();
    return Map<String, dynamic>.from(row as Map? ?? {'id': id});
  }

  /// Queues the customer's receipt. Attaches rather than links: see
  /// migration 0110 for why a receipt is the one message here that
  /// should not carry a share token.
  Future<String> emailReceipt(String receiptId,
      {String? to,
      String dispatch = 'queued',
      String? attachmentPath,
      String? attachmentName}) async {
    final data = await client.rpc('email_receipt', params: {
      'p_receipt_id': receiptId,
      if (to != null && to.trim().isNotEmpty) 'p_to': to.trim(),
      'p_dispatch': dispatch,
      if (attachmentPath != null) 'p_attachment_path': attachmentPath,
      if (attachmentName != null) 'p_attachment_name': attachmentName,
    });
    return data as String;
  }

  /// Queues the receipt and drains that row immediately, returning the
  /// row as it stands afterwards. Same contract as [emailDocumentNow].
  Future<Map<String, dynamic>> emailReceiptNow(String receiptId,
      {String? to, String? attachmentPath, String? attachmentName}) async {
    final id = await emailReceipt(receiptId,
        to: to,
        dispatch: 'immediate',
        attachmentPath: attachmentPath,
        attachmentName: attachmentName);
    try {
      await sendQueuedEmail(id: id);
    } catch (_) {
      // Swallowed on purpose; the row below reports the truth.
    }
    final row = await client
        .from('email_outbox')
        .select('id, status, to_email, sent_at, last_error, attempts')
        .eq('id', id)
        .maybeSingle();
    return Map<String, dynamic>.from(row as Map? ?? {'id': id});
  }

  /// The receipt PDF, where a queued message can attach it. Same path
  /// convention and the same storage policies as a document's.
  Future<String> uploadReceiptPdf(
      String receiptId, String fileName, Uint8List bytes) async {
    final path = '$orgId/receipts/$receiptId/$fileName';
    await client.storage.from('attachments').uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(
              contentType: 'application/pdf', upsert: true),
        );
    return path;
  }

  /// What has been emailed for this receipt, newest first.
  Future<List<Map<String, dynamic>>> receiptEmails(String receiptId) async =>
      Repo._rows(await client
          .from('email_outbox')
          .select('id, to_email, status, dispatch, queued_at, sent_at, '
              'last_error, attachment_name')
          .eq('receipt_id', receiptId)
          .order('queued_at', ascending: false));

  /// Money received from customers, or paid to suppliers.
  ///
  /// These have been recorded and posted since the settlement dialog was
  /// built and have never been listed anywhere — a receipt existed in the
  /// database that no screen could show.
  Future<List<Map<String, dynamic>>> settlements({
    required bool isSales,
    String? contactId,
    int limit = 200,
  }) async {
    final table = isSales ? 'receipts' : 'purchase_payments';
    final dateField = isSales ? 'receipt_date' : 'payment_date';
    var q = client
        .from(table)
        .select('*, contacts(name, code), bank_accounts(name)')
        .eq('org_id', orgId)
        .filter('deleted_at', 'is', null);
    if (contactId != null) q = q.eq('contact_id', contactId);
    return Repo._rows(
        await q.order(dateField, ascending: false).limit(limit));
  }

  /// One settlement with what it was set against.
  ///
  /// The document embed names its constraint because
  /// `payment_allocations` reaches `sales_documents` twice — once for the
  /// invoice being paid and once for a credit note being applied. Left
  /// ambiguous, PostgREST refuses the whole query.
  Future<Map<String, dynamic>> settlement(String id,
      {required bool isSales}) async {
    final table = isSales ? 'receipts' : 'purchase_payments';
    final head = await client
        .from(table)
        .select('*, contacts(name, code, email, address_line1, address_line2, '
            'city, postcode, state_code), bank_accounts(name)')
        .eq('id', id)
        .single();

    final allocations = Repo._rows(await client
        .from('payment_allocations')
        .select(isSales
            ? 'amount, discount_amount, '
                'sales_documents!payment_allocations_invoice_id_fkey'
                '(doc_no, doc_type, doc_date, total_amount)'
            : 'amount, discount_amount, '
                'purchase_documents!payment_allocations_bill_fk'
                '(doc_no, doc_type, doc_date, total_amount)')
        .eq(isSales ? 'receipt_id' : 'payment_id', id)
        .order('created_at'));

    return {
      ...Map<String, dynamic>.from(head as Map),
      'allocations': allocations,
    };
  }

  /// Everything that ever left the building for this document: messages,
  /// share links and PDF downloads, newest first.
  Future<List<Map<String, dynamic>>> documentActivity(String documentId) async =>
      Repo._rows(await client
          .rpc('document_activity', params: {'p_document_id': documentId}));

  /// Records that somebody took the PDF. The file is built in the
  /// browser, so this is a record of what the app did rather than an
  /// access log — see the migration for why that distinction matters.
  Future<void> logDocumentDownload(String documentId) async {
    await client.rpc('log_document_download',
        params: {'p_document_id': documentId});
  }

  Future<List<Map<String, dynamic>>> emailOutbox({String? status}) async {
    var q = client
        .from('email_outbox')
        .select('*, sales_documents(doc_no)')
        .eq('org_id', orgId);
    if (status != null && status != 'all') q = q.eq('status', status);
    return Repo._rows(await q.order('queued_at', ascending: false).limit(200));
  }

  /// Asks the edge function to drain the queue now rather than waiting
  /// for the schedule. Used from the outbox when somebody has just
  /// fixed whatever was wrong.
  Future<Map<String, dynamic>> sendQueuedEmail({String? id}) async {
    final res = await client.functions
        .invoke('send-email', body: {if (id != null) 'id': id});
    return Map<String, dynamic>.from(res.data as Map? ?? {});
  }

  Future<List<Map<String, dynamic>>> appraisalGoals(String appraisalId) async =>
      Repo._rows(await client
          .from('appraisal_goals')
          .select()
          .eq('appraisal_id', appraisalId)
          .order('sort_order'));

  Future<void> saveAppraisalGoal(Map<String, dynamic> values,
      {String? id}) async {
    if (id != null) {
      await client.from('appraisal_goals').update(values).eq('id', id);
    } else {
      await client.from('appraisal_goals').insert({...values, 'org_id': orgId});
    }
  }

  Future<void> makePersonPrimary(String contactId, String personId) async {
    await client
        .from('contact_persons')
        .update({'is_primary': false})
        .eq('contact_id', contactId);
    await client
        .from('contact_persons')
        .update({'is_primary': true})
        .eq('id', personId);
  }
}
