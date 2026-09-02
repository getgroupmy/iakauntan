import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/repository.dart';

/// Which series a contact is numbered in, by type.
///
/// The database decides the code -- `next_contact_code` draws it -- and
/// this prefix is the editor's copy of the same rule: it is what the
/// editor compares against to know whether the code in the field is
/// still the series' suggestion, and what the scanner falls back to
/// when the series cannot be reached. So it must agree with
/// `app.contact_series` in 0477, which `contact_records.sql` asserts.
void main() {
  test('a customer is C-, a supplier S-, a prospect P-', () {
    expect(Repo.contactCodePrefix('customer'), 'C-');
    expect(Repo.contactCodePrefix('supplier'), 'S-');
    expect(Repo.contactCodePrefix('prospect'), 'P-');
  });

  test('customer-and-supplier is numbered as a customer, as it always was', () {
    expect(Repo.contactCodePrefix('both'), 'C-');
  });

  test('and so is anything else', () {
    expect(Repo.contactCodePrefix('employee'), 'C-');
    expect(Repo.contactCodePrefix('other'), 'C-');
  });
}
