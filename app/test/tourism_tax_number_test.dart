import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/pdf_kit.dart';
import 'package:iakauntan/src/data/models.dart';

/// The other registration a tax invoice has to carry — 0642.
///
/// `organizations.tourism_tax_reg_no` has existed since `0001`, on the
/// line after `sst_registration_no`, and nothing had ever written to it
/// or read it: no form asked, no PDF printed it, no function returned
/// it. An operator registered under the Tourism Tax Act had nowhere in
/// this product to record the number RMCD issued.
void main() {
  Organization org({
    String? sst,
    bool sstRegistered = false,
    String? tourism,
  }) => Organization(
    id: 'o',
    name: 'Hotel Seri Malaysia Sdn Bhd',
    slug: 'hotel',
    registrationNo: '202401234567',
    tin: 'C12345678901',
    isSstRegistered: sstRegistered,
    sstRegistrationNo: sst,
    tourismTaxRegNo: tourism,
  );

  group('what prints under the company name', () {
    test('a registered operator carries its Tourism Tax number', () {
      expect(
        letterheadIds(org(tourism: 'TTX-0001234')),
        contains('TTx TTX-0001234'),
      );
    });

    test('and a company that is on neither register carries neither', () {
      final ids = letterheadIds(org());

      expect(ids, ['Reg. No. 202401234567', 'TIN C12345678901']);
    });

    test('the two registers are separate, so one does not gate the other', () {
      // RMCD's Tourism Tax register is not SST's. An accommodation
      // operator below the SST threshold is on one and not the other,
      // and gating this on `isSstRegistered` — which is how the SST
      // number is gated, correctly — would print nothing for exactly
      // the company the field exists for.
      final ids = letterheadIds(org(tourism: 'TTX-0001234'));

      expect(ids, contains('TTx TTX-0001234'));
      expect(ids.any((s) => s.startsWith('SST')), isFalse);
    });

    test('an SST number left behind by a deregistration does not print', () {
      // The flag beside it is the whole point: taking a company off the
      // register does not blank the column, and an old number on a new
      // invoice is a claim to charge tax the company may no longer
      // charge.
      final ids = letterheadIds(
        org(sst: 'W10-1808-32000123', sstRegistered: false),
      );

      expect(ids.any((s) => s.startsWith('SST')), isFalse);
    });

    test('and both print together, in the order the invoice reads', () {
      final ids = letterheadIds(
        org(
          sst: 'W10-1808-32000123',
          sstRegistered: true,
          tourism: 'TTX-0001234',
        ),
      );

      expect(ids, [
        'Reg. No. 202401234567',
        'TIN C12345678901',
        'SST W10-1808-32000123',
        'TTx TTX-0001234',
      ]);
    });

    test('a number that is only spaces is not a registration', () {
      // What an emptied text field sends. `_orNull` in the repository
      // turns it into a null column, but a row written before that and
      // a row imported from elsewhere can both hold whitespace.
      expect(letterheadIds(org(tourism: '   ')).length, 2);
    });
  });

  group('the column reaches the model', () {
    test('off the wire', () {
      expect(
        Organization.fromJson({
          'id': 'o',
          'name': 'Hotel',
          'tourism_tax_reg_no': 'TTX-0001234',
        }).tourismTaxRegNo,
        'TTX-0001234',
      );
    });

    test('and a row without the column is not a registration', () {
      expect(
        Organization.fromJson({'id': 'o', 'name': 'Hotel'}).tourismTaxRegNo,
        isNull,
      );
    });
  });
}
