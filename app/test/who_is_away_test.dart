import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/hr/who_is_away.dart';

Map<String, dynamic> row({
  required DateTime start,
  required DateTime end,
  String? contact,
  bool? hasContact,
}) => <String, dynamic>{
      'start_date': _iso(start),
      'end_date': _iso(end),
      'contact_while_away': contact,
      'has_contact': hasContact ?? (contact != null && contact.isNotEmpty),
    };

LeaveRequest request({
  required String status,
  required DateTime end,
  String? contact,
}) => LeaveRequest(
      id: 'r1',
      requestNo: 'LV-0001',
      startDate: end.subtract(const Duration(days: 2)),
      endDate: end,
      totalDays: 3,
      status: status,
      contactWhileAway: contact,
    );

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  // A fixed today, so the tests say the same thing in December as in
  // June. The absence descriptions are entirely about where today sits
  // relative to the two dates, so a wandering clock is the one thing
  // that would make them lie.
  final today = DateTime(2026, 6, 15);

  group('how an absence reads', () {
    test('leave still ahead is dated', () {
      expect(
        describeAbsence(
          row(start: DateTime(2026, 7, 1), end: DateTime(2026, 7, 10)),
          asAt: today,
        ),
        'Away from 01/07/2026',
      );
    });

    test('leave starting tomorrow says tomorrow', () {
      expect(
        describeAbsence(
          row(start: DateTime(2026, 6, 16), end: DateTime(2026, 6, 20)),
          asAt: today,
        ),
        'Away from tomorrow',
      );
    });

    test('leave under way is described by when it ends, not when it began',
        () {
      expect(
        describeAbsence(
          row(start: DateTime(2026, 6, 8), end: DateTime(2026, 6, 20)),
          asAt: today,
        ),
        'Away until 20/06/2026',
      );
    });

    test('the last day of leave says they are back tomorrow', () {
      expect(
        describeAbsence(
          row(start: DateTime(2026, 6, 10), end: today),
          asAt: today,
        ),
        'Back tomorrow',
      );
    });

    test('leave already over says so rather than claiming an absence', () {
      expect(
        describeAbsence(
          row(start: DateTime(2026, 6, 1), end: DateTime(2026, 6, 5)),
          asAt: today,
        ),
        'Back since 05/06/2026',
      );
    });

    test('a row with no dates does not throw', () {
      expect(
        describeAbsence(const {'start_date': null, 'end_date': null}),
        'Away',
      );
    });
  });

  group('the contact', () {
    test('is shown when there is one', () {
      expect(
        describeContact(row(
          start: today,
          end: today,
          contact: '+60 12-555 0101',
        )),
        '+60 12-555 0101',
      );
    });

    test('says so when there is not, rather than leaving a blank', () {
      final r = row(start: today, end: today);
      expect(describeContact(r), 'No contact given');
      expect(needsContact(r), isTrue);
    });

    test('is read off has_contact, not off the text', () {
      // The database stores a blank contact as null, so the two agree.
      // If a row ever arrives with '' in it, `has_contact` is the one
      // that decides — recomputing here is how the two drift apart.
      final r = row(start: today, end: today, contact: '', hasContact: false);
      expect(needsContact(r), isTrue);
      expect(describeContact(r), 'No contact given');
    });
  });

  group('when the contact may still be changed', () {
    // The same rule `update_leave_contact` enforces. The screen not
    // offering the button is a convenience; the refusal is the control,
    // and leave_requests.sql asserts it on the database side.
    test('a submitted request with the leave still ahead', () {
      expect(
        canEditContact(
          request(status: 'submitted', end: DateTime(2026, 7, 1)),
          asAt: today,
        ),
        isTrue,
      );
    });

    test('an approved request, which is the case that matters', () {
      expect(
        canEditContact(
          request(status: 'approved', end: DateTime(2026, 7, 1)),
          asAt: today,
        ),
        isTrue,
      );
    });

    test('the last day of the leave is still live', () {
      expect(
        canEditContact(request(status: 'approved', end: today), asAt: today),
        isTrue,
      );
    });

    test('leave that ended yesterday is not', () {
      expect(
        canEditContact(
          request(status: 'approved', end: DateTime(2026, 6, 14)),
          asAt: today,
        ),
        isFalse,
      );
    });

    test('a rejected or cancelled request is not an absence', () {
      for (final status in ['rejected', 'cancelled']) {
        expect(
          canEditContact(
            request(status: status, end: DateTime(2026, 7, 1)),
            asAt: today,
          ),
          isFalse,
          reason: '$status should not be editable',
        );
      }
    });
  });
}
