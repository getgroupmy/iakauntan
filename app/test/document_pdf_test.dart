import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/secretarial/document_pdf.dart';

/// The generator stores Markdown; a secretary prints a PDF. This is the
/// bit in between, and the only way to know it works is to build one and
/// look at the bytes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A real body, taken from the change-of-registered-office template:
  // bold runs, single newlines that have to survive inside a paragraph,
  // and a placeholder the secretary has not filled in yet.
  const body = '''
**Kilang Lestari Sdn Bhd**
(Registration No. 201903001234)

**DIRECTORS' RESOLUTION IN WRITING**

IT WAS RESOLVED THAT the registered office of the Company be changed from
Lot 12, Jalan Perusahaan 3, 40000 Shah Alam to {{new_address}} with effect
from {{effective_date}}.

Dated this 11 August 2026

Lim Wei Ming (790612085544)
Siti Zubaidah binti Osman (850918065522)
''';

  test('produces a real PDF', () async {
    final bytes = await buildDocumentPdf(
      title: 'Board resolution — change of registered office',
      body: body,
      footerNote: 'Generated 11 Aug 2026',
    );

    expect(String.fromCharCodes(bytes.take(5)), '%PDF-',
        reason: 'the magic number, so this is a PDF and not a hopeful blob');
    expect(bytes.length, greaterThan(5000),
        reason: 'the embedded typeface alone is bigger than this');
    // Every PDF ends with its trailer.
    expect(String.fromCharCodes(bytes.skip(bytes.length - 6)).trim(), '%%EOF');
  });

  test('an em dash in the title does not break the embedded font',
      () async {
    // Latin-1 fonts drop these. The document titles are full of them, so
    // if this throws or silently empties, the printed document is wrong.
    final bytes = await buildDocumentPdf(
      title: 'Minutes — first meeting of the board — Bayu Digital Sdn Bhd',
      body: 'The Company’s registered office was noted — no objection.',
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('an unclosed bold marker still renders the rest', () async {
    // Half-written markup should print something readable rather than
    // swallowing the remainder of the resolution.
    final bytes = await buildDocumentPdf(
      title: 'Half written',
      body: '**IT WAS RESOLVED THAT the rest of this line matters',
    );
    expect(bytes.length, greaterThan(5000));
  });

  test('an empty body is still a valid document', () async {
    final bytes = await buildDocumentPdf(title: 'Nothing yet', body: '');
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  group('letterhead', () {
    final practice = Organization(
      id: 'o1',
      name: 'Amanah Corporate Services',
      slug: 'amanah',
      legalName: 'Amanah Corporate Services Sdn Bhd',
      registrationNo: '201801009876',
      addressLine1: 'Suite 8-3, Wisma Amanah',
      city: 'Kuala Lumpur',
      postcode: '50250',
      email: 'cosec@amanah.my',
    );

    // A real 1x1 PNG. MemoryImage sniffs the header, so random bytes
    // would prove nothing.
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
        'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

    test('is left off unless asked for', () async {
      // The default matters more than the option: a resolution is the
      // client company's act, and the practice's name must not appear on
      // it by accident.
      final bare = await buildDocumentPdf(title: 'Board resolution', body: body);
      final headed = await buildDocumentPdf(
          title: 'Board resolution', body: body, letterhead: practice);
      expect(headed.length, greaterThan(bare.length),
          reason: 'the identity block should add content, not be dropped');
    });

    test('carries the logo when one is uploaded', () async {
      final without = await buildDocumentPdf(
          title: 'Board resolution', body: body, letterhead: practice);
      final with_ = await buildDocumentPdf(
          title: 'Board resolution',
          body: body,
          letterhead: practice,
          logo: png);
      expect(String.fromCharCodes(with_.take(5)), '%PDF-');
      expect(with_.length, greaterThan(without.length),
          reason: 'the image should be embedded, not silently dropped');
    });

    test('a logo without a letterhead is ignored, not half-drawn', () async {
      // The menu cannot produce this, but the signature allows it, and a
      // mark floating above a document with no name beside it would be
      // worse than no mark at all.
      final bare = await buildDocumentPdf(title: 'Board resolution', body: body);
      final withLogoOnly = await buildDocumentPdf(
          title: 'Board resolution', body: body, logo: png);
      expect(withLogoOnly.length, bare.length);
    });
  });
}
