import 'package:flutter_test/flutter_test.dart';
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
