import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/secretarial/beneficial_owner_sheet.dart';
import 'package:iakauntan/src/features/secretarial/officer_sheet.dart';
import 'package:iakauntan/src/features/secretarial/person_editor.dart';

/// Putting somebody on a statutory register.
///
/// `corp_persons` and `corp_officers` have had tables, RLS, an audit
/// trigger and repository methods since `0061`, and until now nothing
/// called any of it: a secretary could read the s.57 register and had
/// no way to put a director on it.
///
/// What is pressed here is the shape of what gets written, because
/// three of the rules are silent when broken — nothing throws, nothing
/// turns red, and the register is simply wrong in a way that surfaces
/// only when SSM rejects a filing or an AMLA inspection asks.
void main() {
  group('what a person record is', () {
    test('a body corporate keeps no individual identifiers', () {
      // The failure this exists for: somebody types an NRIC, realises
      // the director is a company, flips the toggle, and saves. The
      // NRIC would otherwise still be there — one party with two
      // identifiers, which is the disagreement `corp_persons` is one
      // table to prevent.
      final v = personValues(
        kind: 'corporate',
        fullName: 'Kabeer Holdings Sdn Bhd',
        nric: '900101015555',
        passportNo: 'A1234567',
        passportCountry: 'Malaysia',
        nationality: 'Malaysian',
        dateOfBirth: DateTime(1990, 1, 1),
        gender: 'male',
        isResident: false,
        registrationNo: '201901030189',
        incorporatedIn: 'Malaysia',
      );

      expect(v['nric'], isNull);
      expect(v['passport_no'], isNull);
      expect(v['passport_country'], isNull);
      expect(v['nationality'], isNull);
      expect(v['date_of_birth'], isNull);
      expect(v['gender'], isNull);
      expect(v['registration_no'], '201901030189');
      expect(v['incorporated_in'], 'Malaysia');
      // Not null-able, and "ordinarily resident" is not a question a
      // company answers.
      expect(v['is_resident_in_malaysia'], true);
    });

    test('an individual keeps no company identifiers', () {
      final v = personValues(
        kind: 'individual',
        fullName: 'Nurul Huda binti Ismail',
        nric: '900101015555',
        registrationNo: '201901030189',
        incorporatedIn: 'Malaysia',
      );

      expect(v['nric'], '900101015555');
      expect(v['registration_no'], isNull);
      expect(v['incorporated_in'], isNull);
    });

    test('a director who is not resident is recorded as not resident', () {
      // s.196(4)(a) is checked against this column. Forcing it true for
      // an individual would make every company look compliant.
      final v = personValues(
        kind: 'individual',
        fullName: 'James Tan',
        isResident: false,
      );
      expect(v['is_resident_in_malaysia'], false);
    });

    test('dates go in as dates the database accepts', () {
      final v = personValues(
        kind: 'individual',
        fullName: 'Nurul',
        dateOfBirth: DateTime(1990, 1, 2),
        idVerifiedOn: DateTime(2026, 8, 28),
      );
      expect(v['date_of_birth'], '1990-01-02');
      expect(v['id_verified_on'], '2026-08-28');
    });
  });

  group('what an appointment is', () {
    final appointed = DateTime(2020, 3, 1);

    test('only a secretary carries a licence', () {
      // s.20G requires a licence of a secretary and of no other
      // officer. Somebody moved from secretary to director keeping the
      // licence leaves `licenceLapsed` flagging an expiry at a company
      // that no longer needs one.
      final v = officerValues(
        entityId: 'e1',
        personId: 'p1',
        role: 'director',
        appointedOn: appointed,
        licenceNo: 'LS0001234',
        licenceBody: 'MAICSA',
        licenceExpiresOn: DateTime(2027, 1, 1),
      );

      expect(v['licence_no'], isNull);
      expect(v['licence_body'], isNull);
      expect(v['licence_expires_on'], isNull);
    });

    test('and a secretary keeps it', () {
      final v = officerValues(
        entityId: 'e1',
        personId: 'p1',
        role: 'secretary',
        appointedOn: appointed,
        licenceNo: 'LS0001234',
        licenceBody: 'MAICSA',
        licenceExpiresOn: DateTime(2027, 1, 1),
      );

      expect(v['licence_no'], 'LS0001234');
      expect(v['licence_body'], 'MAICSA');
      expect(v['licence_expires_on'], '2027-01-01');
    });

    test('a reason without a cessation is not a reason', () {
      // Typed, then the date cleared because the resignation turned out
      // not to have happened. Keeping the sentence leaves a note about
      // a resignation on somebody still in office.
      final v = officerValues(
        entityId: 'e1',
        personId: 'p1',
        role: 'director',
        appointedOn: appointed,
        cessationReason: 'Resigned',
      );

      expect(v['resigned_on'], isNull);
      expect(v['cessation_reason'], isNull);
    });

    test('a cessation carries its date and its reason', () {
      final v = officerValues(
        entityId: 'e1',
        personId: 'p1',
        role: 'director',
        appointedOn: appointed,
        resignedOn: DateTime(2026, 6, 30),
        cessationReason: 'Retired by rotation',
      );

      expect(v['resigned_on'], '2026-06-30');
      expect(v['cessation_reason'], 'Retired by rotation');
      expect(v['appointed_on'], '2020-03-01');
    });

    test('the paperwork dates are kept whatever the role', () {
      // s.201 consent and the s.198 declaration are asked of every
      // officer, unlike the licence, and `paperworkComplete` flags a
      // sitting director without them.
      final v = officerValues(
        entityId: 'e1',
        personId: 'p1',
        role: 'chairman',
        appointedOn: appointed,
        consentReceivedOn: DateTime(2020, 2, 28),
        declarationReceivedOn: DateTime(2020, 2, 28),
      );

      expect(v['consent_received_on'], '2020-02-28');
      expect(v['declaration_received_on'], '2020-02-28');
    });
  });

  beneficialOwners();

  group('the roles the register knows', () {
    test('every role in the enum has words', () {
      // `app.corp_officer_role`. A role missing here renders as its own
      // enum label, which is how "compliance_officer" ends up on a
      // printed register.
      for (final code in [
        'director',
        'alternate_director',
        'secretary',
        'auditor',
        'manager',
        'chairman',
        'ceo',
        'cfo',
        'partner',
        'compliance_officer',
      ]) {
        expect(officerRoles.containsKey(code), isTrue, reason: code);
        expect(officerRoleName(code), isNot(contains('_')), reason: code);
      }
    });

    test('only the secretary needs a licence', () {
      expect(roleNeedsLicence('secretary'), isTrue);
      for (final other in ['director', 'auditor', 'chairman', 'partner']) {
        expect(roleNeedsLicence(other), isFalse, reason: other);
      }
    });
  });
}

