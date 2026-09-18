import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/format.dart';
// For `writeCustomFields`, which both `openMatter` and `createTicket`
// need and which each of them used to write out again inline.
import 'custom_fields_repository.dart';
import '../features/documents/transfer.dart';
// `RepoMia` at the foot of this file returns these.
import '../features/mia/mia_credential.dart';
import 'models.dart';

/// All data access for one organization. Every query is additionally
/// filtered by org_id even though RLS already enforces it — belt and
/// braces, and it keeps the generated SQL selective.
/// Blank is not a value. An empty box in a form means "nothing here",
/// and storing `''` would make "never filled in" and "deliberately
/// cleared" indistinguishable to everything downstream.
String? _orNull(String? v) => (v == null || v.trim().isEmpty) ? null : v.trim();

/// One idempotency key, held across the retries of a single attempt.
///
/// Public so the rule below can be asserted directly — it is the whole
/// correctness argument, and it is three lines of state that would
/// otherwise only be exercised against a live database.
///
/// `0307` built the whole mechanism — the key table, the fingerprint
/// check, a daily sweep and a CI test — and its own header notes that
/// the client sends no key. Nothing ever started sending one, so every
/// protected write has been unprotected since: a double tap on Post, or
/// a retry after a request that timed out on the way back, posts twice.
///
/// The rule is what makes a key correct rather than merely present:
///
/// * **Retained across a failure.** That is the case the mechanism
///   exists for — the write may or may not have landed, and only the
///   server knows which.
/// * **Retired on success.** Otherwise two deliberately identical
///   entries — the same petty cash amount twice in a day, which is an
///   ordinary thing to do — would collapse into one.
/// * **Re-minted when the payload changes.** A failure the user fixes
///   by editing the form is a different request, and `0307` refuses a
///   key reused for different arguments.
///
/// The comparison is on the parameter map's own `toString`, which is
/// stable because these maps are built from literals in a fixed order.
/// It does not need to be canonical: the server computes the
/// authoritative fingerprint, so the worst a disagreement here can do
/// is produce a refusal, never a wrong post.
///
/// Keys live in memory, so a page reload loses one. A reload is a fresh
/// attempt from the person's point of view and this is the honest limit
/// of a client-held key, not something worked around.
class IdempotentAttempt {
  String? _key;
  String? _payload;

  String keyFor(Map<String, dynamic> params) {
    final payload = params.toString();
    if (_key == null || payload != _payload) {
      _payload = payload;
      _key = _mint();
    }
    return _key!;
  }

  void succeeded() {
    _key = null;
    _payload = null;
  }

  static final Random _rng = Random.secure();

  static String _mint() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

class Repo {
  Repo(this.client, this.orgId);

  final SupabaseClient client;
  final String orgId;

  final Map<String, IdempotentAttempt> _attempts = {};

  /// Every RPC in this file goes through here, so that being refused is
  /// written down.
  ///
  /// A refusal cannot record itself. The guards inside the SECURITY
  /// DEFINER functions raise `42501`, and the raise unwinds the
  /// transaction any log row would have been written in -- 0235's header
  /// has the measurement. So the record has to be made by a second
  /// request, which is this one: catch the refusal, report it, rethrow
  /// it unchanged so every caller behaves exactly as before.
  ///
  /// What this covers is the explicit refusals -- "Only an owner or
  /// admin may post payroll" and its two hundred siblings. What it does
  /// not cover is a policy that filters rows out of a select, because
  /// that is not an error and nothing anywhere knows it happened.
  ///
  /// `report_denied` never raises and is rate-limited server-side, so a
  /// storm of refusals cannot become a storm of requests that matters.
  Future<dynamic> callRpc(String fn, {Map<String, dynamic>? params}) async {
    try {
      return await client.rpc(fn, params: params);
    } on PostgrestException catch (e) {
      if (e.code == '42501') {
        unawaited(_noteRefusal(fn, e.message));
      }
      rethrow;
    }
  }

  /// A write that must not happen twice.
  ///
  /// `0307`'s protected calls are *overloads*, and its header explains
  /// why the key deliberately has no default: PostgREST picks between
  /// the two by matching parameter names, so a body without the key
  /// matches only the original and a body with it matches only the
  /// wrapper. The consequence for a caller is easy to get wrong and
  /// fails silently — **the wrapper has no defaults on any of its
  /// parameters**, so a call that omits one optional argument does not
  /// error, it quietly resolves to the unprotected original. Callers
  /// here therefore name every parameter, passing an explicit null
  /// rather than leaving one out.
  ///
  /// The key is minted by [IdempotentAttempt], which is what makes it
  /// survive a retry and not a success.
  Future<dynamic> callRpcOnce(
    String fn, {
    required Map<String, dynamic> params,
  }) async {
    final attempt = _attempts.putIfAbsent(fn, IdempotentAttempt.new);
    final result = await callRpc(
      fn,
      params: {...params, 'p_idempotency_key': attempt.keyFor(params)},
    );
    attempt.succeeded();
    return result;
  }

  /// Never allowed to change what the caller sees. The refusal is the
  /// caller's business; recording it is not, and a log that cannot be
  /// written must not turn one error into two.
  Future<void> _noteRefusal(String fn, String? message) async {
    try {
      await client.rpc(
        'report_denied',
        params: {'p_org_id': orgId, 'p_action': fn, 'p_message': message},
      );
    } catch (_) {
      // Deliberately swallowed: see above.
    }
  }

  // ------------------------------------------------------------------
  // Dashboard and reports
  // ------------------------------------------------------------------
  Future<DashboardSummary> dashboard({DateTime? from, DateTime? to}) async {
    final data = await callRpc(
      'dashboard_summary',
      params: {
        'p_org_id': orgId,
        if (from != null) 'p_from': Fmt.iso(from),
        if (to != null) 'p_to': Fmt.iso(to),
      },
    );
    return DashboardSummary(Map<String, dynamic>.from(data as Map));
  }

  Future<List<Map<String, dynamic>>> revenueTrend({int months = 12}) async {
    final data = await callRpc(
      'report_revenue_trend',
      params: {'p_org_id': orgId, 'p_months': months},
    );
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> trialBalance({
    DateTime? from,
    DateTime? to,
  }) async {
    final data = await callRpc(
      'report_trial_balance',
      params: {
        'p_org_id': orgId,
        if (from != null) 'p_from': Fmt.iso(from),
        'p_to': Fmt.iso(to ?? DateTime.now()),
      },
    );
    return _rows(data);
  }

  // ------------------------------------------------------------------
  // Across a company group
  //
  // Combined, not consolidated. `0142_group_reporting.sql` says at
  // length what that means and what is missing; the screen says it in
  // one sentence to the person reading the numbers.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> groupTrialBalance({
    DateTime? from,
    DateTime? to,
  }) async {
    final data = await callRpc(
      'report_group_trial_balance',
      params: {
        'p_org_id': orgId,
        if (from != null) 'p_from': Fmt.iso(from),
        'p_to': Fmt.iso(to ?? DateTime.now()),
      },
    );
    return _rows(data);
  }

  /// The balances and turnover between companies in the group — what a
  /// consolidation would have to eliminate.
  /// The combined trial balance with inter-company trading taken out.
  ///
  /// Refused by 0148 unless every subsidiary is recorded as wholly
  /// owned, because anything less needs minority interest and this does
  /// not compute one. The refusal names the company, and `AsyncView`
  /// shows the sentence.
  Future<List<Map<String, dynamic>>> groupConsolidated({
    DateTime? from,
    DateTime? to,
  }) async {
    final data = await callRpc(
      'report_group_consolidated_trial_balance',
      params: {
        'p_org_id': orgId,
        if (from != null) 'p_from': Fmt.iso(from),
        'p_to': Fmt.iso(to ?? DateTime.now()),
      },
    );
    return _rows(data);
  }

  /// Which pairs reconcile and which do not. Nothing is eliminated for a
  /// pair that disagrees, so this is the list of what has to be sorted
  /// out before the consolidation means anything.
  Future<List<Map<String, dynamic>>> groupEliminationCheck({
    DateTime? from,
    DateTime? to,
  }) async {
    final data = await callRpc(
      'report_group_elimination_check',
      params: {
        'p_org_id': orgId,
        if (from != null) 'p_from': Fmt.iso(from),
        'p_to': Fmt.iso(to ?? DateTime.now()),
      },
    );
    return _rows(data);
  }

  Future<void> setGroupOwnership({
    required String orgId,
    String? parentOrgId,
    double? percent,
  }) => callRpc(
    'set_group_ownership',
    params: {
      'p_org_id': orgId,
      'p_parent_org_id': parentOrgId,
      'p_percent': percent,
    },
  );

  Future<List<Map<String, dynamic>>> groupIntercompany({
    DateTime? from,
    DateTime? to,
  }) async {
    final data = await callRpc(
      'report_group_intercompany',
      params: {
        'p_org_id': orgId,
        if (from != null) 'p_from': Fmt.iso(from),
        'p_to': Fmt.iso(to ?? DateTime.now()),
      },
    );
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> profitLoss({
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await callRpc(
      'report_profit_loss',
      params: {'p_org_id': orgId, 'p_from': Fmt.iso(from), 'p_to': Fmt.iso(to)},
    );
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
    final data = await callRpc(
      'report_profit_loss_by_dimension',
      params: {
        'p_org_id': orgId,
        'p_from': Fmt.iso(from),
        'p_to': Fmt.iso(to),
        if (projectCode != null) 'p_project_code': projectCode,
        if (departmentCode != null) 'p_department_code': departmentCode,
      },
    );
    return _rows(data);
  }

  /// Which project and department codes actually appear in the ledger.
  Future<List<Map<String, dynamic>>> ledgerDimensions() async =>
      _rows(await callRpc('ledger_dimensions', params: {'p_org_id': orgId}));

  Future<List<Map<String, dynamic>>> balanceSheet({DateTime? asAt}) async {
    final data = await callRpc(
      'report_balance_sheet',
      params: {'p_org_id': orgId, 'p_as_at': Fmt.iso(asAt ?? DateTime.now())},
    );
    return _rows(data);
  }

  /// What is sitting in deferred revenue at a date, one row per invoice
  /// line, with the account's own posted balance repeated on each so the
  /// schedule and the ledger are read from one moment.
  Future<List<Map<String, dynamic>>> deferredRevenue({DateTime? asAt}) async {
    final data = await callRpc(
      'report_deferred_revenue',
      params: {'p_org_id': orgId, 'p_as_at': Fmt.iso(asAt ?? DateTime.now())},
    );
    return _rows(data);
  }

  // ------------------------------------------------------------------
  // Telling us it is broken
  //
  // Not org-scoped in the entitlement sense: reporting a fault is not
  // a feature a company buys, so `report_feedback` takes the company
  // only to say where the person was standing. See 0460.
  // ------------------------------------------------------------------

  Future<String> reportFeedback({
    required String title,
    String kind = 'bug',
    String? body,
    String? screen,
    String? appVersion,
    int? severity,
  }) async {
    final data = await callRpc(
      'report_feedback',
      params: {
        'p_title': title,
        'p_kind': kind,
        'p_body': body,
        'p_screen': screen,
        'p_app_version': appVersion,
        'p_severity': severity,
        'p_org_id': orgId,
      },
    );
    return data as String;
  }

  Future<List<Map<String, dynamic>>> myFeedback() async =>
      _rows(await callRpc('my_feedback', params: {'p_org_id': orgId}));

  // ------------------------------------------------------------------
  // The chart of accounts
  //
  // The policies have allowed this since the schema was laid down. What
  // 0459 adds is the refusals: a number the ledger posts to by name
  // cannot be renumbered, an account with postings cannot change what
  // kind of account it is, and one with history is deactivated rather
  // than deleted.
  // ------------------------------------------------------------------

  Future<String> upsertAccount({
    required String code,
    required String name,
    required String type,
    required String subtype,
    String? id,
    String? parentId,
    bool isGroup = false,
    String? description,
  }) async {
    final data = await callRpc(
      'upsert_account',
      params: {
        'p_code': code,
        'p_name': name,
        'p_type': type,
        'p_subtype': subtype,
        'p_id': id,
        'p_parent_id': parentId,
        'p_is_group': isGroup,
        'p_description': description,
        'p_org_id': id == null ? orgId : null,
      },
    );
    return data as String;
  }

  /// Returns `deleted` or `deactivated`, so the screen can say which
  /// happened rather than guessing.
  Future<String> retireAccount(String id) async {
    final data = await callRpc('retire_account', params: {'p_id': id});
    return data as String;
  }

  /// The ledger by account: balance brought forward, every posted line,
  /// balance carried down. What the trial balance is made of.
  ///
  /// [accountId] narrows it to one account, which is what the question
  /// almost always is — a year of a busy company is tens of thousands
  /// of lines.
  Future<List<Map<String, dynamic>>> generalLedger({
    DateTime? from,
    required DateTime to,
    String? accountId,
  }) async => _rows(
    await callRpc(
      'report_general_ledger',
      params: {
        'p_org_id': orgId,
        'p_from': from == null ? null : Fmt.iso(from),
        'p_to': Fmt.iso(to),
        'p_account_id': accountId,
      },
    ),
  );

  Future<List<Map<String, dynamic>>> sstSummary({
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await callRpc(
      'report_sst_summary',
      params: {'p_org_id': orgId, 'p_from': Fmt.iso(from), 'p_to': Fmt.iso(to)},
    );
    return _rows(data);
  }

  // ------------------------------------------------------------------
  // SST taxable periods
  //
  // `sstSummary` above takes any two dates somebody types, which is
  // right for a report and wrong for a return: SST-02 is bi-monthly on
  // a cycle set by the registration date, and the return is due on the
  // last day of the month after the period. 0455 computes both.
  // ------------------------------------------------------------------

  /// Every taxable period since registration, with what was charged in
  /// it and whether the return went in.
  Future<List<Map<String, dynamic>>> sstTaxablePeriods({
    DateTime? from,
    DateTime? to,
  }) async => _rows(
    await callRpc(
      'sst_taxable_periods',
      params: {
        'p_org_id': orgId,
        'p_from': from == null ? null : Fmt.iso(from),
        'p_to': to == null ? null : Fmt.iso(to),
      },
    ),
  );

  /// The periods whose return has not gone in, soonest first.
  Future<List<Map<String, dynamic>>> sstDue({int withinDays = 60}) async =>
      _rows(
        await callRpc(
          'report_sst_due',
          params: {'p_org_id': orgId, 'p_within_days': withinDays},
        ),
      );

  /// What makes up the figure for one period, split by tax type and by
  /// the basis it is due on: sales tax when the goods went, service tax
  /// when the money came, and service tax that reached twelve months
  /// without being paid for. See 0456.
  Future<List<Map<String, dynamic>>> sstReturnLines(DateTime periodEnd) async =>
      _rows(
        await callRpc(
          'sst_return_lines',
          params: {'p_org_id': orgId, 'p_period_end': Fmt.iso(periodEnd)},
        ),
      );

  /// Records that the return for a finished period was filed. The
  /// database refuses a date that is not the end of one, and refuses a
  /// period that has not ended.
  Future<void> fileSstReturn({
    required DateTime periodEnd,
    required double amount,
    String? reference,
  }) => callRpc(
    'file_sst_return',
    params: {
      'p_org_id': orgId,
      'p_period_end': Fmt.iso(periodEnd),
      'p_amount': amount,
      'p_reference': reference,
    },
  );

  // ------------------------------------------------------------------
  // What a posted payroll leaves owing
  //
  // The bank file pays the staff. These are the four bodies that took a
  // slice of the same payroll and are owed it by the fifteenth of the
  // following month. See 0457.
  // ------------------------------------------------------------------

  // -------------------------------------------------------------------
  // One payment across several companies (0462)
  // -------------------------------------------------------------------
  //
  // These three are deliberately not scoped to `orgId`. Everything else
  // on this class asks about the company that is open; a group payment
  // is the one operation whose whole point is the companies that are
  // not. The server decides what the caller may see and settle —
  // `open_documents_across_companies` filters by `app.can_post`, and
  // `payment_batch_lines` by membership — so widening the question here
  // does not widen the answer.

  /// Everything still owed across every company this person may post
  /// in. [kind] is `invoice` or `bill`.
  Future<List<Map<String, dynamic>>> openAcrossCompanies({
    String kind = 'invoice',
    String? search,
  }) async => _rows(
    await callRpc(
      'open_documents_across_companies',
      params: {'p_kind': kind, 'p_search': search},
    ),
  );

  /// Settle documents in several companies with one payment. Each entry
  /// names one document, never a company: the company is read off the
  /// document, so a line cannot say one and settle another.
  ///
  /// Returns the batch id. One call is one transaction — either every
  /// company's receipt is posted or none is.
  Future<String> recordGroupPayment({
    required DateTime paidOn,
    String? reference,
    String? note,
    required List<
      ({
        String documentId,
        bool isSales,
        double amount,
        double discount,
        String? bankAccountId,
        String? paymentModeCode,
      })
    >
    lines,
  }) async {
    final payload = [
      for (final l in lines)
        {
          if (l.isSales)
            'invoice_id': l.documentId
          else
            'bill_id': l.documentId,
          'amount': l.amount,
          if (l.discount > 0) 'discount': l.discount,
          if (l.bankAccountId != null) 'bank_account_id': l.bankAccountId,
          if (l.paymentModeCode != null) 'payment_mode_code': l.paymentModeCode,
        },
    ];
    final id = await callRpc(
      'record_group_payment',
      params: {
        'p_paid_on': Fmt.iso(paidOn),
        'p_reference': reference,
        'p_lines': payload,
        'p_note': note,
      },
    );
    return id as String;
  }

  /// The companies' own lines on one batch — only the ones the reader
  /// belongs to.
  Future<List<Map<String, dynamic>>> paymentBatchLines(String batchId) async =>
      _rows(await callRpc('payment_batch_lines', params: {'p_batch': batchId}));

  Future<List<Map<String, dynamic>>> statutoryRemittances() async => _rows(
    await callRpc(
      'report_statutory_remittances',
      params: {'p_org_id': orgId, 'p_from': null, 'p_to': null},
    ),
  );

  Future<List<Map<String, dynamic>>> statutoryDue({
    int withinDays = 30,
  }) async => _rows(
    await callRpc(
      'report_statutory_due',
      params: {'p_org_id': orgId, 'p_within_days': withinDays},
    ),
  );

  Future<void> recordStatutoryRemittance({
    required String periodId,
    required String code,
    required double amount,
    DateTime? paidOn,
    String? reference,
  }) => callRpc(
    'record_statutory_remittance',
    params: {
      'p_org_id': orgId,
      'p_period_id': periodId,
      'p_code': code,
      'p_amount': amount,
      'p_paid_on': paidOn == null ? null : Fmt.iso(paidOn),
      'p_reference': reference,
    },
  );

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
    final data = await callRpc(
      receivable ? 'report_ar_aging' : 'report_ap_aging',
      params: {'p_org_id': orgId, if (asAt != null) 'p_as_at': Fmt.iso(asAt)},
    );
    return _rows(data);
  }

  // ------------------------------------------------------------------
  // Contacts
  // ------------------------------------------------------------------
  /// The `contact_type` values a listing or picker filter stands for;
  /// null where it stands for all of them.
  ///
  /// `both` is customer *and* supplier, so it belongs in those two
  /// listings and in no others. Folding it into every filter would put
  /// every customer-and-supplier contact under Prospects, which is
  /// where the list stops meaning anything.
  ///
  /// `customer_or_prospect` is the offer's picker: a quotation or a
  /// proforma may be made to somebody you have not sold to yet -- that
  /// is who a quotation is for -- and `transfer_document` (0478) lands
  /// the accepted one on the company's customer record. It is not the
  /// invoice's picker, because an invoice records a sale and a prospect
  /// is by definition somebody there has been none to.
  static List<String>? contactTypesFor(String? type) => switch (type) {
    null || 'all' => null,
    'customer_or_prospect' => const ['customer', 'both', 'prospect'],
    final String t when t == 'customer' || t == 'supplier' => [t, 'both'],
    final String t => [t],
  };

  Future<List<Contact>> contacts({String? type, String? search}) async {
    var query = client
        .from('contacts')
        .select()
        .eq('org_id', orgId)
        .isFilter('deleted_at', null);

    final types = contactTypesFor(type);
    if (types != null) {
      query = query.inFilter('contact_type', types);
    }
    if (search != null && search.trim().isNotEmpty) {
      final q = search.trim();
      query = query.or('name.ilike.%$q%,code.ilike.%$q%,email.ilike.%$q%');
    }

    final data = await query.order('name', ascending: true).limit(200);
    return _rows(data).map(Contact.fromJson).toList();
  }

  Future<Contact> contact(String id) async {
    final data = await client.from('contacts').select().eq('id', id).single();
    return Contact.fromJson(data);
  }

  /// Creates a contact nobody typed a code for, and keeps trying until
  /// the code is one that is free.
  ///
  /// `next_document_number` counts; it does not check. A code can reach
  /// the table without ever passing through it — the CSV import writes
  /// whatever the file said, and a seeded organization arrives with
  /// contacts already numbered — so the counter can sit at 1 while
  /// `C-2026-00001` is taken, and the insert fails on
  /// `contacts_org_id_code_key`.
  ///
  /// Retried rather than pre-checked, because a check would be a guess
  /// about the moment in between. Each call to the sequence yields the
  /// next number, so a second attempt is a different code by
  /// construction; the collision also leaves the counter advanced, which
  /// is how this heals rather than repeating.
  ///
  /// Only for codes this app generates. Where a *person* typed one, a
  /// collision is theirs to see and resolve — silently filing their
  /// supplier under a different number would be worse than the error.
  Future<Contact> createContactWithGeneratedCode(Contact contact) async {
    const attempts = 5;
    for (var attempt = 1; ; attempt++) {
      String code;
      try {
        code = await nextContactCode(contact.contactType);
      } catch (_) {
        // The numbering is a convenience. A supplier with an awkward
        // code beats a scan that failed at the last step -- but in its
        // own series, so it still reads as what it is.
        code =
            '${contactCodePrefix(contact.contactType)}'
            '${DateTime.now().microsecondsSinceEpoch}';
      }

      try {
        return await saveContact(contact.withCode(code));
      } on PostgrestException catch (e) {
        final taken =
            e.code == '23505' &&
            (e.message.contains('contacts_org_id_code_key') ||
                e.message.contains('code'));
        if (!taken || attempt >= attempts) rethrow;
      }
    }
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

  /// The next code in the series for a contact of this type.
  ///
  /// One series per role -- `C-2026-00013`, `S-2026-00001`,
  /// `P-2026-00343` -- so the editor's suggestion and the record
  /// `create_contact_as` makes are numbered from the same place.
  Future<String> nextContactCode(String contactType) async {
    final v = await callRpc(
      'next_contact_code',
      params: {'p_org_id': orgId, 'p_type': contactType},
    );
    return v as String;
  }

  /// The letter each series starts with, for the fallback code when
  /// the counter cannot be reached. The same mapping the database's
  /// `app.contact_series` makes: `both` is numbered among customers.
  static String contactCodePrefix(String contactType) => switch (contactType) {
    'supplier' => 'S-',
    'prospect' => 'P-',
    _ => 'C-',
  };

  /// The other records of this company, and which roles it has no
  /// record for yet.
  ///
  /// Asked rather than worked out here: `contact_records` reads the
  /// same helper `create_contact_as` refuses on, so a menu built from
  /// this cannot offer a record the database will refuse to make.
  Future<Map<String, dynamic>> contactRecords(String contactId) async {
    final row = await callRpc(
      'contact_records',
      params: {'p_contact_id': contactId},
    );
    return Map<String, dynamic>.from(row as Map);
  }

  /// A second record of the same company, in another role.
  ///
  /// The company's details, addresses and people are copied, the code
  /// comes from that role's own series, and the record this was made
  /// from is left exactly as it was -- its code, its type and its
  /// documents. Returns the new record's id.
  Future<String> createContactAs(String contactId, String asType) async {
    final id = await callRpc(
      'create_contact_as',
      params: {'p_contact_id': contactId, 'p_type': asType},
    );
    return id as String;
  }

  /// The records already on file that carry what is being typed: the
  /// same registration number, ID, TIN or name.
  ///
  /// Each row is `{id, code, name, contact_type, matched_on,
  /// same_role}`, the ones already in [contactType] first -- those are
  /// the records a Save would duplicate. Save is not refused on this;
  /// the editor says what is on file and lets the person decide. A
  /// matching number links the saved record to the company's party on
  /// the way in, so the sheet on either shows both.
  Future<List<Map<String, dynamic>>> contactLookalikes({
    required String contactType,
    required String name,
    String? registrationNo,
    String? tin,
    String? idType,
    String? idValue,
    String? excludeId,
  }) async {
    final rows = await callRpc(
      'contact_lookalikes',
      params: {
        'p_org_id': orgId,
        'p_contact_type': contactType,
        'p_name': name,
        'p_registration_no': registrationNo,
        'p_tin': tin,
        'p_id_type': idType,
        'p_id_value': idValue,
        'p_exclude': excludeId,
      },
    );
    return _rows(rows);
  }

  /// The records already on file twice: groups of live contacts that
  /// carry the same registration number, ID or TIN and are not yet one
  /// company.
  ///
  /// What was typed before the editor started warning is not linked by
  /// anything, and no correct behaviour from now on finds it. Reported
  /// rather than linked on sight, because a registration number typed
  /// into the wrong row would otherwise put two companies' invoices on
  /// one statement.
  Future<List<Map<String, dynamic>>> contactDuplicates() async {
    final rows = await callRpc(
      'contact_duplicates',
      params: {'p_org_id': orgId},
    );
    return _rows(rows);
  }

  /// Makes the given records one company, bringing along every record
  /// already linked to any of them. Returns the party's code.
  Future<String> linkContactRecords(List<String> ids) async {
    final row = await callRpc(
      'link_contact_records',
      params: {'p_org_id': orgId, 'p_ids': ids},
    );
    return '${(row as Map)['code']}';
  }

  /// Takes one record back out of its company, for a link made on a
  /// number that turned out to be a typing mistake.
  Future<void> unlinkContactRecord(String contactId) =>
      callRpc('unlink_contact_record', params: {'p_contact_id': contactId});

  /// Whether this account may stand up another company.
  ///
  /// The first is what signing up is for; every one after it is the
  /// Multi-Company module (0486). Asked rather than worked out here so
  /// the button can be absent instead of present and refusing.
  Future<bool> canAddCompany() async {
    final v = await callRpc('can_add_company');
    return v == true;
  }

  // ------------------------------------------------------------------
  // Items
  // ------------------------------------------------------------------
  Future<List<Item>> items({String? search, bool onlyLowStock = false}) async {
    var query = client
        .from('items')
        .select()
        .eq('org_id', orgId)
        .isFilter('deleted_at', null);

    if (search != null && search.trim().isNotEmpty) {
      final q = search.trim();
      query = query.or('name.ilike.%$q%,code.ilike.%$q%,barcode.ilike.%$q%');
    }

    final data = await query.order('code', ascending: true).limit(300);
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
        .order('code', ascending: true);
    return _rows(data).map(TaxCode.fromJson).toList();
  }

  /// Add a rate this company charges.
  ///
  /// The seeded codes cover SST as it stands, which is not the same as
  /// covering every company: a rate changes in a budget, a business is
  /// exempt on one service line and not another, and until now the only
  /// way to record either was a migration.
  ///
  /// `is_default` is set through [setDefaultTaxCode] rather than here,
  /// because making one default means unmaking another and that is one
  /// operation, not two.
  ///
  /// Returns the new row's id. A picker that offered "add a tax code"
  /// has to select what was just added, and it cannot find it by name:
  /// two codes may share one.
  Future<String> createTaxCode({
    required String code,
    required String name,
    required double rate,
    String taxTypeCode = '06',
    bool isExempt = false,
    bool isInclusive = false,
    String? exemptionReason,
  }) async {
    final row = await client
        .from('tax_codes')
        .insert({
          'org_id': orgId,
          'code': code,
          'name': name,
          'rate': rate,
          'tax_type_code': taxTypeCode,
          'is_exempt': isExempt,
          'is_inclusive': isInclusive,
          'exemption_reason': exemptionReason,
        })
        .select('id')
        .single();
    return row['id'] as String;
  }

  /// [isInclusive] changes what FUTURE lines do, not what past ones
  /// did. `app.calc_document_line` resolves it onto a line when the code
  /// is chosen and leaves it there, so turning it on does not restate
  /// any document already raised — the same promise the rate makes.
  Future<void> updateTaxCode(
    String id, {
    required String code,
    required String name,
    required double rate,
    required String taxTypeCode,
    required bool isExempt,
    required bool isInclusive,
    String? exemptionReason,
  }) => client
      .from('tax_codes')
      .update({
        'code': code,
        'name': name,
        'rate': rate,
        'tax_type_code': taxTypeCode,
        'is_exempt': isExempt,
        'is_inclusive': isInclusive,
        'exemption_reason': exemptionReason,
      })
      .eq('id', id)
      .eq('org_id', orgId);

  /// Exactly one default, so the two writes go together. Clearing first
  /// and setting second: the other order leaves two defaults if the
  /// second write fails, and a document editor picking "the default"
  /// would then pick whichever came back first.
  Future<void> setDefaultTaxCode(String id) async {
    await client
        .from('tax_codes')
        .update({'is_default': false})
        .eq('org_id', orgId)
        .neq('id', id);
    await client
        .from('tax_codes')
        .update({'is_default': true})
        .eq('id', id)
        .eq('org_id', orgId);
  }

  /// Retired rather than deleted. A tax code is on every document that
  /// ever used it, and a rate that stops applying today did apply last
  /// year — the trial balance still has to explain itself.
  Future<void> retireTaxCode(String id) => client
      .from('tax_codes')
      .update({'is_active': false, 'is_default': false})
      .eq('id', id)
      .eq('org_id', orgId);

  Future<List<FiscalYear>> fiscalYears() async {
    final data = await client
        .from('fiscal_years')
        // Named because 0521 added a same-org composite key alongside
        // the plain one, so 'fiscal_periods' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, fiscal_periods!fiscal_periods_fiscal_year_id_fkey(*)')
        .eq('org_id', orgId)
        .order('start_date', ascending: false);
    return _rows(data).map(FiscalYear.fromJson).toList();
  }

  /// Creates the year after the last one. Passing a start date is only
  /// for the first year, or for a company changing its year end.
  Future<void> createFiscalYear({DateTime? startDate}) => callRpc(
    'create_fiscal_year',
    params: {
      'p_org_id': orgId,
      if (startDate != null) 'p_start_date': Fmt.iso(startDate),
    },
  );

  Future<void> setPeriodStatus(String periodId, String status) => callRpc(
    'set_fiscal_period_status',
    params: {'p_period_id': periodId, 'p_status': status},
  );

  /// Brings the year's revenue and expenses to nil and puts the result
  /// in equity. `0648`. Returns nothing: what came back is the journal
  /// id, and the screen reads the year again rather than the entry.
  Future<void> closeFiscalYear(String fiscalYearId) => callRpc(
    'close_fiscal_year',
    params: {'p_fiscal_year_id': fiscalYearId},
  );

  /// And reverses it.
  Future<void> reopenFiscalYear(String fiscalYearId) => callRpc(
    'reopen_fiscal_year',
    params: {'p_fiscal_year_id': fiscalYearId},
  );

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
        // Named because 0515 added a same-org composite key alongside
        // the plain one, so 'gl_lines' can now be joined to a journal
        // two ways and PostgREST refuses the embed with PGRST201.
        .select('*, gl_lines!gl_lines_entry_id_fkey(*, accounts(code, name))')
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
    final data = await callRpcOnce(
      'post_manual_journal',
      params: {
        'p_org_id': orgId,
        'p_entry_date': Fmt.iso(date),
        'p_lines': lines,
        'p_description': description,
        // Named even when blank. `0307`'s wrapper has no defaults, so
        // omitting this resolves to the unprotected overload without
        // saying so.
        'p_reference': _orNull(reference),
      },
    );
    return data as String;
  }

  /// Puts an approved claim into the ledger. With a bank account it is
  /// reimbursed straight away; without one it sits in accruals until it
  /// is paid.
  Future<String> postExpenseClaim(
    String claimId, {
    String? bankAccountId,
  }) async {
    final data = await callRpc(
      'post_expense_claim',
      params: {
        'p_claim_id': claimId,
        if (bankAccountId != null) 'p_bank_account_id': bankAccountId,
      },
    );
    return data as String;
  }

  /// Posts the mirror image and voids the original. Nothing is deleted:
  /// a ledger you can erase is not a ledger.
  Future<void> reverseJournal(String entryId, DateTime on) => callRpc(
    'reverse_gl_entry',
    params: {'p_entry_id': entryId, 'p_date': Fmt.iso(on)},
  );

  Future<List<Account>> accounts({bool postableOnly = false}) async {
    var query = client
        .from('accounts')
        .select()
        .eq('org_id', orgId)
        .isFilter('deleted_at', null);
    if (postableOnly) query = query.eq('is_group', false);
    final data = await query.order('code', ascending: true);
    return _rows(data).map(Account.fromJson).toList();
  }

  Future<List<Map<String, dynamic>>> paymentTerms() async {
    final data = await client
        .from('payment_terms')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('days', ascending: true);
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> classificationCodes() async {
    final data = await client
        .from('ref_classification_codes')
        .select()
        .eq('is_active', true)
        .order('code', ascending: true);
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> uomCodes() async {
    final data = await client
        .from('ref_uom_codes')
        .select()
        .eq('is_active', true)
        .order('code', ascending: true);
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> states() async {
    final data = await client.from('ref_states').select().order('code', ascending: true);
    return _rows(data);
  }

  /// Why a supply is exempt, in LHDN's own list.
  ///
  /// `ref_exemption_reasons` was seeded in `0011` with the Sales Tax
  /// and Service Tax exemption orders, and nothing read it — so a tax
  /// code could be marked exempt and `tax_codes.exemption_reason`
  /// stayed null, which is the field `0015_einvoice_prepare` carries
  /// onto the e-Invoice line as `tax_exemption_reason`.
  Future<List<Map<String, dynamic>>> exemptionReasons() async => _rows(
    await client
        .from('ref_exemption_reasons')
        .select('code, description')
        .eq('is_active', true)
        .order('code', ascending: true),
  );

  /// The MSIC 2008 business activity codes SSM registers a company
  /// under.
  ///
  /// `ref_msic_codes` has been in `0002` since the second migration,
  /// seeded in `0011`, with a trigram index on the description so it
  /// can be searched by what a business actually does. Nothing read
  /// it: the onboarding form declared an `_msicCode` that nothing ever
  /// set, and the company card asked for the five digits in a free-text
  /// box.
  Future<List<Map<String, dynamic>>> msicCodes() async => _rows(
    await client
        .from('ref_msic_codes')
        .select('code, description, category')
        .eq('is_active', true)
        .order('code', ascending: true),
  );

  // ------------------------------------------------------------------
  // Foreign exchange
  // ------------------------------------------------------------------
  Future<List<Currency>> currencies() async {
    final data = await client
        .from('ref_currencies')
        .select()
        .eq('is_active', true)
        .order('code', ascending: true);
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
      final data = await callRpc(
        'exchange_rate_for',
        params: {
          'p_org_id': orgId,
          'p_currency': currency,
          'p_on_date': Fmt.iso(onDate),
        },
      );
      return Fmt.toDouble(data);
    } on PostgrestException catch (e) {
      if (e.code == 'P0002') return null;
      rethrow;
    }
  }

  // ------------------------------------------------------------------
  // Recurring journals
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> recurringJournals() async => _rows(
    await client
        .from('recurring_journals')
        .select()
        .eq('org_id', orgId)
        .order('name', ascending: true),
  );

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
    final data = await callRpc(
      'run_recurring_journals_for',
      params: {'p_org_id': orgId, if (on != null) 'p_on': Fmt.iso(on)},
    );
    return (data as num?)?.toInt() ?? 0;
  }

  // ------------------------------------------------------------------
  // Recurring invoices and bills
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> recurringDocuments() async => _rows(
    await client
        .from('recurring_documents')
        .select()
        .eq('org_id', orgId)
        .order('is_active', ascending: false)
        .order('next_run_date', ascending: true),
  );

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
    final data = await callRpc(
      'create_recurring_document',
      params: {
        'p_document_id': documentId,
        'p_name': name,
        'p_frequency': frequency,
        'p_start_date': Fmt.iso(startDate),
        'p_interval_count': intervalCount,
        if (endDate != null) 'p_end_date': Fmt.iso(endDate),
        if (maxOccurrences != null) 'p_max_occurrences': maxOccurrences,
        'p_auto_post': autoPost,
        'p_auto_email': autoEmail,
      },
    );
    return data as String;
  }

  /// Re-snapshots the schedule from another document — last month's
  /// invoice with the new price on it.
  Future<void> updateRecurringTemplate({
    required String id,
    required String documentId,
  }) async {
    await callRpc(
      'update_recurring_template',
      params: {'p_id': id, 'p_document_id': documentId},
    );
  }

  Future<void> saveRecurringDocument(
    String id,
    Map<String, dynamic> patch,
  ) async {
    await client.from('recurring_documents').update(patch).eq('id', id);
  }

  Future<void> deleteRecurringDocument(String id) async {
    await client.from('recurring_documents').delete().eq('id', id);
  }

  /// Raises whatever is due now rather than waiting for the nightly
  /// job. Returns how many documents it made.
  Future<int> runRecurringDocuments({DateTime? on}) async {
    final data = await callRpc(
      'run_recurring_documents_for',
      params: {'p_org_id': orgId, if (on != null) 'p_on': Fmt.iso(on)},
    );
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
    final data = await callRpc(
      contacts ? 'import_contacts' : 'import_items',
      params: {'p_org_id': orgId, 'p_rows': rows, 'p_commit': commit},
    );
    return _rows(data);
  }

  /// A chart of accounts from a file (0550).
  ///
  /// Its own method rather than a third flag on [importRows], because
  /// it asks for a different permission: a chart decides what every
  /// future posting lands on, so the server wants `can_post` where the
  /// contact list wants `can_write`.
  Future<List<Map<String, dynamic>>> importAccounts({
    required List<Map<String, String>> rows,
    required bool commit,
  }) async {
    final data = await callRpc(
      'import_accounts',
      params: {'p_org_id': orgId, 'p_rows': rows, 'p_commit': commit},
    );
    return _rows(data);
  }

  /// The open invoices and bills a company arrives with.
  ///
  /// `asAt` is the changeover — the day the ledger takes these balances
  /// on. Every entry in the run carries it, while each document keeps
  /// the date it was actually raised so the ageing is right. 0150 says
  /// why at length.
  Future<List<Map<String, dynamic>>> importOpenItems({
    required bool invoices,
    required List<Map<String, String>> rows,
    required DateTime asAt,
    required bool commit,
  }) async {
    final data = await callRpc(
      invoices ? 'import_open_invoices' : 'import_open_bills',
      params: {
        'p_org_id': orgId,
        'p_rows': rows,
        'p_as_at': Fmt.iso(asAt),
        'p_commit': commit,
      },
    );
    return _rows(data);
  }

  /// A file of transactions from the old system: one row per LINE,
  /// grouped by document number.
  ///
  /// 0631. Sales invoices, credit notes and debit notes, imported as
  /// DRAFTS — this is the one importer that could create five hundred
  /// documents in a statement, and posting them would put five hundred
  /// journals in the ledger before anybody had read one.
  ///
  /// No `asAt`: unlike the open-item importers, these documents are not
  /// a changeover balance taken on one day. They are the documents
  /// themselves and each keeps its own date.
  ///
  /// Returns the per-row verdicts, the same shape every other importer
  /// here returns, so the screen reads one kind of answer.
  Future<List<Map<String, dynamic>>> importSalesTransactions({
    required List<Map<String, String>> rows,
    required bool commit,
  }) async {
    final data = await callRpc(
      'import_sales_transactions',
      params: {'p_org_id': orgId, 'p_rows': rows, 'p_commit': commit},
    );
    final map = Map<String, dynamic>.from(data as Map);
    return _rows(map['rows']);
  }

  /// The purchase side of [importSalesTransactions].
  ///
  /// 0632. The difference is `supplier_doc_no` — what is printed on the
  /// paper — and that a bill this supplier has already sent is REFUSED
  /// rather than warned about: `0628` warns on a screen where somebody
  /// can judge the match, and a file of four hundred rows has nobody
  /// looking at any one of them.
  Future<List<Map<String, dynamic>>> importPurchaseTransactions({
    required List<Map<String, String>> rows,
    required bool commit,
  }) async {
    final data = await callRpc(
      'import_purchase_transactions',
      params: {'p_org_id': orgId, 'p_rows': rows, 'p_commit': commit},
    );
    final map = Map<String, dynamic>.from(data as Map);
    return _rows(map['rows']);
  }

  /// A file of general journals from the old system.
  ///
  /// 0633, and the one importer that POSTS. A journal has no draft
  /// state the rest of the database understands — the reports filter on
  /// `posted` but `app.apply_account_balance` moves the account balance
  /// whatever the status is — so a draft journal would be absent from
  /// the trial balance and present on the chart of accounts. The dry
  /// run is what replaces the draft.
  Future<List<Map<String, dynamic>>> importJournals({
    required List<Map<String, String>> rows,
    required bool commit,
  }) async {
    final data = await callRpc(
      'import_journals',
      params: {'p_org_id': orgId, 'p_rows': rows, 'p_commit': commit},
    );
    final map = Map<String, dynamic>.from(data as Map);
    return _rows(map['rows']);
  }

  /// The opening trial balance from the old system.
  ///
  /// The control accounts are compared against the open items already
  /// imported rather than posted a second time, and the difference lands
  /// in 3900 — which comes to zero when the two agree. 0151 says why at
  /// length.
  Future<List<Map<String, dynamic>>> importOpeningBalances({
    required List<Map<String, String>> rows,
    required DateTime asAt,
    required bool commit,
  }) async => _rows(
    await callRpc(
      'import_opening_balances',
      params: {
        'p_org_id': orgId,
        'p_rows': rows,
        'p_as_at': Fmt.iso(asAt),
        'p_commit': commit,
      },
    ),
  );

  /// Opening stock quantities and costs.
  ///
  /// Writes movements and average costs and no journal at all — the
  /// inventory balance came in with the trial balance, and posting it
  /// again would double it. The last row of the answer compares the two.
  Future<List<Map<String, dynamic>>> importOpeningStock({
    required List<Map<String, String>> rows,
    required DateTime asAt,
    required bool commit,
  }) async => _rows(
    await callRpc(
      'import_opening_stock',
      params: {
        'p_org_id': orgId,
        'p_rows': rows,
        'p_as_at': Fmt.iso(asAt),
        'p_commit': commit,
      },
    ),
  );

  /// How far a migration has got: the six imports in the order they
  /// have to be done, and the balance of 3900, which is the only one of
  /// the seven that can say it is finished.
  Future<List<Map<String, dynamic>>> migrationProgress() async => _rows(
    await callRpc('report_migration_progress', params: {'p_org_id': orgId}),
  );

  /// What is left in `3900 Opening Balance Equity`, which is a
  /// migration's own arithmetic rather than a report anybody asks for.
  Future<Map<String, dynamic>?> openingBalanceSuspense() async {
    final rows = _rows(
      await callRpc(
        'report_opening_balance_suspense',
        params: {'p_org_id': orgId},
      ),
    );
    return rows.isEmpty ? null : rows.first;
  }

  // ------------------------------------------------------------------
  // Moving money between the company's own accounts
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> bankTransfers() async => _rows(
    await client
        .from('bank_transfers')
        .select(
          // The currency of each end as well as its name: the two
          // amounts are in different money on a cross-border transfer,
          // and one prefix on both would be a lie about one of them.
          '*, from_account:bank_accounts!bank_transfers_from_account_id_fkey'
          '(name, currency), '
          'to_account:bank_accounts!bank_transfers_to_account_id_fkey'
          '(name, currency)',
        )
        .eq('org_id', orgId)
        .order('transfer_date', ascending: false)
        .limit(200),
  );

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
    final id =
        await callRpc(
              'create_bank_transfer',
              params: {
                'p_from_account_id': fromAccountId,
                'p_to_account_id': toAccountId,
                'p_amount_sent': amountSent,
                'p_transfer_date': Fmt.iso(date),
                if (amountReceived != null) 'p_amount_received': amountReceived,
                'p_bank_charges': bankCharges,
                if (reference != null) 'p_reference': reference,
                if (notes != null) 'p_notes': notes,
              },
            )
            as String;
    await callRpc('post_bank_transfer', params: {'p_id': id});
    return id;
  }

  Future<void> voidBankTransfer(String id, String reason) async {
    await callRpc(
      'void_bank_transfer',
      params: {'p_id': id, 'p_reason': reason},
    );
  }

  // ------------------------------------------------------------------
  // The rest of a complete set of financial statements
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> cashFlow({
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await callRpc(
      'report_cash_flow',
      params: {'p_org_id': orgId, 'p_from': Fmt.iso(from), 'p_to': Fmt.iso(to)},
    );
    return _rows(data);
  }

  Future<List<Map<String, dynamic>>> changesInEquity({
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await callRpc(
      'report_changes_in_equity',
      params: {'p_org_id': orgId, 'p_from': Fmt.iso(from), 'p_to': Fmt.iso(to)},
    );
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
        .order('sort_order', ascending: true),
  );

  /// The CP37 listing: what was deducted, on which form, and by when it
  /// has to reach LHDN.
  Future<List<Map<String, dynamic>>> withholdingReport({
    DateTime? from,
    DateTime? to,
  }) async {
    final data = await callRpc(
      'report_withholding',
      params: {
        'p_org_id': orgId,
        if (from != null) 'p_from': Fmt.iso(from),
        if (to != null) 'p_to': Fmt.iso(to),
      },
    );
    return _rows(data);
  }

  Future<String> createWithholding({
    required String billId,
    required String whtCode,
    double? grossAmount,
    double? rate,
    DateTime? certDate,
  }) async {
    final data = await callRpc(
      'create_withholding',
      params: {
        'p_bill_id': billId,
        'p_wht_code': whtCode,
        if (grossAmount != null) 'p_gross_amount': grossAmount,
        if (rate != null) 'p_rate': rate,
        if (certDate != null) 'p_cert_date': Fmt.iso(certDate),
      },
    );
    return data as String;
  }

  Future<void> postWithholding(String id) async {
    await callRpc('post_withholding', params: {'p_id': id});
  }

  Future<void> remitWithholding({
    required String id,
    required DateTime paidOn,
    String? bankAccountId,
    String? reference,
  }) async {
    await callRpc(
      'remit_withholding',
      params: {
        'p_id': id,
        'p_paid_on': Fmt.iso(paidOn),
        if (bankAccountId != null) 'p_bank_account_id': bankAccountId,
        if (reference != null) 'p_reference': reference,
      },
    );
  }

  /// What this customer pays for this item at this quantity: a price
  /// named for their level, a level-wide percentage, or the list price.
  Future<double> itemPrice({
    required String itemId,
    String? contactId,
    double quantity = 1,
  }) async {
    final data = await callRpc(
      'item_price',
      params: {
        'p_item_id': itemId,
        if (contactId != null) 'p_contact_id': contactId,
        'p_quantity': quantity,
      },
    );
    return Fmt.toDouble(data);
  }

  Future<List<Map<String, dynamic>>> priceLevels() async => _rows(
    await client
        .from('price_levels')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('code', ascending: true),
  );

  Future<List<Map<String, dynamic>>> projects() async => _rows(
    await client
        .from('projects')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('code', ascending: true),
  );

  /// Create or amend a project.
  ///
  /// `projects` had no writer at all until `0389` — the table was
  /// reachable only from a database connection, while four screens read
  /// it and one of them said "No projects yet" with no way to make one.
  ///
  /// Returns the row's id, because a project is now also created from
  /// the box that needed one — the hour being recorded against it, the
  /// rate card being set — and that caller has to select what it made.
  Future<String> saveProject(
    Map<String, dynamic> values, {
    String? id,
  }) async {
    if (id == null) {
      final row = await client
          .from('projects')
          .insert({...values, 'org_id': orgId})
          .select('id')
          .single();
      return '${row['id']}';
    }
    await client
        .from('projects')
        .update({...values, 'updated_at': DateTime.now().toIso8601String()})
        .eq('id', id)
        .eq('org_id', orgId);
    return id;
  }

  /// Every project, with the budget beside what the ledger has against
  /// it.
  Future<List<Map<String, dynamic>>> projectBudgets({
    bool includeClosed = false,
  }) async => _rows(
    await callRpc(
      'report_project_budget',
      params: {'p_org_id': orgId, 'p_include_closed': includeClosed},
    ),
  );

  /// Close a job.
  ///
  /// Refused while billable hours on it have never been invoiced,
  /// unless [writeOff] says the decision not to charge has been taken —
  /// `0176`'s refusal for a matter holding client money, one table over.
  Future<void> closeProject(String id, {bool writeOff = false}) async {
    await callRpc(
      'close_project',
      params: {'p_project': id, 'p_write_off': writeOff},
    );
  }

  /// Reopen one. The write-off is not undone: that was a decision.
  Future<void> reopenProject(String id) async {
    await callRpc('reopen_project', params: {'p_project': id});
  }

  // ------------------------------------------------------------------
  // Stock
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> warehouses() async => _rows(
    await client
        .from('warehouses')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('code', ascending: true),
  );

  // ------------------------------------------------------------------
  // Branches
  //
  // A place the company trades from, under the same registration and the
  // same ledger. Two shops with *different* registrations are two
  // companies, not two branches — that is a group, and the database says
  // so: a trigger refuses a document that names another company's
  // branch.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> branches() async => _rows(
    await client
        .from('branches')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('code', ascending: true),
  );

  Future<void> createBranch({
    required String code,
    required String name,
    String? registrationNo,
    String? tin,
    String? sstRegistrationNo,
    String? addressLine1,
    String? postcode,
    String? city,
    String? stateCode,
    String? phone,
    String? email,
  }) => client.from('branches').insert({
    'org_id': orgId,
    'code': code,
    'name': name,
    // Null unless this branch is registered in its own right. The
    // company's own numbers are the default.
    'registration_no': _orNull(registrationNo),
    'tin': _orNull(tin),
    'sst_registration_no': _orNull(sstRegistrationNo),
    'address_line1': _orNull(addressLine1),
    'postcode': _orNull(postcode),
    'city': _orNull(city),
    'state_code': _orNull(stateCode),
    'phone': _orNull(phone),
    'email': _orNull(email),
  });

  Future<void> updateBranch(
    String id, {
    required String code,
    required String name,
    String? registrationNo,
    String? tin,
    String? sstRegistrationNo,
    String? addressLine1,
    String? postcode,
    String? city,
    String? stateCode,
    String? phone,
    String? email,
  }) => client
      .from('branches')
      .update({
        'code': code,
        'name': name,
        'registration_no': _orNull(registrationNo),
        'tin': _orNull(tin),
        'sst_registration_no': _orNull(sstRegistrationNo),
        'address_line1': _orNull(addressLine1),
        'postcode': _orNull(postcode),
        'city': _orNull(city),
        'state_code': _orNull(stateCode),
        'phone': _orNull(phone),
        'email': _orNull(email),
      })
      .eq('id', id)
      .eq('org_id', orgId);

  Future<void> setDefaultBranch(String id) async {
    await client
        .from('branches')
        .update({'is_default': false})
        .eq('org_id', orgId)
        .neq('id', id);
    await client
        .from('branches')
        .update({'is_default': true})
        .eq('id', id)
        .eq('org_id', orgId);
  }

  /// Closed rather than deleted. Documents point at it, and a branch
  /// that shut last year still has to explain last year's takings.
  Future<void> retireBranch(String id) => client
      .from('branches')
      .update({'is_active': false, 'is_default': false})
      .eq('id', id)
      .eq('org_id', orgId);

  // ------------------------------------------------------------------
  // The group of companies this one belongs to
  //
  // Separate registrations mean separate companies, each filing its own
  // return. A group names the ones with the same owner. It does not
  // merge ledgers and does not let anybody read a company they are not
  // already a member of.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> groupCompanies() async =>
      _rows(await callRpc('my_group_companies', params: {'p_org_id': orgId}));

  Future<String> createCompanyGroup(String name) async {
    final row = await client
        .from('company_groups')
        .insert({'name': name, 'created_by': client.auth.currentUser?.id})
        .select('id')
        .single();
    final id = row['id'] as String;
    await joinCompanyGroup(id);
    return id;
  }

  Future<void> joinCompanyGroup(String? groupId) => callRpc(
    'join_company_group',
    params: {'p_org_id': orgId, 'p_group_id': groupId},
  );

  /// Somewhere else to keep stock.
  ///
  /// `ensure_default_warehouse` below has been making one silently since
  /// 0059 because an adjustment needs somewhere to go, and that was the
  /// only way a warehouse had ever come into existence: a company with
  /// two shops could see "Main" and had no way to add the second.
  ///
  /// Returns the row it wrote, because a warehouse is now also created
  /// from the box that needed it — a transfer whose destination is not
  /// on the list yet — and that caller has to select the thing it just
  /// made. A caller that only wanted the side effect can ignore it.
  Future<Map<String, dynamic>> createWarehouse({
    required String code,
    required String name,
    String? addressLine1,
    String? city,
    String? postcode,
    String? stateCode,
  }) async => Map<String, dynamic>.from(
    await client
        .from('warehouses')
        .insert({
          'org_id': orgId,
          'code': code,
          'name': name,
          'address_line1': _orNull(addressLine1),
          'city': _orNull(city),
          'postcode': _orNull(postcode),
          'state_code': _orNull(stateCode),
        })
        .select()
        .single(),
  );

  Future<void> updateWarehouse(
    String id, {
    required String code,
    required String name,
    String? addressLine1,
    String? city,
    String? postcode,
    String? stateCode,
  }) => client
      .from('warehouses')
      .update({
        'code': code,
        'name': name,
        'address_line1': _orNull(addressLine1),
        'city': _orNull(city),
        'postcode': _orNull(postcode),
        'state_code': _orNull(stateCode),
      })
      .eq('id', id)
      .eq('org_id', orgId);

  /// Exactly one default, so both writes go together — same reasoning as
  /// the tax codes: the other order leaves two defaults behind a failed
  /// write, and whatever reads "the default" would take the first.
  Future<void> setDefaultWarehouse(String id) async {
    await client
        .from('warehouses')
        .update({'is_default': false})
        .eq('org_id', orgId)
        .neq('id', id);
    await client
        .from('warehouses')
        .update({'is_default': true})
        .eq('id', id)
        .eq('org_id', orgId);
  }

  /// Closed rather than deleted. Stock movements point at it, and a
  /// warehouse that shut last year still explains where things went.
  Future<void> retireWarehouse(String id) => client
      .from('warehouses')
      .update({'is_active': false, 'is_default': false})
      .eq('id', id)
      .eq('org_id', orgId);

  /// The warehouse a new adjustment is filed against, created if the
  /// organization has none — `warehouses` being empty is not a state the
  /// client can do anything about on its own.
  Future<String> ensureDefaultWarehouse() async {
    final data = await callRpc(
      'ensure_default_warehouse',
      params: {'p_org_id': orgId},
    );
    return data as String;
  }

  /// What the books think is on the shelf, which is what a stock take
  /// sheet opens on.
  Future<List<Map<String, dynamic>>> stockOnHand({String? warehouseId}) async =>
      _rows(
        await callRpc(
          'stock_on_hand',
          params: {
            'p_org_id': orgId,
            if (warehouseId != null) 'p_warehouse_id': warehouseId,
          },
        ),
      );

  /// Every movement of one item in order, with a running quantity and
  /// value — the answer to "the shelf says 44 and the screen says 47".
  ///
  /// Membership is the only bar: a storekeeper who cannot read the
  /// general ledger still has to be able to account for stock.
  Future<List<Map<String, dynamic>>> stockCard({
    required String itemId,
    DateTime? from,
    DateTime? to,
    String? warehouseId,
  }) async => _rows(
    await callRpc(
      'report_stock_card',
      params: {
        'p_org_id': orgId,
        'p_item_id': itemId,
        if (from != null) 'p_from': Fmt.iso(from),
        if (to != null) 'p_to': Fmt.iso(to),
        if (warehouseId != null) 'p_warehouse_id': warehouseId,
      },
    ),
  );

  Future<List<Map<String, dynamic>>> stockAdjustments({int limit = 50}) async =>
      _rows(
        await client
            .from('stock_adjustments')
            .select()
            .eq('org_id', orgId)
            .order('adjustment_date', ascending: false)
            .limit(limit),
      );

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
          },
      ]);
    }
    return id;
  }

  Future<String> postStockAdjustment(String id) async {
    final data = await callRpc('post_stock_adjustment', params: {'p_id': id});
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
    return _rows(await q.order('transaction_date', ascending: true));
  }

  /// Imports statement lines, skipping any already on the account.
  /// Returns {'imported': n, 'skipped': n}.
  Future<Map<String, dynamic>> importBankTransactions(
    String bankAccountId,
    List<Map<String, dynamic>> rows,
  ) async {
    final data = await callRpc(
      'import_bank_transactions',
      params: {'p_bank_account_id': bankAccountId, 'p_rows': rows},
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<List<Map<String, dynamic>>> suggestBankMatches(
    String transactionId,
  ) async => _rows(
    await callRpc(
      'suggest_bank_matches',
      params: {'p_transaction_id': transactionId},
    ),
  );

  Future<void> matchBankTransaction({
    required String transactionId,
    required String sourceTable,
    required String sourceId,
  }) => callRpc(
    'match_bank_transaction',
    params: {
      'p_transaction_id': transactionId,
      'p_source_table': sourceTable,
      'p_source_id': sourceId,
    },
  );

  Future<void> unmatchBankTransaction(String transactionId) => callRpc(
    'unmatch_bank_transaction',
    params: {'p_transaction_id': transactionId},
  );

  /// Book balance, unpresented items, and what is left over.
  Future<Map<String, dynamic>> bankReconciliationStatus({
    required String bankAccountId,
    required DateTime asAt,
    required double statementBalance,
  }) async {
    final data = await callRpc(
      'bank_reconciliation_status',
      params: {
        'p_bank_account_id': bankAccountId,
        'p_as_at': Fmt.iso(asAt),
        'p_statement_balance': statementBalance,
      },
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<String> completeBankReconciliation({
    required String bankAccountId,
    required DateTime statementDate,
    required double statementBalance,
  }) async {
    final data = await callRpc(
      'complete_bank_reconciliation',
      params: {
        'p_bank_account_id': bankAccountId,
        'p_statement_date': Fmt.iso(statementDate),
        'p_statement_balance': statementBalance,
      },
    );
    return data as String;
  }

  /// What stands in the way of closing this account, if anything. Read
  /// this before offering the button: the database refuses a sole owner,
  /// and a button that always fails is worse than no button.
  Future<List<Map<String, dynamic>>> accountDeletionBlockers() async =>
      _rows(await callRpc('my_account_deletion_blockers'));

  /// Closes the signed-in account: the identity disappears from
  /// `profiles` and `auth.users`, every membership stops conferring
  /// anything, push tokens go and every session is killed.
  ///
  /// Nothing is deleted. Roughly a hundred audit columns — who posted
  /// this journal, who approved that payroll — reference the user row,
  /// and a ledger that cannot say who posted an entry is not evidence
  /// of anything. Since 0619 the identity MOVES into a table only the
  /// platform console can read, rather than being overwritten, which is
  /// also the only way back.
  ///
  /// [closeSoleOwnedCompanies] answers the one refusal: a person who is
  /// the last owner of a company cannot simply leave, because the
  /// company would be left with nobody able to administer it. Passing
  /// true closes those companies with them, each recorded as its own
  /// closure.
  Future<Map<String, dynamic>> closeMyAccount({
    String? reason,
    bool closeSoleOwnedCompanies = false,
  }) async {
    final data = await callRpc(
      'close_my_account',
      params: {
        'p_reason': reason,
        'p_close_sole_owned': closeSoleOwnedCompanies,
      },
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// 0158's name for the same thing, kept for callers that pass nothing.
  Future<Map<String, dynamic>> deleteMyAccount() => closeMyAccount();

  /// Closes a company. Its books stay exactly where they are and stop
  /// being visible to anybody but the platform console, which is also
  /// the only way back. Owner only.
  Future<Map<String, dynamic>> closeOrganization(
    String orgId, {
    String? reason,
  }) async {
    final data = await callRpc(
      'close_organization',
      params: {'p_org_id': orgId, 'p_reason': reason},
    );
    return Map<String, dynamic>.from(data as Map);
  }


  /// Every reconciliation closed on an account, newest first, with the
  /// number of statement lines each one closed over — which is what
  /// tells a real reconciliation from one that agreed nothing.
  Future<List<Map<String, dynamic>>> bankReconciliations({
    String? bankAccountId,
  }) async => _rows(
    await callRpc(
      'report_bank_reconciliations',
      params: {
        'p_org_id': orgId,
        if (bankAccountId != null) 'p_bank_account_id': bankAccountId,
      },
    ),
  );

  /// Undoes the most recent reconciliation on its account: the lines go
  /// back to matched-but-unclosed and the record goes, because a
  /// reconciliation that was reopened did not happen.
  Future<void> reopenBankReconciliation(String id) async {
    await callRpc('reopen_bank_reconciliation', params: {'p_id': id});
  }

  // ------------------------------------------------------------------
  // Fixed assets
  // ------------------------------------------------------------------
  Future<List<FixedAsset>> fixedAssets({bool includeDisposed = false}) async {
    var q = client
        .from('fixed_assets')
        // Named because 0512 added a same-org composite key alongside
        // the plain one, so 'contacts' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        // Named because 0518 added a same-org composite key alongside
        // the plain one, so 'purchase_documents' can now be joined two
        // ways and PostgREST refuses the embed with PGRST201.
        .select('*, purchase_documents!fixed_assets_purchase_document_id_fkey(doc_no), contacts!fixed_assets_supplier_id_fkey(name)')
        .eq('org_id', orgId)
        .isFilter('deleted_at', null);
    if (!includeDisposed) q = q.neq('status', 'disposed');
    final data = await q.order('asset_no', ascending: true);
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

  /// Makes a fixed asset out of a posted bill line.
  ///
  /// The cost, the acquisition date, the supplier and the account come
  /// from the line rather than being asked for again — which is the
  /// point: `purchase_document_id` was a column nothing wrote, so the
  /// register and the fixed asset accounts had no way to be compared,
  /// and a typo in the cost went unnoticed for the life of the asset.
  Future<String> capitaliseBillLine(
    String lineId, {
    required String assetNo,
    String? name,
    String? category,
    String method = 'straight_line',
    int? usefulLifeMonths,
    num? ratePercent,
    num residualValue = 0,
  }) async {
    final id = await callRpc(
      'capitalise_bill_line',
      params: {
        'p_line': lineId,
        'p_asset_no': assetNo,
        'p_name': name,
        'p_category': category,
        'p_method': method,
        'p_useful_life_months': usefulLifeMonths,
        'p_rate_percent': ratePercent,
        'p_residual_value': residualValue,
      },
    );
    return id.toString();
  }

  /// Posted bill lines coded to a fixed asset account with nothing in
  /// the register against them.
  Future<List<Map<String, dynamic>>> uncapitalisedPurchases({
    DateTime? asAt,
  }) async => _rows(
    await callRpc(
      'report_uncapitalised_purchases',
      params: {'p_org': orgId, 'p_as_at': asAt == null ? null : Fmt.iso(asAt)},
    ),
  );

  /// What a customer would save by paying early, and by when.
  ///
  /// `payment_terms.discount_percent` and `discount_days` have been
  /// columns since `0003` and nothing read either, so the eight seeded
  /// terms were a settlement discount scheme that never existed.
  Future<Map<String, dynamic>?> settlementDiscount(
    String documentId, {
    DateTime? asAt,
  }) async {
    final rows = _rows(
      await callRpc(
        'settlement_discount_available',
        params: {
          'p_document': documentId,
          'p_as_at': asAt == null ? null : Fmt.iso(asAt),
        },
      ),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Allocates a receipt against an invoice, taking a settlement
  /// discount if one is on offer.
  ///
  /// An RPC and not an insert into `payment_allocations`, because the
  /// discount has to reach the ledger in the same breath.
  /// `app.apply_allocation` clears the invoice by cash *plus* discount
  /// and `post_receipt` credits the receivable by the cash alone, so a
  /// discount written straight into the table would settle the document
  /// and leave the control account overstated by it, permanently.
  Future<String> allocateWithDiscount({
    required String receiptId,
    required String invoiceId,
    required num amount,
    num? discount,
  }) async {
    final id = await callRpc(
      'allocate_with_discount',
      params: {
        'p_receipt': receiptId,
        'p_invoice': invoiceId,
        'p_amount': amount,
        'p_discount': discount,
      },
    );
    return id.toString();
  }

  /// The purchase side of the same thing: Dr Payable, Cr Other Income.
  Future<String> allocatePaymentWithDiscount({
    required String paymentId,
    required String billId,
    required num amount,
    num? discount,
  }) async {
    final id = await callRpc(
      'allocate_payment_with_discount',
      params: {
        'p_payment': paymentId,
        'p_bill': billId,
        'p_amount': amount,
        'p_discount': discount,
      },
    );
    return id.toString();
  }

  /// What a run would charge, per asset, before anything is posted.
  Future<List<DepreciationLine>> depreciationPreview(DateTime asAt) async {
    final data = await callRpc(
      'depreciation_preview',
      params: {'p_org_id': orgId, 'p_as_at': Fmt.iso(asAt)},
    );
    return _rows(data).map(DepreciationLine.fromJson).toList();
  }

  /// Posts the charge. Null when every asset is already up to date —
  /// which is what running it twice looks like.
  Future<String?> runDepreciation(DateTime asAt) async {
    final data = await callRpc(
      'run_depreciation',
      params: {'p_org_id': orgId, 'p_as_at': Fmt.iso(asAt)},
    );
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
    final data = await callRpc(
      'dispose_fixed_asset',
      params: {
        'p_asset_id': assetId,
        'p_date': Fmt.iso(on),
        'p_proceeds': proceeds,
        if (bankAccountId != null) 'p_bank_account_id': bankAccountId,
      },
    );
    return data as String;
  }

  /// Every charge against one asset in order — what the auditor asks
  /// for when a net book value has to be explained.
  Future<List<Map<String, dynamic>>> depreciationHistory(
    String assetId,
  ) async => _rows(
    await callRpc(
      'report_depreciation_history',
      params: {'p_org_id': orgId, 'p_asset_id': assetId},
    ),
  );

  /// The fixed asset note: cost and accumulated depreciation brought
  /// forward, what came in and out, the charge, and the carrying amount,
  /// by category.
  Future<List<Map<String, dynamic>>> assetMovements({
    DateTime? from,
    DateTime? to,
  }) async => _rows(
    await callRpc(
      'report_asset_movements',
      params: {
        'p_org_id': orgId,
        if (from != null) 'p_from': Fmt.iso(from),
        if (to != null) 'p_to': Fmt.iso(to),
      },
    ),
  );

  /// What the open foreign balances would be restated to, one row per
  /// currency. Raises if a currency has no rate on file at that date,
  /// rather than reporting a confident zero for one it cannot price.
  Future<List<FxRevaluation>> fxRevaluationPreview(DateTime asAt) async {
    final data = await callRpc(
      'fx_revaluation_preview',
      params: {'p_org_id': orgId, 'p_as_at': Fmt.iso(asAt)},
    );
    return _rows(data).map(FxRevaluation.fromJson).toList();
  }

  /// Posts the restatement, returning the journal id — or null when
  /// there was nothing to restate.
  Future<String?> revalueForeignBalances(DateTime asAt) async {
    final data = await callRpc(
      'revalue_foreign_balances',
      params: {'p_org_id': orgId, 'p_as_at': Fmt.iso(asAt)},
    );
    return data as String?;
  }

  /// Deferred revenue that has not been released yet, one row per
  /// period end — the shape `recognise_revenue` posts in.
  ///
  /// Everything unposted, not only what is due today: the card splits
  /// the list on whichever date is chosen, so moving that date costs
  /// nothing and what is still to come stays visible beside what is
  /// about to post.
  Future<List<RevenueDue>> revenueScheduleDue() async {
    final data = await callRpc(
      'revenue_schedule_due',
      params: {'p_org_id': orgId},
    );
    return _rows(data).map(RevenueDue.fromJson).toList();
  }

  /// Releases what has been earned up to a date, returning how many
  /// journals were posted. Safe to press twice: a period already
  /// carrying an entry is skipped.
  Future<int> recogniseRevenue(DateTime upto) async {
    final data = await callRpc(
      'recognise_revenue',
      params: {'p_org_id': orgId, 'p_upto': Fmt.iso(upto)},
    );
    return (data as num?)?.toInt() ?? 0;
  }

  /// Every currency this organization could use, with the rate that is
  /// actually in force and where it came from.
  ///
  /// `exchangeRateFor` answers one currency and says nothing about
  /// provenance, which is right for pricing a document and useless for
  /// answering "why is this the rate?". A currency with nothing on file
  /// comes back with a null rate rather than being left out — that row
  /// is the one that will refuse to post.
  Future<List<Map<String, dynamic>>> exchangeRateBoard([
    DateTime? onDate,
  ]) async => _rows(
    await callRpc(
      'exchange_rate_board',
      params: {
        'p_org_id': orgId,
        'p_on_date': Fmt.iso(onDate ?? DateTime.now()),
      },
    ),
  );

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
  }) => client.from('exchange_rates').upsert({
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
        .select('*, ${kind.contactEmbed}(name, code)')
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
        .select(
          '*, ${kind.contactEmbed}(name, code), ${kind.lineEmbed}(*)',
        )
        .eq('id', id)
        .single();
    return BusinessDocument.fromJson(data);
  }

  Future<String> nextDocumentNumber(String docType) async {
    final data = await callRpc(
      'next_document_number',
      params: {'p_org_id': orgId, 'p_doc_type': docType},
    );
    return data as String;
  }

  /// Every series of the modules the company has, as it is set --
  /// prefix, suffix, padding, reset policy, next number, last issued --
  /// with a `sample` of what the next draw will return. Composed by the
  /// server the way the draw composes it, and draws nothing: a settings
  /// screen opened twice numbers nothing twice.
  Future<List<Map<String, dynamic>>> documentNumbering() async {
    final data = await callRpc(
      'document_numbering',
      params: {'p_org_id': orgId},
    );
    return _rows(data);
  }

  /// Set a series. Admin only. Returns the sample of the next number.
  ///
  /// The server refuses a next number below the last one issued while
  /// the prefix, suffix and reset policy stay the same -- those numbers
  /// are on documents already -- and says which number that was.
  Future<String> setDocumentNumbering({
    required String docType,
    required String prefix,
    required String suffix,
    required int padding,
    required String resetPolicy,
    required int nextValue,
  }) async {
    final sample = await callRpc(
      'set_document_numbering',
      params: {
        'p_org_id': orgId,
        'p_doc_type': docType,
        'p_prefix': prefix,
        'p_suffix': suffix,
        'p_padding': padding,
        'p_reset_policy': resetPolicy,
        'p_next_value': nextValue,
      },
    );
    return sample as String;
  }

  /// Creates or replaces a document and its lines. Lines are deleted and
  /// re-inserted so the header totals are recomputed by the database
  /// triggers rather than trusted from the client.
  /// Saves a document, and returns its id AND the number it now carries.
  ///
  /// The number comes back because a NEW document is not numbered until
  /// this call: `next_document_number` advances a counter, and a
  /// document that draws its number when the editor OPENS burns one
  /// every time somebody changes their mind. Gaps in a sales invoice
  /// series are what an auditor asks about. The caller therefore does
  /// not know what the document is called until it is saved, and this
  /// is where it finds out.
  Future<({String id, String docNo})> saveDocument({
    required DocKind kind,
    String? id,
    required String docType,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> lines,
  }) async {
    String documentId;
    String documentNo = (header['doc_no'] as String?) ?? '';

    if (id == null) {
      // Drawn HERE, one statement before the insert that uses it, and
      // only when the caller has not already got one. A number drawn
      // and then not used is a gap; the window for that is now a failed
      // insert rather than an abandoned draft.
      if (documentNo.isEmpty) documentNo = await nextDocumentNumber(docType);
      final payload = {
        ...header,
        'org_id': orgId,
        'doc_type': docType,
        'doc_no': documentNo,
      };
      final row = await client
          .from(kind.table)
          .insert(payload)
          .select()
          .single();
      documentId = row['id'] as String;
      documentNo = row['doc_no'] as String? ?? documentNo;
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
          },
      ]);
    }

    return (id: documentId, docNo: documentNo);
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
  Future<List<Map<String, dynamic>>> einvoiceCredentialStatus() async => _rows(
    await callRpc('einvoice_credential_status', params: {'p_org_id': orgId}),
  );

  /// Leave [clientSecret] null to keep the stored one, which is what
  /// makes correcting a typo in the client id safe.
  Future<void> setEinvoiceCredentials({
    required String environment,
    required String clientId,
    String? clientSecret,
  }) => callRpc(
    'set_einvoice_credentials',
    params: {
      'p_org_id': orgId,
      'p_environment': environment,
      'p_client_id': clientId,
      'p_client_secret': clientSecret,
    },
  );

  Future<void> clearEinvoiceCredentials(String environment) => callRpc(
    'clear_einvoice_credentials',
    params: {'p_org_id': orgId, 'p_environment': environment},
  );

  /// Reads a signing certificate, proves the key matches it, and — unless
  /// [checkOnly] — puts it on file.
  ///
  /// `0615`. Through the edge function rather than through an RPC,
  /// because something has to PARSE the certificate: the serial, the
  /// issuer and the expiry are in the DER, and the one parser in this
  /// product is `supabase/functions/_shared/der.ts`. It is also the only
  /// place that can answer the question worth asking while somebody is
  /// still pasting — does this key match this certificate — which
  /// otherwise arrives from LHDN hours later as a code naming neither.
  ///
  /// Neither PEM comes back. What comes back is what the certificate
  /// SAYS: the issuer, the serial, and when it stops working.
  Future<Map<String, dynamic>> saveEinvoiceCertificate({
    required String certificatePem,
    required String privateKeyPem,
    String? environment,
    bool checkOnly = false,
  }) => callMyInvois('certificate', {
    'certificate_pem': certificatePem,
    'private_key_pem': privateKeyPem,
    if (environment != null) 'environment': environment,
    if (checkOnly) 'check_only': true,
  });

  /// Takes the signing certificate off one environment, leaving the
  /// client id and secret — which is what you do when a certificate is
  /// about to expire and the new one has not arrived.
  Future<void> clearEinvoiceSigningCertificate(String environment) => callRpc(
    'clear_einvoice_signing_certificate',
    params: {'p_org_id': orgId, 'p_environment': environment},
  );

  /// Which version this company files at. The database refuses 1.1
  /// without a certificate on file, because a 1.1 document that cannot
  /// be signed is a submit button that stops working.
  Future<void> setEinvoiceVersion(String version) => callRpc(
    'set_einvoice_version',
    params: {'p_org_id': orgId, 'p_version': version},
  );

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
  }) async => _rows(
    await client
        .from(kind.lineTable)
        .select('id, line_no')
        .eq('document_id', documentId)
        .order('line_no', ascending: true),
  );

  /// Every lot allocation on a document, keyed by line id.
  Future<Map<String, List<Map<String, dynamic>>>> lotsForDocument({
    required DocKind kind,
    required List<String> lineIds,
  }) async {
    if (lineIds.isEmpty) return {};
    final column = kind.isSales ? 'sales_line_id' : 'purchase_line_id';
    final rows = _rows(
      await client
          .from('document_line_lots')
          .select()
          .inFilter(column, lineIds)
          .order('lot_ref', ascending: true),
    );
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
    final data = await callRpc(
      'set_line_lots',
      params: {'p_line_table': lineTable, 'p_line_id': lineId, 'p_lots': lots},
    );
    return (data as num?)?.toInt() ?? 0;
  }

  Future<List<Map<String, dynamic>>> lineLots({
    required String lineTable,
    required String lineId,
  }) async => _rows(
    await callRpc(
      'line_lots',
      params: {'p_line_table': lineTable, 'p_line_id': lineId},
    ),
  );

  /// What still has to be named before this document can post. Empty
  /// means it is ready.
  Future<List<Map<String, dynamic>>> documentLotProblems({
    required String documentId,
    required bool sales,
  }) async => _rows(
    await callRpc(
      'document_lot_problems',
      params: {
        'p_document_id': documentId,
        'p_kind': sales ? 'sales' : 'purchase',
      },
    ),
  );

  /// First expired, first out. Advisory — a physical pick is a physical
  /// fact, and refusing the box in somebody's hand gets worked around.
  Future<List<Map<String, dynamic>>> suggestLots({
    required String itemId,
    String? warehouseId,
    required double quantity,
  }) async => _rows(
    await callRpc(
      'suggest_lots',
      params: {
        'p_item_id': itemId,
        'p_warehouse_id': warehouseId,
        'p_quantity': quantity,
      },
    ),
  );

  Future<List<Map<String, dynamic>>> lotBalances({String? itemId}) async =>
      _rows(
        await callRpc(
          'report_lot_balances',
          params: {
            'p_org_id': orgId,
            'p_item_id': itemId,
            'p_warehouse_id': null,
          },
        ),
      );

  Future<List<Map<String, dynamic>>> expiringStock({
    int withinDays = 90,
  }) async => _rows(
    await callRpc(
      'report_expiring_stock',
      params: {'p_org_id': orgId, 'p_within_days': withinDays},
    ),
  );

  /// Where a batch came from and everywhere it went — the recall
  /// question, and the only thing that justifies typing batch numbers.
  Future<List<Map<String, dynamic>>> traceLot(String lotId) async => _rows(
    await callRpc('trace_lot', params: {'p_org_id': orgId, 'p_lot_id': lotId}),
  );

  // ------------------------------------------------------------------
  // Manufacturing
  //
  // Three things, in the order somebody sets them up: what a thing is
  // made of, where the work happens, and an order to make some. The
  // arithmetic all lives in the database — `confirm_manufacturing_order`
  // takes the snapshot and `post_manufacturing_order` moves the stock
  // and writes the journal in one transaction — so nothing here computes
  // a cost.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> billsOfMaterials() async => _rows(
    await client
        .from('bills_of_materials')
        // Named because 0513 added a same-org composite key alongside
        // the plain one, so 'items' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, items!bills_of_materials_item_id_fkey(code, name)')
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('code', ascending: true),
  );

  Future<Map<String, dynamic>> billOfMaterials(String id) async =>
      Map<String, dynamic>.from(
        await client
            .from('bills_of_materials')
            .select(
              '*, items!bills_of_materials_item_id_fkey(code, name), '
              'bom_lines!bom_lines_bom_id_fkey(*, items!bom_lines_item_id_fkey(code, name)), '
              'bom_operations!bom_operations_bom_id_fkey(*, work_centres(code, name, cost_per_hour))',
            )
            .eq('id', id)
            .eq('org_id', orgId)
            .single(),
      );

  /// Header and both sets of children in one call. The lines are deleted
  /// and re-inserted rather than merged: a recipe is short, and the
  /// alternative is reconciling three lists by hand for no gain.
  Future<String> saveBillOfMaterials({
    String? id,
    required String code,
    required String itemId,
    String? name,
    required num outputQuantity,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> operations,
  }) async {
    final header = {
      'org_id': orgId,
      'code': code,
      'item_id': itemId,
      'name': _orNull(name),
      'output_quantity': outputQuantity,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };

    final String bomId;
    if (id == null) {
      final row = await client
          .from('bills_of_materials')
          .insert(header)
          .select('id')
          .single();
      bomId = row['id'] as String;
    } else {
      bomId = id;
      await client
          .from('bills_of_materials')
          .update(header)
          .eq('id', id)
          .eq('org_id', orgId);
      await client.from('bom_lines').delete().eq('bom_id', id);
      await client.from('bom_operations').delete().eq('bom_id', id);
    }

    if (lines.isNotEmpty) {
      await client.from('bom_lines').insert([
        for (var i = 0; i < lines.length; i++)
          {
            'org_id': orgId,
            'bom_id': bomId,
            'line_no': i + 1,
            'item_id': lines[i]['item_id'],
            'quantity': lines[i]['quantity'],
            'scrap_percent': lines[i]['scrap_percent'] ?? 0,
          },
      ]);
    }
    if (operations.isNotEmpty) {
      await client.from('bom_operations').insert([
        for (var i = 0; i < operations.length; i++)
          {
            'org_id': orgId,
            'bom_id': bomId,
            'step_no': i + 1,
            'work_centre_id': operations[i]['work_centre_id'],
            'name': operations[i]['name'],
            'minutes': operations[i]['minutes'],
          },
      ]);
    }
    return bomId;
  }

  /// Retired rather than deleted: orders already posted against it are
  /// what explains last quarter's cost of sales.
  Future<void> retireBillOfMaterials(String id) => client
      .from('bills_of_materials')
      .update({'is_active': false})
      .eq('id', id)
      .eq('org_id', orgId);

  Future<List<Map<String, dynamic>>> workCentres() async => _rows(
    await client
        .from('work_centres')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('code', ascending: true),
  );

  /// Returns the row's id, so a work centre made from the box that
  /// wanted one can be selected there.
  Future<String> saveWorkCentre({
    String? id,
    required String code,
    required String name,
    num costPerHour = 0,
    num capacityHoursPerDay = 8,
  }) async {
    final payload = {
      'code': code,
      'name': name,
      'cost_per_hour': costPerHour,
      'capacity_hours_per_day': capacityHoursPerDay,
    };
    if (id == null) {
      final row = await client
          .from('work_centres')
          .insert({'org_id': orgId, ...payload})
          .select('id')
          .single();
      return '${row['id']}';
    }
    await client
        .from('work_centres')
        .update(payload)
        .eq('id', id)
        .eq('org_id', orgId);
    return id;
  }

  Future<void> retireWorkCentre(String id) => client
      .from('work_centres')
      .update({'is_active': false})
      .eq('id', id)
      .eq('org_id', orgId);

  Future<List<Map<String, dynamic>>> manufacturingOrders({
    bool openOnly = false,
  }) async {
    var q = client
        .from('manufacturing_orders')
        // Named because 0513 added a same-org composite key alongside
        // the plain one, so 'items' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        // Named because 0520 added a same-org composite key alongside
        // the plain one, so 'bills_of_materials' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, items!manufacturing_orders_item_id_fkey(code, name), bills_of_materials!manufacturing_orders_bom_id_fkey(code)')
        .eq('org_id', orgId);
    if (openOnly) {
      q = q.inFilter('status', ['draft', 'confirmed', 'in_progress']);
    }
    return _rows(await q.order('created_at', ascending: false));
  }

  Future<Map<String, dynamic>> manufacturingOrder(String id) async =>
      Map<String, dynamic>.from(
        await client
            .from('manufacturing_orders')
            .select(
              '*, items!manufacturing_orders_item_id_fkey(code, name), '
              'bills_of_materials!manufacturing_orders_bom_id_fkey'
              '(code, name), '
              'warehouses!manufacturing_orders_warehouse_id_fkey(code, name), '
              'mo_components!mo_components_mo_id_fkey(*, items!mo_components_item_id_fkey(code, name)), '
              'mo_operations!mo_operations_mo_id_fkey(*, work_centres(code, name, cost_per_hour))',
            )
            .eq('id', id)
            .eq('org_id', orgId)
            .single(),
      );

  Future<String> createManufacturingOrder({
    required String bomId,
    required String itemId,
    required String warehouseId,
    required num quantity,
    DateTime? plannedStart,
    DateTime? plannedFinish,
    String? notes,
  }) async {
    final row = await client
        .from('manufacturing_orders')
        .insert({
          'org_id': orgId,
          'order_no': await nextDocumentNumber('manufacturing_order'),
          'bom_id': bomId,
          'item_id': itemId,
          'warehouse_id': warehouseId,
          'quantity': quantity,
          'planned_start': plannedStart?.toIso8601String(),
          'planned_finish': plannedFinish?.toIso8601String(),
          'notes': _orNull(notes),
          'created_by': client.auth.currentUser?.id,
        })
        .select('id')
        .single();
    return row['id'] as String;
  }

  /// Copies the recipe onto the order. A snapshot on purpose: the recipe
  /// can change tomorrow and this order was costed against today's.
  Future<void> confirmManufacturingOrder(String id) =>
      callRpc('confirm_manufacturing_order', params: {'p_mo_id': id});

  /// What is missing, in this order's own warehouse. Stock sitting in
  /// another warehouse is a transfer somebody has to make, not stock
  /// this order can consume.
  Future<List<Map<String, dynamic>>> manufacturingShortages(String id) async =>
      _rows(await callRpc('mo_shortages', params: {'p_mo_id': id}));

  /// Moves the stock and writes the journal, together or not at all.
  /// [quantityDone] short of the order is a partial run, costed
  /// proportionally.
  Future<void> postManufacturingOrder(String id, {num? quantityDone}) =>
      callRpc(
        'post_manufacturing_order',
        params: {'p_mo_id': id, 'p_quantity_done': quantityDone},
      );

  /// Time booked against a step. Where it is left at zero the plan
  /// stands in, because a shop that has not booked its hours still has
  /// to cost its output.
  Future<void> bookOperationMinutes(String operationId, num minutes) => client
      .from('mo_operations')
      .update({'actual_minutes': minutes})
      .eq('id', operationId)
      .eq('org_id', orgId);

  Future<void> cancelManufacturingOrder(String id) => client
      .from('manufacturing_orders')
      .update({'status': 'cancelled'})
      .eq('id', id)
      .eq('org_id', orgId);

  // ------------------------------------------------------------------
  // Chat
  //
  // Every read here goes through a function rather than a table, and
  // that is the point rather than a style choice: a conversation can
  // span two companies, so the rows behind it are not selectable by
  // "my org_id = this org_id" the way everything else in this file is.
  // The functions decide what crosses, and they return names and
  // avatars — never another company's records.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> chatConversations() async => _rows(
    await callRpc('chat_my_conversations', params: {'p_org_id': orgId}),
  );

  /// Who you may start a conversation with. Colleagues first, then
  /// anyone in a company yours is linked to.
  Future<List<Map<String, dynamic>>> chatDirectory() async =>
      _rows(await callRpc('chat_directory', params: {'p_org_id': orgId}));

  /// Newest first, which is the order a thread is read in and the order
  /// a reversed list view wants.
  Future<List<Map<String, dynamic>>> chatThread(
    String conversationId, {
    DateTime? before,
    int limit = 50,
  }) async => _rows(
    await callRpc(
      'chat_thread',
      params: {
        'p_conversation_id': conversationId,
        'p_before': before?.toIso8601String(),
        'p_limit': limit,
      },
    ),
  );

  Future<String> chatStartDirect(String otherUserId, String otherOrgId) async {
    final id = await callRpc(
      'chat_start_direct',
      params: {
        'p_my_org': orgId,
        'p_other_user': otherUserId,
        'p_other_org': otherOrgId,
      },
    );
    return id as String;
  }

  Future<void> chatSend(
    String conversationId,
    String body, {
    required String senderOrgId,
  }) async {
    await client.from('chat_messages').insert({
      'conversation_id': conversationId,
      'sender_id': client.auth.currentUser?.id,
      // The company you are in this conversation *as*, which the
      // database checks against your participant row rather than
      // taking on trust.
      'sender_org_id': senderOrgId,
      'body': body,
    });
    // After the insert, never before: a notification for a message that
    // failed to send is worse than a message that arrives unannounced.
    //
    // Not awaited. The message is committed and the composer should
    // clear now; making somebody watch a spinner through a round trip to
    // a notification service would be paying for other people's phones
    // with their own typing. `notifyPush` swallows its own failures.
    unawaited(notifyPush(conversationId: conversationId));
  }

  /// How long a message stays editable. Kept in step with
  /// `app.chat_edit_window()` by hand, which is a duplication worth
  /// having: the alternative is a round trip on every message drawn, and
  /// the only cost of drift is a menu item that offers an edit the
  /// database then refuses with a sentence saying why.
  static const chatEditWindow = Duration(minutes: 15);

  /// Correct a message. Refused past the window, and by the database
  /// rather than by the screen.
  Future<void> chatEditMessage(String messageId, String body) => callRpc(
    'chat_edit_message',
    params: {'p_message_id': messageId, 'p_body': body},
  );

  /// Take a message back.
  ///
  /// The row keeps its place and says it was deleted; the text and the
  /// attachment rows go. Storage is a second system with its own
  /// permissions, so the object is removed here — best effort, because
  /// the database is the authority and a file with no row is already
  /// unreachable through the app: every URL is minted from the row.
  Future<void> chatDeleteMessage(
    String messageId, {
    List<String> storagePaths = const [],
  }) async {
    await callRpc('chat_delete_message', params: {'p_message_id': messageId});
    if (storagePaths.isEmpty) return;
    try {
      await client.storage.from('chat').remove(storagePaths);
    } catch (_) {
      // See above. Reporting this as a failed delete would be a lie —
      // the message is deleted.
    }
  }

  /// A file or a voice note, which is a message rather than a decoration
  /// on one — so the row goes in first and the attachment hangs off it.
  ///
  /// The bytes go to the `chat` bucket, keyed by conversation. That is
  /// not the `attachments` bucket: that one is keyed by company and its
  /// policies read the first path segment as the tenant boundary, which
  /// is exactly what a file sent to another company must not be judged
  /// by.
  Future<void> chatSendAttachment({
    required String conversationId,
    required String senderOrgId,
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
    String caption = '',
    int? durationMs,
  }) async {
    final voice = durationMs != null;
    // Prefixed with a uuid rather than trusting the name: two people
    // sending `scan.pdf` must not collide, and a name from a phone can
    // contain anything at all.
    final path = '$conversationId/${_uuid()}-${_safeName(fileName)}';

    await client.storage
        .from('chat')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mimeType, upsert: false),
        );

    final row = await client
        .from('chat_messages')
        .insert({
          'conversation_id': conversationId,
          'sender_id': client.auth.currentUser?.id,
          'sender_org_id': senderOrgId,
          'body': caption.trim(),
          'kind': voice ? 'voice' : 'file',
        })
        .select('id')
        .single();

    await client.from('chat_attachments').insert({
      'message_id': row['id'],
      'conversation_id': conversationId,
      'file_name': fileName,
      'storage_path': path,
      'mime_type': mimeType,
      'file_size': bytes.length,
      'duration_ms': durationMs,
    });

    unawaited(notifyPush(conversationId: conversationId));
  }

  /// Short-lived, because the object is private and the policy that
  /// guards it asks whether you are in the conversation *now*.
  Future<String> chatFileUrl(String storagePath) =>
      client.storage.from('chat').createSignedUrl(storagePath, 60 * 60);

  /// Storage rejects a key with characters it cannot round-trip, and a
  /// name typed on a phone is not a key. The original is kept in
  /// `file_name` and is what the reader sees.
  static String _safeName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-');
    final trimmed = cleaned.replaceAll(RegExp(r'^-|-$'), '');
    if (trimmed.isEmpty) return 'file';
    return trimmed.length > 80 ? trimmed.substring(0, 80) : trimmed;
  }

  static String _uuid() {
    final r = Random.secure();
    return List.generate(
      16,
      (_) => r.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// A room rather than a pair. Members arrive as (user, company) pairs
  /// because a person is only reachable *as* a member of one — the same
  /// shape the directory returns.
  Future<String> chatCreateGroup({
    required String title,
    required List<Map<String, dynamic>> members,
  }) async {
    final id = await callRpc(
      'chat_create_group',
      params: {
        'p_my_org': orgId,
        'p_title': title,
        'p_members': [
          for (final m in members)
            {'user_id': m['user_id'], 'org_id': m['org_id']},
        ],
      },
    );
    return id as String;
  }

  /// Refused unless the newcomer's company is linked to *every* company
  /// already in the room — not merely to yours, which would let one
  /// company introduce a stranger into another's conversation.
  Future<void> chatAddParticipant(
    String conversationId,
    String userId,
    String userOrgId,
  ) => callRpc(
    'chat_add_participant',
    params: {
      'p_conversation_id': conversationId,
      'p_user_id': userId,
      'p_org_id': userOrgId,
    },
  );

  Future<void> chatLeave(String conversationId) =>
      callRpc('chat_leave', params: {'p_conversation_id': conversationId});

  Future<List<Map<String, dynamic>>> chatMembers(String conversationId) async =>
      _rows(
        await callRpc(
          'chat_members',
          params: {'p_conversation_id': conversationId},
        ),
      );

  // ------------------------------------------------------------------
  // Calls
  //
  // Signalling only. Every one of these moves a row and rings a phone;
  // none of them carries a byte of audio. The media goes over WebRTC to
  // the SFU named by `room_name`.
  // ------------------------------------------------------------------
  Future<String> chatStartCall(
    String conversationId, {
    bool video = false,
  }) async {
    final id =
        await callRpc(
              'chat_start_call',
              params: {
                'p_conversation_id': conversationId,
                'p_kind': video ? 'video' : 'voice',
              },
            )
            as String;
    // The one notification that is genuinely time critical: it has
    // forty-five seconds to be useful, matching `ringing_until`. Still
    // not awaited — the caller's own call screen should open now, and
    // the ring is on its way while it does.
    unawaited(
      notifyPush(
        conversationId: conversationId,
        kind: 'call',
        callId: id,
        video: video,
      ),
    );
    return id;
  }

  Future<void> chatJoinCall(String callId) =>
      callRpc('chat_join_call', params: {'p_call_id': callId});

  Future<void> chatDeclineCall(String callId) =>
      callRpc('chat_decline_call', params: {'p_call_id': callId});

  Future<void> chatLeaveCall(String callId) =>
      callRpc('chat_leave_call', params: {'p_call_id': callId});

  Future<void> chatEndCall(String callId) =>
      callRpc('chat_end_call', params: {'p_call_id': callId});

  /// The call happening in this conversation right now, if any.
  Future<Map<String, dynamic>?> chatActiveCall(String conversationId) async {
    final rows = _rows(
      await callRpc(
        'chat_active_call',
        params: {'p_conversation_id': conversationId},
      ),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Every phone that should be ringing for this person, anywhere.
  Future<List<Map<String, dynamic>>> chatIncomingCalls() async =>
      _rows(await callRpc('chat_incoming_calls'));

  // ------------------------------------------------------------------
  // Push notifications
  // ------------------------------------------------------------------

  /// Put this device on the register, or move it here.
  ///
  /// `p256dh` and `auth` are a browser's encryption keys and belong only
  /// to a web registration; 0143 refuses a web row without them and a
  /// Firebase token with them.
  Future<void> registerDevice({
    required String token,
    required String platform,
    String? label,
    String? p256dh,
    String? auth,
  }) => callRpc(
    'register_device',
    params: {
      'p_token': token,
      'p_platform': platform,
      if (label != null) 'p_label': label,
      if (p256dh != null) 'p_p256dh': p256dh,
      if (auth != null) 'p_auth': auth,
    },
  );

  Future<void> unregisterDevice(String token) =>
      callRpc('unregister_device', params: {'p_token': token});

  /// Ask for everybody else's devices to be notified.
  ///
  /// Called by the sender's own app immediately after the message or the
  /// call is committed, rather than by a database trigger — a trigger
  /// would be more robust and would mean putting a service key inside
  /// the database, which is the one thing every other decision here is
  /// arranged to avoid. See docs/push-notifications.md.
  ///
  /// Deliberately swallows everything. A notification that did not go
  /// out is not a message that did not send: the row is committed, the
  /// other person sees it the moment they open the app, and turning that
  /// into an error on the sender's screen would report a failure that
  /// did not happen.
  Future<void> notifyPush({
    required String conversationId,
    String kind = 'message',
    String? callId,
    bool video = false,
  }) async {
    try {
      await client.functions.invoke(
        'send-push',
        body: {
          'conversation_id': conversationId,
          'kind': kind,
          if (callId != null) 'call_id': callId,
          if (video) 'video': true,
        },
      );
    } catch (_) {
      // See above.
    }
  }

  /// Where the media server is and what this person may do there.
  ///
  /// Minted by an edge function because it is signed with the SFU's
  /// secret, which the database and the app must never hold. The
  /// function checks the caller is actually in the call before it signs
  /// anything — a room name is not a credential.
  Future<Map<String, dynamic>> chatCallCredentials(String callId) async {
    final res = await client.functions.invoke(
      'call-token',
      body: {'call_id': callId},
    );
    if (res.status >= 400) {
      throw Exception('The call server refused: ${res.data}');
    }
    return Map<String, dynamic>.from(res.data as Map);
  }

  // ------------------------------------------------------------------
  // Ask about your books
  // ------------------------------------------------------------------

  /// Put a question to the assistant and wait for the answer.
  ///
  /// Everything that matters is decided server-side under this session's
  /// own token: whether the company holds the module, whether there is
  /// credit, and — for every report the assistant reads — whether this
  /// person may see it. Nothing here can widen any of that, which is
  /// why the whole call is one round trip to an edge function rather
  /// than a conversation the client drives.
  Future<Map<String, dynamic>> aiAsk(
    String question, {
    String? conversationId,
  }) async {
    final res = await client.functions.invoke(
      'ask',
      body: {
        'org_id': orgId,
        'question': question,
        if (conversationId != null) 'conversation_id': conversationId,
      },
    );
    if (res.status >= 400) {
      // The refusals worth reading — no credit, module off, not your
      // conversation — are written by the database for a person, and
      // arrive here as the body. Flattening them into "the assistant
      // failed" would throw away the only useful part.
      final data = res.data;
      final message = data is Map && data['error'] is String
          ? data['error'] as String
          : '$data';
      throw Exception(message);
    }
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// This person's conversations in this company, newest first.
  Future<List<Map<String, dynamic>>> aiConversations() async {
    final rows = await callRpc(
      'ai_conversations_for',
      params: {'p_org_id': orgId},
    );
    return (rows as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
  }

  /// One conversation and everything said in it.
  Future<Map<String, dynamic>> aiConversation(String id) async {
    final row = await callRpc('ai_conversation', params: {'p_id': id});
    return Map<String, dynamic>.from(row as Map);
  }

  /// What the assistant is able to read, so the screen can say so
  /// rather than leaving somebody guessing what it knows.
  Future<List<Map<String, dynamic>>> aiTools() async {
    final rows = await callRpc(
      'ai_tool_catalogue',
      params: {'p_org_id': orgId},
    );
    return (rows as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
  }

  Future<void> chatMarkRead(String conversationId) =>
      callRpc('chat_mark_read', params: {'p_conversation_id': conversationId});

  Future<void> chatMarkDelivered(String conversationId) => callRpc(
    'chat_mark_delivered',
    params: {'p_conversation_id': conversationId},
  );

  /// Throttled by the caller to roughly one every three seconds, never
  /// per keystroke.
  Future<void> chatTypingPing(String conversationId) => callRpc(
    'chat_typing_ping',
    params: {'p_conversation_id': conversationId},
  );

  Future<void> chatTypingStop(String conversationId) => callRpc(
    'chat_typing_stop',
    params: {'p_conversation_id': conversationId},
  );

  Future<List<Map<String, dynamic>>> chatWhoIsTyping(
    String conversationId,
  ) async => _rows(
    await callRpc(
      'chat_who_is_typing',
      params: {'p_conversation_id': conversationId},
    ),
  );

  /// `idle` is the one thing the server cannot work out for itself:
  /// whether the app that is still connected is being looked at.
  Future<void> chatHeartbeat({bool idle = false}) =>
      callRpc('chat_heartbeat', params: {'p_idle': idle});

  // --- administration ---------------------------------------------

  Future<List<Map<String, dynamic>>> chatAccessList() async =>
      _rows(await callRpc('chat_access_list', params: {'p_org_id': orgId}));

  Future<void> chatSetAccess(String userId, bool enabled) => callRpc(
    'chat_set_access',
    params: {'p_org_id': orgId, 'p_user_id': userId, 'p_enabled': enabled},
  );

  Future<List<Map<String, dynamic>>> chatLinks() async =>
      _rows(await callRpc('chat_links_for', params: {'p_org_id': orgId}));

  Future<void> chatRequestLink(String targetOrgId, {String? note}) => callRpc(
    'chat_request_link',
    params: {
      'p_my_org': orgId,
      'p_target_org': targetOrgId,
      'p_note': _orNull(note),
    },
  );

  Future<void> chatDecideLink(String linkId, bool approve) => callRpc(
    'chat_decide_link',
    params: {'p_link_id': linkId, 'p_approve': approve},
  );

  Future<void> chatRevokeLink(String linkId) =>
      callRpc('chat_revoke_link', params: {'p_link_id': linkId});

  // ------------------------------------------------------------------
  // Salespeople
  //
  // Their own table rather than a pointer at a user, because the person
  // who won the order does not always have a login — and until 0105 the
  // column insisted they did, against `auth.users`, which is global and
  // so did not even keep one organization's documents from naming
  // another's people.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> salespeople({
    bool activeOnly = false,
  }) async {
    var q = client.from('salespeople').select().eq('org_id', orgId);
    if (activeOnly) q = q.eq('is_active', true);
    return _rows(await q.order('name', ascending: true));
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
  }) async => _rows(
    await callRpc(
      'report_sales_by_person',
      params: {'p_org_id': orgId, 'p_from': Fmt.iso(from), 'p_to': Fmt.iso(to)},
    ),
  );

  /// What is still available to take forward from this document into a
  /// [targetType], line by line.
  Future<List<TransferLine>> transferOutstanding(
    String documentId,
    String targetType,
  ) async {
    final data = await callRpc(
      'transfer_outstanding',
      params: {'p_source_id': documentId, 'p_target_type': targetType},
    );
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
    final data = await callRpc(
      'transfer_document',
      params: {
        'p_source_id': sourceId,
        'p_target_type': targetType,
        if (lines != null)
          'p_lines': [
            for (final l in lines)
              {'line_id': l.lineId, 'quantity': l.quantity},
          ],
      },
    );
    return data as String;
  }

  Future<void> deleteDocument(DocKind kind, String id) => client
      .from(kind.table)
      .update({'deleted_at': DateTime.now().toIso8601String()})
      .eq('id', id);

  /// Posts a document. [rpc] overrides the one for its kind, which is
  /// how a goods received note reaches `post_goods_received` — that one
  /// accrues what is owed rather than recording it as payable, and
  /// `post_purchase_document` refuses it by name.
  Future<String> postDocument(DocKind kind, String id, {String? rpc}) async {
    final data = await callRpc(rpc ?? kind.postRpc, params: {'p_id': id});
    return data as String;
  }

  Future<void> voidSalesDocument(String id, String reason) =>
      callRpc('void_sales_document', params: {'p_id': id, 'p_reason': reason});

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
    required List<({String documentId, double amount, double discount})>
    allocations,
    String? bankAccountId,
    String? paymentModeCode,
    /// Which of the company's own payment methods this is. Null on
    /// every settlement before 0635 and on any company that has
    /// configured none; the bank charge then resolves to the company
    /// default and then to account 6300, exactly as it always did.
    String? paymentMethodId,
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
          'payment_method_id': paymentMethodId,
          'reference': reference,
        })
        .select()
        .single();

    final settlementId = row['id'] as String;

    // Every allocation goes through the function, discounted or not.
    // Writing them straight into `payment_allocations` was the path
    // that could carry a discount nothing posted — `0385`'s guard
    // refuses that now, and one path means the discount cannot be
    // written by a route that forgets the journal.
    for (final a in allocations) {
      if (isReceipt) {
        await allocateWithDiscount(
          receiptId: settlementId,
          invoiceId: a.documentId,
          amount: a.amount,
          discount: a.discount > 0 ? a.discount : null,
        );
      } else {
        await allocatePaymentWithDiscount(
          paymentId: settlementId,
          billId: a.documentId,
          amount: a.amount,
          discount: a.discount > 0 ? a.discount : null,
        );
      }
    }

    await callRpc(
      isReceipt ? 'post_receipt' : 'post_purchase_payment',
      params: {'p_id': settlementId},
    );
  }

  /// Open documents for a contact, used by the settlement dialog.
  /// What is still open against one contact, for the statement.
  ///
  /// **Not invoices alone.** This asked for `doc_type = 'invoice'` until
  /// it was noticed that a credit note, a debit note and a refund note
  /// all move the receivable and none of them appeared — on a document
  /// that goes to the customer. Somebody holding a credit note was sent
  /// a statement that overstated what they owed, and it disagreed with
  /// `report_ar_aging`, which signs all four correctly.
  ///
  /// The sign is not applied here. These rows are returned as the
  /// ledger stores them — `balance_amount` is positive on a credit note
  /// too — and [statementSign] in `features/contacts/statement.dart`
  /// decides what each type does to the total. A repository that
  /// negated a column would be answering a question about presentation.
  ///
  /// Unapplied receipts are still absent and are a different shape: a
  /// receipt is not a document and has no row in this table. They are
  /// on the brought-forward statement (`report_statement_of_account`,
  /// 0624), which is where they belong.
  ///
  /// This is the OPEN-ITEM statement: what is still outstanding, one
  /// line per document. The brought-forward one is a different report
  /// and both are legitimate; what neither of them is, is a list of
  /// documents that were never issued.
  Future<List<BusinessDocument>> outstandingFor({
    required DocKind kind,
    required String contactId,
  }) async {
    final data = await client
        .from(kind.table)
        .select('*, ${kind.contactEmbed}(name, code)')
        .eq('org_id', orgId)
        .eq('contact_id', contactId)
        .inFilter(
          'doc_type',
          kind.isSales
              ? const ['invoice', 'credit_note', 'debit_note', 'refund_note']
              : const [
                  'bill',
                  'purchase_credit_note',
                  'purchase_debit_note',
                  'purchase_return',
                ],
        )
        .gt('balance_amount', 0)
        // POSTED, and not voided. Both were missing, and both reached
        // the PDF that goes to the customer.
        //
        // A DRAFT invoice carries its full `balance_amount` from the
        // moment its lines are typed -- measured, not assumed -- so a
        // quote somebody was still working on was sent out as money
        // due. A VOIDED one keeps its balance too: `void_sales_document`
        // sets the status and reverses the ledger entry and never
        // touches the column, because nothing else had ever read it
        // without also asking whether the document was real.
        //
        // These two conditions are `report_ar_aging`'s and
        // `report_ap_aging`'s, word for word -- `d.gl_entry_id is not
        // null and d.status <> 'void'`. The ageing report and the
        // statement are the same open-item question asked twice, and
        // the day they disagree the customer's ledger disagrees with
        // ours. `statement_of_account.sql` asserts they do not.
        //
        // `purchase_return` needs no separate exclusion: it cannot
        // post -- `post_purchase_document_internal` refuses it by name
        // -- so it can never carry a `gl_entry_id` and falls out here.
        .not('gl_entry_id', 'is', null)
        .neq('status', 'void')
        .isFilter('deleted_at', null)
        .order('doc_date', ascending: true);
    return _rows(data).map(BusinessDocument.fromJson).toList();
  }

  // ------------------------------------------------------------------
  // Bank rules (0625)
  //
  // Read and write the table directly, behind its policies, which is
  // what this repository does for master data everywhere else. The
  // policies are `can_read_ledger` to see and `can_post` to change, so
  // a clerk who may not post the books cannot rewrite what a bank line
  // means.
  // ------------------------------------------------------------------

  /// Every rule, in the order they are tried.
  Future<List<Map<String, dynamic>>> bankRules() async => _rows(
    await client
        .from('bank_rules')
        .select('*, accounts!bank_rules_account_same_org(code, name), '
            'contacts!bank_rules_contact_same_org(name)')
        .eq('org_id', orgId)
        .order('sort_order', ascending: true)
        .order('id', ascending: true),
  );

  /// How many unclaimed lines each rule would take, and how many the
  /// rules explain nothing about. Two calls rather than one because
  /// the second is a single number and the screen shows it even while
  /// the list is still loading.
  Future<List<Map<String, dynamic>>> bankRuleCoverage({
    String? bankAccountId,
  }) async => _rows(
    await callRpc(
      'bank_rule_coverage',
      params: {'p_org_id': orgId, 'p_bank_account_id': bankAccountId},
    ),
  );

  Future<int> bankLinesUnexplained({String? bankAccountId}) async {
    final data = await callRpc(
      'bank_lines_unexplained',
      params: {'p_org_id': orgId, 'p_bank_account_id': bankAccountId},
    );
    return (data as num?)?.toInt() ?? 0;
  }

  /// What the rules say one line is. Null when nothing describes it.
  Future<Map<String, dynamic>?> suggestBankCoding(String transactionId) async {
    final rows = _rows(
      await callRpc('suggest_bank_coding',
          params: {'p_transaction_id': transactionId}),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Save a rule. [id] null inserts.
  ///
  /// The empty strings are turned into nulls here rather than in the
  /// form, because `bank_rules_says_something` counts a null as "no
  /// condition" and an empty string as one that matches everything —
  /// and a rule that silently matches every line is the worst thing a
  /// rule can be.
  Future<String> saveBankRule({
    String? id,
    required String name,
    int sortOrder = 100,
    bool isActive = true,
    String? bankAccountId,
    String? direction,
    String? descriptionContains,
    String? referenceContains,
    double? amountMin,
    double? amountMax,
    String? accountId,
    String? contactId,
    String? taxCodeId,
    String? memo,
  }) async {
    String? trimmed(String? v) {
      final t = v?.trim();
      return (t == null || t.isEmpty) ? null : t;
    }

    final values = {
      'org_id': orgId,
      'name': name.trim(),
      'sort_order': sortOrder,
      'is_active': isActive,
      'bank_account_id': bankAccountId,
      'direction': trimmed(direction),
      'description_contains': trimmed(descriptionContains),
      'reference_contains': trimmed(referenceContains),
      'amount_min': amountMin,
      'amount_max': amountMax,
      'account_id': accountId,
      'contact_id': contactId,
      'tax_code_id': taxCodeId,
      'memo': trimmed(memo),
    };

    final row = id == null
        ? await client.from('bank_rules').insert(values).select('id').single()
        : await client
              .from('bank_rules')
              .update(values)
              .eq('id', id)
              .select('id')
              .single();
    return '${row['id']}';
  }

  Future<void> deleteBankRule(String id) =>
      client.from('bank_rules').delete().eq('id', id);

  /// Add or amend a bank account.
  ///
  /// 0529. One call, because a bank account is TWO rows that must not
  /// disagree: the `bank_accounts` row every screen picks from, and the
  /// GL account the ledger posts to. The function makes the GL account
  /// itself unless one is named, so a company with three banks gets
  /// three lines on its balance sheet rather than one.
  Future<String> upsertBankAccount({
    required String name,
    String? bankName,
    String? bankCode,
    String? accountNumber,
    String accountType = 'current',
    String currency = 'MYR',
    String? accountId,
    String? id,
  }) async {
    final data = await callRpc(
      'upsert_bank_account',
      params: {
        'p_name': name,
        'p_bank_name': _orNull(bankName),
        'p_bank_code': _orNull(bankCode),
        'p_account_number': _orNull(accountNumber),
        'p_account_type': accountType,
        'p_currency': currency,
        'p_account_id': accountId,
        'p_id': id,
        'p_org_id': id == null ? orgId : null,
      },
    );
    return data as String;
  }

  Future<List<Map<String, dynamic>>> bankAccounts() async {
    final data = await client
        .from('bank_accounts')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('name', ascending: true);
    return _rows(data);
  }

  /// Rebuild an account's cached balance from the posted ledger.
  ///
  /// Returns the figure it wrote, so the caller can say whether it
  /// moved. `0175` guards it with `app.can_post`; the screen hides the
  /// action from anybody else, which is a convenience rather than the
  /// control.
  Future<double> resyncBankBalance(String bankAccountId) async {
    final data = await client.rpc(
      'resync_bank_balance',
      params: {'p_bank_account_id': bankAccountId},
    );
    return Fmt.toDouble(data);
  }

  Future<List<Map<String, dynamic>>> paymentModes() async {
    final data = await client
        .from('ref_payment_modes')
        .select()
        .eq('is_active', true)
        .order('code', ascending: true);
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
    // payee is asked for by constraint name, which is the answer that
    // comment used to only describe.
    final data = await client
        .from('expenses')
        // Named because 0514 added a same-org composite key alongside
        // the plain one, so 'accounts' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select(
          '*, accounts!expenses_account_id_fkey(code, name), '
          'contacts!expenses_contact_id_fkey(name)',
        )
        .eq('org_id', orgId)
        .isFilter('deleted_at', null)
        .order('expense_date', ascending: false)
        .limit(limit);
    return _rows(data);
  }

  /// One expense with everything a payment voucher prints.
  ///
  /// A separate read from [expenses] because of the double foreign key
  /// that list comment describes: an expense points at `contacts`
  /// twice, so the payee has to be asked for by constraint name or
  /// PostgREST refuses the whole request rather than choosing.
  Future<Map<String, dynamic>?> expenseForVoucher(String id) async {
    final row = await client
        .from('expenses')
        .select(
          '*, accounts!expenses_account_id_fkey(code, name), '
          'bank_accounts!expenses_bank_account_id_fkey(name), '
          'contacts!expenses_contact_id_fkey(name)',
        )
        .eq('org_id', orgId)
        .eq('id', id)
        .maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  /// Creates an expense and posts it in one step — expenses are always
  /// money already spent, so there is no useful draft state.
  /// Returns the id of the expense created, so a receipt photographed
  /// before it existed can be filed against it.
  Future<String> recordExpense({
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
    String? projectCode,
    String? departmentCode,
    List<Map<String, dynamic>>? split,
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
          // The two analysis dimensions. `project_code` has been on
          // this table since the dimensions went in and nothing ever
          // sent it; `department_code` arrived with 0639. Both null is
          // the ordinary case and posts exactly as it always has.
          'project_code': projectCode,
          'department_code': departmentCode,
        })
        .select()
        .single();

    // Before posting, and only before: `set_expense_split` refuses an
    // expense that is already in the ledger, because what a posted
    // expense was for is a journal and not an edit. It also writes the
    // header's amount, tax and account from the lines, so the figures
    // sent above are a first draft the split then corrects.
    if (split != null && split.isNotEmpty) {
      await callRpc('set_expense_split',
          params: {'p_expense_id': row['id'], 'p_lines': split});
    }

    await callRpc('post_expense', params: {'p_id': row['id']});
    return row['id'].toString();
  }

  // ------------------------------------------------------------------
  // A pile at a time
  // ------------------------------------------------------------------

  /// Post many sales documents. Comes back a row per document saying
  /// whether it went and, when it did not, what the database said —
  /// see 0500. One document failing is not the batch failing.
  Future<List<Map<String, dynamic>>> bulkPostDocuments(
          List<String> ids) async =>
      Repo._rows(
        await callRpc('bulk_post_documents', params: {'p_ids': ids}),
      );

  Future<List<Map<String, dynamic>>> bulkEmailDocuments(List<String> ids,
          {String template = 'document_new'}) async =>
      Repo._rows(
        await callRpc('bulk_email_documents',
            params: {'p_ids': ids, 'p_template_code': template}),
      );

  // ------------------------------------------------------------------
  // What is waiting for somebody
  // ------------------------------------------------------------------

  /// The caller's notifications for this company. Unread only unless
  /// asked otherwise; the row level policy decides whose they are.
  Future<List<Map<String, dynamic>>> myNotifications(
          {bool includeRead = false}) async =>
      Repo._rows(await callRpc('my_notifications',
          params: {'p_org': orgId, 'p_include_read': includeRead}));

  Future<int> unreadNotifications() async {
    final n = await callRpc('unread_notifications', params: {'p_org': orgId});
    return (n as num?)?.toInt() ?? 0;
  }

  Future<void> markNotificationRead(String id) =>
      callRpc('mark_notification_read', params: {'p_id': id});

  Future<void> dismissNotification(String id) =>
      callRpc('dismiss_notification', params: {'p_id': id});

  Future<int> markAllNotificationsRead() async {
    final n =
        await callRpc('mark_all_notifications_read', params: {'p_org': orgId});
    return (n as num?)?.toInt() ?? 0;
  }

  /// What one expense was divided into, with each account named.
  Future<List<Map<String, dynamic>>> expenseSplit(String expenseId) async =>
      Repo._rows(
        await callRpc('expense_split', params: {'p_expense_id': expenseId}),
      );

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
    final res = await client.functions.invoke(
      'myinvois',
      body: {'action': action, 'org_id': orgId, ...payload},
    );

    final data = res.data;
    if (data is Map && data['error'] != null) {
      throw MyInvoisException(data['error'].toString(), data['details']);
    }
    return Map<String, dynamic>.from(data as Map);
  }

  /// Submits an e-Invoice to MyInvois.
  ///
  /// [purchaseDocumentId] is the SELF-BILLED path: the e-Invoice a buyer
  /// owes LHDN for a supply the seller cannot file. Same submission,
  /// different preparation, and on that one the supplier block holds the
  /// supplier rather than this company. Name one or the other, never
  /// both.
  Future<Map<String, dynamic>> submitEinvoice({
    String? salesDocumentId,
    String? purchaseDocumentId,
    List<String>? einvoiceIds,
  }) => callMyInvois('submit', {
    if (salesDocumentId != null) 'sales_document_id': salesDocumentId,
    if (purchaseDocumentId != null) 'purchase_document_id': purchaseDocumentId,
    if (einvoiceIds != null) 'einvoice_ids': einvoiceIds,
  });

  /// Says whether a bill owes LHDN a self-billed e-Invoice. The database
  /// refuses once one has been submitted — that is cancelled at
  /// MyInvois, not un-ticked here.
  Future<void> setRequiresSelfBilled(String documentId, bool required) =>
      callRpc(
        'set_requires_self_billed',
        params: {'p_document_id': documentId, 'p_required': required},
      );

  /// Turns a month's rolled-up till sales into the one e-Invoice LHDN
  /// wants for them, and returns its id.
  ///
  /// `0616`. Separate from the rollup because they are separate
  /// decisions: gathering the month is bookkeeping and filing it is a
  /// statutory submission, and until now the second did not exist at
  /// all — `einvoice_consolidations.einvoice_id` was never written by
  /// anything.
  Future<String> prepareConsolidatedEinvoice(String consolidationId) async {
    final out = await callRpc(
      'prepare_consolidated_einvoice',
      params: {'p_consolidation_id': consolidationId},
    );
    return '$out';
  }

  Future<Map<String, dynamic>> refreshEinvoiceStatus({List<String>? ids}) =>
      callMyInvois('status', {if (ids != null) 'einvoice_ids': ids});

  Future<Map<String, dynamic>> cancelEinvoice(String id, String reason) =>
      callMyInvois('cancel', {'einvoice_id': id, 'reason': reason});

  Future<Map<String, dynamic>> validateTin({
    required String tin,
    required String idType,
    required String idValue,
    String? contactId,
  }) => callMyInvois('validate-tin', {
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
        .order('sort_order', ascending: true);
    return _rows(data).map(PipelineStage.fromJson).toList();
  }

  Future<List<Opportunity>> opportunities({String? status = 'open'}) async {
    var query = client
        .from('opportunities')
        // The constraint is named because `sales_documents.opportunity_id`
        // points back at `opportunities`, so PostgREST can join these two
        // tables either way round and refuses to guess (PGRST201).
        .select(
          '*, contacts!opportunities_contact_id_fkey(name), '
          'sales_documents!opportunities_quotation_id_fkey(doc_no)',
        )
        .eq('org_id', orgId)
        .isFilter('deleted_at', null);
    if (status != null && status != 'all') query = query.eq('status', status);
    final data = await query.order('created_at', ascending: false).limit(300);
    return _rows(data).map(Opportunity.fromJson).toList();
  }

  /// Sales orders past the delivery date they were given, with what is
  /// still unshipped. The reader `delivery_date` never had.
  Future<List<Map<String, dynamic>>> lateOrders({DateTime? asAt}) async =>
      _rows(
        await callRpc(
          'report_late_orders',
          params: {
            'p_org_id': orgId,
            'p_as_at': asAt == null ? null : Fmt.iso(asAt),
          },
        ),
      );

  /// Puts a new date on a quotation or proforma whose price has run out.
  Future<void> extendDocumentValidity(String id, DateTime validUntil) =>
      callRpc(
        'extend_document_validity',
        params: {'p_document': id, 'p_valid_until': Fmt.iso(validUntil)},
      );

  Future<void> moveOpportunity(String id, String stageId) =>
      client.from('opportunities').update({'stage_id': stageId}).eq('id', id);

  /// Raises a quotation from a deal and links the two.
  ///
  /// An RPC and not two writes, because the whole point is that the
  /// pipeline figure and the quoted figure start as one number.
  /// `opportunities.quotation_id` carried a comment saying it was set
  /// when this happened and nothing set it, so the forecast came off
  /// one figure and the invoice off another.
  Future<String> quoteOpportunity(
    String opportunityId, {
    DateTime? validUntil,
    String? description,
  }) async {
    final id = await callRpc(
      'quote_opportunity',
      params: {
        'p_opportunity': opportunityId,
        'p_valid_until': validUntil == null ? null : Fmt.iso(validUntil),
        'p_description': description,
      },
    );
    return id.toString();
  }

  /// Attaches a quotation that already exists, or detaches the one
  /// there is. Attaching takes the deal's figure from the document:
  /// that is the priced answer, and the deal's was a guess.
  Future<void> linkOpportunityQuotation(
    String opportunityId,
    String? documentId,
  ) => callRpc(
    'link_opportunity_quotation',
    params: {'p_opportunity': opportunityId, 'p_document': documentId},
  );

  /// Open deals whose figure no longer matches the quotation attached
  /// to them — which is exactly what a forecast is silently wrong by.
  Future<List<Map<String, dynamic>>> pipelineQuoteMismatch() async => _rows(
    await callRpc('report_pipeline_quote_mismatch', params: {'p_org': orgId}),
  );

  /// Closes a deal, with the reason the pipeline never asked for.
  ///
  /// Not `moveOpportunity` to a closed column: that writes the status
  /// and the close date and nothing else, which is how
  /// `won_reason`/`lost_reason`/`competitor` stayed empty from `0008`
  /// until `0373`. Lost and abandoned are refused without a reason.
  Future<void> closeOpportunity({
    required String id,
    required String outcome,
    String? reason,
    String? competitor,
    DateTime? closedOn,
  }) => callRpc(
    'close_opportunity',
    params: {
      'p_opportunity': id,
      'p_outcome': outcome,
      'p_reason': reason,
      'p_competitor': competitor,
      'p_closed_on': closedOn == null ? null : Fmt.iso(closedOn),
    },
  );

  /// Puts a closed deal back on the board, in an open column.
  Future<void> reopenOpportunity(String id, {String? stageId}) => callRpc(
    'reopen_opportunity',
    params: {'p_opportunity': id, 'p_stage': stageId},
  );

  /// Why deals closed, by outcome and reason, with the money and the
  /// competitors named. The thing the reasons are collected for.
  Future<List<Map<String, dynamic>>> winLoss({
    required DateTime from,
    required DateTime to,
  }) async => _rows(
    await callRpc(
      'report_win_loss',
      params: {'p_org_id': orgId, 'p_from': Fmt.iso(from), 'p_to': Fmt.iso(to)},
    ),
  );

  Future<void> closeLead(String id, String reason) =>
      callRpc('close_lead', params: {'p_lead': id, 'p_reason': reason});

  Future<void> reopenLead(String id) =>
      callRpc('reopen_lead', params: {'p_lead': id});

  Future<void> saveOpportunity(
    Map<String, dynamic> values, {
    String? id,
  }) async {
    final payload = {...values, 'org_id': orgId};
    if (id == null) {
      payload['opportunity_no'] = await nextDocumentNumber('opportunity');
      await client.from('opportunities').insert(payload);
    } else {
      await client.from('opportunities').update(values).eq('id', id);
    }
  }

  Future<List<Map<String, dynamic>>> activities({
    bool onlyPending = true,
  }) async {
    var query = client
        .from('activities')
        // Named because 0512 added a same-org composite key alongside
        // the plain one, so 'contacts' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        // Named because 0520 added a same-org composite key alongside
        // the plain one, so 'opportunities' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, contacts!activities_contact_id_fkey(name), opportunities!activities_opportunity_id_fkey(name)')
        .eq('org_id', orgId);
    if (onlyPending) query = query.eq('status', 'pending');
    final data = await query.order('due_date', ascending: true).limit(100);
    return _rows(data);
  }

  // ------------------------------------------------------------------
  // The list you keep beside the books
  //
  // 0526. Personal, and written straight through PostgREST: there is no
  // RPC because there is no rule a function would enforce that row
  // level security does not. `user_id` is the signed-in user's own on
  // every write, because the policy accepts nothing else.
  // ------------------------------------------------------------------

  /// Open items first, soonest due first, undated last — the order the
  /// dashboard card and the list screen both show. `done` asks for the
  /// cleared ones instead.
  Future<List<Todo>> todos({bool done = false, int limit = 100}) async {
    final uid = client.auth.currentUser?.id;
    if (uid == null) return const [];
    var query = client
        .from('todos')
        .select()
        .eq('org_id', orgId)
        .eq('user_id', uid);
    query = done ? query.not('done_at', 'is', null) : query.isFilter('done_at', null);
    final data = await query
        .order('due_date', ascending: true, nullsFirst: false)
        .order('created_at', ascending: true)
        .limit(limit);
    return _rows(data).map(Todo.fromJson).toList();
  }

  Future<void> addTodo({
    required String title,
    String? notes,
    DateTime? dueDate,
    String priority = 'normal',
    String? link,
  }) async {
    final uid = client.auth.currentUser?.id;
    if (uid == null) return;
    await client.from('todos').insert({
      'org_id': orgId,
      'user_id': uid,
      'title': title.trim(),
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
      if (dueDate != null) 'due_date': Fmt.iso(dueDate),
      'priority': priority,
      if (link != null && link.isNotEmpty) 'link': link,
    });
  }

  Future<void> updateTodo(
    String id, {
    String? title,
    String? notes,
    DateTime? dueDate,
    bool clearDueDate = false,
    String? priority,
  }) async {
    await client
        .from('todos')
        .update({
          if (title != null) 'title': title.trim(),
          if (notes != null) 'notes': notes.trim().isEmpty ? null : notes.trim(),
          if (clearDueDate)
            'due_date': null
          else if (dueDate != null)
            'due_date': Fmt.iso(dueDate),
          if (priority != null) 'priority': priority,
        })
        .eq('id', id);
  }

  /// Clearing an item records WHEN, so "what did I finish yesterday"
  /// has an answer. Putting it back is the same call the other way.
  Future<void> setTodoDone(String id, bool done) async {
    await client
        .from('todos')
        .update({'done_at': done ? DateTime.now().toIso8601String() : null})
        .eq('id', id);
  }

  Future<void> deleteTodo(String id) async {
    await client.from('todos').delete().eq('id', id);
  }

  // ------------------------------------------------------------------
  // Where you land when you sign in
  //
  // 0527. One row per person, not per company, so this does not go
  // through `orgId` at all.
  // ------------------------------------------------------------------

  /// The defaults when nothing has been saved. A person who has never
  /// opened the settings screen has no row, and that is not an error.
  Future<UserPreferences> userPreferences() async {
    final uid = client.auth.currentUser?.id;
    if (uid == null) return const UserPreferences();
    final data = await client
        .from('user_preferences')
        .select()
        .eq('user_id', uid)
        .maybeSingle();
    if (data == null) return const UserPreferences();
    return UserPreferences.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> saveUserPreferences(UserPreferences prefs) async {
    final uid = client.auth.currentUser?.id;
    if (uid == null) return;
    await client.from('user_preferences').upsert({
      'user_id': uid,
      'landing_route': prefs.landingRoute,
      'dashboard_cards': prefs.dashboardCards,
    }, onConflict: 'user_id');
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
    await client.storage
        .from('logos')
        .uploadBinary(
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
        .update({'logo_url': versioned})
        .eq('id', orgId);
    return versioned;
  }

  Future<void> removeOrgLogo() async {
    await client.storage.from('logos').remove([_logoPath]);
    await client
        .from('organizations')
        .update({'logo_url': null})
        .eq('id', orgId);
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
    final data = await callRpc(
      'customer_credit_status',
      params: {'p_contact_id': contactId},
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// off | warn | block — what happens when an invoice would take a
  /// customer past their limit.
  Future<void> setCreditControl(String mode) => client
      .from('organizations')
      .update({'credit_control': mode})
      .eq('id', orgId);

  /// The company's own particulars.
  ///
  /// RLS lets an owner or administrator through — `organizations_update`
  /// has checked `can_admin` since 0010 — so this is a form catching up
  /// with a permission rather than a permission being widened.
  ///
  /// `baseCurrency` is deliberately separate and not here: changing it
  /// is not the same kind of act as correcting a registration number.
  /// See [setBaseCurrency].
  Future<void> updateCompanyDetails({
    required String name,
    required String entityType,
    required String roundingMethod,
    String? registrationNo,
    String? tin,
    String? tourismTaxRegNo,
    String? msicCode,
    String? addressLine1,
    String? addressLine2,
    String? addressLine3,
    String? postcode,
    String? city,
    String? stateCode,
    String? email,
    String? phone,
    String? registeredAddressLine1,
    String? registeredAddressLine2,
    String? registeredAddressLine3,
    String? registeredPostcode,
    String? registeredCity,
    String? registeredStateCode,
  }) => client
      .from('organizations')
      .update({
        'name': name,
        'entity_type': entityType,
        'rounding_method': roundingMethod,
        'registration_no': _orNull(registrationNo),
        'tin': _orNull(tin),
        // Not beside the SST number, which lives on its own card
        // because registering for SST is four facts and a default tax
        // code. This one is only a number: a company either has a
        // Tourism Tax registration or it has not.
        'tourism_tax_reg_no': _orNull(tourismTaxRegNo),
        'msic_code': _orNull(msicCode),
        // The business address, which is what goes on the invoice and
        // what `app.prepare_einvoice` sends LHDN as the supplier.
        'address_line1': _orNull(addressLine1),
        'address_line2': _orNull(addressLine2),
        'address_line3': _orNull(addressLine3),
        'postcode': _orNull(postcode),
        'city': _orNull(city),
        'state_code': _orNull(stateCode),
        'email': _orNull(email),
        'phone': _orNull(phone),
        // Null throughout means "the same as the business address", so
        // clearing the checkbox genuinely clears it rather than leaving
        // a stale registered office behind.
        'registered_address_line1': _orNull(registeredAddressLine1),
        'registered_address_line2': _orNull(registeredAddressLine2),
        'registered_address_line3': _orNull(registeredAddressLine3),
        'registered_postcode': _orNull(registeredPostcode),
        'registered_city': _orNull(registeredCity),
        'registered_state_code': _orNull(registeredStateCode),
        // SST is deliberately not here any more. Registering is four
        // facts that have to move together — the flag, the number, the
        // date it took effect and the tax code new lines default to —
        // and `set_sst_registration` is the only thing that knows how.
        // Writing the flag from this form would undo it every time
        // somebody corrected the address.
      })
      .eq('id', orgId);

  /// Invoices from other companies in the group addressed to this one.
  ///
  /// Not everything the group has raised — only documents whose customer
  /// contact points at this company, which is how one company addresses
  /// a document to another. See 0146.
  Future<List<Map<String, dynamic>>> intercompanyInbox() async => Repo._rows(
    await callRpc('intercompany_inbox', params: {'p_org_id': orgId}),
  );

  /// Turn one of them into a draft bill here.
  ///
  /// A draft, because two things cannot be carried across a company
  /// boundary and have to be decided on this side: which expense account
  /// each line belongs to, and which of our items it is.
  Future<String> acceptIntercompanyBill(String salesDocumentId) async {
    final id = await callRpc(
      'accept_intercompany_bill',
      params: {'p_sales_document_id': salesDocumentId, 'p_org_id': orgId},
    );
    return id as String;
  }

  /// Register the company for SST, or take it off the register.
  ///
  /// Everything at once, in the database, because any part of it on its
  /// own is a company that believes it is charging tax and is not: 0145
  /// found one in this very database, registered since onboarding, with
  /// every invoice line still defaulting to 0%.
  ///
  /// [taxCode] is the code new lines should default to — ST8 or ST6 for
  /// service tax, SL10 or SL5 for sales tax. Which registration it is
  /// is not something software should guess.
  Future<void> setSstRegistration({
    required bool registered,
    DateTime? from,
    String? registrationNo,
    String? taxCode,
  }) => callRpc(
    'set_sst_registration',
    params: {
      'p_org_id': orgId,
      'p_registered': registered,
      'p_from': from == null ? null : Fmt.iso(from),
      'p_registration_no': registrationNo,
      'p_tax_code': taxCode,
    },
  );

  /// Whether anything has reached the ledger yet.
  ///
  /// Asked before offering to change the base currency, which is the one
  /// field on the company that cannot be corrected later: every amount
  /// in the ledger is stored as a number in this currency and nowhere
  /// says which. Changing it does not convert anything — it silently
  /// re-labels every figure the company has ever recorded.
  Future<bool> hasPostings() async {
    final rows = Repo._rows(
      await client.from('gl_entries').select('id').eq('org_id', orgId).limit(1),
    );
    return rows.isNotEmpty;
  }

  Future<void> setBaseCurrency(String code) => client
      .from('organizations')
      .update({'base_currency': code})
      .eq('id', orgId);

  /// Whether the generated PDFs should leave room for a header already
  /// printed on the paper. RLS lets only an administrator through, which
  /// is the same bar as replacing the logo.
  Future<void> setPreprintedLetterhead(bool value) => client
      .from('organizations')
      .update({'uses_preprinted_letterhead': value})
      .eq('id', orgId);
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
///
/// Deliberately not routed through [Repo.callRpc]. A refusal here has no
/// organization to be filed under -- `report_denied` takes an org_id and
/// checks membership -- and "somebody who is not platform staff tried the
/// console" is not a tenant's event to hold.
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
        .order('sort_order', ascending: true);
    return Repo._rows(data).map(ModuleInfo.fromJson).toList();
  }

  Future<void> setModule(String orgId, String code, bool enabled) => client.rpc(
    'platform_set_module',
    params: {'p_org_id': orgId, 'p_module_code': code, 'p_enabled': enabled},
  );

  Future<void> setOrgStatus(String orgId, String status) => client.rpc(
    'platform_set_org_status',
    params: {'p_org_id': orgId, 'p_status': status},
  );

  // ------------------------------------------------------------------
  // Closures (0619)
  //
  // On this class rather than on [Repo] because none of the three is
  // about one company: an operator reading these belongs to no tenant,
  // and `Repo` cannot be built without one.
  // ------------------------------------------------------------------

  /// Every closed login, company and ledger account, with the identity
  /// the product no longer shows. [kind] is `user`, `organization` or
  /// `ledger_account`, or null for all three.
  Future<List<Map<String, dynamic>>> closedAccounts({
    String? kind,
    bool includeRestored = false,
  }) async => Repo._rows(
    await client.rpc(
      'platform_closed_accounts',
      params: {'p_kind': kind, 'p_include_restored': includeRestored},
    ),
  );

  /// Closes one on the operator's side — the half of this that answers
  /// a request made by email rather than pressed in Settings.
  Future<Map<String, dynamic>> closeAccount({
    required String kind,
    required String subjectId,
    String? reason,
  }) async {
    final data = await client.rpc(
      'platform_close_account',
      params: {
        'p_kind': kind,
        'p_subject_id': subjectId,
        'p_reason': reason,
      },
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Brings one back. The only way back there is.
  Future<Map<String, dynamic>> restoreAccount(
    String closureId, {
    String? note,
  }) async {
    final data = await client.rpc(
      'platform_restore_account',
      params: {'p_closure_id': closureId, 'p_note': note},
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<List<Map<String, dynamic>>> settings() async {
    final data = await client.from('platform_settings').select().order('key', ascending: true);
    return Repo._rows(data);
  }

  /// Every company's reports, faults first and worst first. See 0460.
  Future<List<Map<String, dynamic>>> feedback({String? status}) async =>
      Repo._rows(
        await client.rpc(
          'platform_feedback',
          params: {'p_status': status, 'p_limit': 300},
        ),
      );

  Future<void> setFeedbackStatus(String id, String status, {String? note}) =>
      client.rpc(
        'set_feedback_status',
        params: {'p_id': id, 'p_status': status, 'p_note': note},
      );

  /// `value` is `dynamic` rather than a map because `platform_settings`
  /// stores jsonb, and not every setting is an object: `mail_domain` is
  /// a bare JSON string, and `app.mail_domain()` reads it with
  /// `#>> '{}'`, which only works on a scalar. Typing this as a map
  /// meant the console could not save one back in the shape the
  /// database needs.
  Future<void> updateSetting(String key, dynamic value) => client
      .rpc('platform_update_setting', params: {'p_key': key, 'p_value': value});

  // ------------------------------------------------------------------
  // Scanning credit
  //
  // Sold in ringgit rather than in scans, because the price is set here
  // and will move. What a tenant bought stays what they bought.
  // ------------------------------------------------------------------

  /// Every tenant's balance and what they have spent lately, emptiest
  /// first — which is the order somebody chasing top-ups wants.
  Future<List<Map<String, dynamic>>> creditSummary() async =>
      Repo._rows(await client.rpc('platform_credit_summary'));

  /// Grants [amount] of credit and raises the invoice for it. Service
  /// tax, if the issuer is registered for it, goes on top.
  Future<Map<String, dynamic>> topUpCredit(
    String orgId,
    double amount, {
    String? note,
  }) async {
    final data = await client.rpc(
      'platform_topup_credit',
      params: {'p_org_id': orgId, 'p_amount': amount, 'p_note': note},
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Signed. Goodwill after an outage, or clawing back a mis-keyed
  /// top-up — either way it writes the same ledger line everything else
  /// does, so it cannot be done invisibly.
  Future<void> adjustCredit(String orgId, double amount, String reason) =>
      client.rpc(
        'platform_adjust_credit',
        params: {'p_org_id': orgId, 'p_amount': amount, 'p_reason': reason},
      );

  Future<List<Map<String, dynamic>>> creditInvoices({String? orgId}) async {
    var query = client.from('platform_invoices').select();
    if (orgId != null) query = query.eq('org_id', orgId);
    return Repo._rows(await query.order('issue_date', ascending: false));
  }

  Future<void> markInvoicePaid(String invoiceId, {String? note}) => client.rpc(
    'platform_mark_invoice_paid',
    params: {'p_invoice_id': invoiceId, 'p_note': note},
  );

  // ------------------------------------------------------------------
  // Statutory rate tables
  //
  // These have no `org_id`: one table, shared by every organization in
  // the database. Anybody may read them — that is what makes "are we
  // filing on verified figures?" answerable — and only a platform
  // administrator may change them.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> statutorySchedules() async => Repo._rows(
    await client
        .from('statutory_schedules')
        .select('*, statutory_rates(*)')
        .order('body', ascending: true)
        .order('effective_from', ascending: false),
  );

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
    final data = await client.rpc(
      'platform_publish_statutory_schedule',
      params: {
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
      },
    );
    return data as String;
  }

  Future<void> setScheduleVerified(
    String scheduleId,
    bool verified, {
    String? source,
    String? notes,
  }) => client.rpc(
    'platform_set_schedule_verified',
    params: {
      'p_schedule_id': scheduleId,
      'p_verified': verified,
      if (source != null) 'p_source': source,
      if (notes != null) 'p_notes': notes,
    },
  );

  // ------------------------------------------------------------------
  // The platform's own trail
  //
  // The rows above are the ones with no `org_id`, and the audit trigger
  // 0442 put on them writes audit rows with no `org_id` either.
  // `auditTrail` cannot reach those: it passes `p_org_id` and the
  // function filters on it, so a null matches no argument. 0444 is the
  // pair of readers that can — refusing anybody who is not a platform
  // administrator, and recording the read where the second one shows
  // it.
  // ------------------------------------------------------------------
  Future<List<AuditEntry>> platformAuditTrail({
    String? table,
    int limit = 100,
  }) async {
    final rows = await client.rpc(
      'platform_audit_trail',
      params: {'p_table': table, 'p_limit': limit},
    );
    return Repo._rows(rows).map(AuditEntry.fromJson).toList();
  }

  Future<List<SecurityEvent>> platformSecurityLog({
    DateTime? since,
    int limit = 200,
  }) async {
    final rows = await client.rpc(
      'platform_security_log',
      params: {
        if (since != null) 'p_since': since.toUtc().toIso8601String(),
        'p_limit': limit,
      },
    );
    return Repo._rows(rows).map(SecurityEvent.fromMap).toList();
  }
}

/// Tenant-scoped extras: team management, module entitlements and the
/// legal firm module.
extension RepoExtras on Repo {
  // ------------------------------------------------------------------
  // Modules the tenant is entitled to
  // ------------------------------------------------------------------
  /// What belongs on this company's navigation.
  ///
  /// Two questions, and 0234 keeps them apart: the company must hold the
  /// module, and it must not have put it away. `org_module_surface`
  /// answers both in one call, and answers the first the same way the
  /// policies do -- which is the point of asking the server rather than
  /// reassembling the rule here, as this method used to. Reading
  /// `org_modules` directly meant the client had its own opinion about
  /// entitlement, and an opinion is exactly what 0232 found had been
  /// standing in for enforcement.
  Future<Set<String>> enabledModules() async {
    final rows = Repo._rows(
      await callRpc('org_module_surface', params: {'p_org_id': orgId}),
    );
    return {
      for (final r in rows)
        if (r['visible'] == true) r['module_code'].toString(),
    };
  }

  /// Every active module with what this company may see of it: whether
  /// it is held, whether it has been put away, and what it costs. The
  /// settings screen's list.
  Future<List<ModuleSurface>> moduleSurface() async {
    final rows = Repo._rows(
      await callRpc('org_module_surface', params: {'p_org_id': orgId}),
    );
    return [for (final r in rows) ModuleSurface.fromMap(r)];
  }

  /// Put a module away, or take it out again. A preference: the server
  /// refuses a module the company does not hold, and hiding one never
  /// closes the API behind it.
  Future<void> setModuleHidden(String module, bool hidden) => callRpc(
    'set_module_hidden',
    params: {'p_org_id': orgId, 'p_module': module, 'p_hidden': hidden},
  );

  /// Add one of the paid add-ons to this company, or take it off.
  ///
  /// Not the same as [setModuleHidden], which is a preference about a
  /// module already held. This is the entitlement itself, and the
  /// monthly price with it. 0488: an owner or admin does this without
  /// asking anybody, which is the door 0486's refusal names.
  Future<void> setOwnModule(String module, bool enabled) => callRpc(
    'set_own_module',
    params: {
      'p_org_id': orgId,
      'p_module_code': module,
      'p_enabled': enabled,
    },
  );

  /// What the add-ons this company holds have cost it so far this
  /// month, line by line and pro-rated by the days each was on.
  ///
  /// The invoice for a month is written on the first of the next one,
  /// so between those two dates this is the only answer to "what am I
  /// paying?". The server refuses anybody but an owner or admin: the
  /// price list is public, what this company pays is not.
  Future<Map<String, dynamic>> moduleCharges() async {
    final data = await callRpc('module_charges', params: {'p_org_id': orgId});
    return Map<String, dynamic>.from(data as Map);
  }

  /// Figures for the modules this company actually uses, keyed by module
  /// code. A company with no such module gets an empty map and keeps the
  /// accounting dashboard.
  Future<Map<String, dynamic>> moduleDashboard() async {
    final data = await callRpc('module_dashboard', params: {'p_org_id': orgId});
    if (data is Map) return Map<String, dynamic>.from(data);
    return const {};
  }

  // ------------------------------------------------------------------
  // Team
  // ------------------------------------------------------------------
  Future<List<TeamMember>> team() async {
    final data = await callRpc('org_team', params: {'p_org_id': orgId});
    return Repo._rows(data).map(TeamMember.fromJson).toList();
  }

  // ------------------------------------------------------------------
  // Access types
  //
  // A company's own answer to "who may see what". The ten built-in roles
  // decide what kind of thing somebody may do; an access type decides
  // which modules they may reach, and whether they may change anything
  // there. Enforced by the restrictive policies 0127 added — everything
  // here is the screen for it, not the rule.
  // ------------------------------------------------------------------
  Future<List<AccessType>> accessTypes() async => Repo._rows(
    await client
        .from('access_types')
        .select('*, access_type_modules(module_code, access)')
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('name', ascending: true),
  ).map(AccessType.fromJson).toList();

  Future<String> createAccessType(String name, {String? description}) async {
    final row = await client
        .from('access_types')
        .insert({
          'org_id': orgId,
          'name': name,
          if (description != null && description.isNotEmpty)
            'description': description,
        })
        .select('id')
        .single();
    return row['id'] as String;
  }

  Future<void> renameAccessType(
    String id,
    String name, {
    String? description,
  }) => client
      .from('access_types')
      .update({'name': name, 'description': description})
      .eq('id', id)
      .eq('org_id', orgId);

  /// Retired rather than deleted, and the members holding it are handed
  /// back their unrestricted access first. Deleting the row alone would
  /// do the second part silently through `on delete set null`, which is
  /// the same outcome arrived at without anybody deciding it.
  Future<void> retireAccessType(String id) => client
      .from('access_types')
      .update({'is_active': false})
      .eq('id', id)
      .eq('org_id', orgId);

  /// `none` removes the row rather than storing it, so the table holds
  /// grants and only grants — and the absence of a row keeps meaning the
  /// same thing whether nobody ever set it or somebody set it back.
  Future<void> setModuleAccess(
    String accessTypeId,
    String moduleCode,
    String access,
  ) async {
    if (access == 'none') {
      await client
          .from('access_type_modules')
          .delete()
          .eq('access_type_id', accessTypeId)
          .eq('module_code', moduleCode);
      return;
    }
    await client.from('access_type_modules').upsert({
      'access_type_id': accessTypeId,
      'module_code': moduleCode,
      'access': access,
    }, onConflict: 'access_type_id,module_code');
  }

  Future<void> setMemberAccessType(String memberId, String? accessTypeId) =>
      callRpc(
        'set_member_access_type',
        params: {'p_member_id': memberId, 'p_access_type_id': accessTypeId},
      );

  /// What the person asking may do, module by module. The same
  /// `app.module_access` the policies use, so a screen cannot disagree
  /// with the database about what somebody may reach.
  Future<Map<String, String>> myModuleAccess() async {
    final rows = Repo._rows(
      await callRpc('my_module_access', params: {'p_org_id': orgId}),
    );
    return {
      for (final r in rows)
        r['module_code'].toString(): r['access']?.toString() ?? 'none',
    };
  }

  /// The actions a company can hand out inside a module. A catalog of
  /// what the product can enforce, so it changes with a migration and
  /// not with a company's mind — which is why nothing writes it.
  Future<List<Map<String, dynamic>>> accessPermissions() async => Repo._rows(
    await client
        .from('access_permissions')
        .select()
        .order('module_code', ascending: true)
        .order('sort_order', ascending: true),
  );

  /// Invites somebody, and hands back the raw invitation token once.
  ///
  /// Null when the address was already a member and the call only
  /// changed their role — there is nothing for them to accept. `0353`
  /// returns the token because nothing else can: what is stored is a
  /// digest, and no e-mail carries it.
  Future<String?> inviteMember(String email, String role) async {
    final data = await callRpc(
      'invite_member',
      params: {'p_org_id': orgId, 'p_email': email, 'p_role': role},
    );
    return data?.toString();
  }

  /// Take up an invitation to another company, and return its id.
  ///
  /// For somebody who already had an account when they were invited.
  /// `app.handle_new_user` claims a pending invitation at signup, so
  /// anybody who signs up afterwards never reaches this — and anybody
  /// who did not had, until now, no way in at all.
  Future<String> acceptInvitation(String token) async {
    final data = await callRpc('accept_invitation', params: {'p_token': token});
    return data as String;
  }

  Future<void> changeMemberRole(String memberId, String role) =>
      client.from('org_members').update({'role': role}).eq('id', memberId);

  Future<void> removeMember(String memberId) =>
      client.from('org_members').delete().eq('id', memberId);

  // ------------------------------------------------------------------
  // Legal firm module
  // ------------------------------------------------------------------
  Future<void> setupLegalModule() =>
      callRpc('setup_legal_module', params: {'p_org_id': orgId});

  Future<List<Matter>> matters({String? status, String? search}) async {
    var query = client
        .from('matters')
        // Named because 0512 added a same-org composite key alongside
        // the plain one, so 'contacts' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, contacts!matters_client_id_fkey(name)')
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

  /// Money received from a client to hold on account for a matter.
  ///
  /// 0549. Client money and office money are two streams and the
  /// difference is the whole of the Solicitors' Accounts Rules: this
  /// reaches the client account and 2300, and it raises no sales
  /// document, because money held for a client is not income.
  Future<String> receiveClientMoney({
    required String matterId,
    required double amount,
    DateTime? date,
    String? description,
    String? reference,
    String? paymentModeCode,
  }) async {
    final id = await callRpc(
      'receive_client_money',
      params: {
        'p_matter': matterId,
        'p_amount': amount,
        if (date != null) 'p_date': Fmt.iso(date),
        if (description != null) 'p_description': description,
        if (reference != null) 'p_reference': reference,
        if (paymentModeCode != null) 'p_payment_mode': paymentModeCode,
      },
    );
    return id.toString();
  }

  /// A disbursement paid out of a matter's client money — stamp duty,
  /// a search fee — or the refund of what is left when it closes.
  ///
  /// The server refuses to overdraw the matter, which is the rule that
  /// stops one client's money funding another's.
  Future<String> payFromClientAccount({
    required String matterId,
    required double amount,
    String? payee,
    DateTime? date,
    String? description,
    String? reference,
    String? paymentModeCode,
    bool refund = false,
  }) async {
    final id = await callRpc(
      'pay_from_client_account',
      params: {
        'p_matter': matterId,
        'p_amount': amount,
        if (payee != null) 'p_payee': payee,
        if (date != null) 'p_date': Fmt.iso(date),
        if (description != null) 'p_description': description,
        if (reference != null) 'p_reference': reference,
        if (paymentModeCode != null) 'p_payment_mode': paymentModeCode,
        'p_refund': refund,
      },
    );
    return id.toString();
  }

  /// Settles a rendered bill out of the client money already held for
  /// its matter — the transfer to office.
  ///
  /// Both legs at once and only from here: the money leaves the client
  /// account AND arrives in the office one, which is what makes it a
  /// transfer rather than a disappearance. Before 0549 the movement
  /// existed and did only the first half.
  Future<String> settleFromClientAccount({
    required String matterId,
    required String invoiceId,
    required double amount,
    DateTime? date,
    String? officeBankAccountId,
    String? reference,
  }) async {
    final id = await callRpc(
      'settle_from_client_account',
      params: {
        'p_matter': matterId,
        'p_invoice': invoiceId,
        'p_amount': amount,
        if (date != null) 'p_date': Fmt.iso(date),
        if (officeBankAccountId != null) 'p_office_bank': officeBankAccountId,
        if (reference != null) 'p_reference': reference,
      },
    );
    return id.toString();
  }

  /// What a matter holds in the client account right now.
  ///
  /// Asked of the server rather than summed in the client, because it
  /// is the same number the server refuses against and two answers to
  /// one question is how a form comes to promise what the database will
  /// not do.
  Future<double> matterClientBalance(String matterId) async {
    final value = await callRpc(
      'matter_client_balance',
      params: {'p_matter': matterId},
    );
    return Fmt.toDouble(value);
  }

  /// Every movement of client money the firm has made, newest first.
  ///
  /// Across matters rather than within one: `clientTransactions` above
  /// answers "what happened on this matter", which is the question the
  /// matter screen asks. This answers "what has been received" and
  /// "what has been paid out", which is what somebody sitting down to
  /// bank a cheque or settle a disbursement is looking at.
  ///
  /// The matter is embedded rather than joined afterwards, because a
  /// client-money line without a matter on it is a line nobody can act
  /// on -- it is the matter, not the amount, that says whose money it
  /// is.
  Future<List<Map<String, dynamic>>> clientAccountLedger({
    required List<String> types,
    int limit = 200,
  }) async {
    final data = await client
        .from('client_account_transactions')
        // The constraint is named because 0521 gave every org-scoped
        // table a second, composite key alongside the plain one, so
        // `matters` is joinable two ways from here and PostgREST
        // refuses an unqualified embed with PGRST201.
        .select('*, matters!client_account_transactions_matter_id_fkey!inner'
            '(matter_no, name, client_id, '
            'contacts!matters_client_id_fkey(name))')
        .eq('org_id', orgId)
        .inFilter('transaction_type', types)
        .order('transaction_date', ascending: false)
        .order('transaction_no', ascending: false)
        .limit(limit);
    return Repo._rows(data);
  }

  /// What every open matter holds, for the picker on those two screens.
  ///
  /// One call rather than `matter_client_balance` per matter: a firm
  /// with forty open matters would otherwise make forty round trips to
  /// draw one dropdown.
  Future<Map<String, double>> matterClientBalances() async {
    final data = await client
        .from('client_account_transactions')
        .select('matter_id, amount, status')
        .eq('org_id', orgId)
        .neq('status', 'void');
    final held = <String, double>{};
    for (final row in Repo._rows(data)) {
      final id = row['matter_id']?.toString();
      if (id == null) continue;
      held[id] = (held[id] ?? 0) + Fmt.toDouble(row['amount']);
    }
    return held;
  }

  Future<List<MatterSummary>> matterSummary() async {
    final data = await callRpc(
      'report_matter_summary',
      params: {'p_org_id': orgId},
    );
    return Repo._rows(data).map(MatterSummary.fromJson).toList();
  }

  /// Files the firm has open or closed that touch these parties.
  ///
  /// Both directions: matters where the firm acts for the proposed
  /// opposing party, and matters where it has acted against the
  /// proposed client. Asked of the database, which is where the rule
  /// lives — `matters.opposing_party` was a column nothing wrote, so
  /// until `0383` this question had no answer at all.
  Future<List<Map<String, dynamic>>> checkMatterConflict({
    String? clientId,
    String? opposingParty,
  }) async => Repo._rows(
    await callRpc(
      'check_matter_conflict',
      params: {
        'p_org': orgId,
        'p_client': clientId,
        'p_opposing_party': opposingParty,
      },
    ),
  );

  /// Opens a file, having asked. An RPC and not an insert, because the
  /// conflict check is the point: Rule 3 of the Legal Profession
  /// (Practice and Etiquette) Rules 1978 is what a firm walks into
  /// when a second partner opens a file against a company it acts for.
  Future<String> openMatter({
    required String name,
    required String clientId,
    String? matterNo,
    String? opposingParty,
    String? matterType,
    String? feeEarner,
    String? responsible,
    num? agreedFee,
    num hourlyRate = 0,
    String? conflictNote,
    Map<String, dynamic> customFields = const {},
  }) async {
    final id = await callRpc(
      'open_matter',
      params: {
        'p_org': orgId,
        'p_matter_no': matterNo ?? await nextDocumentNumber('matter'),
        'p_name': name,
        'p_client': clientId,
        'p_opposing_party': opposingParty,
        'p_matter_type': matterType,
        'p_fee_earner': feeEarner,
        'p_responsible': responsible,
        'p_agreed_fee': agreedFee,
        'p_hourly_rate': hourlyRate,
        'p_conflict_note': conflictNote,
      },
    );
    // The RPC's argument list is fixed and a field this firm invented
    // is not in it, so the fields go on a moment later under the
    // table's own UPDATE policy. `0543` is what makes the gap safe: a
    // row created carrying no custom fields passes, and this update is
    // then held to the whole set exactly as an insert would be.
    //
    // Through `writeCustomFields`, which exists for exactly this and
    // whose own comment names both callers — and which nothing called,
    // because this and `createTicket` each wrote their own copy of it.
    await writeCustomFields('matters', id.toString(), customFields);
    return id.toString();
  }

  /// Fixed-fee matters where billed plus unbilled time has passed the
  /// agreed fee. Reported and not refused: fees get renegotiated, and a
  /// firm that hears about it from the client heard from the wrong
  /// person.
  Future<List<Map<String, dynamic>>> mattersOverAgreedFee() async => Repo._rows(
    await callRpc('report_matters_over_agreed_fee', params: {'p_org': orgId}),
  );

  /// Closes a file, and says what it left unbilled.
  ///
  /// Refuses while the client account still holds anything for the
  /// matter — see `0372`. Unbilled time and disbursements come back in
  /// the result rather than stopping it: they are the firm's own money.
  Future<Map<String, dynamic>> closeMatter(
    String matterId, {
    DateTime? closedOn,
    String? note,
  }) async {
    final data = await callRpc(
      'close_matter',
      params: {
        'p_matter': matterId,
        'p_closed_date': closedOn == null ? null : Fmt.iso(closedOn),
        'p_note': note,
      },
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Puts a closed file back into service.
  Future<void> reopenMatter(String matterId) =>
      callRpc('reopen_matter', params: {'p_matter': matterId});

  Future<List<ClientTransaction>> clientTransactions(String matterId) async {
    final data = await client
        .from('client_account_transactions')
        .select()
        .eq('org_id', orgId)
        .eq('matter_id', matterId)
        .order('transaction_date', ascending: true)
        .order('created_at', ascending: true);
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
        'No client account configured. Open Settings and run the legal setup first.',
      );
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

    await callRpc('post_client_transaction', params: {'p_id': row['id']});
  }

  /// Moves client money from one of a client's matters to another.
  ///
  /// 0358. Both legs at once, because one `transfer_out` on its own is
  /// money taken off a matter and put nowhere. The server refuses a
  /// transfer between different clients and one the source matter does
  /// not hold; `matter_transfer.dart` asks the same two questions first
  /// so the answer arrives before the amount is typed rather than after.
  Future<void> transferBetweenMatters({
    required String fromMatterId,
    required String toMatterId,
    required double amount,
    required DateTime date,
    String? description,
  }) => callRpc(
    'transfer_between_matters',
    params: {
      'p_from': fromMatterId,
      'p_to': toMatterId,
      'p_amount': amount,
      'p_date': Fmt.iso(date),
      if (description != null && description.isNotEmpty)
        'p_description': description,
    },
  );

  /// Corrects a day's clock times, saying who changed it and why.
  ///
  /// 0363. `clock_out` only ever touches today's record, so the
  /// `incomplete` day 0360 marks — a clock-in with no clock-out — had
  /// no way back. HR only, a reason is required, and a day inside a
  /// closed pay period is refused because its overtime has been paid.
  Future<Map<String, dynamic>?> adjustAttendance({
    required String recordId,
    required DateTime clockIn,
    DateTime? clockOut,
    required String reason,
  }) async {
    final out = await callRpc(
      'adjust_attendance',
      params: {
        'p_record': recordId,
        'p_clock_in': clockIn.toUtc().toIso8601String(),
        'p_clock_out': clockOut?.toUtc().toIso8601String(),
        'p_reason': reason,
      },
    );
    return out is Map<String, dynamic> ? out : null;
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
  }) => client.from('time_entries').insert({
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
  }) => client.from('disbursements').insert({
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
  /// Every employee document running out inside the window.
  ///
  /// Current documents only — one a renewal has superseded is not the
  /// company's problem any more, and leaving those on the list is what
  /// turns it into something nobody opens.
  Future<List<Map<String, dynamic>>> expiringDocuments({
    int withinDays = 60,
  }) async => Repo._rows(
    await callRpc(
      'report_expiring_documents',
      params: {'p_org_id': orgId, 'p_within_days': withinDays},
    ),
  );

  /// Record a renewal, and retire the document it replaces.
  ///
  /// Everything not given again is carried across from the old one: a
  /// renewed permit is the same permit with new dates, and retyping the
  /// rest is how it comes out as a different kind from the one it
  /// replaced.
  Future<String> renewEmployeeDocument({
    required String documentId,
    required DateTime expiresDate,
    DateTime? issuedDate,
    String? title,
    String? notes,
  }) async =>
      (await callRpc(
            'renew_employee_document',
            params: {
              'p_document': documentId,
              'p_expires_date': Fmt.iso(expiresDate),
              if (issuedDate != null) 'p_issued_date': Fmt.iso(issuedDate),
              if (title != null && title.trim().isNotEmpty)
                'p_title': title.trim(),
              if (notes != null && notes.trim().isNotEmpty)
                'p_notes': notes.trim(),
            },
          ))
          as String;

  // ------------------------------------------------------------------
  // People
  // ------------------------------------------------------------------

  /// The whole company, name and role only. Backed by a function so the
  /// pay columns on the employee row never travel to the client.
  Future<List<Employee>> directory() async {
    final data = await callRpc(
      'employee_directory',
      params: {'p_org_id': orgId},
    );
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
        .select(
          '*, departments!employees_department_id_fkey(name), '
          'positions!employees_position_id_fkey(title)',
        )
        .eq('org_id', orgId);
    if (status != null && status != 'all') {
      q = q.eq('employment_status', status);
    }
    if (search != null && search.trim().isNotEmpty) {
      final s = '%${search.trim()}%';
      q = q.or('full_name.ilike.$s,employee_no.ilike.$s');
    }
    return Repo._rows(
      await q.order('employee_no', ascending: true),
    ).map(Employee.fromJson).toList();
  }

  Future<Employee?> employee(String id) async {
    final row = await client
        .from('employees')
        // `departments!` names the relationship explicitly. An employee
        // belongs to a department and a department has a head employee,
        // so PostgREST sees two ways to join the two tables and refuses
        // the request rather than guessing. The JSON key stays
        // `departments`, so nothing downstream changes.
        .select(
          '*, departments!employees_department_id_fkey(name), '
          'positions!employees_position_id_fkey(title)',
        )
        .eq('id', id)
        .maybeSingle();
    return row == null
        ? null
        : Employee.fromJson(Map<String, dynamic>.from(row));
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
        .select(
          '*, departments!employees_department_id_fkey(name), '
          'positions!employees_position_id_fkey(title)',
        )
        .eq('org_id', orgId)
        .eq('user_id', uid)
        .maybeSingle();
    return row == null
        ? null
        : Employee.fromJson(Map<String, dynamic>.from(row));
  }

  /// Takes somebody off the payroll.
  ///
  /// Not part of `saveEmployee`, and deliberately: `calculate_payroll_run`
  /// goes by `last_working_date`, so a departure is a statement about
  /// pay rather than a field on a form, and `0371` refuses the halves.
  Future<void> recordDeparture({
    required String employeeId,
    required DateTime lastWorkingDay,
    required String kind,
    String? reason,
    DateTime? resignationDate,
  }) => callRpc(
    'record_departure',
    params: {
      'p_employee': employeeId,
      'p_last_working_date': Fmt.iso(lastWorkingDay),
      'p_status': kind,
      'p_reason': reason,
      'p_resignation_date': resignationDate == null
          ? null
          : Fmt.iso(resignationDate),
    },
  );

  /// Undoes one. A resignation withdrawn and a departure recorded
  /// against the wrong person are both ordinary.
  Future<void> reinstateEmployee(String employeeId) =>
      callRpc('reinstate_employee', params: {'p_employee': employeeId});

  Future<String> saveEmployee(Map<String, dynamic> values, {String? id}) async {
    if (id != null) {
      await client.from('employees').update(values).eq('id', id);
      return id;
    }
    final no = await callRpc(
      'next_document_number',
      params: {'p_org_id': orgId, 'p_doc_type': 'employee'},
    );
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
    String employeeId,
    int taxYear,
  ) async => Repo._rows(
    await client
        .from('employee_tax_reliefs')
        .select()
        .eq('employee_id', employeeId)
        .eq('tax_year', taxYear)
        .order('relief_code', ascending: true),
  ).map(DeclaredRelief.fromJson).toList();

  /// The reliefs an employee may declare — everything the company cannot
  /// work out for itself from the record it already holds.
  ///
  /// This used to pick the schedule here, filtering `statutory_schedules`
  /// on a column called `schedule_type`. There is no such column — a
  /// schedule's body is `body` — so PostgREST answered 42703 and the
  /// whole request failed, every time, for the life of the feature. The
  /// provider turned that into an empty list without a word and the Add
  /// button stayed greyed out, so nobody could declare a relief and
  /// nobody could see why.
  ///
  /// It is an RPC now, and not only to fix the column. `0408` enforces
  /// LHDN's ceiling against the schedule in force at the end of the tax
  /// year; a list assembled here off a different schedule would offer
  /// reliefs the database then refused. One rule, in one place, so the
  /// list offered is the list allowed.
  Future<List<ReliefType>> reliefTypes(int taxYear) async => Repo._rows(
    await callRpc('declarable_reliefs', params: {'p_tax_year': taxYear}),
  ).map(ReliefType.fromJson).toList();

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
    await client.from('departments').select().eq('org_id', orgId).order('name', ascending: true),
  );

  Future<List<Map<String, dynamic>>> positions() async => Repo._rows(
    await client.from('positions').select().eq('org_id', orgId).order('title', ascending: true),
  );

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
        // Named because 0508 added a same-org composite key alongside
        // the plain one, so 'employees' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, employees!attendance_records_employee_id_fkey(full_name)')
        .eq('org_id', orgId);
    if (employeeId != null) q = q.eq('employee_id', employeeId);
    if (from != null) q = q.gte('work_date', Fmt.iso(from));
    if (to != null) q = q.lte('work_date', Fmt.iso(to));
    return Repo._rows(
      await q.order('work_date', ascending: false).limit(200),
    ).map(AttendanceRecord.fromJson).toList();
  }

  Future<void> clockIn({double? lat, double? lng, String? address}) => callRpc(
    'clock_in',
    params: {
      'p_org_id': orgId,
      'p_method': lat == null ? 'web' : 'mobile_gps',
      if (lat != null) 'p_lat': lat,
      if (lng != null) 'p_lng': lng,
      if (address != null) 'p_address': address,
    },
  );

  Future<Map<String, dynamic>> clockOut({double? lat, double? lng}) async {
    final data = await callRpc(
      'clock_out',
      params: {
        'p_org_id': orgId,
        'p_method': lat == null ? 'web' : 'mobile_gps',
        if (lat != null) 'p_lat': lat,
        if (lng != null) 'p_lng': lng,
      },
    );
    return Map<String, dynamic>.from(data as Map);
  }

  // ------------------------------------------------------------------
  // Leave
  // ------------------------------------------------------------------
  Future<List<LeaveType>> leaveTypes() async => Repo._rows(
    await client
        .from('leave_types')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('sort_order', ascending: true),
  ).map(LeaveType.fromJson).toList();

  Future<List<LeaveBalance>> leaveBalances(String employeeId, int year) async =>
      Repo._rows(
        await client
            .from('leave_balances')
            .select('*, leave_types!leave_balances_leave_type_id_fkey(name)')
            .eq('employee_id', employeeId)
            .eq('leave_year', year),
      ).map(LeaveBalance.fromJson).toList();

  Future<List<LeaveRequest>> leaveRequests({
    String? status,
    String? employeeId,
  }) async {
    var q = client
        .from('leave_requests')
        .select(
          '*, employees!leave_requests_employee_id_fkey(full_name), '
          'leave_types!leave_requests_leave_type_id_fkey(name)',
        )
        .eq('org_id', orgId);
    if (status != null && status != 'all') q = q.eq('status', status);
    if (employeeId != null) q = q.eq('employee_id', employeeId);
    return Repo._rows(
      await q.order('start_date', ascending: false).limit(200),
    ).map(LeaveRequest.fromJson).toList();
  }

  Future<void> submitLeave({
    required String leaveTypeId,
    required DateTime start,
    required DateTime end,
    required double days,
    String? reason,
    String? contactWhileAway,
    bool isHalfDay = false,
    String? halfDayPeriod,
  }) => callRpc(
    'submit_leave_request',
    params: {
      'p_org_id': orgId,
      'p_leave_type_id': leaveTypeId,
      'p_start_date': Fmt.iso(start),
      'p_end_date': Fmt.iso(end),
      'p_total_days': days,
      if (reason != null) 'p_reason': reason,
      // `0027` modelled half days and `0365` wrote the rule about which
      // leave may be taken in them. Nothing ever passed the flag, so
      // `0365` guarded a door nobody could open until `0397`.
      if (isHalfDay) 'p_is_half_day': true,
      if (isHalfDay && halfDayPeriod != null)
        'p_half_day_period': halfDayPeriod,
      if (contactWhileAway != null) 'p_contact_while_away': contactWhileAway,
    },
  );

  /// The one field on a live leave request the employee may still
  /// change after submitting it. `0038`'s update policy freezes the
  /// whole row once it leaves draft, which is right for the dates and
  /// wrong for this: where somebody is changes while they are away.
  Future<void> updateLeaveContact(String requestId, String? contact) => callRpc(
    'update_leave_contact',
    params: {'p_request_id': requestId, 'p_contact': contact},
  );

  /// Approved leave overlapping the window, with the contact. HR sees
  /// the organization; anybody else sees their own reporting line and
  /// their own leave, which is what the table's select policy allows.
  Future<List<Map<String, dynamic>>> whoIsAway({
    DateTime? from,
    DateTime? to,
  }) async => Repo._rows(
    await callRpc(
      'report_who_is_away',
      params: {
        'p_org_id': orgId,
        if (from != null) 'p_from': Fmt.iso(from),
        if (to != null) 'p_to': Fmt.iso(to),
      },
    ),
  );

  Future<void> decideLeave(String id, bool approve, {String? note}) => callRpc(
    'decide_leave_request',
    params: {
      'p_request_id': id,
      'p_approve': approve,
      if (note != null) 'p_note': note,
    },
  );

  // ------------------------------------------------------------------
  // Claims
  // ------------------------------------------------------------------
  Future<List<ExpenseClaim>> claims({
    String? status,
    String? employeeId,
  }) async {
    var q = client
        .from('expense_claims')
        .select('*, employees!expense_claims_employee_id_fkey(full_name)')
        .eq('org_id', orgId);
    if (status != null && status != 'all') q = q.eq('status', status);
    if (employeeId != null) q = q.eq('employee_id', employeeId);
    return Repo._rows(
      await q.order('claim_date', ascending: false).limit(200),
    ).map(ExpenseClaim.fromJson).toList();
  }

  /// The claims waiting on the person asking, rather than every claim
  /// in the company.
  ///
  /// Two round trips on purpose. The database answers "which ones",
  /// because who may decide a step is already settled by
  /// `app.may_decide_claim_step` and a second copy of that rule in Dart
  /// would be a second copy to get wrong. The rows then come back
  /// through the same select and the same embed as every other claim
  /// list, so a claim looks identical whichever filter found it.
  Future<List<ExpenseClaim>> claimsAwaitingMe() async {
    final rows = Repo._rows(
      await callRpc('claims_awaiting_my_approval', params: {'p_org_id': orgId}),
    );
    final ids = rows.map((r) => r['claim_id'] as String).toList();
    if (ids.isEmpty) return [];

    return Repo._rows(
      await client
          .from('expense_claims')
          .select('*, employees!expense_claims_employee_id_fkey(full_name)')
          .inFilter('id', ids)
          .order('claim_date', ascending: false)
          .limit(200),
    ).map(ExpenseClaim.fromJson).toList();
  }

  /// The approval chain on one claim, in order.
  ///
  /// Read rather than derived: the steps say who was asked, who has
  /// answered, and which stages were skipped for want of anybody to
  /// fill them — none of which can be worked out from the claim's own
  /// status.
  Future<List<Map<String, dynamic>>> claimApprovals(String claimId) async =>
      Repo._rows(
        await client
            .from('claim_approvals')
            .select(
              '*, approver:employees!claim_approvals_approver_employee_id_fkey'
              '(full_name)',
            )
            .eq('claim_id', claimId)
            .order('step_no', ascending: true),
      );

  Future<void> decideClaim(
    String id,
    bool approve, {
    String? note,
    double? approvedAmount,
  }) => callRpc(
    'decide_expense_claim',
    params: {
      'p_claim_id': id,
      'p_approve': approve,
      if (note != null) 'p_note': note,
      if (approvedAmount != null) 'p_approved_amount': approvedAmount,
    },
  );

  /// The amount at or above which a claim goes up the full chain.
  ///
  /// Below it the employee's manager decides alone. Null where the
  /// company has never set one, which the database reads as zero — every
  /// claim, however small, asks all four stages.
  Future<double?> claimApprovalThreshold() async {
    final row = await client
        .from('claim_approval_settings')
        .select('full_chain_from')
        .eq('org_id', orgId)
        .maybeSingle();
    return (row?['full_chain_from'] as num?)?.toDouble();
  }

  /// Upsert rather than update: most companies have no row until the
  /// first time somebody opens this setting.
  Future<void> setClaimApprovalThreshold(double amount) =>
      client.from('claim_approval_settings').upsert({
        'org_id': orgId,
        'full_chain_from': amount,
      }, onConflict: 'org_id');

  Future<List<Map<String, dynamic>>> claimTypes() async => Repo._rows(
    await client
        .from('claim_types')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('sort_order', ascending: true),
  );

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
    final no = await callRpc(
      'next_document_number',
      params: {'p_org_id': orgId, 'p_doc_type': 'expense_claim'},
    );
    final total = lines.fold<double>(
      0,
      (sum, l) => sum + Fmt.toDouble(l['amount']),
    );
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
        {...lines[i], 'org_id': orgId, 'claim_id': id, 'line_no': i + 1},
    ]);
    return id;
  }

  // ------------------------------------------------------------------
  // Payroll
  // ------------------------------------------------------------------
  // The constraint is named because `0502` gave `payroll_runs` a second
  // foreign key to `pay_periods` -- the composite one that stops a run
  // naming another company's period. Two keys between the same pair of
  // tables is two ways to join them, and PostgREST answers PGRST201
  // rather than guess, which takes out the whole screen. Any embed of
  // `pay_periods` from here has to say which key it means.
  Future<List<PayrollRun>> payrollRuns() async => Repo._rows(
    await client
        .from('payroll_runs')
        .select('*, pay_periods!payroll_runs_period_id_fkey(code, pay_date)')
        .eq('org_id', orgId)
        .order('created_at', ascending: false),
  ).map(PayrollRun.fromJson).toList();

  Future<List<Payslip>> payslips({String? runId, String? employeeId}) async {
    var q = client
        .from('payslips')
        // Named because 0521 added a same-org composite key alongside
        // the plain one, so 'payroll_runs' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, payroll_runs!payslips_run_id_fkey(run_no, pay_periods!payroll_runs_period_id_fkey(code))')
        .eq('org_id', orgId);
    if (runId != null) q = q.eq('run_id', runId);
    if (employeeId != null) q = q.eq('employee_id', employeeId);
    return Repo._rows(
      await q.order('employee_no', ascending: true),
    ).map(Payslip.fromJson).toList();
  }

  Future<Payslip?> payslip(String id) async {
    final row = await client
        .from('payslips')
        // Named because 0521 added a same-org composite key alongside
        // the plain one, so 'payslip_lines and payroll_runs' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, payslip_lines!payslip_lines_payslip_id_fkey(*), payroll_runs!payslips_run_id_fkey(run_no, pay_periods!payroll_runs_period_id_fkey(code))')
        .eq('id', id)
        .maybeSingle();
    return row == null
        ? null
        : Payslip.fromJson(Map<String, dynamic>.from(row));
  }

  /// Creates the period if it does not exist, then a run against it.
  Future<String> startPayrollRun(int year, int month) async {
    final periodId = await callRpc(
      'ensure_pay_period',
      params: {'p_org_id': orgId, 'p_year': year, 'p_month': month},
    );
    final runId = await callRpc(
      'create_payroll_run',
      params: {
        'p_org_id': orgId,
        'p_period_id': periodId,
        'p_description': '${Fmt.monthName(month)} $year payroll',
      },
    );
    return runId as String;
  }

  Future<void> calculatePayroll(String runId) =>
      callRpc('calculate_payroll_run', params: {'p_run_id': runId});

  Future<void> postPayroll(String runId) =>
      callRpc('post_payroll_run', params: {'p_run_id': runId});

  /// The bank instruction for a posted run. Lines that cannot be paid
  /// come back flagged rather than missing.
  Future<List<PaymentLine>> paymentInstruction(String runId) async {
    final data = await callRpc(
      'payroll_payment_instruction',
      params: {'p_run_id': runId},
    );
    return Repo._rows(data).map(PaymentLine.fromJson).toList();
  }

  /// Records that the bank took the file. Separate from producing it,
  /// because only a person can know whether the transfer actually went.
  Future<void> markPayrollPaid(String runId) =>
      callRpc('mark_payroll_paid', params: {'p_run_id': runId});

  // ------------------------------------------------------------------
  // Talent
  // ------------------------------------------------------------------
  Future<List<JobRequisition>> requisitions() async => Repo._rows(
    await client
        .from('job_requisitions')
        // departments is named because 0519 added a same-org composite
        // key alongside the plain one, so it can be joined two ways
        // and PostgREST refuses an unqualified embed.
        // Named because 0521 added a same-org composite key alongside
        // the plain one, so 'applicants' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, departments!job_requisitions_department_id_fkey(name), applicants!applicants_requisition_id_fkey(count)')
        .eq('org_id', orgId)
        .order('created_at', ascending: false),
  ).map(JobRequisition.fromJson).toList();

  /// Raise or amend a vacancy.
  ///
  /// `job_requisitions` had no writer at all until `0394` — the table
  /// was reachable only from a database connection, while `0381` hired
  /// against its rows and counted places against its headcount.
  ///
  /// `status`, `opened_date` and `closed_date` are not sent from here:
  /// `open_requisition` and `close_requisition` own them, because a date
  /// typed beside a status is a date that can disagree with it.
  Future<void> saveRequisition(
    Map<String, dynamic> values, {
    String? id,
  }) async {
    if (id == null) {
      await client.from('job_requisitions').insert({
        ...values,
        'org_id': orgId,
      });
    } else {
      await client
          .from('job_requisitions')
          .update({...values, 'updated_at': DateTime.now().toIso8601String()})
          .eq('id', id)
          .eq('org_id', orgId);
    }
  }

  /// Open a vacancy. The date is the act's, not a form field's.
  Future<void> openRequisition(String id, {DateTime? on}) => callRpc(
    'open_requisition',
    params: {'p_requisition': id, if (on != null) 'p_opened_on': Fmt.iso(on)},
  );

  /// Put it on hold, or cancel it. Filling one is hiring somebody,
  /// which `hire_applicant` does.
  Future<void> closeRequisition(String id, {String status = 'cancelled'}) =>
      callRpc(
        'close_requisition',
        params: {'p_requisition': id, 'p_status': status},
      );

  /// Every vacancy still running, with how long it has been open.
  Future<List<Map<String, dynamic>>> openVacancies() async => Repo._rows(
    await callRpc('report_open_vacancies', params: {'p_org_id': orgId}),
  );

  Future<List<Applicant>> applicants({String? requisitionId}) async {
    var q = client
        .from('applicants')
        .select(
          '*, job_requisitions!applicants_requisition_id_fkey(title), '
          // Who introduced them, by name. `referred_by` was a
          // reference nothing wrote before `0381`.
          'referrer:employees!applicants_referred_by_fkey(full_name)',
        )
        .eq('org_id', orgId);
    if (requisitionId != null) q = q.eq('requisition_id', requisitionId);
    return Repo._rows(
      await q.order('applied_at', ascending: false),
    ).map(Applicant.fromJson).toList();
  }

  Future<void> saveApplicant(Map<String, dynamic> values, {String? id}) async {
    if (id != null) {
      await client.from('applicants').update(values).eq('id', id);
    } else {
      await client.from('applicants').insert({...values, 'org_id': orgId});
    }
  }

  /// Turns a candidate into an employee and links the two records.
  ///
  /// An RPC rather than an insert plus an update, because the whole
  /// point is that they cannot come apart: `hired_employee_id` carried a
  /// comment saying it was set when this happened, nothing set it, and
  /// somebody retyped the name, the phone number and the NRIC from the
  /// record in front of them. It also refuses a start date inside the
  /// notice they owe, and counts the hire against the requisition's
  /// headcount.
  Future<String> hireApplicant(
    String applicantId, {
    required String employeeNo,
    required DateTime hireDate,
    required num basicSalary,
    DateTime? dateOfBirth,
    String? departmentId,
    String? positionId,
    String? managerId,
    String? earlyStartNote,
  }) async {
    final id = await callRpc(
      'hire_applicant',
      params: {
        'p_applicant': applicantId,
        'p_employee_no': employeeNo,
        'p_hire_date': Fmt.iso(hireDate),
        'p_basic_salary': basicSalary,
        'p_date_of_birth': dateOfBirth == null ? null : Fmt.iso(dateOfBirth),
        'p_department': departmentId,
        'p_position': positionId,
        'p_manager': managerId,
        'p_early_start_note': earlyStartNote,
      },
    );
    return id.toString();
  }

  Future<List<Map<String, dynamic>>> referralHires({
    DateTime? from,
    DateTime? to,
  }) async => Repo._rows(
    await callRpc(
      'report_referral_hires',
      params: {
        'p_org': orgId,
        'p_from': from == null ? null : Fmt.iso(from),
        'p_to': to == null ? null : Fmt.iso(to),
      },
    ),
  );

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

  Future<List<Appraisal>> appraisals() async => Repo._rows(
    await client
        .from('appraisals')
        .select(
          '*, employees!appraisals_employee_id_fkey(full_name), '
          'reviewer:employees!appraisals_reviewer_id_fkey(full_name), '
          'appraisal_cycles!appraisals_cycle_id_fkey(name, rating_scale_max, self_review_due, '
          'manager_review_due)',
        )
        .eq('org_id', orgId)
        .order('created_at', ascending: false),
  ).map(Appraisal.fromJson).toList();
}

/// The performance cycle: opening one, the two halves, and settling it.
///
/// Every write here is an RPC rather than a table update. `0379` put a
/// trigger on `appraisals` that judges *which columns moved and who
/// moved them* — a row policy grants the row and has no opinion about
/// columns, so before it the person being appraised could write their
/// own manager rating and their own final rating. Going through the
/// functions means the screen and the database agree about whose half
/// is whose instead of the screen finding out by being refused.
extension RepoAppraisalCycle on Repo {
  Future<List<AppraisalCycle>> appraisalCycles() async => Repo._rows(
    await client
        .from('appraisal_cycles')
        // Named because 0521 added a same-org composite key alongside
        // the plain one, so 'appraisals' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, appraisals!appraisals_cycle_id_fkey(count)')
        .eq('org_id', orgId)
        .order('period_end', ascending: false),
  ).map(AppraisalCycle.fromJson).toList();

  Future<void> saveAppraisalCycle(
    Map<String, dynamic> values, {
    String? id,
  }) async {
    if (id != null) {
      await client.from('appraisal_cycles').update(values).eq('id', id);
    } else {
      await client.from('appraisal_cycles').insert({
        ...values,
        'org_id': orgId,
      });
    }
  }

  /// Opens one appraisal per person employed at the end of the period.
  /// Returns how many it opened; running it again opens nobody twice.
  Future<int> openAppraisalCycle(String cycleId) async {
    final n = await callRpc(
      'open_appraisal_cycle',
      params: {'p_cycle': cycleId},
    );
    return (n as num?)?.toInt() ?? 0;
  }

  Future<void> submitSelfAppraisal(
    String appraisalId, {
    required num rating,
    required String comments,
  }) => callRpc(
    'submit_self_appraisal',
    params: {
      'p_appraisal': appraisalId,
      'p_rating': rating,
      'p_comments': comments,
    },
  );

  Future<void> submitManagerAppraisal(
    String appraisalId, {
    required num rating,
    required String comments,
    num? increment,
    num? bonus,
    bool promotion = false,
    String? developmentPlan,
  }) => callRpc(
    'submit_manager_appraisal',
    params: {
      'p_appraisal': appraisalId,
      'p_rating': rating,
      'p_comments': comments,
      'p_increment': increment,
      'p_bonus': bonus,
      'p_promotion': promotion,
      'p_development_plan': developmentPlan,
    },
  );

  Future<void> finaliseAppraisal(
    String appraisalId, {
    required num finalRating,
    String? calibrationNote,
  }) => callRpc(
    'finalise_appraisal',
    params: {
      'p_appraisal': appraisalId,
      'p_final_rating': finalRating,
      'p_calibration_note': calibrationNote,
    },
  );

  /// Clears one half's submission stamp so its author can write it
  /// again. What was written stays, so they edit their own words rather
  /// than starting from a blank box.
  Future<void> reopenAppraisal(String appraisalId, String side) => callRpc(
    'reopen_appraisal',
    params: {'p_appraisal': appraisalId, 'p_side': side},
  );

  /// Which part the caller holds on each appraisal they can see, as the
  /// database works it out. Asked for rather than computed here so the
  /// buttons and the trigger cannot come to disagree.
  Future<Map<String, String>> myAppraisalParts() async {
    final data = await callRpc('my_appraisal_parts', params: {'p_org': orgId});
    return {
      for (final r in Repo._rows(data))
        r['appraisal_id'] as String: r['my_part']?.toString() ?? '',
    };
  }

  Future<List<AppraisalDue>> appraisalsDue({DateTime? asAt}) async {
    final data = await callRpc(
      'report_appraisals_due',
      params: {'p_org': orgId, if (asAt != null) 'p_as_at': Fmt.iso(asAt)},
    );
    return Repo._rows(data).map(AppraisalDue.fromJson).toList();
  }
}

/// Auditor access to payslips: requested, approved by a company admin,
/// and time-boxed so it lapses without anyone having to remember.
extension RepoPayslipAccess on Repo {
  Future<bool> myPayslipAccess() async {
    final data = await callRpc(
      'my_payslip_access',
      params: {'p_org_id': orgId},
    );
    return data == true;
  }

  Future<List<PayslipAccessRequest>> payslipAccessRequests() async {
    final rows = await client
        .from('payslip_access_requests')
        .select(
          '*, requester:profiles!payslip_access_requests_requested_by_fkey'
          '(full_name, email), '
          'decider:profiles!payslip_access_requests_decided_by_fkey'
          '(full_name, email)',
        )
        .eq('org_id', orgId)
        .order('requested_at', ascending: false);
    return Repo._rows(rows).map(PayslipAccessRequest.fromJson).toList();
  }

  Future<void> requestPayslipAccess({
    required String reason,
    DateTime? from,
    DateTime? to,
  }) => callRpc(
    'request_payslip_access',
    params: {
      'p_org_id': orgId,
      'p_reason': reason,
      if (from != null) 'p_period_from': Fmt.iso(from),
      if (to != null) 'p_period_to': Fmt.iso(to),
    },
  );

  Future<void> decidePayslipAccess(
    String id,
    bool approve, {
    String? note,
    int days = 30,
  }) => callRpc(
    'decide_payslip_access',
    params: {
      'p_request_id': id,
      'p_approve': approve,
      if (note != null) 'p_note': note,
      'p_days': days,
    },
  );

  Future<void> revokePayslipAccess(String id, {String? note}) => callRpc(
    'revoke_payslip_access',
    params: {'p_request_id': id, if (note != null) 'p_note': note},
  );

  /// Payslips a granted reader may see. Goes through a function rather
  /// than the table because the function writes the read into the log —
  /// there is no unlogged way in.
  Future<List<Payslip>> auditPayslips({String? runId}) async {
    final data = await callRpc(
      'audit_list_payslips',
      params: {'p_org_id': orgId, if (runId != null) 'p_run_id': runId},
    );
    return (data as List)
        .map((e) => Payslip.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<Payslip?> auditPayslip(String id) async {
    final data = await callRpc(
      'audit_view_payslip',
      params: {'p_payslip_id': id},
    );
    return data == null
        ? null
        : Payslip.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Who has opened which payslip, and under whose grant.
  Future<List<PayslipAccessLogEntry>> payslipAccessLog({
    int limit = 100,
  }) async {
    final rows = await client
        .from('payslip_access_log')
        .select(
          '*, actor:profiles!payslip_access_log_actor_id_fkey'
          '(full_name, email)',
        )
        .eq('org_id', orgId)
        .order('viewed_at', ascending: false)
        .limit(limit);
    return Repo._rows(rows).map(PayslipAccessLogEntry.fromJson).toList();
  }

  /// Who changed what. The function refuses anyone who is not an owner
  /// or admin, because the diffs carry salaries and bank details.
  ///
  /// 0634 added the two filters somebody actually arrives with — a
  /// person and a range of days. Do not re-read on every keystroke of a
  /// date field: this is a read that WRITES a `sensitive_read`, and one
  /// event per keystroke buries the ones somebody is looking for.
  Future<List<AuditEntry>> auditTrail({
    String? table,
    String? recordId,
    int limit = 100,
    String? actorId,
    DateTime? from,
    DateTime? to,
  }) async {
    final rows = await callRpc(
      'audit_trail',
      params: {
        'p_org_id': orgId,
        'p_table': table,
        'p_record_id': recordId,
        'p_limit': limit,
        'p_actor_id': actorId,
        'p_from': from == null ? null : Fmt.iso(from),
        'p_to': to == null ? null : Fmt.iso(to),
      },
    );
    return Repo._rows(rows).map(AuditEntry.fromJson).toList();
  }

  /// Who appears in the change history, busiest first, for the filter.
  ///
  /// Deliberately not a sensitive read on the server: it is a list of
  /// names for a dropdown, and recording one for drawing a dropdown
  /// fills the security log with events nobody caused.
  Future<List<Map<String, dynamic>>> auditTrailActors() async =>
      Repo._rows(await callRpc(
        'audit_trail_actors',
        params: {'p_org_id': orgId},
      ));

  /// Who got in, what they took out, what they looked at and what they
  /// were refused. Owners and admins only -- the rows carry everybody's
  /// working address.
  Future<List<SecurityEvent>> securityLog({
    String? kind,
    DateTime? since,
    int limit = 200,
  }) async {
    final rows = await callRpc(
      'security_log',
      params: {
        'p_org_id': orgId,
        'p_kind': kind,
        'p_since': since?.toUtc().toIso8601String(),
        'p_limit': limit,
      },
    );
    return Repo._rows(rows).map(SecurityEvent.fromMap).toList();
  }

  Future<Map<String, dynamic>> securitySummary({int days = 30}) async {
    final data = await callRpc(
      'security_summary',
      params: {'p_org_id': orgId, 'p_days': days},
    );
    if (data is Map) return Map<String, dynamic>.from(data);
    return const {};
  }

  /// A copy of something leaving the building. Called by
  /// `exportTextFile` and `exportBytesFile` rather than by screens.
  Future<void> recordExport(String what, [String? detail]) => client.rpc(
    'record_export',
    params: {'p_org_id': orgId, 'p_what': what, 'p_detail': detail},
  );

  /// A refusal the server has already made, reported back so it is
  /// written down. See 0235: a refusal cannot record itself, because the
  /// exception that carries it unwinds the transaction the record was
  /// written in.
  Future<void> reportDenied(String action, [String? message]) => client.rpc(
    'report_denied',
    params: {'p_org_id': orgId, 'p_action': action, 'p_message': message},
  );
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

  Future<List<Map<String, dynamic>>> setupRows(
    String table, {
    String orderBy = 'name',
  }) async => Repo._rows(
    await client.from(table).select().eq('org_id', orgId).order(orderBy, ascending: true),
  );

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
      Repo._rows(
        await client
            .from('public_holidays')
            .select()
            .eq('org_id', orgId)
            .gte('holiday_date', '$year-01-01')
            .lte('holiday_date', '$year-12-31')
            .order('holiday_date', ascending: true),
      );

  /// Fills in the four federal holidays that fall on a fixed date. The
  /// lunar ones are gazetted each year and are not guessed.
  Future<int> addFixedHolidays(int year) async {
    final data = await callRpc(
      'add_fixed_public_holidays',
      params: {'p_org_id': orgId, 'p_year': year},
    );
    return Fmt.toInt(data);
  }

  // ------------------------------------------------------------------
  // Leave entitlement bands
  //
  // Not `setupRows`: the table carries no `org_id` at all — it hangs off
  // its leave type, and RLS reaches the organization through that.
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> leaveBands(String leaveTypeId) async =>
      Repo._rows(
        await client
            .from('leave_entitlement_bands')
            .select()
            .eq('leave_type_id', leaveTypeId)
            .order('service_years_from', ascending: true),
      );

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
  Future<int> applyStatutoryLeaveBands(
    String leaveTypeId,
    String preset,
  ) async {
    final data = await callRpc(
      'apply_statutory_leave_bands',
      params: {'p_leave_type_id': leaveTypeId, 'p_preset': preset},
    );
    return Fmt.toInt(data);
  }

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
      Repo._rows(
        await client
            .from('item_prices')
            // Named because 0521 added a same-org composite key alongside
        // the plain one, so 'price_levels' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, price_levels!item_prices_price_level_id_fkey(code, name)')
            .eq('item_id', itemId)
            .order('min_quantity', ascending: true),
      );

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
      Repo._rows(
        await client
            .from('contact_persons')
            .select()
            .eq('contact_id', contactId)
            .order('is_primary', ascending: false)
            .order('name', ascending: true),
      );

  Future<void> saveContactPerson(
    Map<String, dynamic> values, {
    String? id,
  }) async {
    if (id != null) {
      await client.from('contact_persons').update(values).eq('id', id);
    } else {
      await client.from('contact_persons').insert({...values, 'org_id': orgId});
    }
  }

  Future<List<Map<String, dynamic>>> contactAddresses(String contactId) async =>
      Repo._rows(
        await client
            .from('contact_addresses')
            .select()
            .eq('contact_id', contactId)
            .order('is_default', ascending: false)
            .order('label', ascending: true),
      );

  Future<void> saveContactAddress(
    Map<String, dynamic> values, {
    String? id,
  }) async {
    if (id != null) {
      await client.from('contact_addresses').update(values).eq('id', id);
    } else {
      await client.from('contact_addresses').insert({
        ...values,
        'org_id': orgId,
      });
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
    return Repo._rows(await q.order('created_at', ascending: false).limit(300));
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
    final data = await callRpc(
      'convert_lead',
      params: {
        'p_lead_id': leadId,
        'p_create_opportunity': createOpportunity,
        if (pipelineId != null) 'p_pipeline_id': pipelineId,
        if (amount != null) 'p_amount': amount,
        if (expectedClose != null)
          'p_expected_close_date': Fmt.iso(expectedClose),
      },
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<List<Map<String, dynamic>>> pipelines() async => Repo._rows(
    await client
        .from('pipelines')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('sort_order', ascending: true),
  );

  // ------------------------------------------------------------------
  // Interviews
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> interviews(String applicantId) async =>
      Repo._rows(
        await client
            .from('interviews')
            .select('*, employees:interviewer_id(full_name)')
            .eq('applicant_id', applicantId)
            .order('round_no', ascending: true),
      );

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
    String templateId,
  ) async => Repo._rows(
    await client
        .from('onboarding_template_items')
        .select()
        .eq('template_id', templateId)
        .order('sort_order', ascending: true),
  );

  Future<void> saveTemplateItem(
    Map<String, dynamic> values, {
    String? id,
  }) async {
    if (id != null) {
      await client
          .from('onboarding_template_items')
          .update(values)
          .eq('id', id);
    } else {
      await client.from('onboarding_template_items').insert({
        ...values,
        'org_id': orgId,
      });
    }
  }

  Future<List<Map<String, dynamic>>> onboardingChecklists({
    bool openOnly = true,
  }) async {
    var q = client
        .from('onboarding_checklists')
        .select(
          '*, employees!onboarding_checklists_employee_id_fkey'
          '(full_name, employee_no), '
          'onboarding_tasks!onboarding_tasks_checklist_id_fkey(id, is_done, is_mandatory)',
        )
        .eq('org_id', orgId);
    if (openOnly) q = q.isFilter('completed_at', null);
    return Repo._rows(await q.order('start_date', ascending: false).limit(200));
  }

  Future<List<Map<String, dynamic>>> onboardingTasks(
    String checklistId,
  ) async => Repo._rows(
    await client
        .from('onboarding_tasks')
        .select('*, employees:owner_employee_id(full_name)')
        .eq('checklist_id', checklistId)
        .order('sort_order', ascending: true),
  );

  /// Materialises the template's items as dated tasks. Copied rather
  /// than referenced, so editing the template later does not move the
  /// due dates of an onboarding already under way.
  Future<String> startOnboarding({
    required String employeeId,
    String? templateId,
    DateTime? startDate,
    String kind = 'onboarding',
  }) async {
    final data = await callRpc(
      'start_onboarding',
      params: {
        'p_employee_id': employeeId,
        if (templateId != null) 'p_template_id': templateId,
        if (startDate != null) 'p_start_date': Fmt.iso(startDate),
        'p_kind': kind,
      },
    );
    return data as String;
  }

  /// Returns true when that tick finished the checklist.
  Future<bool> setOnboardingTaskDone(String taskId, bool done) async {
    final data = await callRpc(
      'set_onboarding_task_done',
      params: {'p_task_id': taskId, 'p_done': done},
    );
    return data == true;
  }

  // ------------------------------------------------------------------
  // What an employee record hangs off: dependants, documents, shifts
  // ------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> employeeRows(
    String table,
    String employeeId, {
    String select = '*',
    String orderBy = 'created_at',
  }) async => Repo._rows(
    await client
        .from(table)
        .select(select)
        .eq('employee_id', employeeId)
        .order(orderBy, ascending: true),
  );

  Future<void> saveEmployeeRow(
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

  // ------------------------------------------------------------------
  // Sharing a document with somebody who has no login
  //
  // The token comes back exactly once and is never stored in the clear,
  // so a caller that loses it has to issue a new link rather than look
  // the old one up.
  // ------------------------------------------------------------------
  /// Give one customer a link to their whole account.
  ///
  /// 0493. The sibling of [shareDocument], one step wider: that shares
  /// a document, this shares what the customer owes. Returns the URL
  /// and the address it was emailed to, so somebody reading it out over
  /// the phone can, and a contact with no address on file is not a
  /// reason to refuse.
  Future<Map<String, dynamic>> shareCustomerPortal(
    String contactId, {
    int validDays = 60,
    String? email,
  }) async {
    final data = await callRpc(
      'share_customer_portal',
      params: {
        'p_contact_id': contactId,
        'p_valid_days': validDays,
        'p_email': email,
      },
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<void> revokeCustomerPortal(String contactId) => callRpc(
    'revoke_customer_portal',
    params: {'p_contact_id': contactId},
  );

  /// The links issued to this customer, newest first.
  ///
  /// Read off the table rather than through a function: a member of the
  /// company may select it, and what the screen needs is whether one is
  /// live and whether it has been opened. The token itself is not
  /// there — only its hash ever was.
  Future<List<Map<String, dynamic>>> customerPortalLinks(
    String contactId,
  ) async => Repo._rows(
    await client
        .from('customer_portal_links')
        .select('expires_at, revoked_at, last_opened_at, open_count, '
            'sent_to_email, created_at')
        .eq('contact_id', contactId)
        .order('created_at', ascending: false)
        .limit(10),
  );

  /// What one contact owes and what they have in hand against it.
  ///
  /// 0630. Both sides in one question, because a knock-off screen that
  /// asked twice would show two moments of the same account.
  Future<List<Map<String, dynamic>>> openItems(String contactId) async =>
      Repo._rows(await callRpc(
        'open_items',
        params: {'p_contact_id': contactId},
      ));

  /// Set several credits against several invoices, all or none.
  ///
  /// 0629 and 0630. No journal moves: a credit note credited the
  /// receivable when it was raised and a receipt credited it when it
  /// was banked, which is exactly why this batch is safe to apply in
  /// one statement. Returns how many lines landed.
  Future<int> knockOff(
    String contactId,
    List<Map<String, dynamic>> lines,
  ) async {
    final n = await callRpc(
      'knock_off',
      params: {'p_contact_id': contactId, 'p_lines': lines},
    );
    return (n as num?)?.toInt() ?? 0;
  }

  /// Purchase documents already on the books that look like this one.
  ///
  /// 0628. By the supplier's own number, or -- where the paper carries
  /// no number, which is most till receipts -- by amount and date. It
  /// warns and refuses nothing: a supplier re-issuing a corrected
  /// invoice under the same number is real, and the workaround people
  /// find for a check that is wrong a tenth of the time is to type the
  /// number differently, which destroys the only field it runs on.
  Future<List<Map<String, dynamic>>> duplicatePurchaseDocuments({
    required String contactId,
    String docType = 'bill',
    String? supplierDocNo,
    DateTime? docDate,
    double? totalAmount,
    String? excludeId,
  }) async => Repo._rows(await callRpc(
    'duplicate_purchase_documents',
    params: {
      'p_contact_id': contactId,
      'p_doc_type': docType,
      'p_supplier_doc_no': supplierDocNo,
      'p_doc_date': docDate == null ? null : Fmt.iso(docDate),
      'p_total_amount': totalAmount,
      'p_exclude_id': excludeId,
    },
  ));

  // ------------------------------------------------------------------
  // 0626. Asking a customer for their own tax details.
  //
  // The same mechanism as the portal above, pointed at a form instead
  // of at a statement. The important thing about it is not here: the
  // public submission fills BLANK fields only and never overwrites, and
  // that rule lives in `app.tax_submission_apply` where a client cannot
  // reach it.
  // ------------------------------------------------------------------

  /// Email this contact a link to fill in their own TIN.
  ///
  /// Returns the URL and the address it went to, so somebody reading it
  /// out over the telephone can, and a contact with no address on file
  /// is not a reason to refuse.
  Future<Map<String, dynamic>> requestTaxDetails(
    String contactId, {
    int validDays = 30,
    String? email,
  }) async {
    final data = await callRpc(
      'request_tax_details',
      params: {
        'p_contact_id': contactId,
        'p_valid_days': validDays,
        'p_email': email,
      },
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<void> revokeTaxDetailRequest(String contactId) => callRpc(
    'revoke_tax_detail_request',
    params: {'p_contact_id': contactId},
  );

  /// The tax-details links issued to this contact, newest first.
  ///
  /// Off the table for [customerPortalLinks]'s reason: a member of the
  /// company may select it, and the token itself was never there.
  /// `submission_count` is the column the status line turns on — a link
  /// that was opened and not answered is the one worth chasing.
  Future<List<Map<String, dynamic>>> taxDetailLinks(String contactId) async =>
      Repo._rows(
        await client
            .from('tax_detail_requests')
            .select('expires_at, revoked_at, last_opened_at, open_count, '
                'submission_count, sent_to_email, created_at')
            .eq('contact_id', contactId)
            .order('created_at', ascending: false)
            .limit(10),
      );

  /// What customers have said that disagrees with what is on file.
  ///
  /// Both sides of every disagreement come back, because "they say
  /// C1234567890" is not answerable without "you hold C9999999999".
  Future<List<Map<String, dynamic>>> pendingTaxSubmissions() async =>
      Repo._rows(await callRpc(
        'pending_tax_submissions',
        params: {'p_org_id': orgId},
      ));

  /// Accept what a customer said over what the contact already holds.
  ///
  /// This is the only path that overwrites; the public form cannot.
  /// Where the TIN, the ID type or the ID number moves, the verified
  /// tick goes with it — decided in SQL, not here.
  Future<Map<String, dynamic>> applyTaxSubmission(String submissionId) async {
    final data = await callRpc(
      'apply_tax_submission',
      params: {'p_submission_id': submissionId},
    );
    return Map<String, dynamic>.from(data as Map);
  }

  Future<void> dismissTaxSubmission(String submissionId) => callRpc(
    'dismiss_tax_submission',
    params: {'p_submission_id': submissionId},
  );

  Future<String> shareDocument(
    String documentId, {
    int validDays = 30,
    String? email,
  }) async {
    final data = await callRpc(
      'share_document',
      params: {
        'p_document_id': documentId,
        'p_valid_days': validDays,
        if (email != null && email.trim().isNotEmpty) 'p_email': email.trim(),
      },
    );
    return data as String;
  }

  Future<int> revokeDocumentShare(String documentId) async {
    final data = await callRpc(
      'revoke_document_share',
      params: {'p_document_id': documentId},
    );
    return Fmt.toInt(data);
  }

  Future<List<Map<String, dynamic>>> documentShareLinks(
    String documentId,
  ) async => Repo._rows(
    await client
        .from('document_share_links')
        .select()
        .eq('document_id', documentId)
        .order('created_at', ascending: false),
  );

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
  Future<String> emailDocument(
    String documentId, {
    String? to,
    String templateCode = 'document_new',
    String dispatch = 'queued',
    String? attachmentPath,
    String? attachmentName,
  }) async {
    final data = await callRpc(
      'email_document',
      params: {
        'p_document_id': documentId,
        if (to != null && to.trim().isNotEmpty) 'p_to': to.trim(),
        'p_template_code': templateCode,
        'p_dispatch': dispatch,
        if (attachmentPath != null) 'p_attachment_path': attachmentPath,
        if (attachmentName != null) 'p_attachment_name': attachmentName,
      },
    );
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
    String documentId,
    String fileName,
    Uint8List bytes,
  ) async {
    final path = '$orgId/sales_documents/$documentId/$fileName';
    await client.storage
        .from('attachments')
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'application/pdf',
            upsert: true,
          ),
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
  Future<Map<String, dynamic>> emailDocumentNow(
    String documentId, {
    String? to,
    String templateCode = 'document_new',
    String? attachmentPath,
    String? attachmentName,
  }) async {
    final id = await emailDocument(
      documentId,
      to: to,
      templateCode: templateCode,
      dispatch: 'immediate',
      attachmentPath: attachmentPath,
      attachmentName: attachmentName,
    );
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
  Future<String> emailReceipt(
    String receiptId, {
    String? to,
    String dispatch = 'queued',
    String? attachmentPath,
    String? attachmentName,
  }) async {
    final data = await callRpc(
      'email_receipt',
      params: {
        'p_receipt_id': receiptId,
        if (to != null && to.trim().isNotEmpty) 'p_to': to.trim(),
        'p_dispatch': dispatch,
        if (attachmentPath != null) 'p_attachment_path': attachmentPath,
        if (attachmentName != null) 'p_attachment_name': attachmentName,
      },
    );
    return data as String;
  }

  /// Queues the receipt and drains that row immediately, returning the
  /// row as it stands afterwards. Same contract as [emailDocumentNow].
  Future<Map<String, dynamic>> emailReceiptNow(
    String receiptId, {
    String? to,
    String? attachmentPath,
    String? attachmentName,
  }) async {
    final id = await emailReceipt(
      receiptId,
      to: to,
      dispatch: 'immediate',
      attachmentPath: attachmentPath,
      attachmentName: attachmentName,
    );
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
    String receiptId,
    String fileName,
    Uint8List bytes,
  ) async {
    final path = '$orgId/receipts/$receiptId/$fileName';
    await client.storage
        .from('attachments')
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'application/pdf',
            upsert: true,
          ),
        );
    return path;
  }

  /// What has been emailed for this receipt, newest first.
  Future<List<Map<String, dynamic>>> receiptEmails(String receiptId) async =>
      Repo._rows(
        await client
            .from('email_outbox')
            .select(
              'id, to_email, status, dispatch, queued_at, sent_at, '
              'last_error, attachment_name',
            )
            .eq('receipt_id', receiptId)
            .order('queued_at', ascending: false),
      );

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
        // `bank_accounts` is reachable twice from both tables — the plain
        // key and a composite (org_id, bank_account_id) same-org guard —
        // so the embed has to name which. The constraint is per table,
        // hence the interpolation.
        .select(
          '*, contacts!${table}_contact_id_fkey(name, code), '
          'bank_accounts!${table}_bank_account_id_fkey(name)',
        )
        .eq('org_id', orgId)
        .filter('deleted_at', 'is', null);
    if (contactId != null) q = q.eq('contact_id', contactId);
    return Repo._rows(await q.order(dateField, ascending: false).limit(limit));
  }

  /// One settlement with what it was set against.
  ///
  /// The document embed names its constraint because
  /// `payment_allocations` reaches `sales_documents` twice — once for the
  /// invoice being paid and once for a credit note being applied. Left
  /// ambiguous, PostgREST refuses the whole query.
  Future<Map<String, dynamic>> settlement(
    String id, {
    required bool isSales,
  }) async {
    final table = isSales ? 'receipts' : 'purchase_payments';
    final head = await client
        .from(table)
        .select(
          '*, contacts!${table}_contact_id_fkey(name, code, email, '
          'address_line1, address_line2, city, postcode, state_code), '
          'bank_accounts!${table}_bank_account_id_fkey(name)',
        )
        .eq('id', id)
        .single();

    final allocations = Repo._rows(
      await client
          .from('payment_allocations')
          .select(
            isSales
                ? 'amount, discount_amount, '
                      'sales_documents!payment_allocations_invoice_id_fkey'
                      '(doc_no, doc_type, doc_date, total_amount)'
                : 'amount, discount_amount, '
                      'purchase_documents!payment_allocations_bill_fk'
                      '(doc_no, doc_type, doc_date, total_amount)',
          )
          .eq(isSales ? 'receipt_id' : 'payment_id', id)
          .order('created_at', ascending: true),
    );

    return {
      ...Map<String, dynamic>.from(head as Map),
      'allocations': allocations,
    };
  }

  /// Everything that ever left the building for this document: messages,
  /// share links and PDF downloads, newest first.
  Future<List<Map<String, dynamic>>> documentActivity(
    String documentId,
  ) async => Repo._rows(
    await callRpc('document_activity', params: {'p_document_id': documentId}),
  );

  /// Records that somebody took the PDF. The file is built in the
  /// browser, so this is a record of what the app did rather than an
  /// access log — see the migration for why that distinction matters.
  Future<void> logDocumentDownload(String documentId) async {
    await callRpc(
      'log_document_download',
      params: {'p_document_id': documentId},
    );
  }

  Future<List<Map<String, dynamic>>> emailOutbox({String? status}) async {
    var q = client
        .from('email_outbox')
        // Named because 0516 added a same-org composite key alongside
        // the plain one, so 'sales_documents' can now be joined two
        // ways and PostgREST refuses the embed with PGRST201.
        .select('*, sales_documents!email_outbox_document_id_fkey(doc_no)')
        .eq('org_id', orgId);
    if (status != null && status != 'all') q = q.eq('status', status);
    return Repo._rows(await q.order('queued_at', ascending: false).limit(200));
  }

  /// Asks the edge function to drain the queue now rather than waiting
  /// for the schedule. Used from the outbox when somebody has just
  /// fixed whatever was wrong.
  Future<Map<String, dynamic>> sendQueuedEmail({String? id}) async {
    final res = await client.functions.invoke(
      'send-email',
      body: {if (id != null) 'id': id},
    );
    return Map<String, dynamic>.from(res.data as Map? ?? {});
  }

  Future<List<Map<String, dynamic>>> appraisalGoals(String appraisalId) async =>
      Repo._rows(
        await client
            .from('appraisal_goals')
            .select()
            .eq('appraisal_id', appraisalId)
            .order('sort_order', ascending: true),
      );

  Future<void> saveAppraisalGoal(
    Map<String, dynamic> values, {
    String? id,
  }) async {
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

/// Property: two modules over one spine.
///
/// A site is strata or it is not, and that decides which half of this
/// applies to it; nothing here chooses, it only asks.
///
/// Every figure comes back from the database. The preview an owner is
/// shown and the invoice an owner receives are the same function called
/// twice, so there is nowhere for the two to disagree.
extension RepoProperty on Repo {
  Future<List<Map<String, dynamic>>> propertySites({String? tenure}) async {
    var q = client
        .from('property_sites')
        .select('*, property_units!property_units_site_id_fkey(count)')
        .eq('org_id', orgId)
        .eq('is_active', true);
    if (tenure != null) q = q.eq('tenure', tenure);
    return Repo._rows(await q.order('name', ascending: true));
  }

  Future<Map<String, dynamic>> propertySite(String id) async =>
      Map<String, dynamic>.from(
        await client
            .from('property_sites')
            .select('*, strata_schemes!strata_schemes_site_id_fkey(*)')
            .eq('id', id)
            .eq('org_id', orgId)
            .single(),
      );

  Future<String> savePropertySite(
    Map<String, dynamic> values, {
    String? id,
  }) async {
    if (id == null) {
      final row = await client
          .from('property_sites')
          .insert({...values, 'org_id': orgId})
          .select('id')
          .single();
      return row['id'] as String;
    }
    await client
        .from('property_sites')
        .update(values)
        .eq('id', id)
        .eq('org_id', orgId);
    return id;
  }

  Future<List<Map<String, dynamic>>> propertyUnits(String siteId) async =>
      Repo._rows(
        await client
            .from('property_units')
            .select('*, contacts:owner_contact_id(code, name)')
            .eq('site_id', siteId)
            .eq('org_id', orgId)
            .eq('is_active', true)
            .order('unit_no', ascending: true),
      );

  Future<void> savePropertyUnit(
    Map<String, dynamic> values, {
    String? id,
  }) async {
    if (id == null) {
      await client.from('property_units').insert({...values, 'org_id': orgId});
    } else {
      await client
          .from('property_units')
          .update(values)
          .eq('id', id)
          .eq('org_id', orgId);
    }
  }

  // --- Strata ---------------------------------------------------------

  Future<Map<String, dynamic>?> strataScheme(String siteId) async {
    final rows = Repo._rows(
      await client
          .from('strata_schemes')
          .select(
            '*, strata_charge_rates!strata_charge_rates_scheme_id_fkey(*)',
          )
          .eq('site_id', siteId)
          .eq('org_id', orgId),
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<String> saveStrataScheme(
    Map<String, dynamic> values, {
    String? id,
  }) async {
    if (id == null) {
      final row = await client
          .from('strata_schemes')
          .insert({...values, 'org_id': orgId})
          .select('id')
          .single();
      return row['id'] as String;
    }
    await client
        .from('strata_schemes')
        .update(values)
        .eq('id', id)
        .eq('org_id', orgId);
    return id;
  }

  /// A rate is what an AGM resolved, so it is added and never edited: the
  /// charge raised for January stays raised at January's rate.
  Future<void> addStrataChargeRate(
    String schemeId,
    Map<String, dynamic> values,
  ) => client.from('strata_charge_rates').insert({
    ...values,
    'org_id': orgId,
    'scheme_id': schemeId,
  });

  /// What each parcel would be charged, before anything is written.
  Future<List<Map<String, dynamic>>> strataChargePreview(
    String schemeId,
    DateTime from,
    DateTime to,
  ) async => Repo._rows(
    await callRpc(
      'strata_charge_preview',
      params: {
        'p_scheme_id': schemeId,
        'p_period_from': Fmt.iso(from),
        'p_period_to': Fmt.iso(to),
      },
    ),
  );

  Future<String> raiseStrataCharges(
    String schemeId,
    DateTime from,
    DateTime to, {
    DateTime? dueDate,
  }) async =>
      await callRpc(
            'raise_strata_charges',
            params: {
              'p_scheme_id': schemeId,
              'p_period_from': Fmt.iso(from),
              'p_period_to': Fmt.iso(to),
              'p_due_date': dueDate == null ? null : Fmt.iso(dueDate),
            },
          )
          as String;

  Future<List<Map<String, dynamic>>> strataChargeRuns(String schemeId) async =>
      Repo._rows(
        await client
            .from('strata_charge_runs')
            .select('*')
            .eq('scheme_id', schemeId)
            .eq('org_id', orgId)
            .order('period_from', ascending: false),
      );

  Future<List<Map<String, dynamic>>> strataArrears(
    String schemeId, {
    DateTime? asAt,
  }) async => Repo._rows(
    await callRpc(
      'strata_arrears',
      params: {
        'p_scheme_id': schemeId,
        'p_as_at': Fmt.iso(asAt ?? DateTime.now()),
      },
    ),
  );

  // --- Non-strata -----------------------------------------------------

  Future<List<Map<String, dynamic>>> tenancies({
    String? siteId,
    bool activeOnly = false,
  }) async {
    var q = client
        .from('tenancies')
        .select(
          '*, property_units!tenancies_unit_id_fkey!inner(unit_no, site_id), '
          'contacts:tenant_contact_id(code, name)',
        )
        .eq('org_id', orgId);
    if (siteId != null) q = q.eq('property_units.site_id', siteId);
    if (activeOnly) q = q.eq('status', 'active');
    return Repo._rows(await q.order('tenancy_no', ascending: true));
  }

  Future<void> saveTenancy(Map<String, dynamic> values, {String? id}) async {
    if (id == null) {
      await client.from('tenancies').insert({...values, 'org_id': orgId});
    } else {
      await client
          .from('tenancies')
          .update(values)
          .eq('id', id)
          .eq('org_id', orgId);
    }
  }

  Future<List<Map<String, dynamic>>> rentPreview(
    String siteId,
    DateTime from,
    DateTime to,
  ) async => Repo._rows(
    await callRpc(
      'rent_preview',
      params: {
        'p_site_id': siteId,
        'p_period_from': Fmt.iso(from),
        'p_period_to': Fmt.iso(to),
      },
    ),
  );

  Future<String> raiseRentInvoices(
    String siteId,
    DateTime from,
    DateTime to, {
    DateTime? dueDate,
  }) async =>
      await callRpc(
            'raise_rent_invoices',
            params: {
              'p_site_id': siteId,
              'p_period_from': Fmt.iso(from),
              'p_period_to': Fmt.iso(to),
              'p_due_date': dueDate == null ? null : Fmt.iso(dueDate),
            },
          )
          as String;

  // --- Quit rent and assessment ---------------------------------------

  Future<List<Map<String, dynamic>>> propertyStatutoryDue({
    int withinDays = 60,
  }) async => Repo._rows(
    await callRpc(
      'property_statutory_due',
      params: {'p_org_id': orgId, 'p_within_days': withinDays},
    ),
  );

  Future<List<Map<String, dynamic>>> propertyStatutoryCharges(
    String siteId,
  ) async => Repo._rows(
    await client
        .from('property_statutory_charges')
        // The bill's number, so the list can say what is behind each
        // paid date rather than only that there is one. The constraint
        // is named because `purchase_documents` is reachable from this
        // table only one way today, and naming it keeps a second link
        // from turning the select into a PGRST201 later.
        .select(
          '*, purchase_documents!property_statutory_charges_'
          'bill_document_id_fkey(doc_no)',
        )
        .eq('site_id', siteId)
        .eq('org_id', orgId)
        .order('due_date', ascending: false),
  );

  /// Raise the supplier bill for a quit rent or an assessment.
  ///
  /// The bill is made out of the charge — same amount, same due date,
  /// the site and the period and the account number in the line — so
  /// the two cannot afterwards disagree about what was owed. From here
  /// the charge's paid date is the bill's, and nothing types it.
  Future<String> billStatutoryCharge({
    required String chargeId,
    required String supplierId,
    DateTime? docDate,
    String? supplierDocNo,
  }) async =>
      (await callRpc(
            'bill_statutory_charge',
            params: {
              'p_charge': chargeId,
              'p_supplier': supplierId,
              if (docDate != null) 'p_doc_date': Fmt.iso(docDate),
              if (supplierDocNo != null && supplierDocNo.trim().isNotEmpty)
                'p_supplier_doc_no': supplierDocNo.trim(),
            },
          ))
          as String;

  /// Every statutory charge and what is behind it.
  Future<List<Map<String, dynamic>>> statutoryChargeReport({int? year}) async =>
      Repo._rows(
        await callRpc(
          'report_statutory_charges',
          params: {'p_org_id': orgId, if (year != null) 'p_year': year},
        ),
      );

  Future<void> savePropertyStatutoryCharge(
    Map<String, dynamic> values, {
    String? id,
  }) async {
    if (id == null) {
      await client.from('property_statutory_charges').insert({
        ...values,
        'org_id': orgId,
      });
    } else {
      await client
          .from('property_statutory_charges')
          .update(values)
          .eq('id', id)
          .eq('org_id', orgId);
    }
  }
}

/// Timesheets: hours in, invoice out.
///
/// The billing step is the one that did not exist. `is_billed` and
/// `invoice_id` had been on `time_entries` since the legal module
/// shipped with nothing in the database ever setting them, so recorded
/// time could not become money. `bill_project_time` and
/// `bill_matter_time` are that path, and both refuse to bill the same
/// hour twice.
extension RepoTimesheets on Repo {
  /// [mine] is the ordinary case — somebody filling in their own week.
  Future<List<Map<String, dynamic>>> timeLog({
    DateTime? from,
    DateTime? to,
    String? projectId,
    bool mine = false,
    bool unbilledOnly = false,
  }) async {
    var q = client
        .from('time_entries')
        .select(
          '*, projects!time_entries_project_id_fkey(code, name), '
          'matters!time_entries_matter_id_fkey(matter_no, name)',
        )
        .eq('org_id', orgId);
    if (from != null) q = q.gte('entry_date', Fmt.iso(from));
    if (to != null) q = q.lte('entry_date', Fmt.iso(to));
    if (projectId != null) q = q.eq('project_id', projectId);
    if (mine) q = q.eq('user_id', client.auth.currentUser!.id);
    if (unbilledOnly) q = q.eq('is_billed', false).eq('is_billable', true);
    return Repo._rows(await q.order('entry_date', ascending: false));
  }

  /// The rate is left out on purpose: a trigger resolves it from the
  /// billing rates, so somebody logging two hours does not have to know
  /// what they are charged out at.
  Future<void> saveTimeEntry(Map<String, dynamic> values, {String? id}) async {
    if (id == null) {
      await client.from('time_entries').insert({
        ...values,
        'org_id': orgId,
        'user_id': values['user_id'] ?? client.auth.currentUser!.id,
      });
    } else {
      await client
          .from('time_entries')
          .update(values)
          .eq('id', id)
          .eq('org_id', orgId);
    }
  }

  Future<List<Map<String, dynamic>>> billingRates() async => Repo._rows(
    await client
        .from('billing_rates')
        .select('*, projects!billing_rates_project_id_fkey(code, name)')
        .eq('org_id', orgId)
        .order('effective_from', ascending: false),
  );

  Future<void> addBillingRate(Map<String, dynamic> values) =>
      client.from('billing_rates').insert({...values, 'org_id': orgId});

  Future<String> billProjectTime(
    String projectId,
    DateTime from,
    DateTime to, {
    DateTime? dueDate,
  }) async =>
      await callRpc(
            'bill_project_time',
            params: {
              'p_project_id': projectId,
              'p_from': Fmt.iso(from),
              'p_to': Fmt.iso(to),
              'p_due': dueDate == null ? null : Fmt.iso(dueDate),
            },
          )
          as String;

  Future<String> billMatterTime(
    String matterId,
    DateTime from,
    DateTime to, {
    DateTime? dueDate,
  }) async =>
      await callRpc(
            'bill_matter_time',
            params: {
              'p_matter_id': matterId,
              'p_from': Fmt.iso(from),
              'p_to': Fmt.iso(to),
              'p_due': dueDate == null ? null : Fmt.iso(dueDate),
            },
          )
          as String;

  /// Hours by person, billable against not, and what is still unbilled.
  Future<List<Map<String, dynamic>>> timesheetReport(
    DateTime from,
    DateTime to,
  ) async => Repo._rows(
    await callRpc(
      'report_timesheet',
      params: {'p_org_id': orgId, 'p_from': Fmt.iso(from), 'p_to': Fmt.iso(to)},
    ),
  );
}

/// Chasing overdue invoices, and remembering that you did.
///
/// `report_collections` reads through `report_ar_aging` rather than
/// counting `sales_documents` a second time, so what this screen shows
/// as owed is the same figure the aged receivables show. Two definitions
/// of "outstanding" eventually disagree, and the collections screen is
/// the worst place to find that out.
extension RepoCollections on Repo {
  Future<List<Map<String, dynamic>>> collectionsWorklist({
    DateTime? asAt,
  }) async => Repo._rows(
    await callRpc(
      'report_collections',
      params: {'p_org_id': orgId, 'p_as_at': Fmt.iso(asAt ?? DateTime.now())},
    ),
  );

  Future<List<Map<String, dynamic>>> collectionHistory(
    String contactId,
  ) async => Repo._rows(
    await callRpc('collection_history', params: {'p_contact_id': contactId}),
  );

  /// The rate is not the only thing the database fills in: `created_by`
  /// and `attempted_on` have defaults, so recording a call is the three
  /// fields somebody actually knows.
  Future<void> logCollectionAttempt({
    required String contactId,
    required String channel,
    required String outcome,
    String? documentId,
    DateTime? attemptedOn,
    DateTime? promiseDate,
    num? promiseAmount,
    String? assignedTo,
    String? notes,
  }) => client.from('collection_attempts').insert({
    'org_id': orgId,
    'contact_id': contactId,
    'channel': channel,
    'outcome': outcome,
    if (documentId != null) 'document_id': documentId,
    if (attemptedOn != null) 'attempted_on': Fmt.iso(attemptedOn),
    if (promiseDate != null) 'promise_date': Fmt.iso(promiseDate),
    if (promiseAmount != null) 'promise_amount': promiseAmount,
    if (assignedTo != null) 'assigned_to': assignedTo,
    if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
    'created_by': client.auth.currentUser?.id,
  });
}

/// Approvals, for anything that reaches the ledger.
///
/// The gate is a trigger on the table, not a check in here — posting a
/// document the chain has not cleared fails wherever it is attempted,
/// including from paths this class does not know about. What these
/// methods add is the part a trigger cannot do: telling somebody *why*
/// before they try, and giving them somewhere to send it.
extension RepoApprovals on Repo {
  /// What is on this person's desk, in this company. Never their own
  /// documents: `my_approvals` excludes them for the same reason
  /// `decide_approval` refuses them.
  Future<List<Map<String, dynamic>>> myApprovals() async =>
      Repo._rows(await callRpc('my_approvals', params: {'p_org_id': orgId}));

  /// Whether this document needs approving, whether it has been, and
  /// whose signature it is waiting on. One round trip, because the
  /// editor asks on every load.
  Future<Map<String, dynamic>?> approvalState(
    String entityKind,
    String entityId,
  ) async {
    final rows = Repo._rows(
      await callRpc(
        'approval_state',
        params: {'p_kind': entityKind, 'p_entity_id': entityId},
      ),
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<String> submitForApproval(String entityKind, String entityId) async =>
      await callRpc(
            'submit_for_approval',
            params: {'p_kind': entityKind, 'p_entity_id': entityId},
          )
          as String;

  /// Returns where the *request* stands afterwards — `pending` when
  /// there are steps still to come, not the fate of the step just
  /// decided.
  Future<String> decideApproval(
    String requestId, {
    required bool approve,
    String? note,
  }) async =>
      await callRpc(
            'decide_approval',
            params: {
              'p_request_id': requestId,
              'p_approve': approve,
              'p_note': note,
            },
          )
          as String;

  Future<List<Map<String, dynamic>>> approvalRules() async => Repo._rows(
    await client
        .from('approval_rules')
        .select()
        .eq('org_id', orgId)
        .order('entity_kind', ascending: true)
        .order('step_no', ascending: true),
  );

  Future<void> saveApprovalRule({
    String? id,
    required String entityKind,
    String? docType,
    required num minAmount,
    required int stepNo,
    String? approverRole,
    String? approverUserId,
    bool isActive = true,
  }) async {
    final row = {
      'org_id': orgId,
      'entity_kind': entityKind,
      'doc_type': docType,
      'min_amount': minAmount,
      'step_no': stepNo,
      // Exactly one of the two, which is what the table's check
      // constraint says. Sending both nulls it out rather than tripping
      // the constraint with a confusing message.
      'approver_role': approverUserId == null ? approverRole : null,
      'approver_user_id': approverRole == null ? approverUserId : null,
      'is_active': isActive,
    };
    if (id == null) {
      await client.from('approval_rules').insert(row);
    } else {
      await client.from('approval_rules').update(row).eq('id', id);
    }
  }

  Future<void> deleteApprovalRule(String id) =>
      client.from('approval_rules').delete().eq('id', id);
}

/// Audited financial statements, and the data MBRS wants.
///
/// Nothing here talks to SSM. MBRS has no public API for third-party
/// lodgement: the figures go into mTool, mTool generates the XBRL, and a
/// person uploads that through mPortal. What these methods produce is
/// the dataset for mTool and a record of the reference that came back.
extension RepoFinancialStatements on Repo {
  Future<List<Map<String, dynamic>>> fsFilings() async => Repo._rows(
    await client
        .from('fs_filings')
        .select()
        .eq('org_id', orgId)
        .order('fy_end', ascending: false),
  );

  Future<Map<String, dynamic>?> fsFiling(String id) async {
    final rows = Repo._rows(
      await client.from('fs_filings').select().eq('id', id).limit(1),
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<String> createFsFiling({
    required DateTime fyStart,
    required DateTime fyEnd,
    String framework = 'mpers',
    String auditStatus = 'audited',
    int? employeeCount,
  }) async {
    final row = await client
        .from('fs_filings')
        .insert({
          'org_id': orgId,
          'fy_start': Fmt.iso(fyStart),
          'fy_end': Fmt.iso(fyEnd),
          'framework': framework,
          'audit_status': auditStatus,
          if (employeeCount != null) 'employee_count': employeeCount,
        })
        .select('id')
        .single();
    return row['id'] as String;
  }

  Future<void> updateFsFiling(String id, Map<String, dynamic> patch) =>
      client.from('fs_filings').update(patch).eq('id', id);

  /// The statements as the ledger has them now. Moves when the ledger
  /// moves — which is exactly why freezing exists.
  Future<List<Map<String, dynamic>>> fsPrepare(String filingId) async =>
      Repo._rows(
        await callRpc('fs_prepare', params: {'p_filing_id': filingId}),
      );

  Future<Map<String, dynamic>?> fsBalanceCheck(String filingId) async {
    final rows = Repo._rows(
      await callRpc('fs_balance_check', params: {'p_filing_id': filingId}),
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> fsFreeze(String filingId) async =>
      await callRpc('fs_freeze', params: {'p_filing_id': filingId}) as int;

  Future<void> fsUnfreeze(String filingId) =>
      callRpc('fs_unfreeze', params: {'p_filing_id': filingId});

  Future<void> fsLodge(
    String filingId, {
    required String reference,
    DateTime? lodgedOn,
  }) => callRpc(
    'fs_lodge',
    params: {
      'p_filing_id': filingId,
      'p_reference': reference,
      'p_lodged_on': Fmt.iso(lodgedOn ?? DateTime.now()),
    },
  );

  /// The rows that go into mTool. Frozen figures once frozen, live
  /// before that, and the `is_frozen` flag says which — a preparer
  /// looking at a draft export needs to know it is still moving.
  Future<List<Map<String, dynamic>>> fsExport(String filingId) async =>
      Repo._rows(await callRpc('fs_export', params: {'p_filing_id': filingId}));

  Future<Map<String, dynamic>?> fsDeadlines(String filingId) async {
    final rows = Repo._rows(
      await callRpc('fs_deadlines', params: {'p_filing_id': filingId}),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Which company these accounts are for.
  ///
  /// `fs_filings.corp_entity_id` is the link between a set of accounts
  /// and the `corp_entities` row it belongs to, and `0391` granted
  /// `fs_set_entity` to `authenticated` and then never called it. Until
  /// something did, the column was null on every filing, so
  /// `report_fs_deadlines` fell back to `coalesce(e.name, o.name)` --
  /// the organization's own name -- for all of them, and the
  /// registration number it returns beside it was always null. A
  /// practice with forty companies got forty rows all named after the
  /// practice.
  ///
  /// Null unlinks. A company keeping its own books has no
  /// `corp_entities` row at all and its accounts are still its
  /// accounts, which is what that `coalesce` is for.
  Future<void> fsSetEntity(String filingId, String? entityId) => callRpc(
    'fs_set_entity',
    params: {'p_filing_id': filingId, 'p_entity_id': entityId},
  );

  /// Every filing still to be lodged, and how long is left on each.
  ///
  /// `fs_deadlines` answers for one filing, which is what the filing's
  /// own screen needs and no use at all to a practice with forty
  /// companies: asking it once per row is forty round trips to learn
  /// which one is late. This asks once, and names the company rather
  /// than the filing id.
  ///
  /// Lodged filings are not in it, and neither is anything due further
  /// out than `withinDays` — the question it answers is what is
  /// approaching, not what exists.
  Future<List<Map<String, dynamic>>> fsDeadlinesDue({
    int withinDays = 180,
  }) async => Repo._rows(
    await callRpc(
      'report_fs_deadlines',
      params: {'p_org_id': orgId, 'p_within_days': withinDays},
    ),
  );

  Future<List<Map<String, dynamic>>> fsAuditExemption(String filingId) async =>
      Repo._rows(
        await callRpc('fs_audit_exemption', params: {'p_filing_id': filingId}),
      );

  Future<List<Map<String, dynamic>>> mbrsElements() async => Repo._rows(
    await client
        .from('mbrs_elements')
        .select()
        .eq('is_active', true)
        .order('sort_order', ascending: true),
  );

  /// The deviations from the default mapping, and only those. An empty
  /// list means a standard chart mapped the standard way, not an
  /// unmapped one.
  Future<List<Map<String, dynamic>>> fsAccountMap() async => Repo._rows(
    await client.from('fs_account_map').select().eq('org_id', orgId),
  );

  Future<void> setFsAccountMap(String accountId, String? elementCode) async {
    if (elementCode == null) {
      // Deleting the override restores the default, which is a real
      // choice and not the same as mapping it to nothing.
      await client
          .from('fs_account_map')
          .delete()
          .eq('org_id', orgId)
          .eq('account_id', accountId);
      return;
    }
    await client.from('fs_account_map').upsert({
      'org_id': orgId,
      'account_id': accountId,
      'element_code': elementCode,
    }, onConflict: 'org_id,account_id');
  }
}

/// The service desk.
///
/// Its own extension rather than more surface on [Repo] because the
/// ticketing screens are the only callers, and an extension keeps the
/// module separable. Anything importing this file gets these methods;
/// the ticketing screens do, which is why they import it directly
/// rather than reaching the repo only through the providers.
extension RepoTicketing on Repo {
  Future<List<Map<String, dynamic>>> tickets({
    String? status,
    String? teamId,
    String? priority,
    bool onlyMine = false,
    bool onlyBreached = false,
  }) async {
    var q = client
        .from('tickets')
        // Deliberately no embedded lookups. Every foreign key from
        // `tickets` to a team, a category or a contact is composite —
        // (org_id, x) — so a tenant cannot borrow another's rows, and
        // scripts/check_embeds.py only catches *ambiguous* embeds that
        // failed to name a constraint. It cannot tell whether a named
        // one resolves, so an embed that PostgREST refuses would reach
        // production exactly as the receipts screen once did. The names
        // are joined on the client from lists it already holds.
        .select('*')
        .eq('org_id', orgId)
        .isFilter('deleted_at', null);

    if (status == 'open') {
      // "Open" in a queue means "still ours", not the single status of
      // that name — a ticket waiting on the requester has not left the
      // queue, it is just not moving.
      q = q.inFilter('status', ['new', 'open', 'pending', 'on_hold']);
    } else if (status != null) {
      q = q.eq('status', status);
    }
    if (teamId != null) q = q.eq('team_id', teamId);
    if (priority != null) q = q.eq('priority', priority);
    if (onlyMine) q = q.eq('assignee_id', client.auth.currentUser?.id ?? '');
    if (onlyBreached) {
      q = q.or('response_breached.eq.true,resolution_breached.eq.true');
    }

    return Repo._rows(await q.order('opened_at', ascending: false).limit(200));
  }

  Future<Map<String, dynamic>> ticket(String id) async =>
      Map<String, dynamic>.from(
        await client
            .from('tickets')
            .select('*')
            .eq('id', id)
            .eq('org_id', orgId)
            .single(),
      );

  Future<List<Map<String, dynamic>>> ticketComments(String ticketId) async =>
      Repo._rows(
        await client
            .from('ticket_comments')
            .select()
            .eq('ticket_id', ticketId)
            .eq('org_id', orgId)
            .order('created_at', ascending: true),
      );

  Future<List<Map<String, dynamic>>> ticketEvents(String ticketId) async =>
      Repo._rows(
        await client
            .from('ticket_events')
            .select()
            .eq('ticket_id', ticketId)
            .eq('org_id', orgId)
            .order('created_at', ascending: true),
      );

  Future<List<Map<String, dynamic>>> ticketTeams() async => Repo._rows(
    await client
        .from('ticket_teams')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('name', ascending: true),
  );

  /// Every team including the retired ones, which the list above hides.
  ///
  /// The console is where a retired team is brought back, and a list
  /// that hid them would be a door that locks behind you — the same
  /// reasoning `platform_modules` uses in the platform catalogue.
  Future<List<Map<String, dynamic>>> ticketTeamsAll() async => Repo._rows(
    await client
        .from('ticket_teams')
        .select()
        .eq('org_id', orgId)
        .order('name', ascending: true),
  );

  /// Returns the row's id, so a team made from the box that wanted one
  /// can be selected there.
  Future<String> saveTicketTeam({
    String? id,
    required String code,
    required String name,
    bool? isActive,
  }) async {
    final patch = {'name': name, if (isActive != null) 'is_active': isActive};
    if (id != null) {
      await client.from('ticket_teams').update(patch).eq('id', id);
      return id;
    }
    final row = await client
        .from('ticket_teams')
        .insert({'org_id': orgId, 'code': code, ...patch})
        .select('id')
        .single();
    return '${row['id']}';
  }

  /// Who is on a team, leads first.
  ///
  /// `0192` built the table and nothing ever wrote a row, so a team was
  /// a label. `0355` made the list decide who a ticket on that team may
  /// be handed to.
  Future<List<Map<String, dynamic>>> ticketTeamRoster(String teamId) async =>
      Repo._rows(
        await callRpc('ticket_team_roster', params: {'p_team_id': teamId}),
      );

  Future<void> addTicketTeamMember(
    String teamId,
    String userId, {
    bool isLead = false,
  }) => client.from('ticket_team_members').insert({
    'org_id': orgId,
    'team_id': teamId,
    'user_id': userId,
    'is_lead': isLead,
  });

  Future<void> removeTicketTeamMember(String teamId, String userId) => client
      .from('ticket_team_members')
      .delete()
      .eq('team_id', teamId)
      .eq('user_id', userId);

  /// One lead per team, so making somebody the lead stands the previous
  /// one down first. The unique index in `0355` refuses two, and a
  /// refusal an operator has to work out for themselves is a worse
  /// answer than doing the obvious thing.
  Future<void> setTicketTeamLead(String teamId, String userId) async {
    await client
        .from('ticket_team_members')
        .update({'is_lead': false})
        .eq('team_id', teamId)
        .eq('is_lead', true);
    await client
        .from('ticket_team_members')
        .update({'is_lead': true})
        .eq('team_id', teamId)
        .eq('user_id', userId);
  }

  Future<List<Map<String, dynamic>>> ticketCategories() async => Repo._rows(
    await client
        .from('ticket_categories')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('name', ascending: true),
  );

  Future<List<Map<String, dynamic>>> cannedResponses() async => Repo._rows(
    await client
        .from('canned_responses')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('title', ascending: true),
  );

  Future<String> createTicket({
    required String subject,
    String? description,
    String? categoryCode,
    String? priority,
    String? type,
    String channel = 'web',
    String? requesterContactId,
    Map<String, dynamic> customFields = const {},
  }) async {
    final id = await callRpc(
      'create_ticket',
      params: {
        'p_org_id': orgId,
        'p_subject': subject,
        if (description != null && description.isNotEmpty)
          'p_description': description,
        if (categoryCode != null) 'p_category': categoryCode,
        if (priority != null) 'p_priority': priority,
        if (type != null) 'p_type': type,
        'p_channel': channel,
        if (requesterContactId != null)
          'p_requester_contact_id': requesterContactId,
      },
    );
    // Same gap as `openMatter`, closed by the same method.
    await writeCustomFields('tickets', id as String, customFields);
    return id;
  }

  Future<void> transitionTicket(String id, String to, {String? note}) async {
    await callRpc(
      'transition_ticket',
      params: {'p_ticket': id, 'p_to': to, if (note != null) 'p_note': note},
    );
  }

  Future<void> assignTicket(String id, String? userId) async {
    await callRpc('assign_ticket', params: {'p_ticket': id, 'p_user': userId});
  }

  Future<void> addTicketComment(
    String id,
    String body, {
    bool internal = true,
  }) async {
    await callRpc(
      'add_ticket_comment',
      params: {'p_ticket': id, 'p_body': body, 'p_internal': internal},
    );
  }

  /// Issue a link the requester can read and reply on.
  ///
  /// The token comes back exactly once and is never stored in the clear,
  /// so a caller that loses it issues a new link rather than looking the
  /// old one up — `0094`'s rule, and the reason there is one live link
  /// per ticket.
  Future<String> shareTicket(
    String id, {
    int validDays = 30,
    String? email,
  }) async =>
      (await callRpc(
            'share_ticket',
            params: {
              'p_ticket': id,
              'p_valid_days': validDays,
              if (email != null && email.trim().isNotEmpty)
                'p_email': email.trim(),
            },
          ))
          as String;

  Future<List<Map<String, dynamic>>> ticketShareLinks(String id) async =>
      Repo._rows(
        await client
            .from('ticket_share_links')
            .select()
            .eq('ticket_id', id)
            .eq('org_id', orgId)
            .order('created_at', ascending: false),
      );

  Future<int> revokeTicketShare(String id) async =>
      (await callRpc('revoke_ticket_share', params: {'p_ticket': id})) as int;

  Future<void> escalateTicket(
    String id,
    String kind, {
    String? toTeam,
    String? toUser,
    String? reason,
  }) async {
    await callRpc(
      'escalate_ticket',
      params: {
        'p_ticket': id,
        'p_kind': kind,
        if (toTeam != null) 'p_to_team': toTeam,
        if (toUser != null) 'p_to_user': toUser,
        if (reason != null) 'p_reason': reason,
      },
    );
  }
}

/// Inventory forecasting.
///
/// The reads that matter go through the RPCs rather than the tables:
/// `forecast_suggestions` nets off the draft orders already raised and
/// names the item and the supplier, which a select on `forecast_lines`
/// cannot do without three joins the client would have to keep in step
/// with the migration that owns them.
extension RepoForecasting on Repo {
  /// The company's forecasting settings, or null before anybody has
  /// opened the screen. Null rather than a fabricated default: the
  /// defaults live in the column definitions, and inventing a second
  /// copy here is how the screen comes to disagree with the run.
  Future<Map<String, dynamic>?> forecastSettings() async {
    final row = await client
        .from('forecast_settings')
        .select()
        .eq('org_id', orgId)
        .maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  Future<void> saveForecastSettings(Map<String, dynamic> values) async {
    await client.from('forecast_settings').upsert({
      'org_id': orgId,
      ...values,
    }, onConflict: 'org_id');
  }

  /// The most recent run for a location, or null if none has been made.
  ///
  /// Null [warehouseId] means the company as a whole, and is a different
  /// run from any branch's rather than a wildcard over them — which is
  /// why the filter is `is null` rather than being left off. Leaving it
  /// off would return whichever location was forecast most recently and
  /// present it as this one's.
  Future<Map<String, dynamic>?> latestForecastRun({String? warehouseId}) async {
    var q = client.from('forecast_runs').select().eq('org_id', orgId);
    q = warehouseId == null
        ? q.isFilter('warehouse_id', null)
        : q.eq('warehouse_id', warehouseId);
    final rows = Repo.rows(await q.order('run_at', ascending: false).limit(1));
    return rows.isEmpty ? null : rows.first;
  }

  Future<String> runForecast({String? warehouseId}) async {
    final id = await callRpc(
      'run_inventory_forecast',
      params: {
        'p_org': orgId,
        if (warehouseId != null) 'p_warehouse': warehouseId,
      },
    );
    return id as String;
  }

  Future<List<Map<String, dynamic>>> forecastSuggestions({
    String? warehouseId,
  }) async => Repo.rows(
    await callRpc(
      'forecast_suggestions',
      params: {'p_org': orgId, 'p_warehouse': warehouseId},
    ),
  );

  /// Every line of a run, including the items with nothing to order and
  /// the ones skipped for want of history. The skipped ones are the
  /// point of having this beside the suggestions: an item silently
  /// absent from a replenishment report is one nobody notices they
  /// stopped ordering.
  Future<List<Map<String, dynamic>>> forecastLines(String runId) async =>
      Repo.rows(
        await client
            .from('forecast_lines')
            .select()
            .eq('org_id', orgId)
            .eq('run_id', runId)
            .order('state', ascending: true),
      );

  Future<Map<String, dynamic>?> itemForecastParams(
    String itemId, {
    String? warehouseId,
  }) async {
    var q = client
        .from('item_forecast_params')
        .select()
        .eq('org_id', orgId)
        .eq('item_id', itemId);
    q = warehouseId == null
        ? q.isFilter('warehouse_id', null)
        : q.eq('warehouse_id', warehouseId);
    final row = await q.maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  /// Update, then insert if there was nothing to update.
  ///
  /// Not an upsert. `warehouse_id` is nullable — null means "the
  /// company" — so the unique indexes that enforce one row per item are
  /// *partial*, one for each side of the null. PostgREST names its
  /// conflict target by column list and Postgres will not infer a
  /// partial index from one, so `onConflict: 'org_id,item_id,warehouse_id'`
  /// does not resolve and the write fails at the moment somebody saves
  /// a parameter for the second time.
  Future<void> saveItemForecastParams(
    String itemId,
    Map<String, dynamic> values, {
    String? warehouseId,
  }) async {
    var q = client
        .from('item_forecast_params')
        .update(values)
        .eq('org_id', orgId)
        .eq('item_id', itemId);
    q = warehouseId == null
        ? q.isFilter('warehouse_id', null)
        : q.eq('warehouse_id', warehouseId);
    final updated = Repo.rows(await q.select('id'));
    if (updated.isEmpty) {
      await client.from('item_forecast_params').insert({
        'org_id': orgId,
        'item_id': itemId,
        'warehouse_id': warehouseId,
        ...values,
      });
    }
  }

  /// Raises one draft purchase order per supplier. Passing nothing means
  /// every outstanding suggestion; passing a list means those lines at
  /// those quantities, where the quantity is the total wanted on order
  /// against the suggestion rather than an amount to add to it.
  Future<List<Map<String, dynamic>>> createPurchaseOrdersFromSuggestions({
    List<Map<String, dynamic>>? lines,
    DateTime? expected,
    String? warehouseId,
  }) async => Repo.rows(
    await callRpc(
      'create_po_from_suggestions',
      params: {
        'p_org': orgId,
        'p_warehouse': warehouseId,
        if (lines != null) 'p_lines': lines,
        if (expected != null)
          'p_expected_date': expected.toIso8601String().substring(0, 10),
      },
    ),
  );
}

/// Point of sale.
///
/// Almost every call here is an RPC rather than a table write, and that
/// is the design rather than an accident: a sale, its lines and its
/// tenders are read-only to the API. The functions are the things that
/// know a drawer is open, price a line and prove the money adds up, so
/// a till that could write those rows directly could tell the drawer it
/// had been paid.
extension RepoPos on Repo {
  /// The shops. Registers carry their outlet, which is enough for a
  /// till but not for a settings screen: a shop with a kitchen and no
  /// till yet still has to be configurable, and one with three tills
  /// must not appear three times in the picker.
  Future<List<Map<String, dynamic>>> posOutlets() async => Repo.rows(
    await client
        .from('pos_outlets')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('code', ascending: true),
  );

  /// The tills this company has, with the outlet each stands in.
  Future<List<Map<String, dynamic>>> posRegisters() async => Repo.rows(
    await client
        .from('pos_registers')
        // Named because 0517 added a same-org composite key alongside
        // the plain one, so 'pos_outlets' can now be joined two ways
        // and PostgREST refuses the embed with PGRST201.
        .select('*, pos_outlets!pos_registers_outlet_id_fkey(id, name, code, business_type)')
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('code', ascending: true),
  );

  /// The shift a register is in the middle of, or null if the drawer has
  /// not been opened. Nothing can be sold until this returns a row,
  /// which is deliberate: takings that belong to no count belong to
  /// nobody.
  Future<Map<String, dynamic>?> currentPosShift(String registerId) async {
    final rows = Repo.rows(
      await client
          .from('pos_shifts')
          .select()
          .eq('register_id', registerId)
          .neq('status', 'closed')
          .limit(1),
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<String> openPosShift(String registerId, num float) async =>
      await callRpc(
            'open_pos_shift',
            params: {'p_register': registerId, 'p_float': float},
          )
          as String;

  /// Returns what was expected, what was declared and the difference —
  /// all three, because a variance without the two numbers behind it is
  /// a figure nobody can check.
  /// Stops the till while the drawer is counted.
  ///
  /// 0361. A sale rung up between the count and the close is in
  /// `expected_cash` and not in the notes on the counter, so the
  /// variance comes out wrong by exactly that sale — and is recorded
  /// against whoever counted. Idempotent: two cashiers reaching for the
  /// same button is an ordinary Saturday.
  Future<void> beginPosCount(String shiftId) =>
      callRpc('begin_pos_count', params: {'p_shift': shiftId});

  /// Puts a counting till back into service.
  ///
  /// A count is not a commitment. Without a way back, somebody who
  /// starts counting and finds a customer at the counter closes the
  /// shift early to take the one sale.
  Future<void> resumePosShift(String shiftId) =>
      callRpc('resume_pos_shift', params: {'p_shift': shiftId});

  Future<Map<String, dynamic>?> closePosShift(
    String shiftId,
    num declared, {
    String? notes,
  }) async {
    final rows = Repo.rows(
      await callRpc(
        'close_pos_shift',
        params: {
          'p_shift': shiftId,
          'p_declared': declared,
          if (notes != null) 'p_notes': notes,
        },
      ),
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> posTenderTypes() async => Repo.rows(
    await client
        .from('pos_tender_types')
        .select()
        .eq('org_id', orgId)
        .eq('is_active', true)
        .order('code', ascending: true),
  );

  /// Takes an unsent line off a parked bill. Refuses once the kitchen
  /// has been told — that is [voidPosSaleLine], which wants a reason.
  Future<void> removePosSaleLine(String lineId) async =>
      await callRpc('remove_pos_sale_line', params: {'p_line': lineId});

  /// Takes a line off after the kitchen was told, recording what it
  /// said, why it went and who did it. The line is deleted; the
  /// evidence lives in `pos_sale_line_voids`.
  Future<String> voidPosSaleLine(
    String lineId,
    String reason, {
    String? note,
  }) async =>
      await callRpc(
            'void_pos_sale_line',
            params: {
              'p_line': lineId,
              'p_reason': reason,
              if (note != null) 'p_note': note,
            },
          )
          as String;

  /// Moves chosen lines onto a bill of their own. Two bills, settled
  /// separately — which is the right answer when two people ate
  /// different things and each wants their own invoice.
  ///
  /// A moved line keeps its id, so its modifiers and its kitchen docket
  /// line still point at it. Only which bill it sits on changes.
  Future<String> splitPosSale(String saleId, List<String> lineIds) async =>
      await callRpc(
            'split_pos_sale',
            params: {'p_sale': saleId, 'p_lines': lineIds},
          )
          as String;

  /// Puts two bills back together. Returns how many lines moved.
  Future<int> mergePosSales(String into, String from) async =>
      (await callRpc(
                'merge_pos_sales',
                params: {'p_into': into, 'p_from': from},
              )
              as num)
          .toInt();

  /// One bill, N people, N cards. Nothing moves and no second invoice
  /// is raised — there was one supply, so LHDN gets one document and
  /// the sale simply takes several tenders.
  ///
  /// The shares sum to the total exactly; the remainder rides on the
  /// first. See 0216 for why that beats rounding each independently.
  Future<List<Map<String, dynamic>>> posEvenSplit(
    String saleId,
    int ways,
  ) async => Repo.rows(
    await callRpc('pos_even_split', params: {'p_sale': saleId, 'p_ways': ways}),
  );

  /// The questions a plate comes with: "how spicy", "anything extra".
  /// Empty for most items, which is why the till asks before it opens
  /// anything — a sheet that appears for a tin of drink is a sheet in
  /// the way.
  Future<List<Map<String, dynamic>>> itemModifierOptions(String itemId) async =>
      Repo.rows(
        await callRpc('item_modifier_options', params: {'p_item': itemId}),
      );

  // ------------------------------------------------------------------
  // Keeping the questions themselves
  // ------------------------------------------------------------------
  //
  // 0250. Until it, the only shop with modifiers was the one a
  // migration seeded: the tables were writable and nothing wrote them.

  /// Every question this company asks, retired ones included — a list
  /// that hid them would leave somebody re-creating one under a code
  /// they cannot use.
  Future<List<Map<String, dynamic>>> posModifierGroups() async => Repo.rows(
    await callRpc('pos_modifier_groups_admin', params: {'p_org': orgId}),
  );

  Future<List<Map<String, dynamic>>> posModifierOptions(String groupId) async =>
      Repo.rows(
        await callRpc(
          'pos_modifier_options_admin',
          params: {'p_group': groupId},
        ),
      );

  /// What a dish is currently sold with. Not [itemModifierOptions],
  /// which is the till's question and drops anything retired.
  Future<List<Map<String, dynamic>>> itemModifierGroupIds(
    String itemId,
  ) async => Repo.rows(
    await callRpc('item_modifier_group_ids', params: {'p_item': itemId}),
  );

  Future<String> savePosModifierGroup({
    required String code,
    required String name,
    required int minSelect,
    int? maxSelect,
    String? id,
    int sortOrder = 0,
    bool isActive = true,
    bool allowsFreeText = false,
  }) async =>
      await callRpc(
            'upsert_pos_modifier_group',
            params: {
              'p_org': orgId,
              'p_code': code,
              'p_name': name,
              'p_min_select': minSelect,
              'p_max_select': maxSelect,
              'p_id': id,
              'p_sort_order': sortOrder,
              'p_is_active': isActive,
              'p_allows_free_text': allowsFreeText,
            },
          )
          as String;

  /// Returns how many dishes stop being asked, so the caller can say
  /// what it did rather than that it did something.
  Future<int> retirePosModifierGroup(String groupId) async =>
      (await callRpc('retire_pos_modifier_group', params: {'p_group': groupId}))
          as int;

  Future<String> savePosModifier({
    required String groupId,
    required String code,
    required String name,
    double priceDelta = 0,
    String? id,
    bool isDefault = false,
    int sortOrder = 0,
    bool isActive = true,
  }) async =>
      await callRpc(
            'upsert_pos_modifier',
            params: {
              'p_group': groupId,
              'p_code': code,
              'p_name': name,
              'p_price_delta': priceDelta,
              'p_id': id,
              'p_is_default': isDefault,
              'p_sort_order': sortOrder,
              'p_is_active': isActive,
            },
          )
          as String;

  Future<void> retirePosModifier(String modifierId) async =>
      await callRpc('retire_pos_modifier', params: {'p_modifier': modifierId});

  /// The whole set, in the order they will be asked. Anything not in
  /// the list is detached.
  Future<int> setItemModifierGroups(
    String itemId,
    List<String> groupIds,
  ) async =>
      (await callRpc(
            'set_item_modifier_groups',
            params: {'p_item': itemId, 'p_groups': groupIds},
          ))
          as int;

  /// An answer nobody listed: a name and a price typed at the counter.
  /// 0251, and only for a group whose `allows_free_text` is on — the
  /// server refuses the rest, including a price below nothing.
  Future<String> addLineFreeModifier(
    String lineId, {
    required String groupId,
    required String name,
    double priceDelta = 0,
    int quantity = 1,
  }) async =>
      await callRpc(
            'add_line_free_modifier',
            params: {
              'p_line': lineId,
              'p_group': groupId,
              'p_name': name,
              'p_price_delta': priceDelta,
              'p_quantity': quantity,
            },
          )
          as String;

  Future<String> addLineModifier(
    String lineId,
    String modifierId, {
    int quantity = 1,
  }) async =>
      await callRpc(
            'add_line_modifier',
            params: {
              'p_line': lineId,
              'p_modifier': modifierId,
              'p_quantity': quantity,
            },
          )
          as String;

  /// What was chosen on each line of a sale, for the basket to show.
  /// Read from the snapshot on the line rather than from the menu, so a
  /// bill printed at seven still reads correctly after the menu is
  /// edited at nine.
  Future<List<Map<String, dynamic>>> posSaleLineModifiers(
    String saleId,
  ) async => Repo.rows(
    await client
        .from('pos_sale_line_modifiers')
        // Named for the same reason (0521's composite key). This read
        // has been ambiguous since that migration and nothing said so:
        // `check_embeds.py` treated the `!inner` join modifier as a
        // constraint name and skipped the check entirely.
        .select('*, pos_sale_lines!pos_sale_line_modifiers_line_id_fkey!inner'
            '(sale_id)')
        .eq('pos_sale_lines.sale_id', saleId),
  );

  /// Everything the outlet can actually sell, for a till with nothing
  /// scanned yet. The same sellability rules as [posLookup] — a style
  /// with variants under it is not offered, because tapping one would
  /// raise.
  Future<List<Map<String, dynamic>>> posMenu(String outletId) async =>
      Repo.rows(await callRpc('pos_menu', params: {'p_outlet': outletId}));

  /// A scan or a typed search. One row with `matched_on = 'barcode'` is
  /// the case a till can act on without asking anybody.
  Future<List<Map<String, dynamic>>> posLookup(
    String outletId,
    String code,
  ) async => Repo.rows(
    await callRpc(
      'pos_lookup_item',
      params: {'p_outlet': outletId, 'p_code': code},
    ),
  );

  Future<String> openPosSale(
    String registerId, {
    String? contactId,
    String? clientUuid,
  }) async =>
      await callRpc(
            'open_pos_sale',
            params: {
              'p_register': registerId,
              if (contactId != null) 'p_contact': contactId,
              if (clientUuid != null) 'p_client_uuid': clientUuid,
            },
          )
          as String;

  Future<String> addPosSaleLine(
    String saleId,
    String itemId, {
    num quantity = 1,
    num? price,
    String? note,
  }) async =>
      await callRpc(
            'add_pos_sale_line',
            params: {
              'p_sale': saleId,
              'p_item': itemId,
              'p_quantity': quantity,
              if (price != null) 'p_price': price,
              if (note != null) 'p_note': note,
            },
          )
          as String;

  Future<Map<String, dynamic>?> posSale(String saleId) async {
    final rows = Repo.rows(
      await client.from('pos_sales').select().eq('id', saleId).limit(1),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// The bill's lines, with what the item is tracked by.
  ///
  /// The embed is there for one column. `0546` lets a serial be scanned
  /// at the till, and the till has to know which lines want scanning
  /// BEFORE the cashier presses Take payment — a serial affordance
  /// offered on every line is noise on the ninety-nine that do not have
  /// one, and offered on none is a sale that refuses at the tender
  /// sheet with a queue behind it.
  ///
  /// NAMED, because there are two ways to join. `0520` added
  /// `pos_sale_lines_item_same_org` — a composite key on (org_id,
  /// item_id) that holds a line to its own company's items — alongside
  /// the plain `item_id` one, and PostgREST refuses an unqualified
  /// embed across two candidates with PGRST201. Caught by
  /// `scripts/check_embeds.py` in CI, which is where this belongs: the
  /// ambiguity is a fact about the schema and not about this line.
  Future<List<Map<String, dynamic>>> posSaleLines(String saleId) async =>
      Repo.rows(
        await client
            .from('pos_sale_lines')
            .select('*, items!pos_sale_lines_item_id_fkey(tracking)')
            .eq('sale_id', saleId)
            .order('line_no', ascending: true),
      );

  /// One serial onto one line, checked while the customer is still at
  /// the counter. Returns everything scanned onto the line so far.
  Future<List<String>> posScanSerial(String lineId, String serial) async =>
      ((await callRpc('pos_scan_serial',
                  params: {'p_line': lineId, 'p_serial': serial})
              as List?) ??
          const [])
          .map((e) => '$e')
          .toList(growable: false);

  /// And taking a mis-scan back off.
  Future<List<String>> posUnscanSerial(String lineId, String serial) async =>
      ((await callRpc('pos_unscan_serial',
                  params: {'p_line': lineId, 'p_serial': serial})
              as List?) ??
          const [])
          .map((e) => '$e')
          .toList(growable: false);

  /// Baskets set aside. A till with a queue behind it parks one sale to
  /// serve the next, and the parked ones have to be findable or the
  /// money on them is lost.
  /// The bills parked on this till.
  ///
  /// The table comes with them. A merge picker showing two bills for
  /// RM 34.00 and nothing else is asking the cashier to guess; the
  /// table is what they can see from where they are standing. One
  /// foreign key from `pos_sales` to `pos_tables`, so the embed is
  /// unambiguous and PostgREST resolves it without a hint.
  Future<List<Map<String, dynamic>>> parkedPosSales(String registerId) async =>
      Repo.rows(
        await client
            .from('pos_sales')
            // Named because 0520 added a same-org composite key alongside
        // the plain one, so 'pos_tables' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, pos_tables!pos_sales_table_id_fkey(code, name)')
            .eq('register_id', registerId)
            .eq('status', 'parked')
            .order('opened_at', ascending: true),
      );

  /// Every bill still open in the shop, whichever till holds it.
  ///
  /// [parkedPosSales] answers a narrower question — what is on *this*
  /// register — and is still what the merge bar wants, because merging
  /// two bills across two drawers is not a thing to offer casually.
  /// This one is what a counter needs: a customer walks up holding a
  /// bill a waiter opened on a tablet, and a till that can only see
  /// itself cannot find it at all.
  Future<List<Map<String, dynamic>>> posOpenOrders(String outletId) async =>
      Repo.rows(
        await callRpc('pos_open_orders', params: {'p_outlet': outletId}),
      );

  /// Moves an open bill onto this till — register and shift together.
  ///
  /// The shift is the point. `app.pos_expected_cash` counts by
  /// `shift_id`, so settling another till's bill without this would put
  /// this drawer's cash into that drawer's expected figure and fail
  /// both counts, in opposite directions, for a reason neither cashier
  /// can see.
  Future<void> claimPosSale(String saleId, String registerId) async =>
      await callRpc(
        'claim_pos_sale',
        params: {'p_sale': saleId, 'p_register': registerId},
      );

  /// The room, as one query: every active table in the outlet and the
  /// parked bill sitting on it, if there is one.
  ///
  /// Occupancy is not a column anywhere — it is derived from whether a
  /// parked sale points at the table. That is what makes a crashed
  /// tablet harmless: nothing was left set, so nothing has to be
  /// unset.
  Future<List<Map<String, dynamic>>> posFloorPlan(String outletId) async =>
      Repo.rows(
        await callRpc('pos_floor_plan', params: {'p_outlet': outletId}),
      );

  /// Seats a table and returns the bill on it. Returns the bill that is
  /// already there when there is one, so a second tap on an occupied
  /// table opens it rather than starting a rival.
  Future<String> seatTable(
    String registerId,
    String tableId, {
    int? covers,
  }) async =>
      await callRpc(
            'seat_table',
            params: {
              'p_register': registerId,
              'p_table': tableId,
              if (covers != null) 'p_covers': covers,
            },
          )
          as String;

  /// Writes off a whole parked bill, and says how many lines the
  /// kitchen had cooked from — which is how many became a loss, not how
  /// many were on the bill.
  ///
  /// The lines are kept. They are what was written off, and a voided
  /// sale of nothing tells a manager nothing.
  Future<int> voidPosSale(String saleId, String reason, {String? note}) async =>
      ((await callRpc(
                'void_pos_sale',
                params: {
                  'p_sale': saleId,
                  'p_reason': reason,
                  if (note != null && note.trim().isNotEmpty)
                    'p_note': note.trim(),
                },
              ))
              as num?)
          ?.toInt() ??
      0;

  /// Turns a long table into T1-A, T1-B and so on, and returns the
  /// parts in order.
  ///
  /// The parts are real tables with their own codes, so everything that
  /// already knows about tables — seating, scanning a card, the printed
  /// card sheet — works on them with nothing changed. A party already
  /// sitting there keeps their bill and lands on the first part.
  Future<List<String>> splitPosTable(String tableId, int parts) async {
    final rows = await callRpc(
      'split_pos_table',
      params: {'p_table': tableId, 'p_parts': parts},
    );
    // A `returns setof uuid` comes back as a bare list of strings, not
    // as rows with a column name, so `Repo.rows` is the wrong reader.
    return (rows as List? ?? const []).map((e) => '$e').toList();
  }

  /// Puts a split table back together. Takes the whole table or any of
  /// its parts, because the plan only draws the parts.
  Future<void> mergePosTable(String tableId) async =>
      await callRpc('merge_pos_table', params: {'p_table': tableId});

  /// Moves a bill, and everything ordered on it, to another table.
  Future<void> movePosSale(String saleId, String tableId) async =>
      await callRpc(
        'move_pos_sale',
        params: {'p_sale': saleId, 'p_table': tableId},
      );

  /// The table a scanned card, QR sticker or typed code names.
  ///
  /// Null when nothing matches, which is the answer the till shows —
  /// a scan that finds no table is a card from another shop, a code
  /// nobody printed, or a reader that dropped a character, and none of
  /// those should seat anybody anywhere.
  ///
  /// The normalisation lives in the function, not here: what a shop
  /// prints on its cards must not decide when the app is released.
  Future<Map<String, dynamic>?> posTableByCode(
    String outletId,
    String code,
  ) async {
    final rows = Repo.rows(
      await callRpc(
        'pos_table_by_code',
        params: {'p_outlet': outletId, 'p_code': code},
      ),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// The kitchens in an outlet. A shop with one of them still has one,
  /// because a ticket has to be routed somewhere and `is_default` is
  /// how an outlet with a single kitchen never thinks about routing.
  Future<List<Map<String, dynamic>>> posKitchenStations(
    String outletId,
  ) async => Repo.rows(
    await client
        .from('pos_kitchen_stations')
        .select()
        .eq('outlet_id', outletId)
        .eq('is_active', true)
        .order('sort_order', ascending: true)
        .order('code', ascending: true),
  );

  /// The kinds of order this shop takes. Not a free-for-all: a stall
  /// that does not deliver should not be able to record a delivery, and
  /// a report split by a channel nobody sells has a row that can only
  /// be a mistake.
  Future<List<Map<String, dynamic>>> posOutletChannels(String outletId) async =>
      Repo.rows(
        await client
            .from('pos_outlet_channels')
            .select()
            .eq('outlet_id', outletId)
            .order('sort_order', ascending: true),
      );

  /// Turns one on or off, and picks which one a sale gets when nobody
  /// says. One call, because naming a new default has to clear the old
  /// one in the same transaction.
  Future<void> setOutletChannel(
    String outletId,
    String channel, {
    bool isActive = true,
    bool isDefault = false,
    int sortOrder = 0,
  }) async => await callRpc(
    'set_outlet_channel',
    params: {
      'p_outlet': outletId,
      'p_channel': channel,
      'p_is_active': isActive,
      'p_is_default': isDefault,
      'p_sort_order': sortOrder,
    },
  );

  /// What this till is usually for. A kiosk is takeaway and a waiter's
  /// tablet is dine-in, so nobody has to say so on every sale — which
  /// matters because a control set on every sale is one that gets set
  /// wrong.
  Future<void> setRegisterDefaultChannel(
    String registerId,
    String? channel,
  ) async => await client
      .from('pos_registers')
      .update({'default_channel': channel})
      .eq('id', registerId);

  /// Says this particular bill arrived some other way. Refused once the
  /// sale has completed: the channel is on an issued invoice and part
  /// of what was reported for the day.
  Future<void> setPosSaleChannel(String saleId, String channel) async =>
      await callRpc(
        'set_pos_sale_channel',
        params: {'p_sale': saleId, 'p_channel': channel},
      );

  /// The day, split by how the orders came in — how much of Friday was
  /// delivery, whether the dining room is worth the seats.
  Future<List<Map<String, dynamic>>> posSalesByChannel({
    DateTime? from,
    DateTime? to,
  }) async => Repo.rows(
    await callRpc(
      'pos_sales_by_channel',
      params: {
        'p_org': orgId,
        if (from != null) 'p_from': from.toIso8601String().substring(0, 10),
        if (to != null) 'p_to': to.toIso8601String().substring(0, 10),
      },
    ),
  );

  /// Adds a counter, or renames one. One call rather than two, because
  /// making a second station the default has to clear the first in the
  /// same transaction — the unique partial index rejects a second, and
  /// doing it as two round trips leaves a moment with no default at
  /// all, which is the moment `send_order_to_kitchen` refuses an
  /// unrouted dish.
  Future<String> upsertKitchenStation({
    required String outletId,
    required String code,
    required String name,
    String? id,
    int sortOrder = 0,
    bool isDefault = false,
    bool isActive = true,
  }) async =>
      await callRpc(
            'upsert_kitchen_station',
            params: {
              'p_outlet': outletId,
              'p_code': code,
              'p_name': name,
              if (id != null) 'p_id': id,
              'p_sort_order': sortOrder,
              'p_is_default': isDefault,
              'p_is_active': isActive,
            },
          )
          as String;

  /// Takes a counter out of service. Retired rather than deleted:
  /// `pos_kitchen_tickets.station_id` cascades, so removing the row
  /// would remove every docket it ever received.
  Future<void> retireKitchenStation(String stationId) async =>
      await callRpc('retire_kitchen_station', params: {'p_station': stationId});

  /// "This dish goes to the bar." Null clears it, so the dish falls
  /// back to its category rule and then to the outlet's default.
  Future<void> routeItemToStation(
    String itemId,
    String outletId,
    String? stationId,
  ) async => await callRpc(
    'route_item_to_station',
    params: {'p_item': itemId, 'p_outlet': outletId, 'p_station': stationId},
  );

  /// "Drinks go to the bar."
  Future<void> routeCategoryToStation(
    String categoryId,
    String outletId,
    String? stationId,
  ) async => await callRpc(
    'route_category_to_station',
    params: {
      'p_category': categoryId,
      'p_outlet': outletId,
      'p_station': stationId,
    },
  );

  /// Where everything currently goes, and which of the three rules
  /// decided it. The reason comes back with the answer: a screen
  /// showing only the station would leave somebody unable to tell a
  /// rule they set from a default they inherited.
  Future<List<Map<String, dynamic>>> posStationRouting(String outletId) async =>
      Repo.rows(
        await callRpc('pos_station_routing', params: {'p_outlet': outletId}),
      );

  /// What is on the pass. Only the tickets still in play — served and
  /// cancelled ones are gone, because a board nobody clears is a board
  /// nobody reads.
  Future<List<Map<String, dynamic>>> kitchenDisplay(String stationId) async =>
      Repo.rows(
        await callRpc('kitchen_display', params: {'p_station': stationId}),
      );

  /// Moves a ticket forward. Forward only — `bump_kitchen_ticket`
  /// refuses to go back, so a plate that has left the kitchen cannot be
  /// un-cooked by a mis-tap.
  Future<String> bumpKitchenTicket(String ticketId, String status) async =>
      await callRpc(
            'bump_kitchen_ticket',
            params: {'p_ticket': ticketId, 'p_status': status},
          )
          as String;

  /// Sends what has not been sent. Returns one row per station it
  /// reached, which is what lets the waiter be told "2 to the kitchen,
  /// 1 to the bar" rather than a bare "sent".
  Future<List<Map<String, dynamic>>> sendOrderToKitchen(String saleId) async =>
      Repo.rows(
        await callRpc('send_order_to_kitchen', params: {'p_sale': saleId}),
      );

  /// A day, by provider. Every provider appears whether or not they are
  /// booked — a left join, deliberately, because "who is free this
  /// afternoon" is the question a diary is opened to answer and a list
  /// of only busy people cannot answer it.
  Future<List<Map<String, dynamic>>> posDaySheet(
    String outletId,
    DateTime day,
  ) async => Repo.rows(
    await callRpc(
      'pos_day_sheet',
      params: {
        'p_outlet': outletId,
        'p_date': day.toIso8601String().substring(0, 10),
      },
    ),
  );

  /// The services this company sells by the hour, with the item behind
  /// each one — the price and the name live on the item, because a
  /// haircut is something sold like anything else.
  Future<List<Map<String, dynamic>>> posServices() async => Repo.rows(
    await client
        .from('pos_services')
        // Named because 0513 added a same-org composite key alongside
        // the plain one, so 'items' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, items!pos_services_item_id_fkey(id, name, code, unit_price)')
        .eq('org_id', orgId)
        .eq('is_active', true),
  );

  /// What a shop files its items under.
  ///
  /// `item_categories` has been in 0003 since the first migration, and
  /// nothing in the app could read it, write it or show it — so
  /// `items.category_id` was null for every item anybody typed, and the
  /// kitchen router's "everything in this category" arm had no
  /// categories to route.
  Future<List<Map<String, dynamic>>> itemCategories() async => Repo.rows(
    await client
        .from('item_categories')
        .select('id, code, name, parent_id')
        .eq('org_id', orgId)
        .order('name', ascending: true),
  );

  /// The short lists a company keeps: a project, a department, a price
  /// level, a leave type, a claim category, a ticket category, an
  /// outlet, a food court, a pipeline.
  ///
  /// Every one of them is `org_id`, `code` and `name` and nothing else
  /// required — checked against `information_schema` rather than
  /// assumed — so one writer serves all of them and there is one place
  /// for the mistake instead of nine. The rest of each row keeps its
  /// column default and is edited on the screen that maintains the
  /// list, which is the same bargain `NewItemDialog` makes.
  ///
  /// The table name comes from [quickAddTables] and not from a caller's
  /// string, so a typo is a compile error rather than a 404 at the
  /// moment somebody is mid-invoice.
  Future<String> createQuickRow(
    QuickAddList list, {
    required String name,
    String? code,
  }) async {
    final table = quickAddTables[list]!;
    final row = await client
        .from(table)
        .insert({
          'org_id': orgId,
          'name': name,
          // `pipelines` is the one with no code column; passing one
          // would be a 400 rather than a helpful default.
          if (code != null) 'code': code,
        })
        .select('id')
        .single();
    return '${row['id']}';
  }

  Future<String> saveItemCategory({
    String? id,
    required String code,
    required String name,
    String? parentId,
  }) async {
    final values = <String, dynamic>{
      'org_id': orgId,
      'code': code,
      'name': name,
      'parent_id': parentId,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (id == null) {
      final row = await client
          .from('item_categories')
          .insert(values)
          .select('id')
          .single();
      return '${row['id']}';
    }
    await client.from('item_categories').update(values).eq('id', id);
    return id;
  }

  /// Removes one. The children come up a level and the items that were
  /// in it end up filed under nothing — both are `on delete set null`
  /// in 0003, and neither is something this call decides.
  Future<void> deleteItemCategory(String id) async =>
      await client.from('item_categories').delete().eq('id', id);

  Future<List<Map<String, dynamic>>> posServiceProviders(
    String outletId,
  ) async => Repo.rows(
    await client
        .from('pos_service_providers')
        .select()
        .eq('outlet_id', outletId)
        .eq('is_active', true)
        .order('name', ascending: true),
  );

  /// Somebody who does the work, and who can be booked.
  ///
  /// `employee_id` and `user_id` are both optional on purpose: a chair
  /// may be rented by somebody who is not on the payroll and a studio's
  /// Saturday cover may not have a login.
  Future<String> savePosServiceProvider({
    String? id,
    required String outletId,
    required String code,
    required String name,
    String? employeeId,
    bool isActive = true,
  }) async {
    final values = <String, dynamic>{
      'org_id': orgId,
      'outlet_id': outletId,
      'code': code,
      'name': name,
      'employee_id': employeeId,
      'is_active': isActive,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (id == null) {
      final row = await client
          .from('pos_service_providers')
          .insert(values)
          .select('id')
          .single();
      return '${row['id']}';
    }
    await client.from('pos_service_providers').update(values).eq('id', id);
    return id;
  }

  /// The week somebody works.
  ///
  /// `app.pos_provider_is_open` asks whether the slot falls inside a
  /// block on that weekday with `exists`, so a provider with no rows at
  /// all is open at no time and every booking for them is refused.
  Future<List<Map<String, dynamic>>> posProviderHours(
    String providerId,
  ) async => Repo.rows(
    await client
        .from('pos_provider_hours')
        .select()
        .eq('provider_id', providerId)
        .order('weekday', ascending: true)
        .order('starts_at', ascending: true),
  );

  /// Writes the week whole.
  ///
  /// Deleted and re-inserted rather than merged, because the week is
  /// edited as one thing and the unique index on
  /// `(provider_id, weekday, starts_at)` makes a partial update refuse
  /// on rows that are only being moved.
  Future<void> setPosProviderHours(
    String providerId,
    List<Map<String, dynamic>> blocks,
  ) async {
    await client
        .from('pos_provider_hours')
        .delete()
        .eq('provider_id', providerId);
    if (blocks.isEmpty) return;
    await client.from('pos_provider_hours').insert([
      for (final b in blocks)
        {
          'org_id': orgId,
          'provider_id': providerId,
          'weekday': b['weekday'],
          'starts_at': b['starts_at'],
          'ends_at': b['ends_at'],
        },
    ]);
  }

  /// When somebody is away. Overlaps a slot and the slot is refused.
  Future<List<Map<String, dynamic>>> posProviderTimeOff(
    String providerId,
  ) async => Repo.rows(
    await client
        .from('pos_provider_time_off')
        .select()
        .eq('provider_id', providerId)
        .order('starts_at', ascending: false),
  );

  Future<void> addPosProviderTimeOff({
    required String providerId,
    required DateTime startsAt,
    required DateTime endsAt,
    String? reason,
  }) async => await client.from('pos_provider_time_off').insert({
    'org_id': orgId,
    'provider_id': providerId,
    'starts_at': startsAt.toUtc().toIso8601String(),
    'ends_at': endsAt.toUtc().toIso8601String(),
    'reason': reason,
  });

  Future<void> deletePosProviderTimeOff(String id) async =>
      await client.from('pos_provider_time_off').delete().eq('id', id);

  /// Sells a slot. Refuses an overlap, a slot outside the hours the
  /// provider works, and one while they are away — all three in the
  /// database, so a second device booking the same minute loses.
  Future<String> bookAppointment({
    required String providerId,
    required String itemId,
    required DateTime startsAt,
    String? contactId,
    String? note,
  }) async =>
      await callRpc(
            'book_appointment',
            params: {
              'p_provider': providerId,
              'p_item': itemId,
              'p_starts_at': startsAt.toUtc().toIso8601String(),
              if (contactId != null) 'p_contact': contactId,
              if (note != null) 'p_note': note,
            },
          )
          as String;

  Future<String> setBookingStatus(
    String bookingId,
    String status, {
    String? note,
  }) async =>
      await callRpc(
            'set_booking_status',
            params: {
              'p_booking': bookingId,
              'p_status': status,
              if (note != null) 'p_note': note,
            },
          )
          as String;

  /// Arrival, which is a claim about money rather than a status
  /// somebody types: checking in opens a sale with the service on it at
  /// the price that was quoted, and returns it.
  Future<String> checkInBooking(String bookingId, String registerId) async =>
      await callRpc(
            'check_in_booking',
            params: {'p_booking': bookingId, 'p_register': registerId},
          )
          as String;

  /// The board a customer watches while their food is made. Only the
  /// last four hours, and only orders the kitchen has not finished —
  /// a collection screen listing yesterday is a screen nobody scans.
  Future<List<Map<String, dynamic>>> kioskOrderBoard(String outletId) async =>
      Repo.rows(
        await callRpc('kiosk_order_board', params: {'p_outlet': outletId}),
      );

  Future<String> startKioskOrder(
    String registerId, {
    String? clientUuid,
  }) async =>
      await callRpc(
            'start_kiosk_order',
            params: {
              'p_register': registerId,
              if (clientUuid != null) 'p_client_uuid': clientUuid,
            },
          )
          as String;

  /// Takes the money and gives back the number. One tender, because a
  /// kiosk has nobody to split a payment with, and never cash — there
  /// is no drawer and nobody to open it.
  Future<Map<String, dynamic>?> completeKioskOrder(
    String saleId,
    String tenderId, {
    num? amount,
    String? reference,
  }) async {
    final rows = Repo.rows(
      await callRpc(
        'complete_kiosk_order',
        params: {
          'p_sale': saleId,
          'p_tender': tenderId,
          if (amount != null) 'p_amount': amount,
          if (reference != null) 'p_reference': reference,
        },
      ),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Lands a batch of sales rung up with no signal.
  ///
  /// Safe to call twice, which is the point: a device that is not sure
  /// its request arrived should send again, and each payload comes back
  /// `landed`, `already` or `rejected` rather than being repeated. One
  /// bad payload is rejected on its own and kept in
  /// `pos_offline_rejects`; it does not take the day's takings with it.
  Future<List<Map<String, dynamic>>> ingestOfflineSales(
    String registerId,
    List<Map<String, dynamic>> payloads,
  ) async => Repo.rows(
    await callRpc(
      'ingest_offline_sales',
      params: {'p_register': registerId, 'p_sales': payloads},
    ),
  );

  /// What is still stuck. A payload the server refused is not the
  /// device's problem any more — it is somebody's, and this is where
  /// they find it.
  Future<List<Map<String, dynamic>>> posOfflineProblems() async => Repo.rows(
    await callRpc('pos_offline_problems', params: {'p_org': orgId}),
  );

  /// Who is on a bill, what they hold, and what paying it would earn.
  ///
  /// One read rather than contact-then-balance, so the panel cannot
  /// show a name and a points figure belonging to two different
  /// customers.
  Future<Map<String, dynamic>?> posSaleMember(String saleId) async {
    final rows = Repo.rows(
      await callRpc('pos_sale_member', params: {'p_sale': saleId}),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Finds a member from whatever the customer said — a card number, a
  /// mobile, part of a name. An exact card match sorts first, so
  /// scanning a card returns an answer rather than a shortlist.
  Future<List<Map<String, dynamic>>> loyaltyLookup(String query) async =>
      Repo.rows(
        await callRpc(
          'loyalty_lookup',
          params: {'p_org': orgId, 'p_query': query},
        ),
      );

  /// Puts a customer on a parked bill. This is what redemption reads:
  /// points belong to an account, and an account is reached through the
  /// contact on the sale.
  Future<void> namePosSaleCustomer(String saleId, String? contactId) async =>
      await callRpc(
        'name_pos_sale_customer',
        params: {'p_sale': saleId, 'p_contact': contactId},
      );

  /// Signs somebody up at the counter. Idempotent: a cashier who taps
  /// twice enrols one member and gets back the account they already
  /// had, rather than an error to explain to somebody holding a card.
  Future<String> enrolLoyaltyMember(String contactId, {String? cardNo}) async =>
      await callRpc(
            'enrol_loyalty_member',
            params: {
              'p_contact': contactId,
              if (cardNo != null) 'p_card_no': cardNo,
            },
          )
          as String;

  /// Puts points against a basket. Nothing is deducted yet — the ledger
  /// entries are written when the sale completes, so a parked bill that
  /// is abandoned costs the customer nothing. Zero clears a redemption
  /// somebody thought better of.
  Future<Map<String, dynamic>?> redeemLoyaltyPoints(
    String saleId,
    int points,
  ) async {
    final rows = Repo.rows(
      await callRpc(
        'redeem_loyalty_points',
        params: {'p_sale': saleId, 'p_points': points},
      ),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// The whole answer: what it came to, what the drawer asks for, what
  /// comes back and what rounding did. Four numbers because the customer
  /// can see all four, and a till that only showed the total would be
  /// asking the cashier to do the subtraction.
  Future<Map<String, dynamic>?> completePosSale(
    String saleId,
    List<Map<String, dynamic>> tenders, {
    String? contactId,
  }) async {
    final rows = Repo.rows(
      await callRpc(
        'complete_pos_sale',
        params: {
          'p_sale': saleId,
          'p_tenders': tenders,
          if (contactId != null) 'p_contact': contactId,
        },
      ),
    );
    return rows.isEmpty ? null : rows.first;
  }
}

/// Memberships: paying once a month for things you take one at a time.
///
/// 0218 built all of this — the offers, the subscriptions, the session
/// ledger, and five functions granted to `authenticated` — and nothing
/// in the app has ever called one of them. Every figure below is the
/// server's: the balance, the period boundaries and the coverage
/// decision are all worked out in SQL, because a screen that computed
/// "three classes left" itself would be a second implementation of the
/// membership rules, disagreeing with the receipt on exactly the
/// visits that get argued about.
extension RepoMemberships on Repo {
  /// What this company sells. The offers, not the people on them.
  Future<List<Map<String, dynamic>>> posMemberships() async => Repo.rows(
    await client
        .from('pos_memberships')
        .select('id, code, name, period, sessions_included, is_active')
        .eq('org_id', orgId)
        .order('name', ascending: true),
  );

  /// Who is on what.
  ///
  /// The member's name and the offer's name come back in the same read
  /// rather than as two more round trips per row, which on a list of
  /// two hundred subscriptions is the difference between a screen and
  /// a wait.
  ///
  /// Both embeds name their constraint. The comment that used to sit
  /// here said neither was ambiguous and that `check_embeds` proved it
  /// on every CI run; both halves were wrong. `0513` gave each of these
  /// tables a same-org composite key alongside the plain one, so there
  /// are two ways to join in each direction — and `check_embeds` was
  /// reading only the first string literal of a `.select()`, so it
  /// never saw this line at all.
  Future<List<Map<String, dynamic>>> membershipSubscriptions({
    String? status,
  }) async {
    var query = client
        .from('pos_membership_subscriptions')
        .select(
          'id, started_on, ends_on, status, note, recurring_document_id, '
          'contacts!pos_membership_subscriptions_contact_id_fkey(name), '
          'pos_memberships!pos_membership_subscriptions_membership_id_fkey'
          '(name, period, sessions_included)',
        )
        .eq('org_id', orgId);

    if (status != null && status != 'all') {
      query = query.eq('status', status);
    }
    return Repo.rows(await query.order('started_on', ascending: false));
  }

  /// What is left this period.
  ///
  /// `included` and `remaining` come back null for an unlimited
  /// membership, which is a different thing from zero and is why the
  /// screen has to distinguish them rather than defaulting one to the
  /// other.
  Future<Map<String, dynamic>?> membershipBalance(String subscriptionId) async {
    final rows = Repo.rows(
      await callRpc(
        'membership_balance',
        params: {'p_subscription': subscriptionId},
      ),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// The memberships nobody is billing.
  ///
  /// This exists because `start_membership` deliberately does not fail
  /// when the cashier cannot post: somebody who has paid gets their
  /// membership, and the missing renewal schedule is reported instead
  /// of refused. Reported to nobody is the same as refused, so this is
  /// the half that makes that trade honest.
  Future<List<Map<String, dynamic>>> membershipBillingGaps() async => Repo.rows(
    await callRpc('membership_billing_gaps', params: {'p_org': orgId}),
  );

  /// Starts one from the sale that paid for it. Returns the new
  /// subscription's id.
  Future<String> startMembership(String saleId, String membershipId) async =>
      await callRpc(
            'start_membership',
            params: {'p_sale': saleId, 'p_membership': membershipId},
          )
          as String;

  /// Pausing, cancelling, reinstating. The server stops the billing
  /// when the membership stops; nothing here has to remember to.
  Future<String> setMembershipStatus(
    String subscriptionId,
    String status,
  ) async =>
      await callRpc(
            'set_membership_status',
            params: {'p_subscription': subscriptionId, 'p_status': status},
          )
          as String;

  /// Takes a class on the membership. Returns what the line came down
  /// to — which is the server's arithmetic, not this screen's.
  ///
  /// The line stays on the bill at zero rather than being removed, so
  /// the receipt shows what the member had.
  Future<num> coverLineWithMembership(
    String lineId,
    String subscriptionId,
  ) async {
    final result = await callRpc(
      'cover_line_with_membership',
      params: {'p_line': lineId, 'p_subscription': subscriptionId},
    );
    return (result as num?) ?? 0;
  }

  /// The live subscriptions a customer holds, for the till: "is this
  /// covered?" is asked of a person, and answered from what they are
  /// on.
  Future<List<Map<String, dynamic>>> contactMemberships(
    String contactId,
  ) async => Repo.rows(
    await client
        .from('pos_membership_subscriptions')
        // Named because 0521 added a same-org composite key alongside
        // the plain one, so 'pos_memberships' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('id, status, pos_memberships!pos_membership_subscriptions_membership_id_fkey(name, sessions_included)')
        .eq('org_id', orgId)
        .eq('contact_id', contactId)
        .eq('status', 'active')
        .order('started_on', ascending: false),
  );
}

/// The consolidated e-Invoice a shop owes LHDN.
///
/// 0210 built this and nothing has ever called it. Under e-Invoicing
/// every invoice is a submission, so a shop doing five hundred sales a
/// day would owe LHDN five hundred documents, each with a buyer who
/// bought a drink and will never be identified. The guideline's answer
/// is one consolidated submission per period, due within seven days of
/// month end — and a till that cannot file it is a till that quietly
/// accrues an obligation nobody can see.
///
/// Every date here is the server's. `period_end + 7` is a statutory
/// deadline and belongs in one place, next to the rule that produced
/// it, rather than being recomputed by whichever screen is drawing it.
extension RepoPosEinvoice on Repo {
  /// What is waiting, by period, with the date it is due and how long
  /// is left. A negative `days_left` is a deadline already missed, and
  /// is meant to be shown rather than clamped to zero.
  Future<List<Map<String, dynamic>>> posEinvoiceOutstanding() async =>
      Repo.rows(
        await callRpc('pos_einvoice_outstanding', params: {'p_org': orgId}),
      );

  /// Rolls a period's anonymous sales into a single submission.
  ///
  /// The month is passed explicitly rather than left to the function's
  /// default, because the screen is showing a specific period and the
  /// button under it must file that one — a default that quietly means
  /// "last month" would file a different period from the row that was
  /// pressed.
  Future<Map<String, dynamic>?> consolidatePosEinvoices(
    String periodStart,
  ) async {
    final rows = Repo.rows(
      await callRpc(
        'consolidate_pos_einvoices',
        params: {'p_org': orgId, 'p_month': periodStart},
      ),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// "Boss, I need it under the company name."
  ///
  /// Asked after paying, which is when it is actually said across a
  /// counter. The server refuses once the sale has been rolled into a
  /// consolidation, because that submission has already told LHDN this
  /// sale had no identified buyer.
  Future<String> requestEinvoiceForSale(
    String saleId,
    String contactId,
  ) async =>
      await callRpc(
            'request_einvoice_for_sale',
            params: {'p_sale': saleId, 'p_contact': contactId},
          )
          as String;
}

/// The same shirt in six sizes.
///
/// 0211 made a variant an item rather than a row hanging off one,
/// because everything downstream in this database keys on `item_id` —
/// stock movements, weighted-average cost, `stock_levels`, the
/// forecasting reorder point, sales and purchase lines, the e-Invoice
/// snapshot. A variant that is not an item is a variant stock does not
/// know about. All of that was built and none of it had a caller.
extension RepoItemVariants on Repo {
  /// The axes a style already has, read back out of the children that
  /// exist rather than out of a second copy of the same fact. Empty
  /// means the item has not been split yet.
  Future<List<Map<String, dynamic>>> itemVariantMatrix(String parentId) async =>
      Repo.rows(
        await callRpc('item_variant_matrix', params: {'p_parent': parentId}),
      );

  /// The variants themselves, so the dialog can show what exists rather
  /// than only what axes were used.
  Future<List<Map<String, dynamic>>> itemVariants(String parentId) async =>
      Repo.rows(
        await client
            .from('items')
            .select(
              'id, code, name, variant_attributes, quantity_on_hand, '
              'unit_price, is_active',
            )
            .eq('org_id', orgId)
            .eq('parent_item_id', parentId)
            .isFilter('deleted_at', null)
            .order('code', ascending: true),
      );

  /// Generates the combinations of the axes given.
  ///
  /// Re-runnable by design: a shop that adds a colour in March passes
  /// the full axis list again and gets back only the new combinations,
  /// because the codes are deterministic and existing ones are skipped.
  /// Each returned row carries `created`, so the screen can say what it
  /// actually made rather than implying it made all of them.
  ///
  /// The codes and names are the server's. A client that built
  /// `SHIRT-M-NAVY` itself would be a second implementation of the
  /// naming rule, and the first disagreement would be a duplicate item
  /// nobody can merge.
  Future<List<Map<String, dynamic>>> createItemVariants(
    String parentId,
    Map<String, List<String>> axes,
  ) async => Repo.rows(
    await callRpc(
      'create_item_variants',
      params: {'p_parent': parentId, 'p_axes': axes},
    ),
  );
}

/// Points are a ledger, and somebody has to be able to look at it.
///
/// 0212 built the programme, the entries, the balance, a signed
/// adjustment and a dormancy sweep. The till reached the parts that
/// happen during a sale; these three were granted to `authenticated`
/// and never called. The sweep is the one that matters most: it is on
/// no schedule either, so a shop that set `dormancy_expiry_months`
/// has points that never expire and a liability that only grows.
extension RepoLoyaltyAdmin on Repo {
  /// What a customer holds, what it is worth, and when they last did
  /// anything. `worth` is the programme's redeem value applied on the
  /// server — the rate belongs next to the rule that uses it, not in a
  /// screen that would disagree the day somebody changes it.
  Future<Map<String, dynamic>?> loyaltyAccountBalance(String contactId) async {
    final rows = Repo.rows(
      await callRpc(
        'loyalty_account_balance',
        params: {'p_contact': contactId},
      ),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// A points adjustment somebody has to sign for. Returns the new
  /// balance.
  ///
  /// Deliberately narrower than selling: handing out points is handing
  /// out money, so the server requires an owner or admin and refuses an
  /// adjustment of zero, one with no reason, and one that would take
  /// the account below nothing. All four refusals are its own and are
  /// shown as they arrive.
  Future<int> adjustLoyaltyPoints(
    String accountId,
    int points,
    String note,
  ) async =>
      (await callRpc(
                'adjust_loyalty_points',
                params: {
                  'p_account': accountId,
                  'p_points': points,
                  'p_note': note,
                },
              )
              as num)
          .toInt();

  /// The dormancy sweep. Returns one row per account it cleared, so the
  /// screen can say who lost what rather than reporting a count.
  ///
  /// Idempotent: an account already at zero has nothing to expire, so
  /// running it twice in a day writes nothing the second time. A
  /// programme with no dormancy period set returns nothing at all,
  /// which is the correct answer rather than an error.
  Future<List<Map<String, dynamic>>> expireLoyaltyPoints() async => Repo.rows(
    await callRpc('expire_loyalty_points', params: {'p_org': orgId}),
  );
}

/// The two loose ends the till was left with.
extension RepoPosControls on Repo {
  /// What went off the bills, grouped by reason.
  ///
  /// 0225 wrote this for "the screen a manager opens when the food cost
  /// does not match the takings" and nothing ever opened it. Grouped
  /// rather than listed because one void is an accident and thirty
  /// "not received" in a week is a conversation.
  ///
  /// The dates are the shop's, not the server's: the function works in
  /// Asia/Kuala_Lumpur, so a sale at eleven at night belongs to the day
  /// the shop thinks it does.
  /// The bills written off in a period, one row each.
  ///
  /// Not the same question as [posVoidSummary], which groups lines by
  /// reason. A bill written off before the kitchen cooked anything
  /// writes no line-void rows at all, so that report cannot see the
  /// case the grant exists to control.
  // ------------------------------------------------------------------
  // The names a scheme gives its members (0253)
  // ------------------------------------------------------------------

  /// The scheme itself. One active programme per company, which is
  /// what `app.pos_settle_loyalty` assumes when it looks one up.
  Future<Map<String, dynamic>?> loyaltyProgram() async {
    final rows = Repo.rows(
      await client
          .from('loyalty_programs')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .limit(1),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// How far back a tier looks. Null is for ever — the scheme that
  /// never demotes anybody.
  Future<void> setLoyaltyTierWindow(String programId, int? months) => client
      .from('loyalty_programs')
      .update({'tier_window_months': months})
      .eq('id', programId);

  /// Every band, retired ones included, with how many members are
  /// actually sitting in each.
  Future<List<Map<String, dynamic>>> loyaltyTiers() async =>
      Repo.rows(await callRpc('loyalty_tiers_admin', params: {'p_org': orgId}));

  /// Which tier one account is in, and how far off the next.
  Future<Map<String, dynamic>?> loyaltyMemberTier(String accountId) async {
    final rows = Repo.rows(
      await callRpc('loyalty_member_tier', params: {'p_account': accountId}),
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<String> saveLoyaltyTier({
    required String programId,
    required String code,
    required String name,
    required int minPoints,
    double multiplier = 1,
    String? id,
    bool isActive = true,
  }) async =>
      await callRpc(
            'upsert_loyalty_tier',
            params: {
              'p_program': programId,
              'p_code': code,
              'p_name': name,
              'p_min_points': minPoints,
              'p_multiplier': multiplier,
              'p_id': id,
              'p_is_active': isActive,
            },
          )
          as String;

  Future<void> retireLoyaltyTier(String tierId) async =>
      await callRpc('retire_loyalty_tier', params: {'p_tier': tierId});

  /// Every outlet's trading for one day, for the person who owns all
  /// three shops rather than the one standing in a shop. 0252.
  Future<List<Map<String, dynamic>>> posDayBoard(DateTime date) async =>
      Repo.rows(
        await callRpc(
          'pos_day_board',
          params: {'p_org': orgId, 'p_date': Fmt.iso(date)},
        ),
      );

  Future<List<Map<String, dynamic>>> posVoidedBills(
    DateTime from,
    DateTime to,
  ) async => Repo.rows(
    await callRpc(
      'pos_voided_bills',
      params: {'p_org': orgId, 'p_from': Fmt.iso(from), 'p_to': Fmt.iso(to)},
    ),
  );

  Future<List<Map<String, dynamic>>> posVoidSummary(
    DateTime from,
    DateTime to,
  ) async => Repo.rows(
    await callRpc(
      'pos_void_summary',
      params: {'p_org': orgId, 'p_from': Fmt.iso(from), 'p_to': Fmt.iso(to)},
    ),
  );

  /// Takes money off one line, by a rate or by an amount.
  ///
  /// Passing neither clears it, which is how a discount typed on the
  /// wrong line is undone. The server measures a percentage against the
  /// line's full price rather than what is left of it, so pressing this
  /// twice replaces rather than compounds, and it refuses without a
  /// reason and without the `pos_discount` permission.
  Future<void> discountPosSaleLine(
    String lineId, {
    double? percent,
    double? amount,
    String? reason,
  }) async => await callRpc(
    'discount_pos_sale_line',
    params: {
      'p_line': lineId,
      'p_percent': percent,
      'p_amount': amount,
      'p_reason': reason,
    },
  );

  /// Takes money off the whole bill.
  ///
  /// A percentage is re-applied by the server whenever the basket
  /// changes, so "ten per cent off" is still ten per cent after another
  /// plate arrives. An amount stays as given. Returns what came off,
  /// which is not always what was asked for — the server caps it at the
  /// basket.
  Future<double> discountPosSale(
    String saleId, {
    double? percent,
    double? amount,
    String? reason,
  }) async => Fmt.toDouble(
    await callRpc(
      'discount_pos_sale',
      params: {
        'p_sale': saleId,
        'p_percent': percent,
        'p_amount': amount,
        'p_reason': reason,
      },
    ),
  );

  /// What was discounted, by whom, on which day and in which shop.
  ///
  /// The report the permission exists for. `posVoidSummary` answers
  /// where the food went; this answers where the price went.
  Future<List<Map<String, dynamic>>> posDiscountSummary(
    DateTime from,
    DateTime to,
  ) async => Repo.rows(
    await callRpc(
      'pos_discount_summary',
      params: {'p_org': orgId, 'p_from': Fmt.iso(from), 'p_to': Fmt.iso(to)},
    ),
  );

  /// Every menu schedule a company has written, with how many dishes
  /// are on each and whether it is open right now.
  Future<List<Map<String, dynamic>>> posMenuSchedules() async => Repo.rows(
    await callRpc('pos_menu_schedules_admin', params: {'p_org': orgId}),
  );

  /// The rule and the dishes on it in one call. A schedule saved
  /// without its dishes governs nothing, and the shop finds out at
  /// eleven o'clock.
  Future<String> savePosMenuSchedule({
    required String name,
    String? id,
    List<int>? weekdays,
    String? startsAt,
    String? endsAt,
    List<String>? items,
    bool isActive = true,
  }) async => (await callRpc(
    'upsert_pos_menu_schedule',
    params: {
      'p_org': orgId,
      'p_name': name,
      'p_weekdays': weekdays,
      'p_starts_at': startsAt,
      'p_ends_at': endsAt,
      'p_items': items,
      'p_id': id,
      'p_is_active': isActive,
    },
  )).toString();

  Future<void> retirePosMenuSchedule(String id) async =>
      await callRpc('retire_pos_menu_schedule', params: {'p_schedule': id});

  /// Takes a dish off for today at one outlet — the kitchen has run
  /// out. Guarded on working the till, because the person who notices
  /// is the person on the counter.
  Future<void> stopPosItem(
    String outletId,
    String itemId, {
    String? reason,
  }) async => await callRpc(
    'stop_pos_item',
    params: {'p_outlet': outletId, 'p_item': itemId, 'p_reason': reason},
  );

  /// Puts it back. True when there was something to put back.
  Future<bool> resumePosItem(String outletId, String itemId) async =>
      (await callRpc(
        'resume_pos_item',
        params: {'p_outlet': outletId, 'p_item': itemId},
      )) ==
      true;

  /// What this outlet has run out of today, and who said so.
  Future<List<Map<String, dynamic>>> posStoppedItems(String outletId) async =>
      Repo.rows(
        await callRpc('pos_stopped_items', params: {'p_outlet': outletId}),
      );

  /// Puts a party in the line and hands back their number, what they
  /// were told to expect, and how many are in front of them.
  ///
  /// The number is allocated server-side under an advisory lock, so two
  /// hosts at the door at once cannot give out the same one.
  Future<Map<String, dynamic>> joinPosQueue({
    required String outletId,
    int party = 2,
    String? name,
    String? phone,
    String? note,
  }) async {
    final rows = Repo.rows(
      await callRpc(
        'join_pos_queue',
        params: {
          'p_outlet': outletId,
          'p_party': party,
          'p_name': name,
          'p_phone': phone,
          'p_note': note,
        },
      ),
    );
    return rows.isEmpty ? const {} : rows.first;
  }

  /// Calls, seats or closes a party. `status` is one of `called`,
  /// `seated`, `left`, `no_show`.
  Future<void> setPosQueueStatus(
    String entryId,
    String status, {
    String? tableId,
  }) async => await callRpc(
    'set_pos_queue_status',
    params: {'p_entry': entryId, 'p_status': status, 'p_table': tableId},
  );

  /// Everyone still in the line at this outlet today, in arrival order.
  ///
  /// Minutes waited comes back computed, because a phone with a wrong
  /// clock would otherwise show a different queue from the tablet
  /// beside it and the argument that follows is with a customer.
  Future<List<Map<String, dynamic>>> posQueue(String outletId) async =>
      Repo.rows(await callRpc('pos_queue', params: {'p_outlet': outletId}));

  /// What the line did on one day, per outlet.
  Future<List<Map<String, dynamic>>> posQueueDay(DateTime date) async =>
      Repo.rows(
        await callRpc(
          'pos_queue_day',
          params: {'p_org': orgId, 'p_date': Fmt.iso(date)},
        ),
      );

  /// Every promotion a company has written, retired ones included.
  Future<List<Map<String, dynamic>>> posPromotions() async => Repo.rows(
    await callRpc('pos_promotions_admin', params: {'p_org': orgId}),
  );

  /// The rule and the three lists it is narrowed by, in one call.
  ///
  /// Null for a list leaves it alone; an empty list clears it, which is
  /// how a promotion narrowed to one shop is widened back to all of
  /// them. Saving the rule and its scope separately would let a shop
  /// publish "ten per cent off drinks" as ten per cent off everything.
  Future<String> savePosPromotion({
    required String name,
    required String kind,
    String? id,
    String? code,
    double percent = 0,
    double amount = 0,
    int buy = 0,
    int get = 0,
    DateTime? startsOn,
    DateTime? endsOn,
    List<int>? weekdays,
    String? startsAt,
    String? endsAt,
    double minSubtotal = 0,
    int? maxUses,
    int? maxPerCustomer,
    List<String>? items,
    List<String>? outlets,
    List<String>? channels,
    bool isActive = true,
  }) async => (await callRpc(
    'upsert_pos_promotion',
    params: {
      'p_org': orgId,
      'p_name': name,
      'p_kind': kind,
      'p_code': code,
      'p_percent': percent,
      'p_amount': amount,
      'p_buy': buy,
      'p_get': get,
      'p_starts_on': startsOn == null ? null : Fmt.iso(startsOn),
      'p_ends_on': endsOn == null ? null : Fmt.iso(endsOn),
      'p_weekdays': weekdays,
      'p_starts_at': startsAt,
      'p_ends_at': endsAt,
      'p_min_subtotal': minSubtotal,
      'p_max_uses': maxUses,
      'p_max_per_customer': maxPerCustomer,
      'p_items': items,
      'p_outlets': outlets,
      'p_channels': channels,
      'p_id': id,
      'p_is_active': isActive,
    },
  )).toString();

  Future<void> retirePosPromotion(String id) async =>
      await callRpc('retire_pos_promotion', params: {'p_promo': id});

  /// What is on a bill and what each took off, including a voucher
  /// currently qualifying for nothing and the reason why.
  Future<List<Map<String, dynamic>>> posSalePromotions(String saleId) async =>
      Repo.rows(
        await callRpc('pos_sale_promotions_on', params: {'p_sale': saleId}),
      );

  /// Types a voucher onto a bill. The server refuses a code that does
  /// not qualify rather than attaching it inert, so the error message
  /// is the thing worth showing.
  Future<void> applyPosCoupon(String saleId, String code) async =>
      await callRpc(
        'apply_pos_coupon',
        params: {'p_sale': saleId, 'p_code': code},
      );

  Future<void> removePosSalePromotion(String rowId) async =>
      await callRpc('remove_pos_sale_promotion', params: {'p_row': rowId});

  /// Works the shop's own rules out again against the basket as it now
  /// stands, and returns what the bill comes to. Called after anything
  /// that changes the basket, because a rate on a bill that has shrunk
  /// is no longer that rate.
  Future<double> refreshPosSalePromotions(String saleId) async => Fmt.toDouble(
    await callRpc('refresh_pos_sale_promotions', params: {'p_sale': saleId}),
  );

  /// Takes one modifier back off a parked line.
  ///
  /// `add_line_modifier` has had a caller since the till was built and
  /// this never did, so a waiter who tapped "extra cheese" by mistake
  /// had to void the whole line and ring it again. The server reprices
  /// the line afterwards and refuses once the bill is no longer parked.
  Future<void> removeLineModifier(String lineModifierId) async => await callRpc(
    'remove_line_modifier',
    params: {'p_line_modifier': lineModifierId},
  );

  // ------------------------------------------------------------------
  // Deliveries
  // ------------------------------------------------------------------

  /// Takes or corrects the address on a parked bill.
  ///
  /// One call for both, because "the customer just read the unit number
  /// back differently" is the normal case. Comes back with the zone it
  /// resolved to, what the ride costs and the shortfall sentence when
  /// the order is under the zone's minimum — which the till shows while
  /// the customer is still on the phone.
  ///
  /// [fee] overrides the zone's price. Charging less than the zone says
  /// needs permission to discount, and the server refuses without it.
  Future<Map<String, dynamic>> setPosDelivery({
    required String saleId,
    required String line1,
    required String phone,
    String? line2,
    String? city,
    String? state,
    String? postcode,
    String? recipient,
    String? notes,
    DateTime? promisedAt,
    double? fee,
  }) async {
    final rows = Repo.rows(
      await callRpc(
        'set_pos_delivery',
        params: {
          'p_sale': saleId,
          'p_line1': line1,
          'p_phone': phone,
          'p_line2': line2,
          'p_city': city,
          'p_state': state,
          'p_postcode': postcode,
          'p_recipient': recipient,
          'p_notes': notes,
          'p_promised': promisedAt?.toIso8601String(),
          'p_fee': fee,
        },
      ),
    );
    return rows.isEmpty ? const {} : rows.first;
  }

  /// Takes the address and the fee back off a parked bill. Refused once
  /// a driver has the order.
  Future<void> clearPosDelivery(String saleId) async =>
      await callRpc('clear_pos_delivery', params: {'p_sale': saleId});

  /// Where this bill is going, what the ride costs and who has it.
  Future<Map<String, dynamic>> posDeliveryFor(String saleId) async {
    final rows = Repo.rows(
      await callRpc('pos_delivery_for', params: {'p_sale': saleId}),
    );
    return rows.isEmpty ? const {} : rows.first;
  }

  /// Every run at this outlet that has not landed, oldest first.
  Future<List<Map<String, dynamic>>> posDeliveryBoard(String outletId) async =>
      Repo.rows(
        await callRpc('pos_delivery_board', params: {'p_outlet': outletId}),
      );

  /// Puts a run on a driver's list, or moves it to another one.
  Future<void> assignPosDelivery(String deliveryId, String driverId) async =>
      await callRpc(
        'assign_pos_delivery',
        params: {'p_delivery': deliveryId, 'p_driver': driverId},
      );

  /// Moves a run along. [status] is one of `assigned`, `collected`,
  /// `delivered`, `failed`; a failure has to say why.
  Future<void> setPosDeliveryStatus(
    String deliveryId,
    String status, {
    String? reason,
  }) async => await callRpc(
    'set_pos_delivery_status',
    params: {'p_delivery': deliveryId, 'p_status': status, 'p_reason': reason},
  );

  /// How far this company will go and what it charges to get there.
  Future<List<Map<String, dynamic>>> posDeliveryZones() async => Repo.rows(
    await callRpc('pos_delivery_zones_admin', params: {'p_org': orgId}),
  );

  /// Postcodes are normalised to five digits server-side, so whatever
  /// somebody typed around them does not matter.
  Future<String> savePosDeliveryZone({
    required String outletId,
    required String name,
    String? id,
    List<String>? postcodes,
    double fee = 0,
    double minOrder = 0,
    double? freeAbove,
    int? etaMinutes,
    int sortOrder = 0,
    bool isActive = true,
  }) async => (await callRpc(
    'upsert_pos_delivery_zone',
    params: {
      'p_id': id,
      'p_outlet': outletId,
      'p_name': name,
      'p_postcodes': postcodes ?? const <String>[],
      'p_fee': fee,
      'p_min_order': minOrder,
      'p_free_above': freeAbove,
      'p_eta': etaMinutes,
      'p_sort': sortOrder,
      'p_active': isActive,
    },
  )).toString();

  Future<void> retirePosDeliveryZone(String id) async =>
      await callRpc('retire_pos_delivery_zone', params: {'p_id': id});

  /// The people who carry the orders, with how many each has out now.
  Future<List<Map<String, dynamic>>> posDrivers() async =>
      Repo.rows(await callRpc('pos_drivers_admin', params: {'p_org': orgId}));

  Future<String> savePosDriver({
    required String name,
    String? id,
    String? phone,
    String? vehicle,
    String? plateNo,
    String? outletId,
    bool isActive = true,
  }) async => (await callRpc(
    'upsert_pos_driver',
    params: {
      'p_id': id,
      'p_org': orgId,
      'p_name': name,
      'p_phone': phone,
      'p_vehicle': vehicle,
      'p_plate': plateNo,
      'p_outlet': outletId,
      'p_active': isActive,
    },
  )).toString();

  /// Stands a driver down. Refused while they still have orders out.
  Future<void> retirePosDriver(String id) async =>
      await callRpc('retire_pos_driver', params: {'p_id': id});

  /// What each driver carried on one trading day.
  Future<List<Map<String, dynamic>>> posDriverRuns(DateTime date) async =>
      Repo.rows(
        await callRpc(
          'pos_driver_runs',
          params: {'p_org': orgId, 'p_date': Fmt.iso(date)},
        ),
      );

  /// One day of delivering, per outlet.
  Future<List<Map<String, dynamic>>> posDeliveryDay(DateTime date) async =>
      Repo.rows(
        await callRpc(
          'pos_delivery_day',
          params: {'p_org': orgId, 'p_date': Fmt.iso(date)},
        ),
      );

  // ------------------------------------------------------------------
  // The receipt
  // ------------------------------------------------------------------

  /// The paper, rendered on the server and wrapped to the outlet's own
  /// width.
  ///
  /// Text rather than a widget tree on purpose: it is what a thermal
  /// printer takes, and it means the counter, the phone, the kiosk and
  /// a reprint an hour later all produce the same receipt.
  Future<String> posReceiptText(String saleId) async =>
      (await callRpc(
        'pos_receipt_text',
        params: {'p_sale': saleId},
      ))?.toString() ??
      '';

  /// The service charge this outlet adds, and the tax that rides it.
  ///
  /// A Malaysian bill reads "subject to 10% service charge and 8%
  /// service tax", and the service tax is charged on the amount that
  /// already includes the charge — so this is not a printing choice,
  /// it changes what the customer pays. `0410` does the arithmetic and
  /// `0411` is the setter.
  ///
  /// A null tax code means a charge with nothing on top, which is what
  /// an outlet that is not registered for service tax has.
  Future<void> savePosServiceCharge({
    required String outletId,
    required double percent,
    String? taxCodeId,
  }) => callRpc(
    'set_pos_service_charge',
    params: {
      'p_outlet': outletId,
      'p_percent': percent,
      'p_tax_code': taxCodeId,
    },
  );

  /// What this outlet prints, defaults included.
  Future<Map<String, dynamic>> posReceiptSettings(String outletId) async {
    final rows = Repo.rows(
      await callRpc('pos_receipt_settings_for', params: {'p_outlet': outletId}),
    );
    return rows.isEmpty ? const {} : rows.first;
  }

  /// Saves the header, the footer and the choices in one call, so a
  /// shop is never left having saved half of what it typed.
  Future<void> savePosReceiptSettings({
    required String outletId,
    String? header,
    String? footer,
    int paperMm = 80,
    int copies = 1,
    String language = 'en',
    bool itemCodes = false,
    bool cashier = true,
    bool table = true,
    bool channel = false,
    bool tax = true,
    bool customer = true,
    bool points = true,
    bool qr = true,
  }) async => await callRpc(
    'upsert_pos_receipt_settings',
    params: {
      'p_outlet': outletId,
      'p_header': header,
      'p_footer': footer,
      'p_paper_mm': paperMm,
      'p_copies': copies,
      'p_language': language,
      'p_item_codes': itemCodes,
      'p_cashier': cashier,
      'p_table': table,
      'p_channel': channel,
      'p_tax': tax,
      'p_customer': customer,
      'p_points': points,
      'p_qr': qr,
    },
  );

  /// The last bill this outlet settled, so the settings screen previews
  /// a real receipt rather than an invented basket.
  Future<String?> posRecentSale(String outletId) async => (await callRpc(
    'pos_recent_sale',
    params: {'p_outlet': outletId},
  ))?.toString();

  // ------------------------------------------------------------------
  // Published menus
  // ------------------------------------------------------------------

  /// Every menu link this company has published, with how many bills
  /// came in through each.
  Future<List<Map<String, dynamic>>> posMenuLinks() async => Repo.rows(
    await callRpc('pos_menu_links_admin', params: {'p_org': orgId}),
  );

  /// Publishes a menu, or edits one that is already published.
  ///
  /// Comes back with the token, which is the whole of what a customer
  /// is given: the page at `/menu/<token>` needs nothing else.
  Future<Map<String, dynamic>> savePosMenuLink({
    required String outletId,
    String kind = 'table',
    String? tableId,
    String? registerId,
    String? label,
    DateTime? expiresAt,
    bool singleUse = false,
    String? id,
    bool isActive = true,
  }) async {
    final rows = Repo.rows(
      await callRpc(
        'upsert_pos_menu_link',
        params: {
          'p_outlet': outletId,
          'p_kind': kind,
          'p_table': tableId,
          'p_register': registerId,
          'p_label': label,
          'p_expires': expiresAt?.toIso8601String(),
          'p_single': singleUse,
          'p_id': id,
          'p_active': isActive,
        },
      ),
    );
    return rows.isEmpty ? const {} : rows.first;
  }

  /// Switches a published menu off. The sticker stops working at once;
  /// the orders that came in through it still name it.
  Future<void> retirePosMenuLink(String id) async =>
      await callRpc('retire_pos_menu_link', params: {'p_id': id});

  // ------------------------------------------------------------------
  // Reports somebody builds
  // ------------------------------------------------------------------

  /// The reports this company keeps, plus the caller's own private ones.
  Future<List<Map<String, dynamic>>> posReports() async =>
      Repo.rows(await callRpc('pos_reports_list', params: {'p_org': orgId}));

  /// What a source can be cut by and what it can add up.
  ///
  /// Read from the server rather than listed in Dart, so the picker and
  /// the query can never disagree about which columns exist.
  Future<List<Map<String, dynamic>>> posReportFields(String source) async =>
      Repo.rows(
        await callRpc('pos_report_fields', params: {'p_source': source}),
      );

  /// Saves a built report. Every key is checked server-side against the
  /// same allow-list the query uses, so a report that cannot run cannot
  /// be saved.
  Future<String> savePosReport({
    required String name,
    String source = 'sales',
    List<String> dimensions = const [],
    List<String> measures = const ['gross'],
    String period = 'this_month',
    DateTime? from,
    DateTime? to,
    List<String> outletIds = const [],
    List<String> channels = const [],
    String? sortBy,
    bool sortDesc = true,
    int rowLimit = 200,
    bool shared = true,
    String? id,
  }) async => (await callRpc(
    'upsert_pos_report',
    params: {
      'p_org': orgId,
      'p_name': name,
      'p_source': source,
      'p_dimensions': dimensions,
      'p_measures': measures,
      'p_period': period,
      'p_from': from == null ? null : Fmt.iso(from),
      'p_to': to == null ? null : Fmt.iso(to),
      'p_outlets': outletIds,
      'p_channels': channels,
      'p_sort_by': sortBy,
      'p_sort_desc': sortDesc,
      'p_limit': rowLimit,
      'p_shared': shared,
      'p_id': id,
    },
  )).toString();

  Future<void> deletePosReport(String id) async =>
      await callRpc('delete_pos_report', params: {'p_id': id});

  /// One row per group: the dimension values as text, the measures as
  /// numbers, both in the order the report declared.
  Future<List<Map<String, dynamic>>> runPosReport(String id) async =>
      Repo.rows(await callRpc('run_pos_report', params: {'p_report': id}));

  /// What the columns are called and which two dates it covers today.
  Future<Map<String, dynamic>> posReportHeaders(String id) async {
    final rows = Repo.rows(
      await callRpc('pos_report_headers', params: {'p_report': id}),
    );
    return rows.isEmpty ? const {} : rows.first;
  }
}

/// Saying that a customer is another company in the same group.
///
/// 0142 added `contacts.linked_org_id` and the guarded function that
/// sets it, and nothing ever called it. Two features read that column:
/// 0146 matches an intercompany invoice to the bill it should become,
/// and 0148 eliminates intercompany balances on consolidation. With
/// nothing able to set it, both look and find nothing — a consolidation
/// that silently eliminates none of the trading between sister
/// companies, which is the one thing consolidating is for.
extension RepoGroupContacts on Repo {
  /// Which organization this contact stands for, if any. Read on its
  /// own rather than carried on the `Contact` model deliberately:
  /// putting it there would send it through the ordinary contact update
  /// and around the checks below.
  Future<String?> contactLinkedOrg(String contactId) async {
    final row = await client
        .from('contacts')
        .select('linked_org_id')
        .eq('id', contactId)
        .maybeSingle();
    return row?['linked_org_id'] as String?;
  }

  /// Points a contact at a sister company, or clears the link with
  /// null.
  ///
  /// Not a free-text edit, which is 0142's reasoning and worth keeping:
  /// the target has to be in the same group *and* one the caller can
  /// already reach, because without the second test this becomes a way
  /// to discover which companies exist. Unlinking is always allowed —
  /// it removes an assertion rather than making one.
  Future<void> linkGroupContact(String contactId, String? orgId) async =>
      await callRpc(
        'link_group_contact',
        params: {'p_contact_id': contactId, 'p_org_id': orgId},
      );
}

/// Recipes, the units they are written in, and what the kitchen can
/// still make.
///
/// 0264's side of the till. The dish is a non-stock item — it has to
/// be, or posting the invoice would move stock for a plate nobody keeps
/// a shelf of — so nothing about selling one has ever reached the rice
/// it was made from. A recipe is what closes that, and the countdown is
/// what a kitchen actually asks: how many more can I sell?
extension RepoPosRecipes on Repo {
  /// One row per dish that has a recipe, with what one costs at today's
  /// weighted average.
  Future<List<Map<String, dynamic>>> posRecipes() async =>
      Repo.rows(await callRpc('pos_recipes_list', params: {'p_org': orgId}));

  /// The lines of one, in the order they were written.
  Future<List<Map<String, dynamic>>> posRecipeLines(String recipeId) async =>
      Repo.rows(
        await callRpc('pos_recipe_lines_for', params: {'p_recipe': recipeId}),
      );

  /// What making [quantity] of a dish draws out of the store, with any
  /// sub-recipes already exploded. This is the list that explains why
  /// the countdown says four.
  Future<List<Map<String, dynamic>>> posRecipeRequirement(
    String itemId, {
    num quantity = 1,
  }) async => Repo.rows(
    await callRpc(
      'pos_recipe_requirement',
      params: {'p_item': itemId, 'p_qty': quantity},
    ),
  );

  /// Saves a recipe and all of its lines in one call. Each entry of
  /// [lines] is `{item, quantity, uom, wastage, optional}`.
  Future<String> savePosRecipe({
    required String itemId,
    required num yield_,
    required List<Map<String, dynamic>> lines,
    String? notes,
    bool active = true,
  }) async => (await callRpc(
    'upsert_pos_recipe',
    params: {
      'p_org': orgId,
      'p_item': itemId,
      'p_yield': yield_,
      'p_lines': lines,
      'p_notes': notes,
      'p_active': active,
    },
  )).toString();

  Future<void> deletePosRecipe(String recipeId) async =>
      await callRpc('delete_pos_recipe', params: {'p_recipe': recipeId});

  /// How many more of each dish this outlet can make, and what runs out
  /// first.
  Future<List<Map<String, dynamic>>> posItemAvailability(
    String outletId,
  ) async => Repo.rows(
    await callRpc('pos_item_availability', params: {'p_outlet': outletId}),
  );

  /// Every unit an item's quantities may be written in: the ones its
  /// dimension converts to, plus whatever pack sizes the shop has set.
  Future<List<Map<String, dynamic>>> itemUomOptions(String itemId) async =>
      Repo.rows(await callRpc('item_uom_options', params: {'p_item': itemId}));

  /// One [uom] of this item is [quantity] of the item's own unit.
  Future<void> saveItemUomPack(String itemId, String uom, num quantity) async =>
      await callRpc(
        'upsert_item_uom_pack',
        params: {'p_item': itemId, 'p_uom': uom, 'p_qty': quantity},
      );

  Future<void> deleteItemUomPack(String itemId, String uom) async =>
      await callRpc(
        'delete_item_uom_pack',
        params: {'p_item': itemId, 'p_uom': uom},
      );
}

/// Moving stock between stores, and turning one thing into several.
///
/// 0265. `transfer_in` and `transfer_out` have been movement types
/// since 0006 and nothing ever wrote either; `1320 Goods in Transit`
/// has been in the chart since 0071 for the same never. A chain with a
/// central kitchen had to fake a transfer with two stock adjustments,
/// which loses the audit trail and posts two unexplained entries to
/// 5900 instead of none.
extension RepoStockTransfers on Repo {
  /// Every transfer, newest first, optionally narrowed to one state.
  Future<List<Map<String, dynamic>>> stockTransfers({String? status}) async =>
      Repo.rows(
        await callRpc(
          'stock_transfers_list',
          params: {'p_org': orgId, 'p_status': status},
        ),
      );

  Future<List<Map<String, dynamic>>> stockTransferLines(String id) async =>
      Repo.rows(
        await callRpc('stock_transfer_lines_for', params: {'p_transfer': id}),
      );

  /// Saves a draft. Each entry of [lines] is `{item, quantity, uom, note}`.
  Future<String> saveStockTransfer({
    String? id,
    required String fromWarehouse,
    required String toWarehouse,
    required DateTime date,
    required List<Map<String, dynamic>> lines,
    String? notes,
  }) async => (await callRpc(
    'upsert_stock_transfer',
    params: {
      'p_id': id,
      'p_org': orgId,
      'p_from': fromWarehouse,
      'p_to': toWarehouse,
      'p_date': date.toIso8601String().substring(0, 10),
      'p_lines': lines,
      'p_notes': notes,
    },
  )).toString();

  /// Takes the stock out of the source and parks its value in transit.
  Future<void> sendStockTransfer(String id) async =>
      await callRpc('send_stock_transfer', params: {'p_id': id});

  /// Counts it in. Each entry of [counts] is `{line, quantity}` in the
  /// item's own unit; a line nobody counted is taken as having arrived
  /// in full.
  Future<void> receiveStockTransfer(
    String id, {
    List<Map<String, dynamic>> counts = const [],
  }) async => await callRpc(
    'receive_stock_transfer',
    params: {'p_id': id, 'p_counts': counts},
  );

  Future<void> cancelStockTransfer(String id) async =>
      await callRpc('cancel_stock_transfer', params: {'p_id': id});

  /// The conversions a company keeps: a whole chicken into pieces, a
  /// sack into packs.
  Future<List<Map<String, dynamic>>> itemConversions() async => Repo.rows(
    await callRpc('item_conversions_list', params: {'p_org': orgId}),
  );

  Future<List<Map<String, dynamic>>> itemConversionOutputs(String id) async =>
      Repo.rows(
        await callRpc(
          'item_conversion_outputs_for',
          params: {'p_conversion': id},
        ),
      );

  /// Each entry of [outputs] is `{item, quantity, uom, share}`, and the
  /// shares have to total 100 — the server refuses otherwise, because a
  /// split that does not add up invents or destroys stock value.
  Future<String> saveItemConversion({
    String? id,
    required String code,
    required String name,
    required String fromItem,
    required num fromQuantity,
    required String fromUom,
    required List<Map<String, dynamic>> outputs,
    bool active = true,
  }) async => (await callRpc(
    'upsert_item_conversion',
    params: {
      'p_id': id,
      'p_org': orgId,
      'p_code': code,
      'p_name': name,
      'p_item': fromItem,
      'p_qty': fromQuantity,
      'p_uom': fromUom,
      'p_outputs': outputs,
      'p_active': active,
    },
  )).toString();

  Future<void> deleteItemConversion(String id) async =>
      await callRpc('delete_item_conversion', params: {'p_id': id});

  /// Runs one, returning the value that moved.
  Future<num> runItemConversion(
    String id, {
    num times = 1,
    String? warehouse,
  }) async {
    final result = await callRpc(
      'run_item_conversion',
      params: {'p_conversion': id, 'p_times': times, 'p_warehouse': warehouse},
    );
    return num.tryParse('$result') ?? 0;
  }
}

/// Things sold by weight, and the labels a counter scale prints.
///
/// 0266. Every quantity this system produced was a whole number — the
/// till adds 1, a tile adds 1, a scan adds its pack quantity — so a
/// deli, a fishmonger or anybody selling kuih by the kilogram could not
/// ring a sale up at all.
extension RepoWeighed on Repo {
  /// Everything this shop sells by weight, and what its scale calls it.
  Future<List<Map<String, dynamic>>> weighedItems() async =>
      Repo.rows(await callRpc('weighed_items', params: {'p_org': orgId}));

  /// Says an item is sold by weight, and gives it the number its scale
  /// knows it by. Refused on an item counted in pieces.
  Future<void> setItemWeighed(
    String itemId, {
    required bool weighed,
    String? plu,
  }) async => await callRpc(
    'set_item_weighed',
    params: {'p_item': itemId, 'p_weighed': weighed, 'p_plu': plu},
  );

  /// The label layouts this company's scales print.
  Future<List<Map<String, dynamic>>> scaleFormats() async =>
      Repo.rows(await callRpc('scale_formats_list', params: {'p_org': orgId}));

  /// [kind] is one of `weight_grams`, `weight_kg_3dp`, `price_sen`.
  Future<String> saveScaleFormat({
    String? id,
    required String name,
    required String prefix,
    required int codeDigits,
    required int valueDigits,
    required String kind,
    bool checkDigit = true,
    bool active = true,
  }) async => (await callRpc(
    'upsert_scale_format',
    params: {
      'p_id': id,
      'p_org': orgId,
      'p_name': name,
      'p_prefix': prefix,
      'p_code_digits': codeDigits,
      'p_value_digits': valueDigits,
      'p_kind': kind,
      'p_check': checkDigit,
      'p_active': active,
    },
  )).toString();

  Future<void> deleteScaleFormat(String id) async =>
      await callRpc('delete_scale_format', params: {'p_id': id});
}

/// The food court: stalls under one outlet, and what each is owed.
///
/// 0268. A court is one room, one payment counter and a dozen
/// businesses that are not the same business. Before this a court had
/// to give every stall its own outlet and its own till, which makes the
/// customer queue three times — precisely what a food court exists to
/// avoid.
extension RepoFoodCourt on Repo {
  Future<List<Map<String, dynamic>>> posStalls(String outletId) async =>
      Repo.rows(
        await callRpc('pos_stalls_list', params: {'p_outlet': outletId}),
      );

  Future<String> savePosStall({
    String? id,
    required String outletId,
    required String code,
    required String name,
    required String operatorContactId,
    num commission = 0,
    bool active = true,
  }) async => (await callRpc(
    'upsert_pos_stall',
    params: {
      'p_id': id,
      'p_outlet': outletId,
      'p_code': code,
      'p_name': name,
      'p_operator': operatorContactId,
      'p_commission': commission,
      'p_active': active,
    },
  )).toString();

  /// Whose dish this is. Null puts it back on the court itself.
  /// Which items belong to which stall.
  ///
  /// Read raw rather than through [Item]: `stall_id` is not on the
  /// model, and putting it there would send it back on every save from
  /// the item editor, which knows nothing about stalls and would blank
  /// it.
  Future<List<Map<String, dynamic>>> itemStalls() async => Repo.rows(
    await client
        .from('items')
        .select('id, code, name, stall_id')
        .eq('org_id', orgId)
        .isFilter('deleted_at', null)
        .order('code', ascending: true),
  );

  Future<void> setItemStall(String itemId, String? stallId) async =>
      await callRpc(
        'set_item_stall',
        params: {'p_item': itemId, 'p_stall': stallId},
      );

  /// What each stall sold over a period and what it is owed, with
  /// whether any of those days have already been paid for.
  Future<List<Map<String, dynamic>>> posStallTakings(
    String outletId,
    DateTime from,
    DateTime to,
  ) async => Repo.rows(
    await callRpc(
      'pos_stall_takings',
      params: {
        'p_outlet': outletId,
        'p_from': from.toIso8601String().substring(0, 10),
        'p_to': to.toIso8601String().substring(0, 10),
      },
    ),
  );

  /// Raises one posted purchase bill per stall. Refused for a period
  /// that is not over, or one whose days have been settled already.
  Future<List<Map<String, dynamic>>> settlePosStalls(
    String outletId,
    DateTime from,
    DateTime to,
  ) async => Repo.rows(
    await callRpc(
      'settle_pos_stalls',
      params: {
        'p_outlet': outletId,
        'p_from': from.toIso8601String().substring(0, 10),
        'p_to': to.toIso8601String().substring(0, 10),
      },
    ),
  );

  Future<List<Map<String, dynamic>>> posStallSettlements(
    String outletId,
  ) async => Repo.rows(
    await callRpc('pos_stall_settlements_list', params: {'p_outlet': outletId}),
  );
}

/// Crediting an invoice, and what that puts back.
///
/// 0269. `sales_documents.original_invoice_id` has existed since 0005
/// and nothing ever wrote it — a credit note was a document typed by
/// hand with no record of which invoice it credits. Without that link
/// nothing can be capped at what was sold, and a credited plate cannot
/// tell a recipe which ingredients to return.
extension RepoCreditNotes on Repo {
  /// What is left uncredited on each line of an invoice.
  Future<List<Map<String, dynamic>>> invoiceCreditRemaining(
    String invoiceId,
  ) async => Repo.rows(
    await callRpc('invoice_credit_remaining', params: {'p_invoice': invoiceId}),
  );

  /// Raises and posts a credit note. [lines] is `{invoice line id:
  /// quantity}`; null credits everything still uncredited. Returns the
  /// credit note's id.
  Future<String> creditSalesInvoice(
    String invoiceId, {
    Map<String, num>? lines,
    String? reason,
  }) async => (await callRpc(
    'credit_sales_invoice',
    params: {
      'p_invoice': invoiceId,
      'p_lines': lines == null
          ? null
          : [
              for (final e in lines.entries)
                {'line': e.key, 'quantity': e.value},
            ],
      'p_reason': reason,
    },
  )).toString();
}

/// The same thing one table over, for a supplier's bill.
///
/// 0376. `purchase_documents.original_bill_id` has existed since 0006
/// with the same intent and the same silence. Without the link a
/// supplier credit cannot be capped at what was billed, cannot be paired
/// with the bill on the aged listing, and cannot say whose input tax it
/// adjusts.
extension RepoBillCredits on Repo {
  /// What is left uncredited on each line of a bill.
  Future<List<Map<String, dynamic>>> billCreditRemaining(String billId) async =>
      Repo.rows(
        await callRpc('bill_credit_remaining', params: {'p_bill': billId}),
      );

  /// Raises and posts a credit note against a bill. [lines] is `{bill
  /// line id: quantity}`; null credits everything still uncredited.
  Future<String> creditPurchaseBill(
    String billId, {
    Map<String, num>? lines,
    String? reason,
  }) async => (await callRpc(
    'credit_purchase_bill',
    params: {
      'p_bill': billId,
      'p_lines': lines == null
          ? null
          : [
              for (final e in lines.entries)
                {'line': e.key, 'quantity': e.value},
            ],
      'p_reason': reason,
    },
  )).toString();
}

/// Landed cost: freight, duty and insurance onto what the goods cost.
/// 0271.
extension RepoLandedCost on Repo {
  /// Every run, newest first, optionally narrowed to one state.
  Future<List<Map<String, dynamic>>> landedCostRuns({String? status}) async =>
      Repo.rows(
        await callRpc(
          'landed_cost_runs_list',
          params: {'p_org': orgId, 'p_status': status},
        ),
      );

  /// What each goods line would take, computed by the same function the
  /// posting uses. Safe to call on a draft as often as the screen likes.
  Future<List<Map<String, dynamic>>> landedCostPreview(String runId) async =>
      Repo.rows(await callRpc('landed_cost_preview', params: {'p_run': runId}));

  Future<List<Map<String, dynamic>>> landedCostTargets(String runId) async =>
      Repo.rows(
        await client
            .from('landed_cost_targets')
        // Named because 0518 added a same-org composite key alongside
        // the plain one, so 'purchase_documents' can now be joined two
        // ways and PostgREST refuses the embed with PGRST201.
        .select('bill_id, purchase_documents!landed_cost_targets_bill_id_fkey(doc_no, doc_date)')
            .eq('run_id', runId),
      );

  Future<List<Map<String, dynamic>>> landedCostCharges(String runId) async =>
      Repo.rows(
        await client
            .from('landed_cost_charges')
        // Named because 0514 added a same-org composite key alongside
        // the plain one, so 'accounts' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, accounts!landed_cost_charges_account_id_fkey(code, name)')
            .eq('run_id', runId)
            .order('line_no', ascending: true),
      );

  /// Saves a draft. [bills] is a list of posted bill ids; each entry of
  /// [charges] is `{description, amount, basis, account}`.
  Future<String> saveLandedCostRun({
    String? id,
    required DateTime date,
    required List<String> bills,
    required List<Map<String, dynamic>> charges,
    String? notes,
  }) async => (await callRpc(
    'upsert_landed_cost_run',
    params: {
      'p_id': id,
      'p_org': orgId,
      'p_date': date.toIso8601String().substring(0, 10),
      'p_bills': [
        for (final b in bills) {'bill': b},
      ],
      'p_charges': charges,
      'p_notes': notes,
    },
  )).toString();

  Future<void> postLandedCostRun(String id) async =>
      await callRpc('post_landed_cost_run', params: {'p_run': id});

  Future<void> cancelLandedCostRun(String id) async =>
      await callRpc('cancel_landed_cost_run', params: {'p_run': id});
}

/// AR/AP contra: offsetting what a party owes against what is owed to
/// them. 0272.
extension RepoContra on Repo {
  Future<List<Map<String, dynamic>>> contraNotes({String? status}) async =>
      Repo.rows(
        await callRpc(
          'contra_notes_list',
          params: {'p_org': orgId, 'p_status': status},
        ),
      );

  /// Everything outstanding on both sides for a party, found from either
  /// of their contact records.
  Future<List<Map<String, dynamic>>> contraCandidates(String contactId) async =>
      Repo.rows(
        await callRpc('contra_candidates', params: {'p_contact': contactId}),
      );

  Future<List<Map<String, dynamic>>> contraLines(String id) async =>
      Repo.rows(await callRpc('contra_lines', params: {'p_id': id}));

  /// Each entry of [invoices] and [bills] is `{document, amount}`, and
  /// the two sides have to come to the same figure.
  Future<String> createContra({
    required DateTime date,
    required List<Map<String, dynamic>> invoices,
    required List<Map<String, dynamic>> bills,
    String? notes,
  }) async => (await callRpcOnce(
    'create_contra',
    params: {
      'p_org': orgId,
      'p_date': date.toIso8601String().substring(0, 10),
      'p_invoices': invoices,
      'p_bills': bills,
      'p_notes': notes,
    },
  )).toString();

  Future<void> voidContra(String id, String reason) async =>
      await callRpc('void_contra', params: {'p_id': id, 'p_reason': reason});
}

/// Deposits: money taken or paid before there is a document for it.
/// 0273.
extension RepoDeposits on Repo {
  Future<List<Map<String, dynamic>>> depositNotes({
    String? kind,
    String? status,
  }) async => Repo.rows(
    await callRpc(
      'deposit_notes_list',
      params: {'p_org': orgId, 'p_kind': kind, 'p_status': status},
    ),
  );

  /// What is still held for a party — the number somebody needs before
  /// raising the invoice the deposit was taken for.
  Future<List<Map<String, dynamic>>> depositsHeldFor(String contactId) async =>
      Repo.rows(
        await callRpc('deposits_held_for', params: {'p_contact': contactId}),
      );

  Future<List<Map<String, dynamic>>> depositHistory(String id) async =>
      Repo.rows(await callRpc('deposit_history', params: {'p_id': id}));

  /// One deposit note, whole.
  ///
  /// `deposit_notes_list` gives the party by name, which is enough to
  /// read a list and not enough to spend one: `apply_deposit` refuses a
  /// document belonging to anybody else and one written in another
  /// currency, so setting a deposit against an invoice needs the
  /// contact and the currency off the note itself.
  Future<Map<String, dynamic>> depositNote(String id) async =>
      Map<String, dynamic>.from(
        await client
            .from('deposit_notes')
            .select()
            .eq('id', id)
            .eq('org_id', orgId)
            .single(),
      );

  /// [kind] is 'customer' or 'supplier'.
  Future<String> createDeposit({
    required String kind,
    required String contactId,
    required DateTime date,
    required num amount,
    String? bankAccountId,
    String? mode,
    String? reference,
    String? notes,
  }) async => (await callRpcOnce(
    'create_deposit',
    params: {
      'p_org': orgId,
      'p_kind': kind,
      'p_contact': contactId,
      'p_date': date.toIso8601String().substring(0, 10),
      'p_amount': amount,
      'p_bank': bankAccountId,
      'p_mode': mode,
      'p_reference': reference,
      'p_notes': notes,
    },
  )).toString();

  Future<void> applyDeposit({
    required String depositId,
    required String documentId,
    required num amount,
  }) async => await callRpc(
    'apply_deposit',
    params: {
      'p_deposit': depositId,
      'p_document': documentId,
      'p_amount': amount,
    },
  );

  /// [kind] is 'refund' (give it back) or 'forfeit' (keep it).
  Future<void> settleDeposit({
    required String depositId,
    required String kind,
    required num amount,
    String? reason,
    String? bankAccountId,
  }) async => await callRpc(
    'settle_deposit',
    params: {
      'p_deposit': depositId,
      'p_kind': kind,
      'p_amount': amount,
      'p_reason': reason,
      'p_bank': bankAccountId,
    },
  );

  Future<void> voidDeposit(String id, String reason) async =>
      await callRpc('void_deposit', params: {'p_id': id, 'p_reason': reason});
}

/// Budgets, and the third column of a management account. 0274.
extension RepoBudgets on Repo {
  Future<List<Map<String, dynamic>>> budgets() async =>
      Repo.rows(await callRpc('budgets_list', params: {'p_org': orgId}));

  Future<List<Map<String, dynamic>>> budgetLines(String budgetId) async =>
      Repo.rows(
        await callRpc('budget_lines_for', params: {'p_budget': budgetId}),
      );

  /// Budget, actual and variance for a run of periods. [fromPeriod] and
  /// [toPeriod] are period numbers within the budget's own year, so a
  /// quarter is 1–3 rather than a date range that might cut a month in
  /// half.
  Future<List<Map<String, dynamic>>> budgetVsActual(
    String budgetId, {
    int? fromPeriod,
    int? toPeriod,
  }) async => Repo.rows(
    await callRpc(
      'report_budget_vs_actual',
      params: {
        'p_budget': budgetId,
        'p_from_period': fromPeriod,
        'p_to_period': toPeriod,
      },
    ),
  );

  Future<String> saveBudget({
    String? id,
    required String fiscalYearId,
    required String name,
    String? departmentCode,
    String? notes,
  }) async => (await callRpc(
    'upsert_budget',
    params: {
      'p_id': id,
      'p_org': orgId,
      'p_year': fiscalYearId,
      'p_name': name,
      'p_department': departmentCode,
      'p_notes': notes,
    },
  )).toString();

  /// Each entry of [lines] is `{account, period, amount}`. Sent whole
  /// and replacing what was there, the way document lines are.
  Future<void> setBudgetLines(
    String budgetId,
    List<Map<String, dynamic>> lines,
  ) async => await callRpc(
    'set_budget_lines',
    params: {'p_budget': budgetId, 'p_lines': lines},
  );

  Future<void> buildBudgetFromActual({
    required String budgetId,
    required String fromYearId,
    num upliftPercent = 0,
  }) async => await callRpc(
    'build_budget_from_actual',
    params: {
      'p_budget': budgetId,
      'p_from_year': fromYearId,
      'p_uplift_percent': upliftPercent,
    },
  );

  Future<void> approveBudget(String id) async =>
      await callRpc('approve_budget', params: {'p_id': id});

  Future<void> archiveBudget(String id) async =>
      await callRpc('archive_budget', params: {'p_id': id});
}

/// Post-dated cheques: the register, and what happens when one matures.
/// 0275.
extension RepoPdc on Repo {
  Future<List<Map<String, dynamic>>> postDatedCheques({
    String? direction,
    String? status,
  }) async => Repo.rows(
    await callRpc(
      'pdc_list',
      params: {'p_org': orgId, 'p_direction': direction, 'p_status': status},
    ),
  );

  /// What is still outstanding and matures by [to], plus anything past
  /// its date and not banked.
  Future<List<Map<String, dynamic>>> pdcMaturing({
    DateTime? from,
    DateTime? to,
  }) async => Repo.rows(
    await callRpc(
      'pdc_maturing',
      params: {
        'p_org': orgId,
        'p_from': from?.toIso8601String().substring(0, 10),
        'p_to': to?.toIso8601String().substring(0, 10),
      },
    ),
  );

  /// [direction] is 'incoming' or 'outgoing'. Each entry of [documents]
  /// is `{document, amount}`, and they must come to the cheque.
  Future<String> recordPdc({
    required String direction,
    required String contactId,
    required String chequeNo,
    required DateTime chequeDate,
    required num amount,
    List<Map<String, dynamic>> documents = const [],
    String? bankAccountId,
    String? bankName,
    DateTime? receivedOn,
    String? notes,
  }) async => (await callRpcOnce(
    'record_pdc',
    params: {
      'p_org': orgId,
      'p_direction': direction,
      'p_contact': contactId,
      'p_cheque_no': chequeNo,
      'p_cheque_date': chequeDate.toIso8601String().substring(0, 10),
      'p_amount': amount,
      'p_documents': documents,
      'p_bank': bankAccountId,
      'p_bank_name': bankName,
      'p_received': receivedOn?.toIso8601String().substring(0, 10),
      'p_notes': notes,
    },
  )).toString();

  Future<void> depositPdc(String id, {DateTime? on}) async => await callRpc(
    'deposit_pdc',
    params: {'p_id': id, 'p_on': on?.toIso8601String().substring(0, 10)},
  );

  Future<void> clearPdc(String id, {DateTime? on}) async => await callRpc(
    'clear_pdc',
    params: {'p_id': id, 'p_on': on?.toIso8601String().substring(0, 10)},
  );

  Future<void> bouncePdc(String id, String reason) async =>
      await callRpc('bounce_pdc', params: {'p_id': id, 'p_reason': reason});

  Future<void> cancelPdc(String id, String reason) async =>
      await callRpc('cancel_pdc', params: {'p_id': id, 'p_reason': reason});
}

/// The forward view of cash. 0276.
extension RepoCashFlow on Repo {
  /// Weekly buckets with a running balance, thirteen weeks by default.
  Future<List<Map<String, dynamic>>> cashForecast({
    int weeks = 13,
    bool useHistory = true,
  }) async => Repo.rows(
    await callRpc(
      'report_cash_forecast',
      params: {'p_org': orgId, 'p_weeks': weeks, 'p_use_history': useHistory},
    ),
  );

  /// The first week the balance goes below zero, or null when it does
  /// not. The single number the rest of the report is context for.
  Future<DateTime?> cashRunsOutOn({int weeks = 13}) async {
    final v = await callRpc(
      'cash_runs_out_on',
      params: {'p_org': orgId, 'p_weeks': weeks},
    );
    return v == null ? null : DateTime.tryParse('$v');
  }

  Future<List<Map<String, dynamic>>> cashForecastDetail({
    required DateTime from,
    required DateTime to,
    bool useHistory = true,
  }) async => Repo.rows(
    await callRpc(
      'cash_forecast_detail',
      params: {
        'p_org': orgId,
        'p_from': from.toIso8601String().substring(0, 10),
        'p_to': to.toIso8601String().substring(0, 10),
        'p_use_history': useHistory,
      },
    ),
  );

  /// What each customer has actually done, so somebody can see why the
  /// forecast moved an invoice and argue with it.
  Future<List<Map<String, dynamic>>> customerPaymentLags() async => Repo.rows(
    await callRpc('customer_payment_lags', params: {'p_org': orgId}),
  );

  Future<List<Map<String, dynamic>>> cashForecastItems() async => Repo.rows(
    await callRpc('cash_forecast_items_list', params: {'p_org': orgId}),
  );

  Future<String> saveCashForecastItem({
    String? id,
    required String direction,
    required String description,
    required num amount,
    required DateTime expectedOn,
    String recurrence = 'once',
    DateTime? until,
    String? notes,
  }) async => (await callRpc(
    'upsert_cash_forecast_item',
    params: {
      'p_id': id,
      'p_org': orgId,
      'p_direction': direction,
      'p_description': description,
      'p_amount': amount,
      'p_expected_on': expectedOn.toIso8601String().substring(0, 10),
      'p_recurrence': recurrence,
      'p_until': until?.toIso8601String().substring(0, 10),
      'p_notes': notes,
    },
  )).toString();

  Future<void> retireCashForecastItem(String id) async =>
      await callRpc('retire_cash_forecast_item', params: {'p_id': id});
}

/// Item bundles: an item that is six other things. 0277.
extension RepoBundles on Repo {
  Future<List<Map<String, dynamic>>> itemBundles() async =>
      Repo.rows(await callRpc('item_bundles_list', params: {'p_org': orgId}));

  /// The parts, exploded through any sub-bundles, with what each costs.
  Future<List<Map<String, dynamic>>> bundleParts(String itemId) async =>
      Repo.rows(await callRpc('item_bundle_for', params: {'p_item': itemId}));

  /// Price, cost and what that leaves — the number somebody needs
  /// before deciding what to charge for the set.
  Future<Map<String, dynamic>?> bundleMargin(String itemId) async {
    final rows = Repo.rows(
      await callRpc('bundle_margin', params: {'p_item': itemId}),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// How many can be sold out of what is on the shelf.
  Future<Map<String, dynamic>?> bundleAvailability(
    String itemId, {
    String? warehouseId,
  }) async {
    final rows = Repo.rows(
      await callRpc(
        'bundle_availability',
        params: {'p_item': itemId, 'p_warehouse': warehouseId},
      ),
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Each entry of [parts] is `{item, quantity, uom, wastage}`.
  Future<String> saveItemBundle({
    required String itemId,
    required List<Map<String, dynamic>> parts,
    String? notes,
    bool active = true,
  }) async => (await callRpc(
    'upsert_item_bundle',
    params: {
      'p_org': orgId,
      'p_item': itemId,
      'p_lines': parts,
      'p_notes': notes,
      'p_active': active,
    },
  )).toString();
}

/// Collecting from a customer, through the company's own acquirer.
///
/// Distinct from the platform's gateways, which settle
/// `platform_invoices` — iAkauntan billing its own subscribers. These
/// are the company's own credentials, and nothing here ever reads a key
/// back: `0412` holds them in a table with RLS and no policies, and the
/// only way in is the three functions below.
extension RepoTenantPayments on Repo {
  /// Which acquirers this company has set up, and whether each is ready.
  ///
  /// Never the keys. `org_payment_gateway_status` answers with
  /// `has_api_key` and `has_signature_key` and nothing that could carry
  /// a secret — `0412` asserts that on the function's own signature and
  /// `tenant_gateway_credentials.sql` asserts it on the row that comes
  /// back.
  Future<List<Map<String, dynamic>>> orgPaymentGateways() async => Repo.rows(
    await callRpc('org_payment_gateway_status', params: {'p_org_id': orgId}),
  );



  /// Saves an acquirer's credentials.
  ///
  /// A null key leaves the stored one alone, which is what makes
  /// correcting a collection id safe. Sending an empty string would be
  /// the same as sending nothing — `0412` trims and treats blank as
  /// absent — so the caller does not have to decide.
  Future<void> saveOrgPaymentGateway({
    required String gateway,
    required String mode,
    String? apiKey,
    String? collectionRef,
    String? signatureKey,
    bool? isActive,
  }) => callRpc(
    'set_org_payment_gateway',
    params: {
      'p_org_id': orgId,
      'p_gateway': gateway,
      'p_mode': mode,
      'p_api_key': apiKey,
      'p_collection_ref': collectionRef,
      'p_signature_key': signatureKey,
      'p_is_active': isActive,
    },
  );

  /// Where the takings land, and what the receipt calls them.
  Future<void> saveOrgPaymentSettlement({
    required String gateway,
    required String mode,
    String? bankAccountId,
    String? paymentModeCode,
  }) => callRpc(
    'set_org_payment_settlement',
    params: {
      'p_org_id': orgId,
      'p_gateway': gateway,
      'p_mode': mode,
      'p_bank_account': bankAccountId,
      'p_payment_mode': paymentModeCode,
    },
  );

  Future<void> clearOrgPaymentGateway({
    required String gateway,
    required String mode,
  }) => callRpc(
    'clear_org_payment_gateway',
    params: {'p_org_id': orgId, 'p_gateway': gateway, 'p_mode': mode},
  );
}

/// Bank feeds.
///
/// `0567`. The same shape as the acquirer credentials in
/// `RepoTenantPayments` and for the same reason: a bank feed credential
/// reads somebody's bank statements, so it is held in a table nothing
/// can select from and read back only as "is one set".
///
/// Its own extension rather than sitting in that one, because a feed is
/// money arriving from the bank's own records and an acquirer is money
/// arriving from a customer. They share a shape, not a subject.
extension RepoBankFeeds on Repo {
  /// What a screen may know about the feed on one account, or null
  /// where there is no feed.
  Future<Map<String, dynamic>?> bankFeedStatus(String bankAccountId) async {
    final row = await callRpc(
      'bank_feed_status',
      params: {'p_bank_account_id': bankAccountId},
    );
    return row == null ? null : Map<String, dynamic>.from(row as Map);
  }

  // `connect_bank_feed` deliberately has NO wrapper here yet.
  //
  // `0567` built it and asserted it, and no bank is connectable until
  // somebody writes a connector — so a form to call it would be a form
  // that cannot be submitted, and a wrapper for a call nobody can make
  // is exactly the dead declaration this repository spent `d9a28b8`
  // removing seven of. It goes in on the day the first connector does,
  // beside the form that uses it. The SQL is ready and waiting.

  /// Stop pulling, or start again. Keeps the credential either way.
  Future<void> setBankFeedPaused(String bankAccountId, bool paused) =>
      callRpc('set_bank_feed_paused', params: {
        'p_bank_account_id': bankAccountId,
        'p_paused': paused,
      });

  /// Remove the credential. The row and its runs stay, because what was
  /// imported and when is the company's record of where its statements
  /// came from.
  Future<void> disconnectBankFeed(String bankAccountId) =>
      callRpc('disconnect_bank_feed', params: {
        'p_bank_account_id': bankAccountId,
      });

  /// Every pull, newest first. A feed that has stopped is otherwise
  /// silent until somebody fails to reconcile.
  Future<List<Map<String, dynamic>>> bankFeedRuns(String bankAccountId) async =>
      Repo.rows(
        await client
            .from('bank_feed_runs')
            .select('id, started_at, finished_at, ok, imported, skipped, error')
            .eq('org_id', orgId)
            .order('started_at', ascending: false)
            .limit(20),
      );
}

/// What MIA's members and firms register said about a corporate officer
/// or a practice.
///
/// `0603`. Reading is an ordinary select under the table's own policy;
/// writing goes through `upsert_mia_credential`, which reads the owning
/// organization or firm OFF THE SUBJECT rather than taking it from the
/// caller.
extension RepoMia on Repo {
  /// Reading is not filtered by `org_id` here, unlike almost every
  /// other query in this file. A firm's own credential has no org: the
  /// row's owner is either an organization or a practice, and the
  /// table's read policy asks whichever applies. Adding `.eq('org_id',
  /// orgId)` would hide every firm credential from the practice that
  /// owns it.
  Future<List<MiaCredential>> miaCredentials({
    required String subjectType,
    required String subjectId,
  }) async => Repo._rows(
        await client
            .from('mia_credentials')
            .select(
              '*, verifier:profiles!mia_credentials_verified_by_fkey'
              '(full_name, email)',
            )
            .eq('subject_type', subjectType)
            .eq('subject_id', subjectId)
            .order('kind', ascending: true),
      ).map(MiaCredential.fromJson).toList();

  Future<String> saveMiaCredential({
    required String subjectType,
    required String subjectId,
    required String kind,
    required Map<String, Object> fields,
  }) async =>
      (await callRpc('upsert_mia_credential', params: {
        'p_subject_type': subjectType,
        'p_subject_id': subjectId,
        'p_kind': kind,
        'p_fields': fields,
      })).toString();

  Future<void> deleteMiaCredential(String id) async =>
      await callRpc('delete_mia_credential', params: {'p_id': id});

}

/// A company's own payment methods. 0635.
extension RepoPaymentMethods on Repo {
  /// The company's own payment methods, live ones only.
  Future<List<PaymentMethod>> paymentMethods() async {
    final data = await callRpc('payment_methods_for', params: {
      'p_org_id': orgId,
    });
    return Repo._rows(data).map(PaymentMethod.fromJson).toList();
  }

  /// Create one, or amend the one [id] names.
  ///
  /// [chargeAccountId] null is a value, not an omission: it means this
  /// method has no account of its own and the company's is used. The
  /// database resolves that at posting time, so a screen does not have
  /// to know what the fallback is.
  Future<String> savePaymentMethod({
    required String name,
    String? id,
    String? paymentModeCode,
    String? bankAccountId,
    String? chargeAccountId,
    double chargePercent = 0,
    double chargeFixed = 0,
    bool isDefault = false,
    bool isActive = true,
    int sortOrder = 0,
    String? notes,
  }) async =>
      (await callRpc('save_payment_method', params: {
        'p_org_id': orgId,
        'p_name': name,
        'p_id': id,
        'p_payment_mode_code': paymentModeCode,
        'p_bank_account_id': bankAccountId,
        'p_charge_account_id': chargeAccountId,
        'p_charge_percent': chargePercent,
        'p_charge_fixed': chargeFixed,
        'p_is_default': isDefault,
        'p_is_active': isActive,
        'p_sort_order': sortOrder,
        'p_notes': notes,
      })).toString();

  /// Retire one. Soft, because receipts already name it.
  Future<void> archivePaymentMethod(String id) async =>
      await callRpc('archive_payment_method', params: {'p_id': id});

  /// What this method's stated rate comes to on [amount].
  ///
  /// Asked of the database rather than computed here, so the rule lives
  /// in one place. It is a suggestion for the screen: posting uses what
  /// the document says, never this.
  Future<double> suggestedCharge(String methodId, double amount) async =>
      Fmt.toDouble(await callRpc('suggested_charge', params: {
        'p_payment_method_id': methodId,
        'p_amount': amount,
      }));
}

/// A company's own report layouts. 0637.
extension RepoReportLayouts on Repo {
  // -------------------------------------------------------------------
  // Report layouts (0637)
  // -------------------------------------------------------------------

  /// A P&L or Balance Sheet, composed by the database from this
  /// company's layout.
  ///
  /// The rows come back already totalled — one per section, formula and
  /// account. Nothing on this side adds anything up, because the
  /// arithmetic on a document somebody signs belongs in one place.
  Future<List<Map<String, dynamic>>> reportWithLayout({
    required String kind,
    DateTime? from,
    DateTime? to,
    String? layoutId,
    String? projectCode,
    String? departmentCode,
  }) async {
    final data = await callRpc('report_with_layout', params: {
      'p_org_id': orgId,
      'p_kind': kind,
      'p_from': from == null ? null : Fmt.iso(from),
      'p_to': to == null ? null : Fmt.iso(to),
      'p_layout_id': layoutId,
      'p_project_code': projectCode,
      'p_department_code': departmentCode,
    });
    return Repo._rows(data);
  }

  /// This company's layouts for one report, the active one first.
  Future<List<ReportLayout>> reportLayouts(String kind) async {
    final data = await callRpc('report_layouts_for', params: {
      'p_org_id': orgId,
      'p_kind': kind,
    });
    return Repo._rows(data).map(ReportLayout.fromJson).toList();
  }

  /// One layout's rows, in order, for the builder.
  Future<List<LayoutRow>> layoutRows(String layoutId) async {
    final data = await callRpc('layout_rows', params: {
      'p_layout_id': layoutId,
    });
    return Repo._rows(data).map(LayoutRow.fromJson).toList();
  }

  /// Copy the standard layout into an editable one and make it active.
  Future<String> createLayoutFromBuiltin(String kind, {String? name}) async =>
      (await callRpc('create_layout_from_builtin', params: {
        'p_org_id': orgId,
        'p_kind': kind,
        'p_name': name,
      })).toString();

  /// Replace a layout's rows in one go.
  ///
  /// All of them, because rows refer to each other by key and applying
  /// a builder's changes one at a time would pass through states where
  /// a formula points at a row that has not arrived.
  Future<void> saveLayoutRows(String layoutId, List<LayoutRow> rows) async =>
      await callRpc('save_layout_rows', params: {
        'p_layout_id': layoutId,
        'p_rows': [for (final r in rows) r.toJson()],
      });

  Future<void> activateReportLayout(String id) async =>
      await callRpc('activate_report_layout', params: {'p_layout_id': id});

  Future<void> archiveReportLayout(String id) async =>
      await callRpc('archive_report_layout', params: {'p_layout_id': id});
}
