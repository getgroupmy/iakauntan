import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/legal/matter_conflicts.dart';

/// The form in front of `open_matter`.
///
/// The conflict rule is the database's — `0383` — and these assertions
/// are about the form agreeing with it, so a solicitor is not told the
/// file is fine and then refused.
void main() {
  MatterConflict c({
    String no = 'M-1',
    String status = 'open',
    String direction = 'we act for the other side',
    String? client = 'ABC Sdn Bhd',
    String? other = 'Delta Trading Sdn Bhd',
  }) =>
      MatterConflict(
        matterNo: no,
        matterName: 'A file',
        status: status,
        direction: direction,
        clientName: client,
        otherSide: other,
      );

  group('when a reason is required', () {
    test('never, where there is no conflict', () {
      expect(conflictNeedsNote(const []), isFalse);
      expect(
        matterBlockedBecause(
          name: 'Conveyancing',
          clientId: 'client-1',
          conflicts: const [],
          conflictNote: null,
        ),
        isNull,
      );
    });

    test('for an open file the firm is on the other side of', () {
      final why = matterBlockedBecause(
        name: 'Conveyancing',
        clientId: 'client-1',
        conflicts: [c()],
        conflictNote: null,
      );
      expect(why, contains('both sides'));
      expect(why, contains('1 open file'));
    });

    test('and for a closed one too', () {
      // The duty of confidence outlives the retainer, so a closed file
      // is a conflict of a different weight and not of none.
      final why = matterBlockedBecause(
        name: 'Conveyancing',
        clientId: 'client-1',
        conflicts: [c(status: 'closed')],
        conflictNote: null,
      );
      expect(why, contains('outlives the retainer'));
    });

    test('a written reason clears it', () {
      expect(
        matterBlockedBecause(
          name: 'Conveyancing',
          clientId: 'client-1',
          conflicts: [c()],
          conflictNote: 'Unrelated retainer; both consented in writing.',
        ),
        isNull,
      );
    });

    test('whitespace is not a reason', () {
      // A box somebody pressed space in to get past the screen is the
      // failure the note exists to prevent, and `open_matter` refuses
      // it too.
      expect(
        matterBlockedBecause(
          name: 'Conveyancing',
          clientId: 'client-1',
          conflicts: [c()],
          conflictNote: '   ',
        ),
        isNotNull,
      );
    });

    test('several open files are counted', () {
      final why = matterBlockedBecause(
        name: 'Conveyancing',
        clientId: 'client-1',
        conflicts: [c(), c(no: 'M-2'), c(no: 'M-3', status: 'closed')],
        conflictNote: null,
      );
      expect(why, contains('2 open files'));
    });
  });

  group('what the form will not send', () {
    test('a matter with no client', () {
      expect(
        matterBlockedBecause(
          name: 'Conveyancing',
          clientId: null,
          conflicts: const [],
          conflictNote: null,
        ),
        contains('for a client'),
      );
    });

    test('or no name', () {
      expect(
        matterBlockedBecause(
          name: '  ',
          clientId: 'client-1',
          conflicts: const [],
          conflictNote: null,
        ),
        contains('Name the matter'),
      );
    });
  });

  group('how a conflict reads', () {
    test('the two directions are not the same conversation', () {
      expect(describeConflict(c()), contains('we act for ABC Sdn Bhd'));
      expect(
        describeConflict(
            c(direction: 'we have acted against this client')),
        contains('we acted against Delta Trading Sdn Bhd'),
      );
    });

    test('and the file is named with its state', () {
      expect(describeConflict(c()), startsWith('M-1 · A file'));
      expect(describeConflict(c(status: 'closed')), endsWith('(closed)'));
      expect(describeConflict(c(status: 'on_hold')), endsWith('(open)'));
    });
  });
}
