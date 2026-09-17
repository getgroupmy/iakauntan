import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/providers.dart';

/// What a company bought, and what this person is let into.
///
/// Two questions, and the screens asked them in three different ways —
/// `.when(loading: () => true)`, a `.valueOrNull` with a null check, and
/// an awaited read. Their own comments said the three agree ("The answer
/// is the same and so is the permissiveness while it loads"); nothing
/// made them, and none could be called by a unit test because each took
/// a `WidgetRef`.
///
/// Hiding is a courtesy throughout — `0127`'s restrictive policies are
/// the control — which is exactly why the permissive default is safe and
/// why it has to be the same everywhere. A screen that guessed "no"
/// while an answer was in flight would hide a paid module from the
/// person who bought it.
void main() {
  group('whether a module is open to somebody', () {
    test('a module the company never bought is shut', () {
      expect(
        moduleAllowed(entitled: {'pos'}, access: const {}, code: 'hrms'),
        isFalse,
      );
    });

    test('and one it did buy is open', () {
      expect(
        moduleAllowed(entitled: {'pos', 'hrms'}, access: const {}, code: 'hrms'),
        isTrue,
      );
    });

    test('unless this person is kept out of it', () {
      // Bought by the company and closed to this member. Both questions
      // have to say yes.
      expect(
        moduleAllowed(
          entitled: {'hrms'},
          access: const {'hrms': 'none'},
          code: 'hrms',
        ),
        isFalse,
      );
    });

    test('read-only is still open — it is a door, not a pen', () {
      expect(
        moduleAllowed(
          entitled: {'hrms'},
          access: const {'hrms': 'read'},
          code: 'hrms',
        ),
        isTrue,
      );
    });
  });

  group('and what it does before either answer has arrived', () {
    test('an entitlement list still loading is not a refusal', () {
      // Null is "not known yet". Reading it as "not bought" empties the
      // navigation on every cold start, and puts it back a moment later.
      expect(
        moduleAllowed(entitled: null, access: const {}, code: 'hrms'),
        isTrue,
      );
    });

    test('nor is an access map still loading', () {
      expect(
        moduleAllowed(entitled: {'hrms'}, access: null, code: 'hrms'),
        isTrue,
      );
    });

    test('but a list that has arrived and does not name it is', () {
      // The difference that matters: an empty set is an answer, and null
      // is the absence of one.
      expect(
        moduleAllowed(entitled: const {}, access: null, code: 'hrms'),
        isFalse,
      );
    });

    test('while an access map that does not mention it is not', () {
      // What the database answers for a member with no access type at
      // all, which is most of them.
      expect(
        moduleAllowed(
          entitled: {'hrms'},
          access: const {'pos': 'read'},
          code: 'hrms',
        ),
        isTrue,
      );
    });
  });

  group('whether they may change anything in it', () {
    test('write is write, and read is not', () {
      expect(
        moduleWriteAllowed(access: const {'pos': 'write'}, code: 'pos'),
        isTrue,
      );
      expect(
        moduleWriteAllowed(access: const {'pos': 'read'}, code: 'pos'),
        isFalse,
      );
      expect(
        moduleWriteAllowed(access: const {'pos': 'none'}, code: 'pos'),
        isFalse,
      );
    });

    test('and an answer that has not arrived reads as write', () {
      expect(moduleWriteAllowed(access: null, code: 'pos'), isTrue);
      expect(moduleWriteAllowed(access: const {}, code: 'pos'), isTrue);
    });

    test('it never asks whether the company bought the module', () {
      // `permissionHeld` uses this for a named permission — voiding a
      // sent line, say — and a permission is not sold, so it never
      // appears in the entitlement list. Asking would deny every one of
      // them to everybody.
      expect(
        moduleWriteAllowed(
          access: const {'pos.void_sent_line': 'write'},
          code: 'pos.void_sent_line',
        ),
        isTrue,
      );
    });
  });
}
