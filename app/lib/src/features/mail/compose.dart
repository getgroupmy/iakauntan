/// The words a compose box puts on the screen, and the checks it makes
/// before anything is queued.
///
/// Separated from the dialog because all of it is decidable without a
/// widget: whether an address can be sent to, what a reply's subject
/// is, and what the quoted original looks like underneath it. A dialog
/// cannot be asserted about; these can.
library;

/// Whether this could be an address, in the same terms the database
/// uses.
///
/// Deliberately loose, and deliberately the same looseness as
/// `send_from_mailbox`: address syntax is far wider than anything worth
/// writing here, and the provider refuses what it refuses. What this
/// catches is the empty box and the name typed without a domain —
/// before somebody is told their message was sent.
///
/// The two checks are not one check. A rule that only ever said "that
/// is not an email address" would say it about an empty box too, which
/// reads as a rejection of something the person has not typed yet.
String? checkRecipient(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return 'Who is this going to?';
  final ok = RegExp(r'^[^@\s,]+@[^@\s,]+\.[^@\s,]+$').hasMatch(value);
  return ok ? null : 'That is not an email address we can send to.';
}

/// The subject a reply carries.
///
/// "Re:" once. A thread five replies deep whose subject reads
/// "Re: Re: Re: Re: Re: About your invoice" is a mail client nobody
/// wants to have written, and the prefix is matched without regard to
/// case because the one that came back from somebody else's client may
/// be "RE:".
String replySubject(String? original) {
  final subject = (original ?? '').trim();
  if (subject.isEmpty) return 'Re: (no subject)';
  if (RegExp(r'^re\s*:', caseSensitive: false).hasMatch(subject)) {
    return subject;
  }
  return 'Re: $subject';
}

/// The original, quoted under the empty space the reply goes in.
///
/// Plain text with `>` in front of each line, which is what mail has
/// done since before any of this existed and what every client still
/// renders as a quote. The blank lines at the top are where the cursor
/// lands: a reply box whose first character sits against the quoted
/// text is one people delete their way out of.
String quotedReply({
  required String from,
  String? body,
  DateTime? at,
}) {
  final when = at == null ? '' : ' on ${_day(at)}';
  final lines = (body ?? '').trimRight().split('\n');
  final quoted = [
    for (final line in lines) line.isEmpty ? '>' : '> $line',
  ].join('\n');
  return '\n\n$from wrote$when:\n$quoted\n';
}

String _day(DateTime at) {
  final d = at.toLocal();
  return '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}

/// The whole address a mailbox row stands for.
///
/// The domain is asked of the database rather than written here.
/// `0328` made it a setting precisely so a deployment under another
/// name would not need a migration edited, and a literal in the app is
/// the same mistake one layer up.
String mailboxAddress(Map<String, dynamic> mailbox, String domain) =>
    '${mailbox['local_part']}@$domain';

/// What the picker says beside an address.
///
/// "Yours" matters more than it looks. Somebody with two addresses in
/// the list is choosing between one their colleagues can read and one
/// they cannot, and that is the difference the label has to carry.
String mailboxKind(Map<String, dynamic> mailbox) =>
    mailbox['is_personal'] == true ? 'Yours' : 'Shared with the company';

/// Whether a line in a mailbox is one that left.
bool isOutgoing(Map<String, dynamic> row) => row['direction'] == 'out';

/// What a line in the list says about where it got to.
///
/// Only for messages that left. Nothing says "received" against
/// something that arrived: the fact it is there is what that means.
String? deliveryNote(Map<String, dynamic> row) {
  if (!isOutgoing(row)) return null;
  return switch ('${row['status']}') {
    'queued' => 'Sending',
    'sent' => 'Sent',
    'failed' => 'Could not be sent',
    'cancelled' => 'Cancelled',
    _ => null,
  };
}
