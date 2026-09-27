import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/format.dart';
import 'package:iakauntan/src/features/feedback/attachment_picker.dart';
import 'package:iakauntan/src/features/feedback/file_drop.dart';

/// What the bug-report dialog will take, and what it says when it will
/// not.
///
/// The limits are enforced twice on purpose — here, and in `0660` by
/// `attach_feedback_file` and a CHECK on the row. These assertions are
/// about the FIRST copy, whose whole job is to say no before somebody
/// waits out a twelve-megabyte upload to be told by the server.
///
/// The dropping itself cannot be asserted here: it is browser events
/// on `web.document`, and there is no document in a widget test. What
/// can be asserted is every decision made about the files once they
/// arrive, which is where the mistakes are.
void main() {
  DroppedFile file(String name, int size) => DroppedFile(
        name: name,
        bytes: Uint8List(size),
      );

  group('what a file size reads as', () {
    test('bytes, kilobytes and megabytes', () {
      expect(Fmt.bytes(0), '0 B');
      expect(Fmt.bytes(512), '512 B');
      expect(Fmt.bytes(1024), '1 KB');
      expect(Fmt.bytes(2048), '2 KB');
      expect(Fmt.bytes(1024 * 1024), '1.0 MB');
      expect(Fmt.bytes(10 * 1024 * 1024), '10.0 MB');
    });

    test('binary units, because that is what the file manager shows', () {
      // 1,000,000 bytes is "1 MB" to a disk manufacturer and 977 KB to
      // every operating system this app runs on. The limit has to mean
      // the same thing here as in the Finder window the file came
      // from, or a 10 MB refusal reads as a lie.
      expect(Fmt.bytes(1000000), '977 KB');
    });
  });

  group('which files are taken', () {
    test('an ordinary screenshot is', () {
      expect(feedbackFileRefusal(file('shot.png', 40000), 0), isNull);
    });

    test('an empty one is not, and says so', () {
      final why = feedbackFileRefusal(file('empty.png', 0), 0);
      expect(why, isNotNull);
      expect(why, contains('empty.png'));
    });

    test('one over the limit is refused with both numbers', () {
      // Both, because "too big" without a size leaves somebody
      // guessing how much to crop.
      final why = feedbackFileRefusal(
          file('huge.png', maxFeedbackFileBytes + 1), 0);
      expect(why, isNotNull);
      expect(why, contains('huge.png'));
      expect(why, contains('10.0 MB'));
    });

    test('exactly the limit is allowed', () {
      // The boundary. `>` and `>=` differ by one file that the
      // database would have accepted.
      expect(
        feedbackFileRefusal(file('exact.png', maxFeedbackFileBytes), 0),
        isNull,
      );
    });

    test('the sixth is refused, and the fifth is not', () {
      expect(
        feedbackFileRefusal(file('fifth.png', 100), maxFeedbackFiles - 1),
        isNull,
      );
      final why =
          feedbackFileRefusal(file('sixth.png', 100), maxFeedbackFiles);
      expect(why, isNotNull);
      expect(why, contains('Remove one'));
    });

    test('the limits are the ones 0660 enforces', () {
      // If these drift from the migration, the dialog accepts a file
      // the server then refuses — after the upload, which is the worst
      // moment to find out.
      expect(maxFeedbackFiles, 5);
      expect(maxFeedbackFileBytes, 10485760);
    });
  });

  group('accepting a batch', () {
    test('takes what it can and reports the rest', () {
      // Somebody dragging four screenshots and a video wants the
      // screenshots. Refusing the whole drop because one file was too
      // big makes them drag the other four again.
      final outcome = AttachmentPicker.accept(const [], [
        file('a.png', 100),
        file('huge.mov', maxFeedbackFileBytes + 1),
        file('b.png', 100),
      ]);
      expect(outcome.kept.map((f) => f.name), ['a.png', 'b.png']);
      expect(outcome.refused, hasLength(1));
      expect(outcome.refused.first, contains('huge.mov'));
    });

    test('counts what is already there, not just the batch', () {
      // Four chosen and three dropped is seven, and the limit is five.
      final existing = [for (var i = 0; i < 4; i++) file('old$i.png', 10)];
      final outcome = AttachmentPicker.accept(existing, [
        file('new1.png', 10),
        file('new2.png', 10),
        file('new3.png', 10),
      ]);
      expect(outcome.kept, hasLength(maxFeedbackFiles));
      expect(outcome.refused, hasLength(2));
    });

    test('does not mutate the list it was given', () {
      // The caller holds this list in widget state and hands it
      // straight back through `onChanged`. Mutating it in place would
      // mean the new value and the old are the same object, and
      // `setState` would rebuild with a list Flutter believes is
      // unchanged.
      final existing = [file('kept.png', 10)];
      final before = List.of(existing);
      AttachmentPicker.accept(existing, [file('added.png', 10)]);
      expect(existing, before);
      expect(existing, hasLength(1));
    });

    test('an empty drop changes nothing', () {
      final existing = [file('kept.png', 10)];
      final outcome = AttachmentPicker.accept(existing, const []);
      expect(outcome.kept.map((f) => f.name), ['kept.png']);
      expect(outcome.refused, isEmpty);
    });
  });
}
