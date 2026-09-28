import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/contacts/scanned_contact.dart';

/// What a read letterhead actually fills in.
///
/// `scan_target_fields` asks the reader for sixteen columns on
/// `contacts.contact`. Until now the contact form used six of them --
/// the typed properties on `OcrExtraction` -- and the other ten were
/// asked for on every scan, paid for, shown in the scan's own listing,
/// and then typed in again by hand off the same piece of paper.
///
/// These assert the two decisions in the mapping that are not obvious:
/// which of the two sources wins, and that the address comes from one
/// of them whole.
void main() {
  const states = [
    {'code': '10', 'name': 'Selangor'},
    {'code': '14', 'name': 'Wilayah Persekutuan Kuala Lumpur'},
    {'code': '07', 'name': 'Pulau Pinang'},
  ];

  test('the columns the reader answered reach the boxes', () {
    final filled = scannedContact(
      const OcrExtraction(
        supplierName: 'Kedai Runcit Maju',
        fields: {
          'name': 'Kedai Runcit Maju',
          'legal_name': 'Kedai Runcit Maju Sdn Bhd',
          'registration_no': '201901001234',
          'old_registration_no': '571389-H',
          'tin': 'C1234567890',
          'sst_registration_no': 'W10-1808-31000001',
          'email': 'akaun@maju.com.my',
          'phone': '03-7788 1234',
          'mobile': '012-345 6789',
        },
      ),
      states: states,
    );

    // The eight that had nowhere to go before are the point of this.
    expect(filled.boxes['legalName'], 'Kedai Runcit Maju Sdn Bhd');
    expect(filled.boxes['oldRegistrationNo'], '571389-H');
    expect(filled.boxes['sstNo'], 'W10-1808-31000001');
    expect(filled.boxes['mobile'], '012-345 6789');
    // And the ones that already worked still do.
    expect(filled.boxes['name'], 'Kedai Runcit Maju');
    expect(filled.boxes['registrationNo'], '201901001234');
    expect(filled.boxes['tin'], 'C1234567890');
    expect(filled.boxes['email'], 'akaun@maju.com.my');
    expect(filled.boxes['phone'], '03-7788 1234');
  });

  test('a reading with no columns fills exactly what it used to', () {
    // Every scan taken before `0681`, and every reader that answers in
    // prose rather than in columns. The typed properties are the
    // fallback and this is the whole of what they cover.
    final filled = scannedContact(
      OcrExtraction(
        supplierName: 'Syarikat Lama',
        supplierTaxId: 'C9998887776',
        supplierRegistrationNo: '199501000123',
        supplierEmail: 'lama@example.my',
        supplierPhone: '04-222 3333',
        supplierAddress: '12 Jalan Besar\nTaman Sri Muda\n40300 Shah Alam',
      ),
      states: states,
    );

    expect(filled.boxes['name'], 'Syarikat Lama');
    expect(filled.boxes['tin'], 'C9998887776');
    expect(filled.boxes['registrationNo'], '199501000123');
    expect(filled.boxes['email'], 'lama@example.my');
    expect(filled.boxes['phone'], '04-222 3333');
    expect(filled.boxes['address1'], '12 Jalan Besar');
    expect(filled.boxes['address2'], 'Taman Sri Muda, 40300 Shah Alam');
    expect(filled.boxes['postcode'], '40300');
    // Never guessed out of a printed block. `splitScannedAddress` says
    // why and this end must not undo it.
    expect(filled.boxes.containsKey('city'), isFalse);
    expect(filled.stateCode, isNull);
  });

  test('the reader wins over the parse where both answered', () {
    // `fields` is keyed by the destination's own columns because `0681`
    // handed the reader that list. The typed properties are what the
    // app made of the document afterwards. Where they disagree the
    // column the reader was asked for is the authoritative one.
    final filled = scannedContact(
      const OcrExtraction(
        supplierName: 'MAJU',
        supplierTaxId: 'WRONG',
        fields: {'name': 'Kedai Runcit Maju', 'tin': 'C1234567890'},
      ),
      states: states,
    );

    expect(filled.boxes['name'], 'Kedai Runcit Maju');
    expect(filled.boxes['tin'], 'C1234567890');
  });

  test('a column the reader left blank falls back to the parse', () {
    // "The tax number is not printed on this receipt" is a useful
    // answer, and it must not blank a field the parse did find.
    final filled = scannedContact(
      const OcrExtraction(
        supplierPhone: '03-7788 1234',
        fields: {'name': 'Kedai Runcit Maju', 'phone': '   '},
      ),
      states: states,
    );

    expect(filled.boxes['phone'], '03-7788 1234');
  });

  test('the address comes from the reader whole, three lines and all', () {
    final filled = scannedContact(
      const OcrExtraction(
        fields: {
          'address_line1': 'Lot 5, Jalan Industri 3',
          'address_line2': 'Kawasan Perindustrian Sri Muda',
          'address_line3': 'Seksyen 25',
          'postcode': '40400',
          'city': 'Shah Alam',
          'state_code': 'Selangor',
        },
      ),
      states: states,
    );

    expect(filled.boxes['address1'], 'Lot 5, Jalan Industri 3');
    // Two configured lines, one box. Joined rather than dropped: an
    // address that runs to three lines is an ordinary Malaysian
    // address, not a malformed one.
    expect(filled.boxes['address2'],
        'Kawasan Perindustrian Sri Muda, Seksyen 25');
    expect(filled.boxes['postcode'], '40400');
    // The city IS filled here, and only here: the reader named it.
    expect(filled.boxes['city'], 'Shah Alam');
    expect(filled.stateCode, '10');
  });

  test('a reader address is never mixed with a split one', () {
    // The decision worth asserting. This reading carries BOTH: columns
    // for the address, and a printed block that is a different address
    // entirely. Taking the postcode from one and the lines from the
    // other produces an address that is wrong and looks right.
    final filled = scannedContact(
      const OcrExtraction(
        supplierAddress: '99 Jalan Lain\nTaman Berbeza\n11900 Bayan Lepas',
        fields: {'address_line1': 'Lot 5, Jalan Industri 3'},
      ),
      states: states,
    );

    expect(filled.boxes['address1'], 'Lot 5, Jalan Industri 3');
    expect(filled.boxes.containsKey('postcode'), isFalse);
    expect(filled.boxes.containsKey('address2'), isFalse);
  });

  test('an address answered blank is not an answer', () {
    // The reader is asked every address column and says so when a
    // receipt does not print one. Blank answers must not count as "the
    // reader gave an address": that would take the reader's branch,
    // fill nothing, and throw away the address that IS printed on the
    // page -- a scan that got worse for having been asked more.
    final filled = scannedContact(
      const OcrExtraction(
        supplierAddress: '12 Jalan Besar\nTaman Sri Muda\n40300 Shah Alam',
        fields: {'address_line1': '   ', 'city': '', 'postcode': ' '},
      ),
      states: states,
    );

    expect(filled.boxes['address1'], '12 Jalan Besar');
    expect(filled.boxes['postcode'], '40300');
  });

  test('the state is accepted as a code as well as a name', () {
    // The column is called `state_code`, so a reader answers with
    // either depending on how literally it read the name.
    expect(
      scannedContact(const OcrExtraction(fields: {'state_code': '14'}),
              states: states)
          .stateCode,
      '14',
    );
    expect(
      scannedContact(
              const OcrExtraction(fields: {'state_code': 'Kuala Lumpur'}),
              states: states)
          .stateCode,
      '14',
    );
    // Google's spelling, which is not LHDN's. `stateCodeFor` carries
    // the alias table and this must go through it.
    expect(
      scannedContact(const OcrExtraction(fields: {'state_code': 'Penang'}),
              states: states)
          .stateCode,
      '07',
    );
  });

  test('a state nothing matches is left unset, not written through', () {
    // `state_code` is a foreign key into `ref_states`. A name written
    // into it is not a slightly wrong value, it is a save that fails at
    // the last step with a message about a constraint.
    expect(
      scannedContact(const OcrExtraction(fields: {'state_code': 'Singapore'}),
              states: states)
          .stateCode,
      isNull,
    );
    // And the same when the reference table could not be reached at
    // all, which is what the editor passes when `ref_states` fails.
    expect(
      scannedContact(const OcrExtraction(fields: {'state_code': 'Selangor'}))
          .stateCode,
      isNull,
    );
  });

  test('a column with no box does not become one', () {
    // `website` is asked for and is not on the `Contact` model. It must
    // not land in a box named after it -- `_c('website')` would make
    // one on the spot, and a controller nothing draws is a value
    // silently thrown away.
    final filled = scannedContact(
      const OcrExtraction(fields: {'website': 'https://maju.com.my'}),
      states: states,
    );

    expect(filled.boxes.containsKey('website'), isFalse);
    expect(filled.isEmpty, isTrue);
  });

  test('nothing read fills nothing', () {
    expect(scannedContact(null).isEmpty, isTrue);
    expect(scannedContact(const OcrExtraction()).isEmpty, isTrue);
  });
}
