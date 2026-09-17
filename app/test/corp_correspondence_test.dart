import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/corp_models.dart';
import 'package:iakauntan/src/features/secretarial/entity_editor.dart';

/// Who the Registrar writes to.
///
/// `corp_entities.correspondence_email` and `corp_entities.phone` have
/// been columns since `0061`, declared on the two lines after
/// `business_address`, and nothing ever asked for either. A secretary
/// kept both in the engagement letter, where the product cannot read
/// them — so a company whose form SSM queried had no contact on its own
/// file.
///
/// `correspondence_email` was found by the column sweep. `phone` was
/// NOT and could not have been: the sweep matches a column name as a
/// word across the whole tree, and `phone` appears in a hundred places
/// with nothing to do with this table. It was found by reading the row
/// beside the one the sweep reported.
void main() {
  group('the email shape is checked, because a typo fails silently', () {
    test('an ordinary address passes', () {
      expect(fieldProblem('secretary@firma.com.my', email: true), isNull);
      expect(fieldProblem('a.b+tag@sub.domain.co', email: true), isNull);
    });

    test('and an address with no domain does not', () {
      expect(
        fieldProblem('secretary@firma', email: true),
        contains('does not look like'),
      );
    });

    test('nor one with no @ at all', () {
      expect(fieldProblem('secretaryfirma.com.my', email: true), isNotNull);
    });

    test('nor one with a space in the middle', () {
      // What a paste out of a letter looks like.
      expect(fieldProblem('secretary @firma.com.my', email: true), isNotNull);
      expect(fieldProblem('secretary@firma .com.my', email: true), isNotNull);
    });

    test('and a sentence with an address in it is not an address', () {
      // What a paste out of an engagement letter actually looks like.
      // The regex is ANCHORED, and this is the case that proves it: an
      // unanchored one matches the address inside the sentence and
      // stores the sentence, so the notice is addressed to
      // "Write to secretary@firma.com.my please" and goes nowhere.
      //
      // A mutant that dropped the anchors survived the whole group
      // until this went in — 'secretary @firma.com.my' does not match
      // either way, because the character before the @ has to be a
      // non-space.
      expect(
        fieldProblem('Write to secretary@firma.com.my please', email: true),
        isNotNull,
      );
      expect(
        fieldProblem('Secretary <secretary@firma.com.my>', email: true),
        isNotNull,
      );
    });

    test('and a blank one is allowed, because most files have none', () {
      // Not every company on a secretary's list has given an address,
      // and refusing to save the rest of the form over it would be
      // this screen inventing a requirement the Registrar does not
      // have.
      expect(fieldProblem('', email: true), isNull);
      expect(fieldProblem('   ', email: true), isNull);
      expect(fieldProblem(null, email: true), isNull);
    });

    test('a required field still says so when it is empty', () {
      expect(fieldProblem('', required: true), 'Required');
      expect(fieldProblem('  ', required: true), 'Required');
      expect(fieldProblem('Nama Sdn Bhd', required: true), isNull);
    });

    test('and a field that is neither takes anything', () {
      // The phone box. Malaysian numbers are written a dozen ways —
      // +60, 03-, 013 — and a screen that refused one of them would
      // refuse a number that works.
      expect(fieldProblem('+60 3-2345 6789'), isNull);
      expect(fieldProblem('013-555 1234'), isNull);
      expect(fieldProblem('not a number at all'), isNull);
    });

    test('an email check is not applied unless it was asked for', () {
      // The same helper builds every box on the form. If the flag were
      // ignored, the registered office would have to look like an
      // email address.
      expect(fieldProblem('12, Jalan Ampang, Kuala Lumpur'), isNull);
    });
  });

  group('both columns reach the model', () {
    test('off the wire', () {
      final e = CorpEntity.fromJson({
        'id': 'c1',
        'name': 'Firma Sdn Bhd',
        'entity_type': 'sdn_bhd',
        'correspondence_email': 'secretary@firma.com.my',
        'phone': '+60 3-2345 6789',
      });

      expect(e.correspondenceEmail, 'secretary@firma.com.my');
      expect(e.phone, '+60 3-2345 6789');
    });

    test('and a row with neither says nothing rather than empty', () {
      // The entity screen prints an em dash for a missing one. An
      // empty string would print as blank space, which reads as a
      // field that failed to load.
      final e = CorpEntity.fromJson({
        'id': 'c1',
        'name': 'Firma Sdn Bhd',
        'entity_type': 'sdn_bhd',
      });

      expect(e.correspondenceEmail, isNull);
      expect(e.phone, isNull);
    });
  });
}
