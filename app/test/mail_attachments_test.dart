import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/mail/attachments.dart';

/// What an attachment reads as in the inbox.
///
/// The reason any of this exists is in `0354`: the ingest path dropped
/// every MIME part it did not recognise as text, so a supplier's PDF
/// invoice reached the covering note and stopped. Nothing said so —
/// which is why the assertions below lean on the difference between
/// "nothing was attached" and "we do not know", and refuse to let the
/// screen turn the second into the first.
void main() {
  group('how big it is', () {
    test('reads in the unit somebody would use', () {
      expect(sizeLabel(512), '512 B');
      expect(sizeLabel(2048), '2 KB');
      expect(sizeLabel(3 * 1024 * 1024), '3.0 MB');
    });

    test('and a size nobody recorded is nothing, not nought', () {
      // "0 B" is a claim about the file. A size the ingest path did not
      // record is not a file of no size.
      expect(sizeLabel(null), isNull);
      expect(sizeLabel(0), isNull);
      expect(sizeLabel(''), isNull);
      expect(sizeLabel('not a number'), isNull);
    });

    test('a number that arrived as text still counts', () {
      // PostgREST hands `bigint` back as a string often enough that
      // parsing it is the difference between a size and no size.
      expect(sizeLabel('4096'), '4 KB');
    });
  });

  group('what it is', () {
    test('is taken from what the sender declared', () {
      expect(kindLabel(contentType: 'application/pdf', filename: 'x.pdf'), 'PDF');
      expect(kindLabel(contentType: 'image/jpeg', filename: 'x.jpg'), 'Image');
      expect(kindLabel(contentType: 'text/csv', filename: 'x.csv'),
          'Spreadsheet');
      expect(kindLabel(contentType: 'text/plain', filename: 'x.txt'), 'Text');
    });

    test('and the declaration beats the extension when they disagree', () {
      // A `.pdf` that arrived as `image/jpeg` is a photograph somebody
      // renamed. The sender's own header is the better evidence.
      expect(
        kindLabel(contentType: 'image/jpeg', filename: 'invoice.pdf'),
        'Image',
      );
    });

    test('the extension is the fallback, not the answer', () {
      expect(kindLabel(contentType: null, filename: 'invoice.pdf'), 'PDF');
      expect(kindLabel(contentType: '  ', filename: 'notes.docx'), 'DOCX');
    });

    test('and a file that says nothing at all still has a word', () {
      expect(kindLabel(contentType: null, filename: 'attachment'), 'File');
      expect(kindLabel(contentType: null, filename: '.hidden'), 'File');
      expect(kindLabel(contentType: null, filename: 'trailing.'), 'File');
    });
  });

  group('the line under the name', () {
    test('carries both when both are known', () {
      expect(
        attachmentLine({
          'filename': 'invoice-4471.pdf',
          'content_type': 'application/pdf',
          'size_bytes': 88123,
        }),
        'PDF · 86 KB',
      );
    });

    test('and leaves no stray separator when the size is not', () {
      // "PDF · " is the shape this avoids.
      expect(
        attachmentLine({
          'filename': 'invoice-4471.pdf',
          'content_type': 'application/pdf',
        }),
        'PDF',
      );
    });
  });

  group('the heading over them', () {
    test('counts, and counts one properly', () {
      expect(attachmentsHeading(1), '1 attachment');
      expect(attachmentsHeading(3), '3 attachments');
    });

    test('and says nothing at all when there is nothing', () {
      // A message with no attachments shows no section, rather than a
      // line announcing an absence — which on this screen would read as
      // a claim that the sender attached nothing, and that is exactly
      // the claim the old pipeline made falsely.
      expect(attachmentsHeading(0), isNull);
      expect(attachmentsHeading(-1), isNull);
    });
  });
}
