import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/secretarial/beneficial_owner_sheet.dart';
import 'package:iakauntan/src/features/secretarial/charge_sheet.dart';
import 'package:iakauntan/src/features/secretarial/officer_sheet.dart';
import 'package:iakauntan/src/features/secretarial/person_editor.dart';
import 'package:iakauntan/src/features/secretarial/share_class_sheet.dart';
import 'package:iakauntan/src/features/secretarial/share_event_sheet.dart';

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
      );
      expect(v['date_of_birth'], '1990-01-02');
    });

    test('and the identity check is not one of them', () {
      // Customer due diligence is a record of an act by a person:
      // this document, seen by this individual, on this day. `0380`
      // writes all three together through `verify_person_identity`,
      // and a form that could still send the date on its own could
      // assert a check nobody carried out.
      final v = personValues(kind: 'individual', fullName: 'Nurul');
      expect(v.containsKey('id_verified_on'), isFalse);
      expect(v.containsKey('id_verified_by'), isFalse);
      expect(v.containsKey('id_document_type'), isFalse);
    });
  });

  group('who stands in for whom', () {
    final appointed = DateTime(2020, 3, 1);

    test('an alternate director names their principal', () {
      final v = officerValues(
        entityId: 'e1',
        personId: 'p1',
        role: 'alternate_director',
        appointedOn: appointed,
        alternateFor: 'officer-lim',
      );
      expect(v['alternate_for'], 'officer-lim');
    });

    test('and the form will not send one without', () {
      // s.208: an alternate votes in their principal's place and not as
      // well as them, so a board's quorum cannot be worked out from a
      // register that does not say whose place it was.
      expect(
        officerBlockedBecause(role: 'alternate_director'),
        contains('particular director'),
      );
      expect(
        officerBlockedBecause(
            role: 'alternate_director', alternateFor: 'officer-lim'),
        isNull,
      );
    });

    test('a role that stands in for nobody is not asked', () {
      // Asking a chairman whose place they act in invites an answer
      // that means nothing, and the register would then carry it.
      expect(roleStandsInForSomebody('chairman'), isFalse);
      expect(roleStandsInForSomebody('director'), isFalse);
      expect(roleStandsInForSomebody('alternate_director'), isTrue);
      expect(roleStandsInForSomebody('secretary'), isTrue);
      expect(officerBlockedBecause(role: 'director'), isNull);
    });

    test('and a principal set on one is dropped on the way out', () {
      // Somebody moved from alternate to director keeping a principal
      // would be a director standing in for another director, which
      // the register has no way to read.
      final v = officerValues(
        entityId: 'e1',
        personId: 'p1',
        role: 'director',
        appointedOn: appointed,
        alternateFor: 'officer-lim',
      );
      expect(v['alternate_for'], isNull);
    });

    test('and the flag is never sent at all', () {
      // `is_alternate` and the role said the same thing twice, set
      // independently by this screen. `0380` derives it from
      // `alternate_for`, so sending it would be the screen asserting
      // something it is not the authority on.
      final v = officerValues(
        entityId: 'e1',
        personId: 'p1',
        role: 'alternate_director',
        appointedOn: appointed,
        alternateFor: 'officer-lim',
      );
      expect(v.containsKey('is_alternate'), isFalse);
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
  charges();
  shares();

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

/// The register of charges.
///
/// `corp_charges` has had a table, RLS, an audit trigger and
/// `saveCorpCharge` since `0061` with nothing calling it, so a company
/// could not record a charge it must lodge within thirty days.
///
/// The thirty days are the reason this file exists at all. s.352 does
/// not impose a late fee: a charge not registered in time is **void
/// against the liquidator**, so the security a lender believes it holds
/// is absent at the only moment it is ever needed. That arithmetic had
/// no assertion anywhere until now.
void charges() {
  group('the thirty days (s.352)', () {
    test('run from the date of the instrument', () {
      expect(
        registrationDeadline(DateTime(2026, 8, 1)),
        DateTime(2026, 8, 31),
      );
      // Across a month boundary, and across February.
      expect(
        registrationDeadline(DateTime(2026, 2, 10)),
        DateTime(2026, 3, 12),
      );
    });

    test('thirty days, not a month', () {
      // A month would be 31 days from 1 August and 28 from 1 February.
      // The Act says thirty, and a charge lodged on day 31 in the
      // belief that "a month" was meant is void.
      final due = registrationDeadline(DateTime(2026, 8, 1));
      expect(due.difference(DateTime(2026, 8, 1)).inDays, 30);
    });

    test('a charge lodged inside the window is not overdue', () {
      expect(
        registrationOverdue(
          DateTime(2026, 8, 1),
          registeredOn: DateTime(2026, 8, 20),
          asAt: DateTime(2026, 12, 1),
        ),
        isFalse,
        reason: 'lodged in time stays in time however long ago it was',
      );
    });

    test('the last day is still in time', () {
      // Asked on the deadline itself: the thirty days have not yet run
      // out, and telling a secretary the charge is void on the morning
      // they can still lodge it is the worst possible moment to be
      // wrong by one day.
      expect(
        registrationOverdue(
          DateTime(2026, 8, 1),
          asAt: DateTime(2026, 8, 31),
        ),
        isFalse,
      );
    });

    test('the day after is not', () {
      expect(
        registrationOverdue(
          DateTime(2026, 8, 1),
          asAt: DateTime(2026, 9, 1),
        ),
        isTrue,
      );
    });
  });

  group('what a charge is', () {
    final created = DateTime(2026, 8, 1);

    test('an amount nobody recorded is null, not nought', () {
      // A charge securing an unrecorded amount is not a charge securing
      // nothing, and an all-monies debenture has no figure at all.
      expect(amountOf(''), isNull);
      expect(amountOf('   '), isNull);
      expect(amountOf('abc'), isNull);
      expect(amountOf('-1'), isNull);
      expect(amountOf('250000'), 250000);
      expect(amountOf('250,000.50'), 250000.5,
          reason: 'typed the way somebody reads it off an instrument');
    });

    test('a satisfaction cannot be filed for an unsatisfied charge', () {
      // The date was entered, then the satisfaction turned out not to
      // have happened. Keeping it leaves a memorandum of satisfaction
      // against a charge that is still outstanding, which is the one
      // thing on this register a chargee would litigate about.
      final v = chargeValues(
        entityId: 'e1',
        chargeeName: 'Maybank Berhad',
        createdOn: created,
        satisfactionFiledOn: DateTime(2026, 9, 1),
      );
      expect(v['satisfied_on'], isNull);
      expect(v['satisfaction_filed_on'], isNull);
    });

    test('and a satisfied one carries both dates', () {
      final v = chargeValues(
        entityId: 'e1',
        chargeeName: 'Maybank Berhad',
        createdOn: created,
        satisfiedOn: DateTime(2026, 9, 1),
        satisfactionFiledOn: DateTime(2026, 9, 8),
      );
      expect(v['satisfied_on'], '2026-09-01');
      expect(v['satisfaction_filed_on'], '2026-09-08');
    });

    test('the whole instrument reaches its own columns', () {
      final v = chargeValues(
        entityId: 'e1',
        chargeeName: '  Maybank Berhad  ',
        createdOn: created,
        chargeNo: 'C123456',
        chargeType: 'Fixed and floating',
        registeredOn: DateTime(2026, 8, 15),
        amountSecured: 250000,
        propertyCharged: 'The whole undertaking',
        ranking: 'First',
        notes: 'Facility agreement dated 30 July 2026',
      );
      expect(v['chargee_name'], 'Maybank Berhad', reason: 'trimmed');
      expect(v['created_on'], '2026-08-01');
      expect(v['registered_on'], '2026-08-15');
      expect(v['charge_no'], 'C123456');
      expect(v['charge_type'], 'Fixed and floating');
      expect(v['amount_secured'], 250000);
      expect(v['currency'], 'MYR');
      expect(v['property_charged'], 'The whole undertaking');
      expect(v['ranking'], 'First');
      expect(v['notes'], 'Facility agreement dated 30 July 2026');
    });

    test('boxes left empty are null rather than empty strings', () {
      final v = chargeValues(
        entityId: 'e1',
        chargeeName: 'Maybank Berhad',
        createdOn: created,
        chargeNo: '   ',
        propertyCharged: '',
        ranking: '  ',
        notes: '',
      );
      for (final k in ['charge_no', 'property_charged', 'ranking', 'notes']) {
        expect(v[k], isNull, reason: k);
      }
    });
  });
}

/// The register of members, and the movements it is computed from.
///
/// `corp_register_of_members` and the `check_share_event` trigger have
/// been in `0064` since the schema went in, and `supabase/tests/
/// secretarial.sql` already holds the arithmetic against them: who
/// gains the shares, who is left with what, the percentage, the issued
/// capital, and that nobody can transfer shares they do not hold.
///
/// What was missing was any way to put a movement in. These press the
/// Dart half — the shape sent to `corp_share_events`, whose party rules
/// are a CHECK constraint. Send the wrong shape and the insert is
/// refused with a sentence about `corp_share_events_parties_ck`, which
/// is true and no help to the person who typed it.
void shares() {
  group('which parties a movement has', () {
    test('an allotment has a transferee and no transferor', () {
      // The shares did not exist before an allotment, so there is
      // nobody to have held them.
      expect(eventHasFrom('allotment'), isFalse);
      expect(eventHasTo('allotment'), isTrue);
    });

    test('a cancellation has a transferor and no transferee', () {
      // And they do not exist after it.
      expect(eventHasFrom('cancellation'), isTrue);
      expect(eventHasTo('cancellation'), isFalse);
    });

    test('transfer, transmission and conversion have both', () {
      for (final t in ['transfer', 'transmission', 'conversion']) {
        expect(eventHasFrom(t), isTrue, reason: t);
        expect(eventHasTo(t), isTrue, reason: t);
      }
    });

    test('a transferor chosen and then the type changed is dropped', () {
      // The failure this exists for: a secretary starts a transfer,
      // picks the transferor, then realises it is an allotment and
      // changes the type. The transferor is still selected in the
      // dropdown, and sending it fails the CHECK constraint.
      final v = shareEventValues(
        entityId: 'e', shareClassId: 'c',
        eventType: 'allotment',
        eventDate: DateTime(2026, 3, 1),
        quantity: 1000,
        fromPersonId: 'seller',
        toPersonId: 'buyer',
      );
      expect(v['from_person_id'], isNull);
      expect(v['to_person_id'], 'buyer');
    });

    test('a transferee left over on a cancellation is dropped', () {
      final v = shareEventValues(
        entityId: 'e', shareClassId: 'c',
        eventType: 'cancellation',
        eventDate: DateTime(2026, 3, 1),
        quantity: 500,
        fromPersonId: 'holder',
        toPersonId: 'buyer',
      );
      expect(v['from_person_id'], 'holder');
      expect(v['to_person_id'], isNull);
    });
  });

  group('the consideration', () {
    test('a price a share times the quantity is the total', () {
      // What the s.78 return reports. Asking for it twice is asking two
      // fields to agree, and they will not: somebody who changes the
      // quantity does not revisit a total typed five fields ago.
      expect(considerationFor(1.50, 1000), 1500.00);
    });

    test('it is rounded to the sen, not left long', () {
      // 0.3333 a share on 3000 shares is 999.9 exactly, but 0.1 on
      // three shares is 0.30000000000000004 in binary floating point,
      // and total_consideration is numeric(18,2).
      expect(considerationFor(0.1, 3), 0.30);
      expect(considerationFor(1.0 / 3.0, 7), 2.33);
    });

    test('no price means no total, not zero', () {
      // Shares issued for a consideration other than cash have one
      // under s.78(2), and it is a sentence rather than a number. A
      // zero total would assert they were issued for nothing.
      expect(considerationFor(null, 1000), isNull);
      final v = shareEventValues(
        entityId: 'e', shareClassId: 'c',
        eventType: 'allotment',
        eventDate: DateTime(2026, 3, 1),
        quantity: 1000,
        toPersonId: 'buyer',
        isCash: false,
        considerationNote: 'Transfer of the Jalan Ampang premises',
      );
      expect(v['consideration_per_share'], isNull);
      expect(v['total_consideration'], isNull);
      expect(v['consideration_note'], 'Transfer of the Jalan Ampang premises');
    });

    test('a note typed and then the cash toggle flipped back is dropped', () {
      // s.78(2) wants to know what the consideration was when it was
      // not cash, and only then. A note left on a cash allotment says
      // the company took something it did not.
      final v = shareEventValues(
        entityId: 'e', shareClassId: 'c',
        eventType: 'allotment',
        eventDate: DateTime(2026, 3, 1),
        quantity: 1000,
        toPersonId: 'buyer',
        pricePerShare: 1.0,
        isCash: true,
        considerationNote: 'Transfer of the Jalan Ampang premises',
      );
      expect(v['consideration_note'], isNull);
      expect(v['total_consideration'], 1000.00);
    });
  });

  group('what belongs to a transfer only', () {
    test('Form 32A, the duty and the stamp certificate are kept', () {
      final v = shareEventValues(
        entityId: 'e', shareClassId: 'c',
        eventType: 'transfer',
        eventDate: DateTime(2026, 3, 1),
        quantity: 200,
        fromPersonId: 'seller',
        toPersonId: 'buyer',
        pricePerShare: 2.0,
        instrumentRef: '32A/2026/004',
        stampDuty: 1.20,
        stampCertificateNo: 'STMP-889',
      );
      expect(v['instrument_ref'], '32A/2026/004');
      expect(v['stamp_duty'], 1.20);
      expect(v['stamp_certificate_no'], 'STMP-889');
    });

    test('and dropped on every other kind of movement', () {
      // The failure this exists for: the sheet is reused for the next
      // movement and the instrument number carries over. An allotment
      // filed against Form 32A/2026/004 points at an instrument of
      // transfer that does not exist, and stamp duty on it asserts a
      // payment to the Collector that was never made.
      for (final t in ['allotment', 'transmission', 'cancellation',
                       'conversion']) {
        final v = shareEventValues(
          entityId: 'e', shareClassId: 'c',
          eventType: t,
          eventDate: DateTime(2026, 3, 1),
          quantity: 200,
          fromPersonId: eventHasFrom(t) ? 'seller' : null,
          toPersonId: eventHasTo(t) ? 'buyer' : null,
          instrumentRef: '32A/2026/004',
          stampDuty: 1.20,
          stampCertificateNo: 'STMP-889',
        );
        expect(v['instrument_ref'], isNull, reason: t);
        expect(v['stamp_duty'], isNull, reason: t);
        expect(v['stamp_certificate_no'], isNull, reason: t);
      }
    });
  });

  group('what a class of shares is', () {
    test('the code is upper case, because it is filed under', () {
      // `corp_share_classes` is unique on (entity_id, code). A class
      // entered as `ord` on one company and `ORD` on the next is two
      // names for one thing, and the uniqueness constraint will not
      // notice.
      final v = shareClassValues(
        entityId: 'e', code: '  ord ', name: 'Ordinary',
        currency: 'myr', votesPerShare: 1,
      );
      expect(v['code'], 'ORD');
      expect(v['currency'], 'MYR');
    });

    test('a blank name means the default, not a class with no name', () {
      final v = shareClassValues(
        entityId: 'e', code: 'ORD', name: '   ',
        currency: 'MYR', votesPerShare: 1,
      );
      expect(v['name'], 'Ordinary');
    });

    test('blank rights are null, not an empty string', () {
      final v = shareClassValues(
        entityId: 'e', code: 'ORD', name: 'Ordinary',
        currency: 'MYR', votesPerShare: 1, rights: '   ',
      );
      expect(v['rights'], isNull);
    });

    test('zero votes is a real answer', () {
      // A non-voting preference share is the ordinary case, not a
      // mistake. Refusing zero would make the class unrecordable.
      expect(votesOf('0'), 0);
      expect(votesOf('1.5'), 1.5);
    });

    test('negative votes and nonsense are refused', () {
      expect(votesOf('-1'), isNull);
      expect(votesOf(''), isNull);
      expect(votesOf('one'), isNull);
    });
  });
}
