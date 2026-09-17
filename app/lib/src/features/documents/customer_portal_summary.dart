import '../../core/format.dart';

/// What a customer sees when they open their own account.
///
/// 0067 gives them a link to one invoice; 0493 gives them a link to all
/// of them. The words are here rather than in the page for the same
/// reason `subscription_summary.dart` keeps its own: these are sentences
/// about money owed to somebody, read by a person with no account and no
/// support channel except replying to the email, and a sentence
/// assembled inside a `build` method among the padding is a sentence
/// nobody can assert.

/// One invoice on the account, as `open_customer_portal` reports it.
class PortalInvoice {
  const PortalInvoice({
    required this.id,
    required this.docNo,
    required this.balance,
    required this.total,
    required this.overdue,
    this.dueDate,
    this.docDate,
  });

  factory PortalInvoice.fromMap(Map<String, dynamic> m) => PortalInvoice(
    id: m['id']?.toString() ?? '',
    docNo: m['doc_no']?.toString() ?? '',
    balance: Fmt.toDouble(m['balance_amount']),
    total: Fmt.toDouble(m['total_amount']),
    // Decided by the server against Malaysian time, not by the device.
    // A phone in another time zone must not tell somebody they are late
    // when they are not.
    overdue: m['overdue'] == true,
    dueDate: Fmt.parseDate(m['due_date']),
    docDate: Fmt.parseDate(m['doc_date']),
  );

  final String id;
  final String docNo;
  final double balance;
  final double total;
  final bool overdue;
  final DateTime? dueDate;
  final DateTime? docDate;

  /// True where part of it has already been paid, which is the only
  /// case in which showing the total as well as the balance helps.
  bool get partlyPaid => total > balance && balance > 0;
}

/// The account behind one portal token.
class PortalAccount {
  const PortalAccount({
    required this.state,
    required this.companyName,
    required this.contactName,
    required this.currency,
    required this.outstanding,
    required this.invoices,
    this.logoUrl,
    this.companyEmail,
    this.companyPhone,
  });

  factory PortalAccount.fromMap(Map<String, dynamic> m) {
    final company = Map<String, dynamic>.from(m['company'] as Map? ?? {});
    final contact = Map<String, dynamic>.from(m['contact'] as Map? ?? {});
    return PortalAccount(
      state: m['state']?.toString() ?? 'invalid',
      companyName: company['name']?.toString() ?? '',
      contactName: contact['name']?.toString() ?? '',
      currency: m['currency']?.toString() ?? 'MYR',
      outstanding: Fmt.toDouble(m['total_outstanding']),
      invoices: [
        for (final i in (m['invoices'] as List? ?? const []))
          PortalInvoice.fromMap(Map<String, dynamic>.from(i as Map)),
      ],
      logoUrl: company['logo_url']?.toString(),
      companyEmail: company['email']?.toString(),
      companyPhone: company['phone']?.toString(),
    );
  }

  final String state;
  final String companyName;
  final String contactName;
  final String currency;
  final double outstanding;
  final List<PortalInvoice> invoices;
  final String? logoUrl;
  final String? companyEmail;
  final String? companyPhone;

  bool get isOpen => state == 'open';
  bool get owesNothing => invoices.isEmpty;
}

/// The figure at the top.
///
/// A customer who owes nothing is told so in words. "RM 0.00" beside
/// "outstanding" reads like a system that has lost their payments.
String portalOutstandingLine(PortalAccount a) => a.owesNothing
    ? 'Nothing outstanding'
    : Fmt.money(a.outstanding, currency: a.currency);

/// And the sentence under it.
String portalSummaryLine(PortalAccount a) {
  if (a.owesNothing) {
    return 'Your account with ${a.companyName} is settled. Thank you.';
  }
  final n = a.invoices.length;
  final overdue = a.invoices.where((i) => i.overdue).length;
  final invoices = n == 1 ? '1 invoice' : '$n invoices';
  if (overdue == 0) {
    return '$invoices outstanding with ${a.companyName}.';
  }
  // Named rather than implied. Somebody who is late usually knows, and
  // being told plainly is less annoying than being made to work it out
  // from a row of dates.
  final late = overdue == n
      ? 'all of them past due'
      : '$overdue of them past due';
  return '$invoices outstanding with ${a.companyName}, $late.';
}

