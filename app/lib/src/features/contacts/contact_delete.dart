/// Deleting a contact, and saying why not.
///
/// Asked for as: a delete button in the contacts list and on the
/// contact itself, a warning before it happens, and — where the contact
/// has transaction data — a message saying it cannot be deleted because
/// there is data.
///
/// ## Two dialogs, and they are not the same dialog
///
/// The first asks. The second explains a refusal. Running them together
/// — a confirm that greys itself out when the contact is in use — was
/// the other way to build this and needs the counts BEFORE the button
/// is pressed, which means a query per row in a list of two hundred.
/// Asking the server once, when somebody has actually decided, is both
/// cheaper and the only version that cannot be stale.
///
/// ## The refusal is read from the code, not the sentence
///
/// `0654` raises `23503` for "something still points at this" and
/// `42501` for "not yours to delete", and the two need different
/// things said. Reading the English would work until somebody rewords
/// the migration, which is exactly the kind of coupling that survives
/// review and fails quietly; `codeOfRefusal` reads the SQLSTATE and
/// the message is passed through as the detail.
///
/// The message is passed through rather than rewritten, deliberately.
/// The server already names what is in the way — "3 sales documents and
/// 1 receipt" — and a client that replaced that with "this contact has
/// data" would be throwing away the only part somebody can act on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';

/// What kind of refusal came back.
enum ContactDeleteRefusal {
  /// `23503`. Something still points at the contact, and the message
  /// says what.
  inUse,

  /// `42501`. Not this person's to delete.
  notAllowed,

  /// `P0002`. Already gone — two tabs, or two people.
  alreadyGone,

  /// Anything else: a dropped connection, a server that fell over.
  unknown,
}

/// Which of the four a thrown error is.
///
/// Reads the SQLSTATE rather than the sentence. A `PostgrestException`
/// is the only thing that can carry one; everything else — a socket
/// that closed, a timeout — is [ContactDeleteRefusal.unknown], because
/// a failure with no code is not a refusal and must not be reported as
/// one. Saying "this contact has data" to somebody whose wifi dropped
/// sends them looking for documents that are not there.
ContactDeleteRefusal refusalOf(Object error) {
  if (error is! PostgrestException) return ContactDeleteRefusal.unknown;
  return switch (error.code) {
    '23503' => ContactDeleteRefusal.inUse,
    '42501' => ContactDeleteRefusal.notAllowed,
    'P0002' => ContactDeleteRefusal.alreadyGone,
    _ => ContactDeleteRefusal.unknown,
  };
}

/// The heading over the refusal.
String refusalTitle(ContactDeleteRefusal refusal) => switch (refusal) {
  ContactDeleteRefusal.inUse => 'This contact cannot be deleted',
  ContactDeleteRefusal.notAllowed => 'Not yours to delete',
  ContactDeleteRefusal.alreadyGone => 'Already deleted',
  ContactDeleteRefusal.unknown => 'The contact was not deleted',
};

/// What to say under it.
///
/// [detail] is the server's own sentence. For [ContactDeleteRefusal.inUse]
/// it names and counts what is in the way, which is the whole value of
/// the message, so it is shown and then explained rather than replaced.
String refusalBody(ContactDeleteRefusal refusal, String detail) {
  final said = detail.trim();
  return switch (refusal) {
    ContactDeleteRefusal.inUse =>
      '$said.\n\nA contact that documents or ledger entries point at '
          'cannot be removed — deleting it would take the name off '
          'records that are already posted. Delete or reassign those '
          'first, or leave the contact in place and stop using it.',
    ContactDeleteRefusal.notAllowed =>
      said.isEmpty
          ? 'You do not have permission to delete contacts in this company.'
          : said,
    ContactDeleteRefusal.alreadyGone =>
      'Somebody has already deleted this contact — possibly you, in '
          'another tab. Nothing further to do.',
    // The server's own words where there are any, because an unknown
    // failure is exactly the case where guessing is worst.
    ContactDeleteRefusal.unknown => said.isEmpty
        ? 'Something went wrong and the contact was not deleted. Try again.'
        : said,
  };
}

/// The sentence that gets a confirmation.
///
/// Names the contact. "Delete this contact?" over a list of two hundred
/// is a question somebody answers about the wrong row.
String deleteWarning(String name) {
  final who = name.trim().isEmpty ? 'this contact' : name.trim();
  return 'Delete $who?\n\nThis cannot be undone. It is only possible '
      'while nothing points at the contact — no documents, no payments, '
      'no ledger entries.';
}

/// Ask, delete, and explain a refusal. Returns true if it was deleted.
///
/// Both callers — the row in the list and the contact itself — go
/// through this, so the warning and the refusal are worded once.
Future<bool> confirmAndDeleteContact(
  BuildContext context,
  WidgetRef ref, {
  required String id,
  required String name,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      key: const ValueKey('contact-delete-confirm'),
      title: const Text('Delete contact'),
      content: Text(deleteWarning(name)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('contact-delete-proceed'),
          style: FilledButton.styleFrom(
            backgroundColor: context.colors.danger,
          ),
          onPressed: () => Navigator.of(dialog).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;

  final repo = ref.read(repoProvider);
  if (repo == null) return false;

  try {
    await repo.deleteContact(id);
  } catch (error) {
    if (!context.mounted) return false;
    final refusal = refusalOf(error);
    final detail = error is PostgrestException
        ? error.message
        : error.toString();
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const ValueKey('contact-delete-refused'),
        icon: Icon(
          refusal == ContactDeleteRefusal.inUse
              ? Icons.link_off
              : Icons.error_outline,
          color: context.colors.danger,
        ),
        title: Text(refusalTitle(refusal)),
        content: SingleChildScrollView(
          child: Text(refusalBody(refusal, detail)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    // Gone is gone. The row has to leave the list either way, and
    // reporting "not deleted" for a contact that is not there would
    // leave it on screen until a reload.
    return refusal == ContactDeleteRefusal.alreadyGone;
  }
  return true;
}
