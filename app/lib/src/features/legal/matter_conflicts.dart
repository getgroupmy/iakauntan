/// Opening a file, having asked whether the firm can act.
///
/// The conflict rule itself is the database's — `check_matter_conflict`
/// and `open_matter` in `0383` — and it is asked rather than worked out
/// again here, because two implementations of one professional rule
/// disagree eventually and the wrong one is the one somebody relies on.
///
/// What this file decides is what the form does with the answer: when a
/// written reason becomes mandatory, and how the result reads.
library;

/// One file the firm already has that touches these parties.
class MatterConflict {
  const MatterConflict({
    required this.matterNo,
    required this.matterName,
    required this.status,
    required this.direction,
    this.clientName,
    this.otherSide,
  });

  final String matterNo;
  final String matterName;
  final String status;

  /// Which way round it is: whether the firm acts for the proposed
  /// opponent, or has acted against the proposed client. Both are
  /// conflicts and they are not the same conversation.
  final String direction;
  final String? clientName;
  final String? otherSide;

  /// A closed file is still a conflict — the duty of confidence
  /// survives the retainer — but it is a different weight of one, and
  /// the form says which so the solicitor is not left to guess.
  bool get isOpen => status == 'open' || status == 'on_hold';

  factory MatterConflict.fromJson(Map<String, dynamic> j) => MatterConflict(
        matterNo: j['matter_no']?.toString() ?? '',
        matterName: j['matter_name']?.toString() ?? '',
        status: j['status']?.toString() ?? '',
        direction: j['direction']?.toString() ?? '',
        clientName: j['client_name'] as String?,
        otherSide: j['other_side'] as String?,
      );
}

/// Whether the form must have a written reason before it will send.
///
/// Any conflict at all, open or closed. A closed file's duty of
/// confidence does not end with the retainer, and asking a solicitor to
/// write a sentence is a small price beside the one for not asking.
bool conflictNeedsNote(List<MatterConflict> found) => found.isNotEmpty;

/// What the form will not send, in the words to show if so.
String? matterBlockedBecause({
  required String name,
  required String? clientId,
  required List<MatterConflict> conflicts,
  required String? conflictNote,
}) {
  if (clientId == null) return 'A matter is opened for a client.';
  if (name.trim().isEmpty) return 'Name the matter.';
  if (conflictNeedsNote(conflicts) &&
      (conflictNote == null || conflictNote.trim().isEmpty)) {
    final open = conflicts.where((c) => c.isOpen).length;
    return open > 0
        ? 'This would put the firm on both sides of $open open file'
            '${open == 1 ? '' : 's'}. If it has been considered and '
            'cleared, write down why.'
        : 'The firm has acted for one of these parties before. The duty '
            'of confidence outlives the retainer — say why this is '
            'clear.';
  }
  return null;
}

/// How one conflict reads on the form.
String describeConflict(MatterConflict c) {
  final side = c.direction == 'we act for the other side'
      ? 'we act for ${c.clientName ?? 'them'}'
      : 'we acted against ${c.otherSide ?? 'them'}';
  return '${c.matterNo} · ${c.matterName} — $side '
      '(${c.isOpen ? 'open' : c.status})';
}
