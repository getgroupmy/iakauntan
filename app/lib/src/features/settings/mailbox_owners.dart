/// Whose an address is, for the screen that lists them.
///
/// `0559` gave a mailbox three states — shared, personal, and personal
/// with nobody left on it — and built `request_mailbox` with an owner
/// and `assign_mailbox` to move one. Nothing in the app reached any of
/// it: the repository still asked for an address with two arguments,
/// `assign_mailbox` had no caller at all, and the list showed every
/// address as though they were all the company's. The rule was
/// enforced and invisible, which is the half that gets forgotten.
library;

import '../../data/models.dart';

/// Whether this row belongs to one person rather than to the company.
bool isPersonalMailbox(Map<String, dynamic> row) => row['is_personal'] == true;

/// Who it belongs to, said the way somebody reading a list needs it.
///
/// [names] maps a user id to what to call them. A personal mailbox
/// whose owner is not in that map is still somebody's — saying "shared"
/// there would be the opposite of true — so it says that without
/// naming them.
String mailboxOwnerLabel(Map<String, dynamic> row, Map<String, String> names) {
  if (!isPersonalMailbox(row)) return 'Shared with the company';
  final owner = row['owner_id'] as String?;
  if (owner == null) {
    // `on delete set null`. The mail is still here and an administrator
    // can reach it, which is the one case where they can — so the list
    // has to say why rather than leaving a blank.
    return 'Nobody — that account was closed';
  }
  final named = names[owner];
  return named != null && named.isNotEmpty ? named : 'One of your colleagues';
}

/// What the button that moves it should say.
///
/// Moving a personal one to the company is not the same act as giving
/// a shared one to a person, and a button labelled "Hand over" for both
/// hides which of the two is about to happen. Giving it back makes
/// every message in it readable by every member, and that deserves its
/// own words.
String handOverLabel(Map<String, dynamic> row) =>
    isPersonalMailbox(row) ? 'Move or give back' : 'Give it to somebody';

/// The line under the handover dialog, which is where the consequence
/// belongs.
String handOverWarning(String? newOwnerId) => newOwnerId == null
    ? 'Everything in this mailbox becomes readable by everybody who '
        'works here. That is what a company address means, and it '
        'cannot be undone for mail already in it.'
    : 'Only they will be able to read what is in it. You will not, '
        'and neither will anybody else here.';

/// The people an address can be given to.
///
/// Active members with an account. An invitation that has not been
/// accepted has no user to own anything, and `request_mailbox` and
/// `assign_mailbox` both refuse one — so offering them here would be
/// offering a choice the database is about to refuse.
List<TeamMember> mailboxOwnerCandidates(List<TeamMember> team) => [
      for (final m in team)
        if (m.status == 'active' && (m.userId ?? '').isNotEmpty) m,
    ];

/// What to call somebody in the picker.
String memberLabel(TeamMember m) {
  final name = (m.fullName ?? '').trim();
  if (name.isNotEmpty) return name;
  final email = (m.email ?? '').trim();
  return email.isNotEmpty ? email : 'A colleague';
}

/// A user id to display name map, for [mailboxOwnerLabel].
Map<String, String> namesById(List<TeamMember> team) => {
      for (final m in team)
        if ((m.userId ?? '').isNotEmpty) m.userId!: memberLabel(m),
    };
