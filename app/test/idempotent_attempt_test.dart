import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/repository.dart';

/// The rule that makes an idempotency key correct rather than merely
/// present.
///
/// `0307` built the mechanism — the key table, the fingerprint check, a
/// daily sweep, a CI test — and the client never sent a key, so every
/// protected write has been unprotected since. Sending *a* key is not
/// enough on its own: a fresh key on every attempt protects nothing,
/// and a key that never retires collapses two entries somebody meant to
/// make twice.
void main() {
  Map<String, dynamic> journal({num amount = 100, String? reference}) => {
        'p_org_id': 'org-1',
        'p_entry_date': '2026-09-01',
        'p_lines': [
          {'account': '5100', 'debit': amount, 'credit': 0},
          {'account': '1100', 'debit': 0, 'credit': amount},
        ],
        'p_description': 'Petty cash',
        'p_reference': reference,
      };

  test('the same attempt, tried twice, sends the same key', () {
    final attempt = IdempotentAttempt();
    final first = attempt.keyFor(journal());
    final again = attempt.keyFor(journal());
    expect(again, first,
        reason: 'a retry with the same payload is the same request, and a '
            'fresh key would post it a second time');
  });

  test('a key retires on success, so an identical entry posts again', () {
    // Two identical RM50 petty cash entries on one day is an ordinary
    // thing to do. A key held past the first success would swallow the
    // second and return the first entry's id.
    final attempt = IdempotentAttempt();
    final first = attempt.keyFor(journal(amount: 50));
    attempt.succeeded();
    final second = attempt.keyFor(journal(amount: 50));
    expect(second, isNot(first));
  });

  test('editing the form after a failure mints a new key', () {
    // 0307 refuses a key reused for different arguments with 22023, so
    // reusing one here would turn a corrected resubmission into an
    // error the person cannot act on.
    final attempt = IdempotentAttempt();
    final first = attempt.keyFor(journal(amount: 100));
    final corrected = attempt.keyFor(journal(amount: 110));
    expect(corrected, isNot(first));
  });

  test('a change in any field counts, including one left blank before',
      () {
    final attempt = IdempotentAttempt();
    final blank = attempt.keyFor(journal());
    final withRef = attempt.keyFor(journal(reference: 'PV-1'));
    expect(withRef, isNot(blank));
  });

  test('going back to the earlier payload is still a new attempt', () {
    // The comparison is against the last payload, not a history of
    // them. Somebody who edits and edits back has made two attempts and
    // the second is not a retry of the first — and even if it were,
    // erring towards a fresh key errs towards posting, which the person
    // can see and undo, rather than towards silently not posting.
    final attempt = IdempotentAttempt();
    final first = attempt.keyFor(journal(amount: 100));
    attempt.keyFor(journal(amount: 110));
    final back = attempt.keyFor(journal(amount: 100));
    expect(back, isNot(first));
  });

  test('keys are long enough to collide with nothing and short enough '
      'for the column', () {
    // `idempotency_keys.key` is `check (length(key) between 1 and 255)`.
    final keys = <String>{};
    for (var i = 0; i < 500; i++) {
      final attempt = IdempotentAttempt();
      final k = attempt.keyFor(journal(amount: i));
      expect(k.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(k), isTrue);
      keys.add(k);
    }
    expect(keys.length, 500, reason: 'two attempts must not share a key');
  });
}
