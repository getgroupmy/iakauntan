/// A MyInvois document a supplier sent US, and what can be done with it.
///
/// The inbound half of e-Invoice. `einvoice_*` is entirely outbound —
/// seven tables and a submitter — and until `0650` nothing in this
/// product had ever kept one that arrived.
///
/// Everything here is a pure function over a row, and that is the point:
/// this file can be asserted without a database, a phone or a screen,
/// and `received_einvoices_screen.dart` is left with nothing but layout.
///
/// ## The refusals are stated twice on purpose
///
/// [draftBillProblem] repeats rules that `0650` already enforces —
/// there must be a supplier, the currency has to be one we know, and a
/// refund note has no purchase document to become. That is not a rule
/// enforced in Dart; the database is still the one refusing. It is the
/// same rule said EARLY, so that a button which cannot work is drawn
/// disabled with the reason beside it rather than as a button that
/// answers with an exception.
///
/// The two must not drift, so each sentence here names the same
/// condition as the SQL and `received_einvoice_test.dart` asserts the
/// wording against the type codes `0650` actually maps.
library;

/// The MyInvois document types that become a purchase document.
///
/// `01` invoice, `02` credit note, `03` debit note — the three a
/// SUPPLIER sends. `04` is a refund note and `11`–`14` are self-billed,
/// which this company issues rather than receives; neither has a
/// purchase document to become, and guessing one would post the wrong
/// sign. `0650` refuses them by the same list.
const receivedBillableTypes = <String, String>{
  '01': 'bill',
  '02': 'purchase_credit_note',
  '03': 'purchase_debit_note',
};

/// What each MyInvois type code is called on screen.
const receivedTypeLabels = <String, String>{
  '01': 'Invoice',
  '02': 'Credit note',
  '03': 'Debit note',
  '04': 'Refund note',
  '11': 'Self-billed invoice',
  '12': 'Self-billed credit note',
  '13': 'Self-billed debit note',
  '14': 'Self-billed refund note',
};

/// One document as it arrived.
class ReceivedEinvoice {
  /// Constructs one from named fields.
  const ReceivedEinvoice({
    required this.id,
    required this.status,
    this.docNo,
    this.issueDate,
    this.typeCode,
    this.currency,
    this.supplierName,
    this.supplierTin,
    this.payableAmount = 0,
    this.totalTax = 0,
    this.contactId,
    this.contactName,
    this.billId,
    this.myinvoisUuid,
    this.problems = const [],
    this.lineCount = 0,
  });

  /// Reads one out of a PostgREST row.
  ///
  /// Every field is optional because every field of the row is: the
  /// document was written by somebody else's system, and `0650` stores
  /// what could be read rather than refusing what could not.
  factory ReceivedEinvoice.fromJson(Map<String, dynamic> row) {
    final contact = row['contacts'];
    return ReceivedEinvoice(
      id: '${row['id']}',
      status: '${row['status'] ?? 'received'}',
      docNo: _text(row['doc_no']),
      issueDate: _date(row['issue_date']),
      typeCode: _text(row['type_code']),
      currency: _text(row['currency']),
      supplierName: _text(row['supplier_name']),
      supplierTin: _text(row['supplier_tin']),
      payableAmount: _number(row['payable_amount']),
      totalTax: _number(row['total_tax']),
      contactId: _text(row['contact_id']),
      contactName: contact is Map ? _text(contact['name']) : null,
      billId: _text(row['bill_id']),
      myinvoisUuid: _text(row['myinvois_uuid']),
      problems: row['problems'] is List
          ? [for (final p in row['problems'] as List) '$p']
          : const [],
      lineCount: _count(row['received_einvoice_lines']),
    );
  }

  final String id;
  final String status;
  final String? docNo;
  final DateTime? issueDate;
  final String? typeCode;
  final String? currency;
  final String? supplierName;
  final String? supplierTin;
  final double payableAmount;
  final double totalTax;
  final String? contactId;
  final String? contactName;
  final String? billId;
  final String? myinvoisUuid;

  /// What the parser could not make sense of, in its own words.
  ///
  /// An empty list is not a promise that the figures are right — only
  /// that nothing structural was missing.
  final List<String> problems;

  final int lineCount;

  /// Whether a bill has already been drafted from this.
  bool get isBilled => billId != null;
}

