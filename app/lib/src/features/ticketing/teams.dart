/// Support teams, and who is actually on one.
///
/// `0192` created `ticket_teams` and `ticket_team_members` together.
/// The app reached the first — to filter a list and to label a row —
/// and never the second, and it could not create a team either: every
/// team in existence came from a demo seed. So routing existed and
/// decided nothing, and "assign it to somebody on Billing" was a
/// question with no answer.
///
/// `0355` makes the membership list decide, and declines to when it is
/// empty. Everything here is pure and asserted in `ticket_teams_test.dart`.
library;

/// A code from a name somebody typed.
///
/// `ticket_teams` is unique on `(org_id, code)` and the code is what a
/// later migration or an import would refer to a team by, so it has to
/// be stable and typeable. Generated rather than asked for: an operator
/// naming a team "Billing & Credit Control" should not also have to
/// invent `billing_credit_control`.
String teamCode(String name) {
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  return slug.isEmpty ? 'team' : slug;
}

/// Why a team cannot be saved, or null.
String? teamBlockedBecause({
  required String name,
  required Iterable<String> takenCodes,
  String? editingCode,
}) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'A team needs a name.';
  final code = teamCode(trimmed);
  // Renaming a team to its own name is not a clash with itself.
  if (code != editingCode && takenCodes.contains(code)) {
    return 'There is already a team with that name.';
  }
  return null;
}

/// What the members line says about a team.
///
/// The empty case is the one worth wording carefully, because it is not
/// a gap in the data — it is a live setting with a consequence. A team
/// nobody is on accepts any assignee, and an operator looking at this
/// list should be able to see which of their teams are in that state
/// without opening each one.
String rosterSummary(List<Map<String, dynamic>> roster) {
  if (roster.isEmpty) return 'Anybody can be given these — nobody is on it';
  final lead = roster.where((m) => m['is_lead'] == true).firstOrNull;
  final n = roster.length;
  final who = n == 1 ? '1 person' : '$n people';
  if (lead == null) return '$who, no lead';
  return '$who, led by ${memberName(lead)}';
}

/// A person's name, falling back to the address.
///
/// `profiles.full_name` is null until somebody fills it in, and a blank
/// line in a list of people is how a team looks empty when it is not.
String memberName(Map<String, dynamic> member) {
  final name = '${member['full_name'] ?? ''}'.trim();
  if (name.isNotEmpty) return name;
  final email = '${member['email'] ?? ''}'.trim();
  return email.isNotEmpty ? email : 'Somebody with no name on record';
}

/// Who is left to add: active members of the company who are not on
/// this team already.
///
/// An invited member with no `user_id` is not offered, for the reason
/// `assignableMembers` gives — there is nobody yet to name.
List<Map<String, dynamic>> addableTo({
  required Iterable<Map<String, dynamic>> orgTeam,
  required Iterable<Map<String, dynamic>> roster,
}) {
  final already = {for (final m in roster) '${m['user_id']}'};
  return [
    for (final m in orgTeam)
      if (m['status'] == 'active' &&
          m['user_id'] != null &&
          !already.contains('${m['user_id']}'))
        m,
  ];
}
