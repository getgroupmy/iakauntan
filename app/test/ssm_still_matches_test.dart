import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/ssm_repository.dart';
import 'package:iakauntan/src/features/contacts/contact_editor.dart';

/// Whether the form still says what SSM's register said.
///
/// `contacts.ssm_verified_at` is a claim that somebody looked this
/// company up and the register answered. `set_contact_ssm_entity`
/// stamps it, and its own comment is blunt about what else it does:
/// "OVERWRITES THE NAME AND THE REGISTRATION NUMBER: that is the point
/// — the registry is the authority on both".
///
/// So this gate stands between a lookup and two consequences. A contact
/// that passes it when it should not carries a verification nobody
/// performed AND has its typed name replaced by the registry's.
///
/// The two directions do not cost the same:
///
///   * too EAGER records a check that did not happen, on a column whose
///     whole purpose is to say that it did;
///   * too SHY costs a second lookup and nothing else.
///
/// Every comparison here is therefore written to err shy, and the tests
/// below assert both sides of each one — an "it matches" case alone
/// passes against a function that returns true for everything, and a
/// "it does not" case alone passes against one that never stamps at all.
void main() {
  SsmEntity registry({
    String name = 'KABEER HOLDINGS SDN. BHD.',
    String? regNo = '201901030189',
  }) => SsmEntity(name: name, regNo: regNo);

  bool matches({
    SsmEntity? chosen,
    String name = 'KABEER HOLDINGS SDN. BHD.',
    String registrationNo = '201901030189',
  }) => ssmStillMatches(
    chosen: chosen ?? registry(),
    name: name,
    registrationNo: registrationNo,
  );

  group('nothing was looked up', () {
    test('so there is nothing to stamp', () {
      // The commonest case by far: most contacts are typed, never
      // looked up, and must not end up carrying `ssm_verified_at`.
      expect(
        ssmStillMatches(
          chosen: null,
          name: 'KABEER HOLDINGS SDN. BHD.',
          registrationNo: '201901030189',
        ),
        isFalse,
      );
    });
  });

  group('the form still says what the register said', () {
    test('untouched', () {
      expect(matches(), isTrue);
    });

    test('and case is not an edit', () {
      // The register SHOUTS. An operator tidying it to title case has
      // not contradicted it, and refusing here would mean nobody could
      // have a readable name and a verified one at the same time.
      expect(matches(name: 'Kabeer Holdings Sdn. Bhd.'), isTrue);
    });

    test('nor is room around it', () {
      expect(matches(name: '  KABEER HOLDINGS SDN. BHD.  '), isTrue);
      expect(matches(registrationNo: ' 201901030189 '), isTrue);
    });

    test('and a registry answer with no number matches an empty box', () {
      expect(
        matches(chosen: registry(regNo: null), registrationNo: ''),
        isTrue,
      );
      // The same thing written the other way by the parser. An empty
      // string and a null are one answer -- "the register gave no
      // number" -- and reading them as two refused a stamp that had
      // been earned.
      expect(matches(chosen: registry(regNo: ''), registrationNo: ''), isTrue);
      expect(
        matches(chosen: registry(regNo: '   '), registrationNo: '  '),
        isTrue,
      );
    });
  });

  group('the form no longer says it', () {
    test('a name corrected by hand stops the stamp', () {
      // The case the gate exists for, in the words of its own comment:
      // somebody looks a company up and then corrects the name.
      expect(matches(name: 'KABEER HOLDINGS BERHAD'), isFalse);
    });

    test('and so does a name merely added to', () {
      expect(matches(name: 'KABEER HOLDINGS SDN. BHD. (KL BRANCH)'), isFalse);
    });

    test('a space inside the name is a different name', () {
      // Not trimmed away: only the ends are. A double space in the
      // middle is text the register did not return, and this errs shy.
      expect(matches(name: 'KABEER  HOLDINGS SDN. BHD.'), isFalse);
    });

    test('one digit of the registration number is enough', () {
      expect(matches(registrationNo: '201901030180'), isFalse);
      expect(matches(registrationNo: '20190103018'), isFalse);
    });

    test('clearing the number stops it', () {
      expect(matches(registrationNo: ''), isFalse);
    });

    test('and typing one the register did not give stops it too', () {
      // The registry was silent about the number and somebody supplied
      // one from a letterhead. That is not the register's answer.
      expect(
        matches(chosen: registry(regNo: null), registrationNo: '201901030189'),
        isFalse,
      );
    });

    test('an emptied name stops it', () {
      expect(matches(name: ''), isFalse);
      expect(matches(name: '   '), isFalse);
    });
  });

  test('both halves have to hold, not either', () {
    // Asserted directly, because `&&` written as `||` passes every
    // single-field test above: each of those changes one field and
    // leaves the other matching.
    expect(matches(name: 'SOMETHING ELSE SDN. BHD.'), isFalse);
    expect(matches(registrationNo: '999999999999'), isFalse);
    expect(
      matches(name: 'SOMETHING ELSE SDN. BHD.', registrationNo: '999999999999'),
      isFalse,
    );
  });
}