String? _text(Object? v) {
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

/// A date out of a row, or null.
///
/// Null is an ordinary answer here and not a fault: `0650` stores a
/// null `issue_date` for a document whose date the producer mangled,
/// because losing the document over a bad date field would be worse
/// than showing one with no date on it.
DateTime? _date(Object? v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  return DateTime.tryParse('$v');
}

double _number(Object? v) => switch (v) {
  num n => n.toDouble(),
  String s => double.tryParse(s) ?? 0,
  _ => 0,
};

/// The count out of a PostgREST aggregate embed.
///
/// `received_einvoice_lines(count)` comes back as a list holding one
/// object, and a list of the rows themselves when the embed asked for
/// them instead. Both are counted, because a screen that asked for the
/// lines should not have to ask again for how many there are.
int _count(Object? v) {
  if (v is! List) return 0;
  if (v.length == 1 && v.first is Map && (v.first as Map).containsKey('count')) {
    final c = (v.first as Map)['count'];
    return c is num ? c.toInt() : 0;
  }
  return v.length;
}

/// What this document is called on screen.
String receivedTypeLabel(String? code) =>
    receivedTypeLabels[code] ?? (code == null ? 'Document' : 'Type $code');

/// The status, as somebody reading the list would say it.
String receivedStatusLabel(String status) => switch (status) {
  'received' => 'Received',
  'billed' => 'Billed',
  'ignored' => 'Ignored',
  _ => status,
};

/// Why a bill cannot be drafted from this document yet, or null.
///
/// The same conditions `0650` refuses on, said before the round trip so
/// the button can be disabled with the reason beside it. See the
/// library comment: the database is still the one enforcing them.
///
/// [knownCurrencies] is what this company has on file. Passing null
/// means "not loaded yet", and the currency is then NOT complained
/// about — a screen that has not finished loading must not accuse a
/// perfectly ordinary document of naming an unknown currency.
String? draftBillProblem(
  ReceivedEinvoice doc, {
  Set<String>? knownCurrencies,
}) {
  if (doc.isBilled) {
    return 'A bill has already been drafted from this document.';
  }
  if (doc.status == 'ignored') {
    return 'This document was set aside. Move it back to Received first.';
  }
  if (doc.contactId == null) {
    return 'Link a supplier to this document first.';
  }
  final type = doc.typeCode;
  if (type == null || !receivedBillableTypes.containsKey(type)) {
    return '${receivedTypeLabel(type)} has no purchase document to '
        'become. Only an invoice, a credit note or a debit note does.';
  }
  final currency = doc.currency;
  if (currency == null) {
    return 'The document does not say what currency it is in.';
  }
  if (knownCurrencies != null && !knownCurrencies.contains(currency)) {
    return '$currency is not a currency this company has set up.';
  }
  return null;
}

/// What the drafted document would be called.
String draftBillKindLabel(String? typeCode) =>
    switch (receivedBillableTypes[typeCode]) {
      'bill' => 'bill',
      'purchase_credit_note' => 'purchase credit note',
      'purchase_debit_note' => 'purchase debit note',
      _ => 'purchase document',
    };

/// The one line under a document in the list.
///
/// The supplier and what is owed, because those are what somebody
/// scanning the list is looking for — and the document number, because
/// that is what they will be asked for on the telephone.
String receivedSummaryLine(ReceivedEinvoice doc) {
  final parts = <String>[
    doc.supplierName ?? 'Supplier not named',
    if (doc.docNo != null) doc.docNo!,
  ];
  return parts.join(' · ');
}

/// Whether this document is worth a warning in the list.
///
/// Problems from the parser, or a supplier nobody has linked yet.
/// Being unbilled is NOT a warning: that is the ordinary state of
/// everything that has just arrived.
bool receivedNeedsAttention(ReceivedEinvoice doc) =>
    doc.status == 'received' &&
    (doc.problems.isNotEmpty || doc.contactId == null);

/// What to say when a supplier has not been matched.
///
/// `0650` matches by TIN and by registration number and deliberately
/// never by name, because "Pembekal Jaya" and "Pembekal Jaya Sdn Bhd"
/// are two rows in most contact lists. So the screen has to offer the
/// choice, and this is the sentence that asks for it — including the
/// TIN, which is the thing somebody will search their contact list for.
String supplierPrompt(ReceivedEinvoice doc) {
  if (doc.contactId != null) return doc.contactName ?? 'Supplier linked';
  final tin = doc.supplierTin;
  if (tin == null) {
    return 'No supplier on file matches this document, and it carries no '
        'TIN to match on.';
  }
  return 'No supplier on file carries TIN $tin. Pick one, or create it '
      'from what the document says.';
}

/// Whether the import answered with a document that is already here.
///
/// `record_received_einvoice` is idempotent on a hash of the raw
/// document, so importing the same file twice returns the FIRST row
/// rather than raising. That is the right behaviour and the wrong
/// silence: somebody who has just pressed import needs to be told that
/// nothing new arrived, or they will press it again.
String importOutcome(Map<String, dynamic> result) {
  final duplicate = result['duplicate'] == true;
  final docNo = _text(result['docNo']);
  final supplier = _text(result['supplierName']);
  final named = [
    if (supplier != null) supplier,
    if (docNo != null) docNo,
  ].join(' ');

  if (duplicate) {
    return named.isEmpty
        ? 'That document is already here — nothing new was imported.'
        : 'That document is already here: $named. Nothing new was imported.';
  }
  return named.isEmpty ? 'Document imported.' : 'Imported $named.';
}

/// Everything the import wants to warn about, in the order it matters.
///
/// Three different questions, and they are not the same one:
///
///   * addressed to somebody else — the document is not ours at all;
///   * the totals do not agree — it is ours and it does not add up;
///   * the parser's own problems — parts of it could not be read.
///
/// The first is the most serious and comes first, because it changes
/// what the other two mean.
List<String> importWarnings(Map<String, dynamic> result) {
  final out = <String>[];
  final addressed = _text(result['addressedTo']);
  if (addressed != null) {
    out.add(
      'This document is addressed to $addressed, not to this company. '
      'It has been kept so you can see it, but check before paying it.',
    );
  }
  final totals = _text(result['totalsProblem']);
  if (totals != null) out.add(totals);
  final problems = result['problems'];
  if (problems is List) {
    for (final p in problems) {
      final s = _text(p);
      if (s != null) out.add(s);
    }
  }
  return out;
}
