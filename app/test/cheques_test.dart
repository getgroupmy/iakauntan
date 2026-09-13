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

    test(
      'worth looking at for one that matured and is still sitting there',
      () {
        expect(chequeTone({'status': 'held', 'days_to_go': -1}), Tone.warn);
        expect(
          chequeTone({'status': 'deposited', 'days_to_go': -8}),
          Tone.warn,
        );
      },
    );

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

  /// The worklist that sat behind the register for a year.
  ///
  /// `pdc_maturing` and `pdcMaturingProvider` both existed, the screen
  /// invalidated the provider after every action on a cheque, and
  /// nothing read it — so the only thing a shop saw was the whole
  /// register, cleared and bounced cheques among them, each with its
  /// own countdown. The cheque sitting in a drawer was one line of two
  /// hundred.
  ///
  /// What the database returns is `supabase/tests/post_dated_cheques.sql`'s
  /// business. What is asserted here is the sentence: the count, its
  /// verb, and — the part worth getting right — that the two directions
  /// are totalled apart.
  group('chequesToBankLine', () {
    Map<String, dynamic> cheque({
      String direction = 'incoming',
      String chequeDate = '2026-10-15',
      double amount = 1000,
      bool overdue = false,
    }) => {
      'id': 'c1',
      'pdc_no': 'PDC-0001',
      'direction': direction,
      'status': 'held',
      'party': 'Ahmad Trading',
      'cheque_no': '123456',
      'cheque_date': chequeDate,
      'amount': amount,
      'overdue': overdue,
    };

    test('nothing outstanding says nothing', () {
      expect(chequesToBankLine(const []), isNull);
    });

    test('one maturing is a note, not a warning', () {
      final line = chequesToBankLine([cheque(chequeDate: '2026-10-15')]);

      expect(line, isNotNull);
      expect(
        line!.tone,
        isNull,
        reason:
            'nothing here is late, so colouring it would put a '
            'warning against a cheque nobody has done anything wrong '
            'about',
      );
      expect(line.text, contains('One cheque is maturing'));
      expect(line.text, contains('15/10/2026'));
      expect(line.text, contains('1,000.00 to bank'));
    });

    test('several agree with their verb', () {
      final line = chequesToBankLine([
        cheque(chequeDate: '2026-10-15'),
        cheque(chequeDate: '2026-10-20'),
      ]);

      expect(line!.text, contains('2 cheques are maturing'));
      expect(line.text, isNot(contains('1 cheques')));
      // The nearest, not the last.
      expect(line.text, contains('15/10/2026'));
    });

    test('one past its date outranks everything still to come', () {
      final line = chequesToBankLine([
        cheque(chequeDate: '2026-08-31', overdue: true, amount: 2500),
        cheque(chequeDate: '2026-10-15', amount: 700),
      ]);

      expect(line!.tone, Tone.warn);
      expect(line.text, contains('One cheque is past its date'));
      // Only the late one is counted in the money: the sentence is
      // about what has gone wrong, not about the register.
      expect(line.text, contains('2,500.00'));
      expect(line.text, isNot(contains('3,200.00')));
    });

    test('the two directions are never added together', () {
      // A cheque we were given and have not banked is money not
      // collected. A cheque we wrote that nobody has presented is money
      // still in the account that somebody is entitled to take. One
      // figure covering both would be neither.
      final line = chequesToBankLine([
        cheque(overdue: true, amount: 2000),
        cheque(direction: 'outgoing', overdue: true, amount: 300),
      ]);

      expect(line!.text, contains('2,000.00 to bank'));
      expect(line.text, contains('300.00 we wrote and nobody has presented'));
      expect(line.text, isNot(contains('2,300.00')));
    });

    test('an outgoing-only list does not offer to bank RM 0.00', () {
      final line = chequesToBankLine([
        cheque(direction: 'outgoing', overdue: true, amount: 300),
      ]);

      expect(line!.text, isNot(contains('to bank')));
      expect(line.text, contains('RM 300.00 we wrote'));
    });
  });
}