/// One row.
String portalInvoiceLine(PortalInvoice i) {
  if (i.dueDate == null) return i.docNo;
  return i.overdue
      ? '${i.docNo} · was due ${Fmt.date(i.dueDate)}'
      : '${i.docNo} · due ${Fmt.date(i.dueDate)}';
}

/// What is said beside the amount when part of it is already paid, so
/// the figure shown is not mistaken for the whole invoice.
String? portalPartPaidNote(PortalInvoice i) =>
    i.partlyPaid ? 'of ${Fmt.money(i.total)}' : null;

/// Every unhappy state says the same thing in different words: ask the
/// company. Naming which of them it is helps the customer say something
/// useful when they do — and these are the words of a stranger's system
/// talking to somebody about money, so none of them blames the reader.
({String title, String body}) portalStateMessage(String state) =>
    switch (state) {
      'expired' => (
        title: 'This link has expired',
        body: 'Ask the company that sent it for a new one.',
      ),
      'revoked' => (
        title: 'This link is no longer in use',
        body: 'A newer link may have replaced it. Ask the company that '
            'sent it.',
      ),
      'withdrawn' => (
        title: 'This account is no longer open',
        body: 'Ask the company that sent the link.',
      ),
      _ => (
        title: 'We cannot find this account',
        body: 'Check the link is complete, or ask the company that sent it.',
      ),
    };

// ---------------------------------------------------------------------
// The other end of it
// ---------------------------------------------------------------------
// Everything above is read by the customer. What follows is read by the
// company deciding whether to give them a link — a different person
// with a different question, kept in the same file because it is the
// same feature and the two sets of words have to agree about what a
// portal is.

/// A portal link as the company sees it, from `customer_portal_links`.
class PortalLinkState {
  const PortalLinkState({
    required this.live,
    this.expiresAt,
    this.lastOpenedAt,
    this.openCount = 0,
    this.sentTo,
  });

  /// The live one, if there is one. Revoked and expired rows are still
  /// in the table and are deliberately not it.
  factory PortalLinkState.fromRows(List<Map<String, dynamic>> rows) {
    final now = DateTime.now();
    for (final r in rows) {
      if (r['revoked_at'] != null) continue;
      final expires = Fmt.parseDate(r['expires_at']);
      if (expires != null && expires.isBefore(now)) continue;
      return PortalLinkState(
        live: true,
        expiresAt: expires,
        lastOpenedAt: Fmt.parseDate(r['last_opened_at']),
        openCount: (r['open_count'] as num?)?.toInt() ?? 0,
        sentTo: r['sent_to_email']?.toString(),
      );
    }
    return const PortalLinkState(live: false);
  }

  final bool live;
  final DateTime? expiresAt;
  final DateTime? lastOpenedAt;
  final int openCount;
  final String? sentTo;
}

/// What the company is told about the link it has given out.
///
/// Whether the customer has actually opened it is the useful part: a
/// link sent and never opened is a conversation that has not happened,
/// and knowing that is the difference between chasing and waiting.
String portalLinkStatusLine(PortalLinkState s) {
  if (!s.live) {
    return 'No link is open. One can be sent to the address on this '
        'contact.';
  }
  final until = s.expiresAt == null ? '' : ' until ${Fmt.date(s.expiresAt)}';
  if (s.openCount == 0) {
    return 'A link is open$until, and has not been opened yet.';
  }
  final opened = s.lastOpenedAt == null
      ? 'opened'
      : 'last opened ${Fmt.date(s.lastOpenedAt)}';
  return 'A link is open$until, $opened.';
}

/// The confirmation before issuing one.
///
/// It says the two things a person should think about before pressing
/// it: this shows the customer everything they owe, and it replaces any
/// link already out there.
String portalIssuePrompt({required bool replacing, String? sendingTo}) {
  final to = (sendingTo ?? '').isEmpty
      ? 'There is no address on this contact, so the link will be shown '
            'here for you to pass on.'
      : 'It will be emailed to $sendingTo.';
  final replaced = replacing
      ? ' Any link already open for this customer stops working.'
      : '';
  return 'They will see every invoice still outstanding on their account, '
      'and be able to pay any of it. $to$replaced';
}
