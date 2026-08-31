import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/pos/offline_problems_dialog.dart';

Map<String, dynamic> reject({
  String? register = 'Counter 1',
  String? takenAt = '2026-08-30T13:45:00Z',
  Object? total = 42.5,
  String? code,
  String? message,
}) => {
  'reject_id': 'r1',
  'register': register,
  'taken_at': takenAt,
  'total': total,
  'error_code': code,
  'message': message,
};

void main() {
  group('which till took it, and when', () {
    test('both, when both are known', () {
      expect(problemLine(reject()), startsWith('Counter 1 · '));
    });

    test('a till that has since been deleted is still named as one', () {
      // The function left-joins the register, so this can come back
      // null. A blank line reads as a bug in the screen.
      expect(
        problemLine(reject(register: null, takenAt: null)),
        'a till nobody can name',
      );
    });

    test('and a payload with no time on it says only the till', () {
      expect(problemLine(reject(takenAt: null)), 'Counter 1');
    });
  });

  group('why the server would not take it', () {
    test("the server's own sentence, where there is one", () {
      expect(
        problemReason(reject(message: 'That shift is already closed.')),
        'That shift is already closed.',
      );
    });

    test('the SQLSTATE only where there is not', () {
      // A code alone tells a shop manager nothing, but it beats a
      // blank line.
      expect(problemReason(reject(code: '23514')), 'Refused: 23514');
    });

    test('and neither is said as itself', () {
      expect(problemReason(reject()), 'Refused, with no reason given.');
    });

    test('a message of only spaces is no message', () {
      expect(problemReason(reject(message: '   ', code: '42501')),
          'Refused: 42501');
    });
  });

  group('whether money crossed the counter', () {
    test('it did when the payload adds up to something', () {
      expect(tookMoney(reject(total: 42.5)), isTrue);
    });

    test('and it did not when the payload is empty', () {
      // A refused payload with nothing on it is a bug in the till, not
      // a hole in the takings.
      expect(tookMoney(reject(total: 0)), isFalse);
      expect(tookMoney(reject(total: null)), isFalse);
    });

    test('a total that came back as a string still counts', () {
      expect(tookMoney(reject(total: '42.50')), isTrue);
    });
  });

  group('what the shop is short', () {
    test('over the sales that took something', () {
      final t = offlineProblemTotals([
        reject(total: 42.5),
        reject(total: 0),
        reject(total: 45.9),
      ]);
      expect(t.sales, 2);
      expect(t.total, 88.4);
    });

    test('and it is rounded to the sen', () {
      final t = offlineProblemTotals([
        reject(total: 0.1),
        reject(total: 0.2),
      ]);
      expect(t.total, 0.3);
    });

    test('nothing at all is nothing', () {
      final t = offlineProblemTotals(const []);
      expect(t.sales, 0);
      expect(t.total, 0);
    });
  });

  group('the line at the top', () {
    test('names the money and the count', () {
      expect(
        problemsHeadline((sales: 2, total: 88.4)),
        '2 sales worth RM 88.40 never landed.',
      );
    });

    test('one sale is said as one', () {
      expect(
        problemsHeadline((sales: 1, total: 42.5)),
        '1 sale worth RM 42.50 never landed.',
      );
    });

    test('and refused payloads that took nothing say so', () {
      // There are rows on the screen; none of them is a hole in the
      // takings, and saying "RM 0.00 never landed" would read as one.
      expect(problemsHeadline((sales: 0, total: 0)), 'Nothing took money.');
    });
  });
}
