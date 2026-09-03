import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';

EinvoiceDocument doc({
  String status = 'valid',
  DateTime? deadline,
}) =>
    EinvoiceDocument(
      id: 'e1',
      internalDocNo: 'INV-1',
      status: status,
      typeCode: '01',
      issueDate: DateTime(2026, 3, 4),
      validatedAt: DateTime.now(),
      cancelDeadline: deadline,
    );

void main() {
  // LHDN allows a supplier to cancel a validated e-Invoice only inside
  // 72 hours; after that the correction is a credit note. The database
  // stamps the deadline and `myinvois/cancel` refuses a late request —
  // this getter is what decides whether the button is offered at all,
  // and it had no test. A getter reading `isBefore` where it means
  // `isAfter` would offer cancellation only once it had become
  // impossible.
  group('the 72-hour cancellation window', () {
    test('inside the window a valid document can be cancelled', () {
      final d = doc(deadline: DateTime.now().add(const Duration(hours: 5)));
      expect(d.canCancel, isTrue);
      expect(d.cancelWindowLeft!.inMinutes, greaterThan(0));
    });

    test('once it has closed it cannot', () {
      final d = doc(deadline: DateTime.now().subtract(const Duration(hours: 1)));
      expect(d.canCancel, isFalse);
      expect(d.cancelWindowLeft!.isNegative, isTrue);
    });

    // Only a validated invoice has a window at all: a submission still
    // in flight, or one LHDN rejected, is not something to cancel.
    test('a document that is not valid never can, deadline or not', () {
      final ahead = DateTime.now().add(const Duration(hours: 5));
      for (final s in ['draft', 'queued', 'submitted', 'invalid',
                       'cancelled', 'rejected', 'failed']) {
        expect(doc(status: s, deadline: ahead).canCancel, isFalse,
            reason: '$s should not offer cancellation');
      }
    });

    test('and neither can one with no deadline recorded', () {
      expect(doc(deadline: null).canCancel, isFalse);
      expect(doc(deadline: null).cancelWindowLeft, isNull);
    });

    // The window is read from the deadline the database stamped, not
    // recomputed here — two clocks disagreeing about 72 hours is how a
    // button appears that the edge function then refuses.
    test('the window comes from the stored deadline', () {
      final stamped = DateTime.now().add(const Duration(hours: 71));
      final d = doc(deadline: stamped);
      expect(d.cancelDeadline, stamped);
      expect(d.cancelWindowLeft!.inHours, 70);
    });
  });
}
