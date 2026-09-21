/// The person, as distinct from the company.
///
/// Everything else in this application is about a set of books. This is
/// about whoever is looking at them: their name, how they want to be
/// addressed, and how to ring them.
///
/// It had no screen. `profiles` has held these columns since `0001`,
/// `app.handle_new_user` writes them once at signup, and the only
/// reader was `create_org_screen.dart` pre-filling onboarding — so a
/// person who typed their name wrongly at registration had no way to
/// correct it, on any surface, ever. Reported as "why is there no
/// profile settings page on the mobile app" and the answer turned out
/// to be that there is none anywhere.
///
/// ## What belongs here and what does not
///
/// The five things on the old "Your account" card at the foot of
/// Settings — change password, change email, change mobile, join
/// another company, sign out — are ACCOUNT actions, and they stay where
/// they are as well as appearing here. They go through GoTrue and each
/// one re-verifies; none of them is a field on a form.
///
/// `email` is shown and NOT editable. It is a copy of the auth address
/// and `0649` refuses to write it: editing it here would change what
/// "Signed in as" says while leaving the address that actually signs
/// somebody in, and receives their reset link, exactly as it was.
///
/// `locale` and `timezone` are not here at all. They have defaults of
/// `en-MY` and `Asia/Kuala_Lumpur` and nothing in the app reads either
/// — every date goes through `Fmt`, which carries Malaysian formats as
/// constants. Two controls that change nothing are worse than two
/// missing controls.
library;

/// What is on the form, and what was on it when it opened.
///
/// A record rather than a class so that two of them compare by value,
/// which is the whole of [profileChanged].
typedef ProfileDraft = ({String fullName, String salutation, String phone});

/// The draft a row from `profiles` opens as.
///
/// Nulls become empty strings, because a text box has no null: the two
/// are the same thing to somebody looking at the screen, and treating
/// them differently is how a form decides it has been edited before
/// anybody has touched it.
ProfileDraft profileDraftFrom(Map<String, dynamic>? row) => (
  fullName: '${row?['full_name'] ?? ''}'.trim(),
  salutation: '${row?['salutation'] ?? ''}'.trim(),
  phone: '${row?['phone'] ?? ''}'.trim(),
);

/// Whether there is anything to save.
///
/// Records compare by value, so this is the whole of it. It is a
/// function rather than an inline `!=` because the Save button and the
/// "leave without saving" prompt both have to ask, and two copies of
/// the comparison is two chances for the button to be pressable while
/// the prompt says nothing has changed.
bool profileChanged(ProfileDraft before, ProfileDraft after) =>
    before != after;

/// What is wrong with the name, or null if nothing is.
///
/// Required, because this is the name on every letter and every
/// approval this person signs. A profile with a blank name shows as
/// blank in the member list, the approval inbox and the audit trail,
/// and none of those has anywhere else to look.
String? profileNameProblem(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return 'Your name cannot be empty.';
  // Two characters, not one. A single letter is a keystroke, not a
  // name, and the commonest way this column gets one is somebody
  // clearing the box and pressing Save before they type.
  if (name.length < 2) return 'That is too short to be a name.';
  if (name.length > 120) return 'That is longer than the record allows.';
  return null;
}

/// What to call this person on screen, given everything known.
///
/// The name if there is one, then the email, then a word rather than a
/// blank. The last case is not hypothetical: `close_my_account` (0158)
/// sets the name to "Deleted user" and the email to NULL, so a row with
/// neither is a state this schema deliberately produces.
String profileDisplayName(Map<String, dynamic>? row) {
  final name = '${row?['full_name'] ?? ''}'.trim();
  if (name.isNotEmpty) return name;
  final email = '${row?['email'] ?? ''}'.trim();
  if (email.isNotEmpty) return email;
  return 'Your account';
}

/// The name with the title in front of it, for a heading.
///
/// "Mr Ahmad Ismail". Not used on letters — those have their own
/// formatting — but it is what the top of this screen says, and it is
/// the only place the salutation is ever visibly used, which is worth
/// knowing before deciding the field is decoration.
String profileFormalName(Map<String, dynamic>? row) {
  final title = '${row?['salutation'] ?? ''}'.trim();
  final name = profileDisplayName(row);
  return title.isEmpty ? name : '$title $name';
}

/// What to send to `update_my_profile` for one field.
///
/// The empty string, NOT null, when a box has been emptied. `0649`
/// treats null as "leave this column alone" and the empty string as
/// "clear it", which is the only arrangement that lets the screen send
/// a subset of the fields AND lets somebody remove a telephone number
/// they no longer want on file.
///
/// A field that has not changed is sent as null, so a save touches only
/// what was edited.
String? profileFieldToSend(String before, String after) =>
    before.trim() == after.trim() ? null : after.trim();

/// What a save should send, given the draft and what was loaded.
///
/// Empty when nothing changed, which is a save nobody should have been
/// able to ask for — the button is disabled — and which this returns
/// honestly rather than sending an update of nothing.
Map<String, String> profileChanges(ProfileDraft before, ProfileDraft after) => {
  if (profileFieldToSend(before.fullName, after.fullName) != null)
    'fullName': after.fullName.trim(),
  if (profileFieldToSend(before.salutation, after.salutation) != null)
    'salutation': after.salutation.trim(),
  if (profileFieldToSend(before.phone, after.phone) != null)
    'phone': after.phone.trim(),
};

/// What to say when the database refuses a save.
///
/// The three refusals `0649` can raise, in the words of somebody who
/// has to do something about it. Anything else is passed through: a
/// sentence written for a developer is better than a sentence written
/// for nobody.
String profileSaveProblem(Object error) {
  final text = '$error';
  if (text.contains('Not signed in')) {
    return 'You have been signed out. Sign in again and try once more.';
  }
  if (text.contains('has been closed')) {
    return 'This login has been closed, so it cannot be changed.';
  }
  if (text.contains('No profile on file')) {
    return 'There is no profile record for this login. Please tell us — '
        'this is ours to fix, not yours.';
  }
  return 'Could not save: $text';
}