/// The register of beneficial owners.
///
/// `corp_beneficial_owners` has had a table, RLS, an audit trigger and
/// `saveCorpBeneficialOwner` since `0061`, and nothing called it. s.60B
/// has required the register since 1 April 2024, so a company using
/// this product could not keep a register it is obliged to keep.
void beneficialOwners() {
  group('what makes somebody a beneficial owner', () {
    test('a ground, and nothing else will do', () {
      // s.60B does not let a company simply nominate somebody. An entry
      // with nothing ticked and nothing written asserts that a person
      // controls the company for a reason nobody recorded, which is a
      // name rather than a register entry.
      expect(
        hasGround(
            shares: false, voting: false, directors: false, influence: false),
        isFalse,
      );
    });

    test('any one of the four is enough', () {
      for (var i = 0; i < 4; i++) {
        expect(
          hasGround(
            shares: i == 0,
            voting: i == 1,
            directors: i == 2,
            influence: i == 3,
          ),
          isTrue,
          reason: 'ground $i',
        );
      }
    });

    test('and so is some other ground, written down', () {
      // The Act's list is not closed. Control through an arrangement
      // counts, and the register records it in words.
      expect(
        hasGround(
          shares: false,
          voting: false,
          directors: false,
          influence: false,
          other: 'Controls the board through a shareholders agreement',
        ),
        isTrue,
      );
    });

    test('whitespace is not a ground', () {
      // The box is not empty, and nothing has been said.
      expect(
        hasGround(
          shares: false,
          voting: false,
          directors: false,
          influence: false,
          other: '   ',
        ),
        isFalse,
      );
    });
  });

  group('what an entry on the register is', () {
    test('a shareholding nobody recorded is null, not nought', () {
      // Zero is a claim -- "holds none of it". An unrecorded holding
      // that reads as a recorded nought is what an inspection finds and
      // the company cannot explain.
      final v = beneficialOwnerValues(
        entityId: 'e1',
        personId: 'p1',
        appointsDirectors: true,
      );
      expect(v['shareholding_percent'], isNull);
      expect(v.containsKey('shareholding_percent'), isTrue);
    });

    test('a percentage is parsed, and an impossible one is not', () {
      expect(percentOf('25'), 25);
      expect(percentOf(' 33.5 '), 33.5);
      expect(percentOf('0'), 0, reason: 'nought typed on purpose is nought');
      expect(percentOf(''), isNull);
      expect(percentOf('abc'), isNull);
      // `numeric(7,4)` would store this happily, and the register would
      // say somebody holds two thousand per cent of a company.
      expect(percentOf('2000'), isNull);
      expect(percentOf('-5'), isNull);
      expect(percentOf('100'), 100);
    });

    test('a reason without a cessation is not a reason', () {
      final v = beneficialOwnerValues(
        entityId: 'e1',
        personId: 'p1',
        holds20pcShares: true,
        cessationReason: 'Shares transferred',
      );
      expect(v['ceased_on'], isNull);
      expect(v['cessation_reason'], isNull);
    });

    test('a cessation carries its date and its reason', () {
      final v = beneficialOwnerValues(
        entityId: 'e1',
        personId: 'p1',
        holds20pcShares: true,
        ceasedOn: DateTime(2026, 7, 1),
        cessationReason: 'Shares transferred',
      );
      expect(v['ceased_on'], '2026-07-01');
      expect(v['cessation_reason'], 'Shares transferred');
    });

    test('amending an entry leaves the date it was entered alone', () {
      // `entered_on` is when the company first recorded this person.
      // Rewriting it on every amendment would restate the register's
      // own history each time somebody corrected a typo.
      final amend = beneficialOwnerValues(
        entityId: 'e1',
        personId: 'p1',
        holds20pcVoting: true,
      );
      expect(amend.containsKey('entered_on'), isFalse);

      final fresh = beneficialOwnerValues(
        entityId: 'e1',
        personId: 'p1',
        holds20pcVoting: true,
        enteredOn: DateTime(2026, 8, 29),
      );
      expect(fresh['entered_on'], '2026-08-29');
    });

    test('every ground the Act names reaches its own column', () {
      final v = beneficialOwnerValues(
        entityId: 'e1',
        personId: 'p1',
        holds20pcShares: true,
        holds20pcVoting: true,
        appointsDirectors: true,
        significantInfluence: true,
        otherControl: 'And an arrangement besides',
        shareholdingPercent: 42.5,
        notifiedOn: DateTime(2026, 8, 20),
      );
      expect(v['holds_20pc_shares'], true);
      expect(v['holds_20pc_voting'], true);
      expect(v['appoints_majority_directors'], true);
      expect(v['has_significant_influence'], true);
      expect(v['other_control'], 'And an arrangement besides');
      expect(v['shareholding_percent'], 42.5);
      expect(v['notified_on'], '2026-08-20');
    });

    test('an empty other ground is null rather than an empty string', () {
      final v = beneficialOwnerValues(
        entityId: 'e1',
        personId: 'p1',
        holds20pcShares: true,
        otherControl: '  ',
      );
      expect(v['other_control'], isNull);
    });
  });
}
