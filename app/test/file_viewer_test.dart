// A document is shown in the app, not handed to another one.
//
// Asked for as "images or pdf files should not open using external
// browser or app, all should be in app only ... to avoid exposure of
// link and addresses".
//
// Four screens used to mint a SIGNED URL and call
// `launchUrl(..., LaunchMode.externalApplication)`. That puts a working
// link to a private document into a different application — its
// address bar, its history, whatever an extension can read — for the
// life of the signature, forwardable to anybody. On bank statements.
//
// `showFileInApp` takes the BYTES, so no URL is created at all. What is
// assertable here is the decision it makes about what it is looking at:
// a wrong answer draws a PDF's raw bytes as a broken image, or sends an
// image through a PDF renderer that refuses it.
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/shared/file_viewer.dart';

void main() {
  group('is it a PDF', () {
    test('the recorded type is believed first', () {
      expect(looksLikePdfFile('statement', 'application/pdf'), isTrue);
    });

    test('and an image is an image whatever it is called', () {
      // A phone camera producing `IMG_7621.PDF` is not a thing, but a
      // file named after the document it photographs is — and the type
      // the server recorded is the better answer either way.
      expect(looksLikePdfFile('my-pdf-receipt.jpg', 'image/jpeg'), isFalse);
      expect(looksLikePdfFile('scan.pdf', 'image/png'), isFalse);
    });

    test('the name decides when nothing recorded a type', () {
      // A browser that will not name a dropped file leaves `mime_type`
      // null, and the extension is then all there is. `0714` made that
      // reachable: a file dropped on the window carries whatever the
      // browser says, which is sometimes nothing.
      expect(looksLikePdfFile('august-statement.pdf', null), isTrue);
      expect(looksLikePdfFile('AUGUST-STATEMENT.PDF', null), isTrue);
      expect(looksLikePdfFile('receipt.jpg', null), isFalse);
    });

    test('an empty type is not a type', () {
      // Which is what a browser gives for a file it does not recognise,
      // and it travels into `mime_type` as a string that is not a MIME
      // type rather than as null.
      expect(looksLikePdfFile('august.pdf', ''), isTrue);
      expect(looksLikePdfFile('august.jpg', ''), isFalse);
    });

    test('and a file with no extension and no type is not a PDF', () {
      // Drawn as an image, which fails visibly, rather than sent to a
      // PDF renderer that throws — and on a phone the PDF branch
      // refuses outright, which would be the wrong sentence entirely.
      expect(looksLikePdfFile('scan', null), isFalse);
    });
  });
}
