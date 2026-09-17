import '../../core/format.dart';

/// What a customer sees when they are asked for their own tax details.
///
/// 0626. From this year an e-Invoice will not clear MyInvois without the
/// buyer's TIN and the identification number it was issued against, and
/// the only person who has them is the buyer. The sibling of
/// `customer_portal_summary.dart` and here for its reason: these are
/// sentences read by a person with no account and no support channel
/// except replying to the email, and a sentence assembled inside a
/// `build` method among the padding is a sentence nobody can assert.

/// The fields this form asks about, in the order it asks about them.
///
/// One list, used by the form, by the review card and by the labels
/// below, so a field added to one cannot go missing from another. It is
/// the same list `app.tax_submission_apply` walks, and that is not a
/// coincidence worth breaking.
const taxDetailFields = <String>[
  'tin',
  'id_type',
  'id_value',
  'sst_registration_no',
  'email',
  'phone',
  'address_line1',
  'address_line2',
  'address_line3',
  'postcode',
  'city',
  'state_code',
  'country_code',
];

/// What to call a field when telling somebody it disagrees.
///
/// `sst_registration_no` reaching a screen is the same failure as a
/// check constraint name reaching one: true, and not a sentence anybody
/// can act on.
String taxFieldLabel(String key) => switch (key) {
  'tin' => 'TIN',
  'id_type' => 'ID type',
  'id_value' => 'ID number',
  'sst_registration_no' => 'SST number',
  'email' => 'Email',
  'phone' => 'Phone',
  'address_line1' => 'Address line 1',
  'address_line2' => 'Address line 2',
  'address_line3' => 'Address line 3',
  'postcode' => 'Postcode',
  'city' => 'Town or city',
  'state_code' => 'State',
  'country_code' => 'Country',
  _ => key,
};

/// What `open_tax_detail_request` answered: who is asking, and what
/// they already hold.
class TaxDetailsInvite {
  const TaxDetailsInvite({
    required this.state,
    required this.companyName,
    required this.contactName,
    required this.held,
    this.logoUrl,
    this.companyEmail,
    this.tinVerified = false,
    this.alreadySubmitted = false,
  });

  factory TaxDetailsInvite.fromMap(Map<String, dynamic> m) {
    final company = Map<String, dynamic>.from(m['company'] as Map? ?? {});
    final contact = Map<String, dynamic>.from(m['contact'] as Map? ?? {});
    return TaxDetailsInvite(
      state: m['state']?.toString() ?? 'invalid',
      companyName: company['name']?.toString() ?? '',
      contactName: contact['name']?.toString() ?? '',
      logoUrl: company['logo_url']?.toString(),
      companyEmail: company['email']?.toString(),
      tinVerified: contact['is_tin_verified'] == true,
      alreadySubmitted: m['already_submitted'] == true,
      held: {
        for (final f in taxDetailFields)
          f: (contact[f]?.toString() ?? '').trim(),
      },
    );
  }

  final String state;
  final String companyName;
  final String contactName;
  final String? logoUrl;
  final String? companyEmail;
  final bool tinVerified;
  final bool alreadySubmitted;

  /// What the company holds today, keyed by [taxDetailFields]. Shown in
  /// the form so the customer corrects rather than retypes — a blank
  /// form produces a conflict for every field typed differently, and a
  /// conflict is the case that needs a human.
  final Map<String, String> held;

  bool get isOpen => state == 'open';
}

/// Every unhappy state says the same thing in different words: ask the
/// company that sent it. Naming which of them it is helps the customer
/// say something useful when they do.
({String title, String body}) taxDetailsStateMessage(String state) =>
    switch (state) {
      'expired' => (
        title: 'This link has expired',
        body: 'Links are open for a limited time. Reply to the email you '
            'were sent and they will send another.',
      ),
      'revoked' => (
        title: 'This link has been replaced',
        body: 'A newer link was sent for the same company. Look for the '
            'most recent email, or reply to it and ask for another.',
      ),
      'withdrawn' => (
        title: 'This link is no longer in use',
        body: 'The company that sent it has closed the record this link '
            'was for. Reply to their email if you think that is wrong.',
      ),
      _ => (
        title: 'This link does not open anything',
        body: 'It may have been copied incompletely. Try the link in the '
            'email again, or reply to it and ask for another.',
      ),
    };

