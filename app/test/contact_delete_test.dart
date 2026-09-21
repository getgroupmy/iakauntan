/// Deleting a contact, and what is said when it cannot be.
///
/// The rule that matters lives in the database — `0654`'s
/// `delete_contact` refuses while anything still points at the contact,
/// and `supabase/tests/contact_delete.sql` is where that is asserted,
/// including the case that used to succeed in silence: a customer whose
/// only history is in the ledger, deleted through an ON DELETE SET NULL
/// key that detaches every posted line without complaining.
///
/// What is asserted HERE is the half the app owns: which refusal came
/// back, and what a person is told about it. Three things can go wrong
/// in ways nothing else notices:
///
///   * READING THE SENTENCE instead of the code. The English in the
///     migration is prose and will be reworded; the SQLSTATE is the
///     contract.
///   * CALLING A DROPPED CONNECTION A REFUSAL. A failure with no code
///     is not "this contact has data", and saying so sends somebody
///     hunting for documents that do not exist.
///   * THROWING AWAY THE COUNTS. The server says "3 sales documents and
///     1 receipt". That is the only part somebody can act on, and a
///     client that replaced it with "this contact has data" would have
///     been easier to write and useless.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/contacts/contact_delete.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  PostgrestException refusal(String code, String message) =>
      PostgrestException(message: message, code: code);

  group('which refusal came back', () {
    test('23503 is something still pointing at it', () {
      expect(
        refusalOf(refusal('23503', 'Kedai Besi cannot be deleted while …')),
        ContactDeleteRefusal.inUse,
      );
    });

    test('42501 is permission', () {
      expect(
        refusalOf(refusal('42501', 'Deleting a contact needs permission …')),
        ContactDeleteRefusal.notAllowed,
      );
    });

    test('P0002 is a contact somebody else already deleted', () {
      expect(
        refusalOf(refusal('P0002', 'That contact has already been deleted')),
        ContactDeleteRefusal.alreadyGone,
      );
    });

    test('and anything without a code is not a refusal at all', () {
      // The one worth being careful about. A socket that closed is not
      // the server saying no, and reporting it as "this contact has
      // data" would send somebody looking for documents that are not
      // there.
      expect(
        refusalOf(Exception('Connection closed')),
        ContactDeleteRefusal.unknown,
      );
      expect(
        refusalOf(refusal('PGRST301', 'JWT expired')),
        ContactDeleteRefusal.unknown,
      );
      expect(refusalOf('a string'), ContactDeleteRefusal.unknown);
    });

    test('the code is read, not the words', () {
      // The coupling this avoids: a message that happens to contain
      // "permission" must not become a permission refusal, and a
      // reworded migration must not change what the app decides.
      expect(
        refusalOf(
          refusal('23503', 'you do not have permission — no, 2 receipts'),
        ),
        ContactDeleteRefusal.inUse,
      );
    });
  });

  group('what is said about it', () {
    test('the counts survive into the message', () {
      final body = refusalBody(
        ContactDeleteRefusal.inUse,
        'Kedai Besi Maju cannot be deleted while it still has '
        '3 sales documents, 1 receipt',
      );
      expect(body, contains('3 sales documents'));
      expect(body, contains('1 receipt'));
      expect(body, contains('Kedai Besi Maju'));
      // And the sentence that says what to do next, which is the whole
      // difference between a refusal and a dead end.
      expect(body.toLowerCase(), contains('delete or reassign'));
    });

    test('each refusal has its own heading', () {
      final titles = {
        for (final r in ContactDeleteRefusal.values) refusalTitle(r),
      };
      // Four refusals, four headings. Two sharing one would mean a
      // permission problem and a data problem reading identically.
      expect(titles.length, ContactDeleteRefusal.values.length);
    });

    test('an unknown failure says what the server said', () {
      expect(
        refusalBody(ContactDeleteRefusal.unknown, 'Connection closed'),
        contains('Connection closed'),
      );
    });

    test('and has something to say when the server said nothing', () {
      // An empty detail is the case where guessing is worst and
      // silence is worse still: the dialog would be a heading and a
      // Close button.
      for (final r in ContactDeleteRefusal.values) {
        expect(refusalBody(r, '').trim(), isNotEmpty, reason: '$r');
      }
    });

    test('already-gone does not ask for anything to be done', () {
      final body = refusalBody(ContactDeleteRefusal.alreadyGone, '');
      expect(body.toLowerCase(), contains('nothing further to do'));
    });
  });

  group('the warning before it happens', () {
    test('names the contact', () {
      // "Delete this contact?" over a list of two hundred rows is a
      // question somebody answers about the wrong one.
      expect(deleteWarning('Kedai Besi Maju'), contains('Kedai Besi Maju'));
    });

    test('and says it cannot be undone', () {
      expect(
        deleteWarning('Kedai Besi Maju').toLowerCase(),
        contains('cannot be undone'),
      );
    });

    test('and says the condition, before the server has to', () {
      // The request asked for a warning and then an error. Saying the
      // rule in the warning means most people meet it once rather than
      // twice.
      final warning = deleteWarning('Kedai Besi Maju').toLowerCase();
      expect(warning, contains('documents'));
      expect(warning, contains('ledger'));
    });

    test('a contact with no name still reads as a sentence', () {
      // Possible: a row saved before the name was required, or a blank
      // one from an import. "Delete ?" is what the fallback exists to
      // stop.
      expect(deleteWarning('   '), contains('Delete this contact?'));
      expect(deleteWarning(''), isNot(contains('Delete ?')));
    });
  });
}
