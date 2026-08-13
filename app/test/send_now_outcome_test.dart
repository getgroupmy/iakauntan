import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/documents/email_dialog.dart';

/// What the person who pressed Send now is told, and whether the dialog
/// gets out of the way.
///
/// Pure, and worth pinning: the mistake it exists to prevent is saying
/// "Sent" over a row that is merely queued. Whoever pressed the button
/// then tells a customer the invoice is on its way, and the two of them
/// discover otherwise at different times.
void main() {
  test('a row that actually sent says so, and finishes', () {
    final r = sendNowOutcome(
        {'status': 'sent', 'to_email': 'ap@buyer.example'});
    expect(r.message, contains('ap@buyer.example'));
    expect(r.message, startsWith('Sent'));
    expect(r.finished, isTrue);
    expect(r.error, isNull);
  });

  test('a refusal keeps the dialog open and repeats the reason', () {
    final r = sendNowOutcome({
      'status': 'failed',
      'last_error': 'The domain is not verified',
    });
    expect(r.finished, isFalse);
    expect(r.error, 'The domain is not verified');
    expect(r.message, contains('The domain is not verified'));
  });

  test('a refusal with no reason still says something usable', () {
    final r = sendNowOutcome({'status': 'failed'});
    expect(r.finished, isFalse);
    expect(r.error, isNotNull);
    expect(r.error, isNot(contains('null')));
  });

  // The case this whole function exists for. Send now queues the row and
  // then drains it; if the drain fails the row is untouched and still
  // going out on the schedule. Reporting that as "Sent" is the lie, and
  // reporting it as a failure would be the opposite one.
  test('a row still queued is neither sent nor failed', () {
    final r = sendNowOutcome({'status': 'queued'});
    expect(r.message, isNot(startsWith('Sent')));
    expect(r.message, contains('Queued'));
    expect(r.message, contains('next scheduled send'));
    expect(r.finished, isTrue);
    expect(r.error, isNull);
  });

  test('an unrecognised status is treated as queued, not as sent', () {
    // A status this build has never heard of is a row whose fate is
    // unknown. The safe reading is the one that does not claim delivery.
    final r = sendNowOutcome({'status': 'something_new'});
    expect(r.message, isNot(startsWith('Sent')));
    expect(r.error, isNull);
  });

  test('a row with no status at all does not claim delivery', () {
    final r = sendNowOutcome(const {});
    expect(r.message, isNot(startsWith('Sent')));
    expect(r.finished, isTrue);
  });
}
