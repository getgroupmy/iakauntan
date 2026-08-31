import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/theme.dart';
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

  group('what a cheque row claims', () {
    test('bad news for one that bounced', () {
      expect(chequeTone({'status': 'bounced', 'days_to_go': 30}), Tone.bad);
    });

    test('worth looking at for one that matured and is still sitting there',
        () {
      expect(chequeTone({'status': 'held', 'days_to_go': -1}), Tone.warn);
      expect(chequeTone({'status': 'deposited', 'days_to_go': -8}), Tone.warn);
    });

    test('and nothing for one whose day has not come', () {
      expect(chequeTone({'status': 'held', 'days_to_go': 0}), isNull);
      expect(chequeTone({'status': 'held', 'days_to_go': 14}), isNull);
    });

    test('a cheque that is finished is never late', () {
      // `days_to_go` goes on counting down after a cheque clears or is
      // handed back, and means nothing once it has. Colouring on it
      // would put a warning against a cheque nobody owes anything
      // about.
      expect(chequeTone({'status': 'cleared', 'days_to_go': -400}), isNull);
      expect(chequeTone({'status': 'cancelled', 'days_to_go': -400}), isNull);
      expect(chequeTone({'status': 'returned', 'days_to_go': -400}), isNull);
    });
  });

}
