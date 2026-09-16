import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/mia/mia_credential.dart';
import 'package:iakauntan/src/features/mia/mia_parser.dart';

/// Reading a row copied out of MIA's members and firms search.
///
/// The register renders an HTML table server-side, so a copied row
/// arrives tab-separated — and the Contact Details cell holds newlines,
/// which is the part that makes this more than a `split`.
///
/// Every example here is fictional. The register is somebody else's
/// list and none of it belongs in this repository.
void main() {
  const parser = MiaResultParser();

  group('a member row', () {
    const row = '12345\tTAN AH KOW\tCA\tSelangor\tYes';

    test('is read as a member', () {
      expect(parser.parse(row)!.kind, MiaKind.member);
    });

    test('with every column in the right box', () {
      final r = parser.parse(row)!;

      expect(r['member_no'], '12345');
      expect(r['member_name'], 'TAN AH KOW');
      expect(r['member_type'], 'CA');
      expect(r['state'], 'Selangor');
      expect(r['pc_holder'], 'true');
    });

    test('and a member without a practising certificate says so', () {
      // Not null, and not absent. "No" is an answer the register gave.
      final r = parser.parse('12345\tTAN AH KOW\tCA\tSelangor\tNo')!;

      expect(r['pc_holder'], 'false');
    });

    test('a category this app has not seen arrives as itself', () {
      // MIA has LA and AM besides CA. A parser that only knew the one
      // it had been shown would drop the others on the floor.
      expect(parser.parse('12345\tA B\tLA\tPerak\tYes')!['member_type'], 'LA');
      expect(parser.parse('12345\tA B\tAM\tPerak\tNo')!['member_type'], 'AM');
    });

    test('and one copied without its tabs is still read', () {
      // Out of a PDF, or retyped. The fallback pattern.
      final r = parser.parse('12345 TAN AH KOW CA Selangor Yes')!;

      expect(r.kind, MiaKind.member);
      expect(r['member_no'], '12345');
      expect(r['member_name'], 'TAN AH KOW');
      expect(r['state'], 'Selangor');
      expect(r['pc_holder'], 'true');
    });

    test('a state of more than one word survives the fallback', () {
      // The greedy/lazy trap: "WP Kuala Lumpur" is three words between
      // the type and the Yes.
      final r = parser.parse('12345 TAN AH KOW CA WP Kuala Lumpur Yes')!;

      expect(r['state'], 'WP Kuala Lumpur');
      expect(r['member_name'], 'TAN AH KOW');
    });
  });

  group('a firm row', () {
    const row = 'AF 1234\tABC & CO PLT\t'
        'LEVEL 3, MENARA XYZ, JALAN AMPANG, 50450 KUALA LUMPUR\t'
        'WP Kuala Lumpur\tMYR\t'
        'Tel: 60312345678\nFax: \nEmail: someone@abc.com.my\t'
        'www.abc.com.my';

    test('is read as a firm', () {
      expect(parser.parse(row)!.kind, MiaKind.firm);
    });

    test('with the contact block pulled apart', () {
      final r = parser.parse(row)!;

      expect(r['firm_no'], 'AF 1234');
      expect(r['firm_name'], 'ABC & CO PLT');
      expect(r['address'],
          'LEVEL 3, MENARA XYZ, JALAN AMPANG, 50450 KUALA LUMPUR');
      expect(r['state'], 'WP Kuala Lumpur');
      expect(r['tel'], '60312345678');
      expect(r['email'], 'someone@abc.com.my');
      expect(r['website'], 'www.abc.com.my');
    });

    test('and a blank line in it is blank, not the next line', () {
      // "Fax:" with nothing after it. Reading the e-mail into the fax
      // box is the shape of mistake that makes a record worse than none.
      expect(parser.parse(row)!['fax'], isNull);
    });

    test('the country column is not kept', () {
      // The register renders it as "MYR" — a currency code standing in
      // for a country, which means nothing either way.
      expect(parser.parse(row)!.fields.containsKey('country'), isFalse);
    });

    test('a firm number is normalised however it was written', () {
      for (final typed in ['AF 0759', 'AF0759', 'af 0759', 'af0759']) {
        final r = parser.parse('$typed\tSOME FIRM\t\tSelangor\tMYR\t\t')!;
        expect(r['firm_no'], 'AF 0759', reason: typed);
      }
    });

    test('and the block survives a paste that lost its tabs inside it',
        () {
      // The three contact lines arriving as their own cells, which is
      // what a paste through a plain-text field does. Indexing the
      // website by position would take the fax line instead.
      const split = 'AF 1234\tABC & CO PLT\tSOME ROAD\tSelangor\tMYR\t'
          'Tel: 60312345678\tFax: 60312345679\tEmail: a@b.my\t'
          'www.abc.com.my';
      final r = parser.parse(split)!;

      expect(r['tel'], '60312345678');
      expect(r['fax'], '60312345679');
      expect(r['email'], 'a@b.my');
      expect(r['website'], 'www.abc.com.my');
    });
  });

  group('what it will not guess at', () {
    // THE `, , ,` GUARD IS AN EQUIVALENT MUTANT and deleting it passes
    // this file. That is not a missing assertion: a row starting with a
    // comma matches neither the firm pattern nor the member one, so it
    // falls through to the same null either way. The guard is kept for
    // what it says — the empty row is a KNOWN shape, not an accident of
    // two patterns failing — and because the patterns are the sort of
    // thing that gets loosened later.
    test('the empty row a search with no result renders', () {
      // MIA still draws one row, with ", , ," for the address and
      // "Tel: Fax: Email:" for the contact block. It is not a
      // credential and must not become one.
      expect(parser.parse(', , ,\tTel: Fax: Email:'), isNull);
    });

    test('nothing at all', () {
      expect(parser.parse(''), isNull);
      expect(parser.parse('   \n  '), isNull);
    });

    test('and text that is neither', () {
      expect(parser.parse('No record found. Please contact Membership '
          'Department at 0327229000 for further confirmation.'), isNull);
      expect(parser.parse('Member No.\tMember\'s Name'), isNull);
    });
  });

  test('what was pasted is kept exactly', () {
    // The row goes into `raw_text` whatever was parsed out of it,
    // because an audit wants to see what the screen was shown.
    const row = '12345\tTAN AH KOW\tCA\tSelangor\tYes';

    expect(parser.parse(row)!.raw, row);
  });
}