/// Why the form cannot be sent yet, or null when it can.
///
/// Reported in the order the FORM asks, so somebody is never told about
/// a field below the one they are looking at.
String? taxDetailsProblem({
  required String tin,
  required String idValue,
  required Map<String, String> held,
}) {
  final hasTin = tin.trim().isNotEmpty;
  final hasId = idValue.trim().isNotEmpty;

  // The pair, not either one. LHDN validates a TIN *against* an
  // identification number, so a TIN with nothing to match it against
  // fails at submission and the customer hears about it months later
  // through an invoice that was rejected.
  if (hasTin && !hasId) {
    return 'LHDN checks a TIN against the registration or identification '
        'number it was issued to. Please give both.';
  }
  if (hasId && !hasTin) {
    return 'Please give the TIN as well as the registration or '
        'identification number.';
  }

  // Nothing at all. The database refuses this with a check constraint,
  // and a constraint name is not a sentence anybody can act on.
  //
  // `id_type` is deliberately not counted. It is a dropdown with a
  // default, so it is never empty, and counting it would make an
  // untouched form look like an answer — which is exactly what it did
  // when this was first written, and the Send button on an empty form
  // went live.
  final anything = taxDetailFields.any(
    (f) => f != 'id_type' && (held[f] ?? '').trim().isNotEmpty,
  );
  if (!hasTin && !anything) {
    return 'There is nothing to send yet. Please fill in at least your '
        'TIN and the number it was issued against.';
  }
  return null;
}

/// What the form says once it has been sent.
///
/// The two outcomes are genuinely different and saying "thank you" to
/// both would be a lie in one of them: a customer whose correction is
/// waiting for somebody has not finished, and telling them they have
/// means they will not chase it.
String taxDetailsThanks({
  required String companyName,
  required bool awaitingReview,
}) {
  if (awaitingReview) {
    return 'Thank you. Some of what you sent differs from what '
        '$companyName already has on file, so somebody there will look '
        'at it before it is changed. Nothing else is needed from you.';
  }
  return 'Thank you. $companyName now has what they need to issue you '
      'e-Invoices. Nothing else is needed from you.';
}

/// The tax-details links issued to one contact — whether one is live,
/// and whether they have opened it. The same shape as
/// `PortalLinkState`, deliberately: it is the same mechanism.
class TaxDetailLinkState {
  const TaxDetailLinkState({
    required this.live,
    this.expiresAt,
    this.lastOpenedAt,
    this.openCount = 0,
    this.submissionCount = 0,
    this.sentTo,
  });

  factory TaxDetailLinkState.fromRows(List<Map<String, dynamic>> rows) {
    final now = DateTime.now();
    for (final r in rows) {
      if (r['revoked_at'] != null) continue;
      final expires = Fmt.parseDate(r['expires_at']);
      if (expires != null && expires.isBefore(now)) continue;
      return TaxDetailLinkState(
        live: true,
        expiresAt: expires,
        lastOpenedAt: Fmt.parseDate(r['last_opened_at']),
        openCount: (r['open_count'] as num?)?.toInt() ?? 0,
        submissionCount: (r['submission_count'] as num?)?.toInt() ?? 0,
        sentTo: r['sent_to_email']?.toString(),
      );
    }
    return const TaxDetailLinkState(live: false);
  }

  final bool live;
  final DateTime? expiresAt;
  final DateTime? lastOpenedAt;
  final int openCount;
  final int submissionCount;
  final String? sentTo;
}

/// Where the link has got to, in one line.
///
/// "Opened but not answered" is called out on purpose. It is the state
/// worth chasing — somebody read the email, went to the page, and
/// stopped — and it is invisible if the line only says whether a link
/// is open.
String taxDetailsLinkStatusLine(TaxDetailLinkState s) {
  if (!s.live) {
    return 'No link is open. One can be sent to the address on this '
        'contact.';
  }
  final until = s.expiresAt == null ? '' : ' until ${Fmt.date(s.expiresAt)}';
  if (s.submissionCount > 0) {
    return 'A link is open$until, and they have answered it.';
  }
  if (s.openCount == 0) {
    return 'A link is open$until, and has not been opened yet.';
  }
  final opened = s.lastOpenedAt == null
      ? 'opened'
      : 'last opened ${Fmt.date(s.lastOpenedAt)}';
  return 'A link is open$until, $opened, and not answered yet.';
}

