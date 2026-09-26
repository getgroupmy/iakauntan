import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/error_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// What a person is shown when something failed.
///
/// The screenshot that caused this: the database refused to close a
/// bank reconciliation that was out by RM 11,008.23, in a sentence
/// written for that moment, and the phone showed the sentence wrapped
/// in `PostgrestException(message: ..., code: 23514, details: Bad
/// Request, hint: null)`.
void main() {
  group('errorText', () {
    test('gives the database its own sentence, without the envelope', () {
      const said = 'The reconciliation is out by -11008.23. There are 24 '
          'statement lines still unmatched. Completing it now would bury '
          'the difference.';
      final shown = errorText(
        const PostgrestException(message: said, code: '23514',
            details: 'Bad Request'),
      );

      expect(shown, said);
      // The three things the wrapper used to add.
      expect(shown, isNot(contains('PostgrestException')));
      expect(shown, isNot(contains('23514')));
      expect(shown, isNot(contains('Bad Request')));
    });

    test('falls back to the details when there is no message', () {
      expect(
        errorText(const PostgrestException(message: '  ', details: 'No rows')),
        'No rows',
      );
    });

    test('says something rather than nothing when the error is empty', () {
      expect(errorText(const PostgrestException(message: '')), isNotEmpty);
      expect(errorText(null), isNotEmpty);
    });

    test('unwraps the other two Supabase envelopes', () {
      expect(errorText(const AuthException('Email not confirmed')),
          'Email not confirmed');
      expect(errorText(const StorageException('Object not found')),
          'Object not found');
    });

    test('an error of our own is shown as the sentence it carries', () {
      expect(errorText(const _Ours('That bill is already paid.')),
          'That bill is already paid.');
    });

    test('an error of our own with nothing to say still prints', () {
      // Not swallowed into "Something went wrong": an unrecognised
      // failure shown untidily beats one shown as nothing at all.
      expect(errorText(const _Ours('   ')), contains('_Ours'));
    });

    test('a connection that never landed says so in words', () {
      expect(
        errorText(Exception(
            "ClientException with SocketException: Failed host lookup: "
            "'db.example.supabase.co'")),
        offlineMessage,
      );
      // And it does not leak where the server lives.
      expect(errorText(Exception('Failed host lookup: db.example.co')),
          isNot(contains('db.example.co')));
    });

    test("strips the prefix Dart puts on an object nobody named", () {
      expect(errorText(Exception('The file is empty.')), 'The file is empty.');
      expect(errorText(StateError('No company is open.')),
          'No company is open.');
    });

    test('an unknown error is still shown, not hidden', () {
      expect(errorText('the server sent nothing back'),
          'the server sent nothing back');
    });
  });
}

class _Ours implements Exception, Explained {
  const _Ours(this.message);

  @override
  final String message;
}
