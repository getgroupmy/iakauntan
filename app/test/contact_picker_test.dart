import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/contacts/new_contact_dialog.dart';

/// The rows every contact picker offers.
void main() {
  Contact c(String id, String code, String name) =>
      Contact(id: id, code: code, name: name, contactType: 'customer');

  test('a contact is named, with its code as the second line', () {
    final options = contactPickerOptions([c('c1', 'C-0001', 'Ramli')]);
    expect(options.single.value, 'c1');
    expect(options.single.label, 'Ramli');
    expect(options.single.sublabel, 'C-0001');
  });

  test('and is findable by the code somebody is reading off paper', () {
    // Half the people reaching for a customer have a document in front
    // of them; the other half remember the name.
    expect(contactPickerOptions([c('c1', 'C-0001', 'Ramli')]).single.keywords,
        contains('C-0001'));
  });

  test('a contact with no code shows no empty second line', () {
    // 0479 lets a code be blank until the series fills it in, and a
    // dash floating under a name reads as missing data.
    expect(contactPickerOptions([c('c1', '', 'Ramli')]).single.sublabel,
        isNull);
  });

  test('the order given is the order kept', () {
    // Which is the order the screen sorted them into — the picker's job
    // is to filter, not to re-sort.
    expect(
      contactPickerOptions([
        c('c1', 'C-0002', 'Bayu'),
        c('c2', 'C-0001', 'Ramli'),
      ]).map((o) => o.value),
      ['c1', 'c2'],
    );
  });
}
