import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/features/team/audit_trail_card.dart';

/// Narrowing the change history. `0634`.
///
/// The trail is capped at 500 rows newest first, so "who changed the
/// bank details in March" was unanswerable once five hundred things had
/// happened since. Two things are asserted here, and both are about
/// what the screen SAYS rather than what it fetches:
///
///   * **an empty list means different things.** "Nothing recorded yet"
///     is wrong and discouraging when the truth is "nothing in March by
///     that person", and somebody who believes the first stops looking.
///   * **the button says the range.** Somebody has to be able to see
///     that the list in front of them is not everything.
void main() {
  group('clearing one filter is not clearing them all', () {
    // `null` is a value each of these can take, so `copyWith(actorId:
    // null)` has to mean "clear it" rather than "leave it" — which is
    // what the sentinel in `AuditFilter` is for, and what a plain
    // `??` implementation would get wrong.
    test('a filter set to null is cleared, not left alone', () {
      const filter = AuditFilter(actorId: 'someone');
      expect(filter.copyWith(actorId: null).actorId, isNull);
    });

    test('and the others survive it', () {
      final from = DateTime(2026, 3);
      final to = DateTime(2026, 3, 31);
      final filter = AuditFilter(actorId: 'someone', from: from, to: to);
      final cleared = filter.copyWith(actorId: null);
      expect(cleared.actorId, isNull);
      expect(cleared.from, from);
      expect(cleared.to, to);
    });

    test('an untouched field is untouched', () {
      const filter = AuditFilter(actorId: 'someone');
      expect(filter.copyWith(from: DateTime(2026, 3)).actorId, 'someone');
    });

    test('empty is empty, and one filter is not', () {
      expect(const AuditFilter().isEmpty, isTrue);
      expect(const AuditFilter(actorId: 'x').isEmpty, isFalse);
      expect(AuditFilter(from: DateTime(2026, 3)).isEmpty, isFalse);
      expect(AuditFilter(to: DateTime(2026, 3)).isEmpty, isFalse);
    });

    // The provider rebuilds on identity, so two equal filters must not
    // be two reads — and reading the trail WRITES a `sensitive_read`.
    test('two equal filters are one filter', () {
      expect(
        AuditFilter(actorId: 'x', from: DateTime(2026, 3)),
        AuditFilter(actorId: 'x', from: DateTime(2026, 3)),
      );
      expect(
        AuditFilter(actorId: 'x', from: DateTime(2026, 3)).hashCode,
        AuditFilter(actorId: 'x', from: DateTime(2026, 3)).hashCode,
      );
      expect(
        const AuditFilter(actorId: 'x'),
        isNot(const AuditFilter(actorId: 'y')),
      );
    });
  });

  group('what an empty list means', () {
    test('nothing at all is different from nothing matching', () {
      expect(
        auditTrailEmptyLine(const AuditFilter()),
        contains('Nothing recorded yet'),
      );
      final filtered = auditTrailEmptyLine(const AuditFilter(actorId: 'x'));
      expect(filtered, isNot(contains('Nothing recorded yet')));
      expect(filtered, contains('Nothing matches those filters'));
      // And says what to do about it, because the way out of an empty
      // filtered list is not obvious.
      expect(filtered, contains('Widen the dates'));
    });
  });

  group('what the date button says', () {
    test('nothing chosen says any date', () {
      expect(auditRangeLabel(const AuditFilter()), 'Any date');
    });

    test('a range says both ends', () {
      final label = auditRangeLabel(
        AuditFilter(from: DateTime(2026, 3), to: DateTime(2026, 3, 31)),
      );
      expect(label, contains('–'));
      expect(label, contains('2026'));
    });

    test('one end says which end it is', () {
      expect(
        auditRangeLabel(AuditFilter(from: DateTime(2026, 3))),
        startsWith('From '),
      );
      expect(
        auditRangeLabel(AuditFilter(to: DateTime(2026, 3, 31))),
        startsWith('To '),
      );
    });
  });
}
