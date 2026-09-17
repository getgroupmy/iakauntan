import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/denials.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

PostgrestException refusal(String message, {String? code}) =>
    PostgrestException(message: message, code: code);

void main() {
  group('whether an error is somebody being told no', () {
    test('42501 is, whatever it says', () {
      // Every app.can_* guard in this schema raises it by hand.
      expect(
        looksLikeARefusal(
          refusal('not permitted to write for this organization',
              code: '42501'),
        ),
        isTrue,
      );
    });

    test('and so is a row-level security refusal, which has no code the '
        'client can see', () {
      expect(
        looksLikeARefusal(
          refusal('new row violates row-level security policy for table '
              '"invoices"'),
        ),
        isTrue,
      );
    });

    test('so are the words every app.can_* guard raises, on their own', () {
      // A guard raising through a path that loses the SQLSTATE still
      // says the same sentence, and it is still a refusal.
      expect(
        looksLikeARefusal(refusal('not permitted to read this organization')),
        isTrue,
      );
    });

    test('a check constraint is not — it is being told you are wrong', () {
      // "The shares come to 90%" is a business rule refusing a shape.
      // Every one of them in the security log would bury the handful
      // that are somebody reaching for a company they do not hold.
      expect(
        looksLikeARefusal(
          refusal('The shares of a conversion must come to 100.',
              code: '23514'),
        ),
        isFalse,
      );
    });

    test('nor is a missing row', () {
      expect(
        looksLikeARefusal(refusal('No such conversion.', code: 'P0002')),
        isFalse,
      );
    });

    test('nor a broken connection', () {
      expect(looksLikeARefusal(Exception('Connection closed')), isFalse);
    });

    test('an ordinary error that says it in words still counts', () {
      // A refusal reaching the client through something that is not a
      // PostgrestException is still a refusal.
      expect(
        looksLikeARefusal(Exception('permission denied for table items')),
        isTrue,
      );
    });

    test('and the words are matched however they are cased', () {
      expect(
        looksLikeARefusal(refusal('Permission Denied for table items')),
        isTrue,
      );
    });
  });

  group('what the log records as the thing refused', () {
    test("the screen's own name for it, when it gave one", () {
      // The sentence coming back says what the database thought, not
      // what the person was trying to do.
      expect(
        deniedAction(refusal('not permitted', code: '42501'),
            doing: 'Post a journal'),
        'Post a journal',
      );
    });

    test('and the message when it did not', () {
      expect(
        deniedAction(refusal('not permitted', code: '42501')),
        'not permitted',
      );
    });

    test('a blank name is no name', () {
      expect(
        deniedAction(refusal('not permitted', code: '42501'), doing: '   '),
        'not permitted',
      );
    });
  });

  group("the server's own sentence", () {
    test('is the message, not the whole exception', () {
      expect(
        deniedDetail(refusal('not permitted to read this organization',
            code: '42501')),
        'not permitted to read this organization',
      );
    });

    test('is flattened onto one line', () {
      // A stack trace across a log is a log nobody reads.
      expect(
        deniedDetail(refusal('not permitted\n  because of\tthings')),
        'not permitted because of things',
      );
    });

    test('and is cut short when it runs on', () {
      final long = deniedDetail(refusal('x' * 500));
      expect(long.length, 200);
      expect(long.endsWith('…'), isTrue);
    });

    test('one exactly at the limit is left alone', () {
      final exact = deniedDetail(refusal('x' * 200));
      expect(exact.length, 200);
      expect(exact.endsWith('…'), isFalse);
    });

    test('a plain error is said as itself', () {
      expect(deniedDetail(Exception('nope')), 'Exception: nope');
    });
  });
}
