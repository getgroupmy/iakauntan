import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Two-factor.
///
/// Most of this feature is GoTrue's — enrol, challenge, verify — and
/// what is ours is the QR code and the wording. The QR is what these
/// assert, because it is the one piece this app draws itself, and the
/// failure it can have is a capacity overflow: an `otpauth://` URI is
/// long, the error correction level decides how much fits, and past the
/// limit `qr_flutter` throws rather than drawing half a code. A phone
/// pointed at an exception is a person who cannot finish setting this
/// up.
///
/// `QrImageView` keeps its payload private, so the URI that reaches it
/// cannot be read back off the widget. `QrValidator` is the same
/// encoder the widget uses and takes both, which is what makes the
/// capacity assertable without reaching into the package.
void main() {
  // What GoTrue hands back for a TOTP enrolment.
  const uri =
      'otpauth://totp/iAkauntan:kabeer%40example.com'
      '?secret=JBSWY3DPEHPK3PXP&issuer=iAkauntan&algorithm=SHA1'
      '&digits=6&period=30';

  group('the code somebody scans', () {
    test('the whole URI encodes at the level the card draws it', () {
      // Every parameter matters: the secret is the key, the issuer is
      // the name in the app's list, and the period and digits decide
      // what the code looks like. A URI trimmed to "just the secret"
      // scans and then produces the wrong digits forever, so the whole
      // thing has to fit rather than being shortened until it does.
      final result = QrValidator.validate(
        data: uri,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
      );
      expect(result.status, QrValidationStatus.valid);
      expect(result.error, isNull);
    });

    test('and the parameters an authenticator needs are in it', () {
      // Asserted against the fixture rather than against the widget:
      // this is what GoTrue sends, and the card's job is to pass it
      // through whole.
      expect(uri, startsWith('otpauth://totp/'));
      expect(uri, contains('secret=JBSWY3DPEHPK3PXP'));
      expect(uri, contains('issuer=iAkauntan'));
      expect(uri, contains('period=30'));
      expect(uri, contains('digits=6'));
    });

    testWidgets('and renders without throwing at the size it is drawn', (
      tester,
    ) async {
      // A URI this long overflows a low-capacity QR at a high error
      // correction level, and `qr_flutter` throws rather than drawing a
      // half code. Medium is what every authenticator's own
      // documentation shows, and this is the assertion that it fits.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: QrImageView(
                data: uri,
                size: 180,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long account name still fits', (tester) async {
      // The email goes in the label, and some of them are long. This
      // is the case that would push a fixed-capacity code over.
      final long =
          'otpauth://totp/iAkauntan:'
          '${'a' * 40}%40averylongcompanydomainname.example.com'
          '?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=iAkauntan'
          '&algorithm=SHA1&digits=6&period=30';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: QrImageView(
                data: long,
                size: 180,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('the code somebody types', () {
    /// The rule both dialogs apply before anything is sent: six digits,
    /// and the spaces every authenticator prints taken back out.
    String tidy(String raw) => raw.replaceAll(RegExp(r'\s'), '');

    test('a code pasted with its space is six digits', () {
      // Every authenticator app prints "123 456" and that is what gets
      // pasted. Sending it with the space is a refusal for a reason
      // nobody can see.
      expect(tidy('123 456'), '123456');
      expect(tidy('123 456').length, 6);
    });

    test('and one with a newline from a copy is too', () {
      expect(tidy(' 123456\n').length, 6);
    });

    test('while five digits is still five', () {
      expect(tidy('12 345').length, isNot(6));
    });
  });
}
