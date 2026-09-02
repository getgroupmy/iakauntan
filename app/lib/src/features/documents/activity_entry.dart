/// One row of a document's timeline, decided apart from how it is drawn.
///
/// `document_activity` returns six kinds of thing from six different
/// tables — an email, a share link, a PDF download, a change from the
/// audit trail, a payment allocated against the invoice, and what LHDN
/// said. They arrive with different columns carrying the interesting
/// word: an email's is `status`, a change's is `detail`. Deciding which
/// word goes where is the part worth testing, so it lives here and the
/// dialog only paints it.
library;

/// How a row should read: good news, bad news, still waiting, or plain.
enum ActivityTone { good, bad, waiting, neutral, muted }

class ActivityLine {
  const ActivityLine({
    required this.icon,
    required this.label,
    required this.badge,
    required this.tone,
    this.detail,
    this.recipient,
    this.note,
  });

  /// A name for the icon the dialog draws. Kept as a string so this file
  /// stays free of Flutter and can be tested without a widget tree.
  final String icon;

  /// What happened, in the past tense: 'Emailed', 'Changed', 'Paid'.
  final String label;

  /// The one word somebody is scanning for, shown in a coloured chip.
  final String badge;

  final ActivityTone tone;

  /// Anything further worth a line of small print beside the badge.
  final String? detail;

  /// Who it concerns — the recipient, the person who made the change,
  /// the customer who paid, the buyer LHDN was told about.
  final String? recipient;

  final String? note;

  static ActivityLine from(Map<String, dynamic> row) {
    final kind = row['kind'] as String? ?? '';
    final status = (row['status'] as String? ?? '').trim();
    final detail = _clean(row['detail']);
    final recipient = _clean(row['recipient']);
    final note = _clean(row['note']);

    switch (kind) {
      case 'email':
        return ActivityLine(
          icon: 'mail',
          label: 'Emailed',
          badge: status,
          tone: switch (status) {
            'sent' => ActivityTone.good,
            'failed' => ActivityTone.bad,
            'cancelled' => ActivityTone.muted,
            _ => ActivityTone.waiting,
          },
          detail: detail,
          recipient: recipient,
          note: note,
        );
      case 'share link':
        return ActivityLine(
          icon: 'link',
          label: 'Link shared',
          badge: status,
          tone: switch (status) {
            'opened' => ActivityTone.good,
            'revoked' || 'expired' => ActivityTone.muted,
            _ => ActivityTone.neutral,
          },
          detail: detail,
          recipient: recipient,
          note: note,
        );
      case 'change':
        // The interesting word is in `detail` — 'raised', 'posted to
        // the ledger', 'voided'. `status` is the raw trigger operation
        // and means nothing to a reader.
        final what = detail ?? status;
        return ActivityLine(
          icon: 'history',
          label: 'Changed',
          badge: what,
          tone: switch (what) {
            'raised' || 'posted to the ledger' || 'settled in full' =>
              ActivityTone.good,
            'voided' || 'rejected' || 'deleted' => ActivityTone.bad,
            'part paid' => ActivityTone.waiting,
            _ => ActivityTone.neutral,
          },
          detail: null,
          recipient: recipient,
          // A bare list of column names reads as debris; say what it is.
          note: note == null ? null : 'changed $note',
        );
      case 'payment':
        return ActivityLine(
          icon: 'payment',
          label: 'Paid',
          badge: status.isEmpty ? 'received' : status,
          tone: ActivityTone.good,
          detail: detail,
          recipient: recipient,
          note: note,
        );
      case 'e-invoice':
        return ActivityLine(
          icon: 'einvoice',
          label: 'e-Invoice',
          badge: status,
          tone: switch (status) {
            'valid' => ActivityTone.good,
            'invalid' || 'rejected' || 'failed' => ActivityTone.bad,
            'cancelled' => ActivityTone.muted,
            _ => ActivityTone.waiting,
          },
          detail: detail,
          recipient: recipient,
          note: note,
        );
      default:
        return ActivityLine(
          icon: 'pdf',
          label: 'PDF downloaded',
          badge: status,
          tone: ActivityTone.neutral,
          detail: detail,
          recipient: recipient,
          note: note,
        );
    }
  }

  static String? _clean(Object? v) {
    final s = v?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }
}
