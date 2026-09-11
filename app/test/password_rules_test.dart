import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/auth/password_rules.dart';

/// The password typed twice.
///
/// A password box shows nothing back, so a typo in it is a password
/// nobody knows — including the person who just set it, who finds out
/// at the next sign-in and has to reset an account they registered
/// minutes ago.
void main() {
  group('choosing one', () {
    test('has to be long enough', () {
      expect(passwordError('short1', isNew: true), contains('8'));
      expect(passwordError('longenough', isNew: true), isNull);
      expect(passwordMinLength, 8);
    });

    test('and the length is only asked of a NEW one', () {
      // An existing password shorter than eight is still their
      // password. Refusing it at sign-in locks somebody out of their
      // own account over a rule that arrived after they set it.
      expect(passwordError('short1'), isNull);
      expect(passwordError('short1', isNew: false), isNull);
    });

    test('an empty box is asked for either way', () {
      expect(passwordError(''), isNotNull);
      expect(passwordError(null, isNew: true), isNotNull);
    });
  });

  group('typing it twice', () {
    test('the same way passes', () {
      expect(
        confirmPasswordError(password: 'longenough', confirm: 'longenough'),
        isNull,
      );
    });

    test('a different way does not', () {
      // The whole point of the field.
      expect(
        confirmPasswordError(password: 'longenough', confirm: 'longenoug'),
        passwordMismatch,
      );
      expect(
        confirmPasswordError(password: 'longenough', confirm: 'Longenough'),
        passwordMismatch,
        reason: 'case is part of a password',
      );
      expect(
        confirmPasswordError(password: 'longenough ', confirm: 'longenough'),
        passwordMismatch,
        reason: 'a trailing space is part of a password too',
      );
    });

    test('and an empty second box is its own refusal', () {
      // Somebody who has not typed it yet has not made a mistake, and
      // being told they have is a form arguing about the order they
      // fill it in.
      final empty = confirmPasswordError(password: 'longenough', confirm: '');
      expect(empty, isNotNull);
      expect(empty, isNot(passwordMismatch));
      expect(empty!.toLowerCase(), contains('again'));
    });

    test('the refusal is about the pair, not about one box', () {
      // Either one of them could hold the typo, and a password nobody
      // can see is one nobody can compare by eye.
      expect(passwordMismatch.toLowerCase(), contains('two passwords'));
      expect(confirmPasswordLabel.toLowerCase(), contains('confirm'));
    });
  });
}