/// The confirmation before issuing one.
///
/// It says the two things a person should think about: what the
/// customer will be shown, and that this replaces any link already out
/// there. Unlike the portal prompt it also says what the page is NOT,
/// because "we sent your customer a link" reads alarming until you know
/// there is no money on it.
String taxDetailsIssuePrompt({required bool replacing, String? sendingTo}) {
  final to = (sendingTo ?? '').isEmpty
      ? 'There is no address on this contact, so the link will be shown '
            'here for you to pass on.'
      : 'It will be emailed to $sendingTo.';
  final replaced = replacing
      ? ' Any link already open for this contact stops working.'
      : '';
  return 'They will see the name, address and tax numbers you hold for '
      'them, and be able to correct them. Nothing about their account or '
      'any amount owing is on that page. $to$replaced';
}

/// One thing a customer said that disagrees with what is on file.
class TaxConflict {
  const TaxConflict({
    required this.field,
    required this.theirs,
    required this.ours,
  });

  factory TaxConflict.fromMap(Map<String, dynamic> m) => TaxConflict(
    field: m['field']?.toString() ?? '',
    theirs: m['theirs']?.toString() ?? '',
    ours: m['ours']?.toString() ?? '',
  );

  final String field;
  final String theirs;
  final String ours;
}

/// One submission waiting for somebody to decide about it.
class TaxSubmission {
  const TaxSubmission({
    required this.id,
    required this.contactId,
    required this.contactName,
    required this.conflicts,
    this.submittedAt,
    this.byName,
    this.byEmail,
    this.appliedFields = const [],
  });

  factory TaxSubmission.fromMap(Map<String, dynamic> m) => TaxSubmission(
    id: m['submission_id']?.toString() ?? '',
    contactId: m['contact_id']?.toString() ?? '',
    contactName: m['contact_name']?.toString() ?? '',
    submittedAt: Fmt.parseDate(m['submitted_at']),
    byName: m['submitted_by_name']?.toString(),
    byEmail: m['submitted_by_email']?.toString(),
    appliedFields: [
      for (final f in (m['applied_fields'] as List? ?? const []))
        f.toString(),
    ],
    conflicts: [
      for (final c in (m['conflicts'] as List? ?? const []))
        TaxConflict.fromMap(Map<String, dynamic>.from(c as Map)),
    ],
  );

  final String id;
  final String contactId;
  final String contactName;
  final DateTime? submittedAt;
  final String? byName;
  final String? byEmail;
  final List<String> appliedFields;
  final List<TaxConflict> conflicts;
}

/// Who said it and when, for the heading of a waiting submission.
String taxSubmissionWho(TaxSubmission s) {
  final when = s.submittedAt == null ? '' : ' on ${Fmt.date(s.submittedAt)}';
  final who = (s.byName ?? '').trim().isNotEmpty
      ? s.byName!.trim()
      : ((s.byEmail ?? '').trim().isNotEmpty
            ? s.byEmail!.trim()
            : 'Somebody at ${s.contactName}');
  return '$who$when';
}

/// One disagreement, in a line somebody can decide about.
///
/// Both sides, always. "They say C1234567890" is not answerable without
/// "you hold C9999999999", and a screen that shows only the new value
/// is a screen that gets accepted without being read.
String taxConflictLine(TaxConflict c) =>
    '${taxFieldLabel(c.field)}: they say “${c.theirs}”, '
    'you hold “${c.ours}”';

/// What the submission already changed without asking, if anything.
///
/// Said out loud rather than left implicit: somebody looking at a list
/// of disagreements should know that three other fields were filled in
/// from the same form, because that is a change to their master data
/// that nobody approved and they are entitled to see it.
String? taxAppliedNote(TaxSubmission s) {
  if (s.appliedFields.isEmpty) return null;
  final names = [
    for (final f in taxDetailFields)
      if (s.appliedFields.contains(f)) taxFieldLabel(f),
  ];
  if (names.length == 1) {
    return '${names.first} was blank and has been filled in from this '
        'form.';
  }
  return '${names.take(names.length - 1).join(', ')} and ${names.last} '
      'were blank and have been filled in from this form.';
}
