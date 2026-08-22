import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/documents/cheques_screen.dart';

void main() {
  group('chequeDirection', () {
    test('says which way it goes', () {
      expect(chequeDirection('incoming'), 'We were given it');
      expect(chequeDirection('outgoing'), 'We wrote it');
    });
  });

  group('chequeWhen', () {
    test('counts down to maturity', () {
      expect(
        chequeWhen({'status': 'held', 'days_to_go': 45}),
        'Due in 45 days',
      );
      expect(chequeWhen({'status': 'held', 'days_to_go': 1}), 'Due in 1 day');
      expect(chequeWhen({'status': 'held', 'days_to_go': 0}), 'Due today');
    });

    test('and shouts about the one nobody banked', () {
      // "in -5 days" would bury the only line on this register that
      // needs somebody to do something today.
      expect(
        chequeWhen({'status': 'held', 'days_to_go': -5}),
        'Was due 5 days ago — not banked',
      );
      expect(
        chequeWhen({'status': 'deposited', 'days_to_go': -1}),
        'Was due 1 day ago — not banked',
      );
    });

    test('a finished cheque says what became of it, not a countdown', () {
      expect(chequeWhen({'status': 'cleared', 'days_to_go': -60}), 'Cleared');
      expect(chequeWhen({'status': 'bounced', 'days_to_go': -60}), 'Returned');
      expect(
        chequeWhen({'status': 'cancelled', 'days_to_go': 10}),
        'Handed back',
      );
    });
  });

  group('chequeSummary', () {
    test('names the party, the cheque and the bank', () {
      expect(
        chequeSummary({
          'party': 'A contractor',
          'cheque_no': '123456',
          'bank_name': 'CIMB',
          'cheque_date': '2026-10-15',
        }),
        'A contractor · no. 123456 · CIMB · 15/10/2026',
      );
    });

    test('and leaves the bank out when nobody wrote it down', () {
      expect(
        chequeSummary({
          'party': 'A contractor',
          'cheque_no': '123456',
          'cheque_date': '2026-10-15',
        }),
        'A contractor · no. 123456 · 15/10/2026',
      );
    });
  });

  group('chequeActions', () {
    test('a held cheque can go four ways', () {
      expect(chequeActions('held'), ['deposit', 'clear', 'bounce', 'cancel']);
    });

    test('one already paid in cannot be paid in again or handed back', () {
      // It is with the bank; there is nothing to hand back.
      expect(chequeActions('deposited'), ['clear', 'bounce']);
    });

    test('and a finished one can go nowhere', () {
      expect(chequeActions('cleared'), isEmpty);
      expect(chequeActions('bounced'), isEmpty);
      expect(chequeActions('cancelled'), isEmpty);
    });
  });
}
