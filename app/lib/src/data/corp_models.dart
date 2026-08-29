import '../core/format.dart';

/// Corporate secretarial records.
///
/// The subject here is a *client company* — one the firm acts as company
/// secretary for. It is deliberately not an organization: an
/// organization is a tenant with logins, and a client company is a
/// subject of record that may never sign in at all.
class CorpEntity {
  CorpEntity({
    required this.id,
    required this.name,
    required this.entityType,
    required this.status,
    this.registrationNo,
    this.oldRegistrationNo,
    this.incorporatedOn,
    this.fyeDay,
    this.fyeMonth,
    this.registeredOffice,
    this.businessAddress,
    this.natureOfBusiness,
    this.clientRef,
    this.isAuditExempt = false,
    this.hasConstitution = false,
    this.engagedOn,
    this.disengagedOn,
    this.notes,
  });

  final String id;
  final String name;
  final String entityType;
  final String status;
  final String? registrationNo;
  final String? oldRegistrationNo;
  final DateTime? incorporatedOn;
  final int? fyeDay;
  final int? fyeMonth;
  final String? registeredOffice;
  final String? businessAddress;
  final String? natureOfBusiness;
  final String? clientRef;
  final bool isAuditExempt;
  final bool hasConstitution;
  final DateTime? engagedOn;
  final DateTime? disengagedOn;
  final String? notes;

  /// Only public companies must hold an AGM — the 2016 Act removed the
  /// requirement for private companies entirely, and a screen that asks
  /// a Sdn Bhd about its AGM is a screen that teaches the wrong law.
  bool get mustHoldAgm => entityType == 'berhad' || entityType == 'clbg';

  bool get isActive => disengagedOn == null &&
      (status == 'incorporated' || status == 'dormant');

  String get typeLabel => switch (entityType) {
        'sdn_bhd' => 'Sdn Bhd',
        'berhad' => 'Berhad',
        'llp' => 'PLT',
        'sole_prop' => 'Sole proprietor',
        'partnership' => 'Partnership',
        'foreign' => 'Foreign company',
        'clbg' => 'Limited by guarantee',
        _ => Fmt.label(entityType),
      };

  String get fyeLabel => fyeMonth == null
      ? '—'
      : '${fyeDay ?? 31} ${Fmt.monthName(fyeMonth!)}';

  factory CorpEntity.fromJson(Map<String, dynamic> j) => CorpEntity(
        id: j['id'] as String,
        name: j['name']?.toString() ?? '',
        entityType: j['entity_type']?.toString() ?? 'sdn_bhd',
        status: j['status']?.toString() ?? 'incorporated',
        registrationNo: j['registration_no']?.toString(),
        oldRegistrationNo: j['old_registration_no']?.toString(),
        incorporatedOn: Fmt.parseDate(j['incorporated_on']),
        fyeDay: j['financial_year_end_day'] == null
            ? null
            : Fmt.toInt(j['financial_year_end_day']),
        fyeMonth: j['financial_year_end_month'] == null
            ? null
            : Fmt.toInt(j['financial_year_end_month']),
        registeredOffice: j['registered_office']?.toString(),
        businessAddress: j['business_address']?.toString(),
        natureOfBusiness: j['nature_of_business']?.toString(),
        clientRef: j['client_ref']?.toString(),
        isAuditExempt: j['is_audit_exempt'] == true,
        hasConstitution: j['has_constitution'] == true,
        engagedOn: Fmt.parseDate(j['engaged_on']),
        disengagedOn: Fmt.parseDate(j['disengaged_on']),
        notes: j['notes']?.toString(),
      );
}

/// A person or body corporate, with the identification a secretary has
/// to hold. One record serves as officer, member and beneficial owner —
/// an NRIC kept in three places is an NRIC that will disagree with
/// itself.
class CorpPerson {
  CorpPerson({
    required this.id,
    required this.kind,
    required this.fullName,
    this.nric,
    this.passportNo,
    this.nationality,
    this.registrationNo,
    this.dateOfBirth,
    this.email,
    this.phone,
    this.address,
    this.isResident = true,
    this.idVerifiedOn,
    this.isPep = false,
    this.formerName,
    this.passportCountry,
    this.gender,
    this.incorporatedIn,
    this.line1,
    this.line2,
    this.city,
    this.postcode,
    this.stateCode,
    this.country,
    this.idDocumentType,
    this.kycNotes,
  });

  final String id;
  final String kind;
  final String fullName;
  final String? nric;
  final String? passportNo;
  final String? nationality;
  final String? registrationNo;
  final DateTime? dateOfBirth;
  final String? email;
  final String? phone;
  final String? address;
  final bool isResident;
  final DateTime? idVerifiedOn;
  final bool isPep;

  // The editable parts. `address` above is those four joined for
  // display; an editor needs them apart, because a person moves house
  // one line at a time and a joined string cannot be typed back into
  // the columns it came from.
  final String? formerName;
  final String? passportCountry;
  final String? gender;
  final String? incorporatedIn;
  final String? line1;
  final String? line2;
  final String? city;
  final String? postcode;
  final String? stateCode;
  final String? country;
  final String? idDocumentType;
  final String? kycNotes;

  bool get isCorporate => kind == 'corporate';

  /// What goes in brackets after the name on every statutory form.
  String? get identifier => isCorporate ? registrationNo : (nric ?? passportNo);

  bool get isVerified => idVerifiedOn != null;

  factory CorpPerson.fromJson(Map<String, dynamic> j) => CorpPerson(
        id: j['id'] as String,
        kind: j['kind']?.toString() ?? 'individual',
        fullName: j['full_name']?.toString() ?? '',
        nric: j['nric']?.toString(),
        passportNo: j['passport_no']?.toString(),
        nationality: j['nationality']?.toString(),
        registrationNo: j['registration_no']?.toString(),
        dateOfBirth: Fmt.parseDate(j['date_of_birth']),
        email: j['email']?.toString(),
        phone: j['phone']?.toString(),
        address: [
          j['address_line1'],
          j['address_line2'],
          j['postcode'],
          j['city'],
        ].where((p) => p != null && p.toString().isNotEmpty).join(', '),
        isResident: j['is_resident_in_malaysia'] != false,
        idVerifiedOn: Fmt.parseDate(j['id_verified_on']),
        isPep: j['is_pep'] == true,
        formerName: j['former_name']?.toString(),
        passportCountry: j['passport_country']?.toString(),
        gender: j['gender']?.toString(),
        incorporatedIn: j['incorporated_in']?.toString(),
        line1: j['address_line1']?.toString(),
        line2: j['address_line2']?.toString(),
        city: j['city']?.toString(),
        postcode: j['postcode']?.toString(),
        stateCode: j['state_code']?.toString(),
        country: j['country']?.toString(),
        idDocumentType: j['id_document_type']?.toString(),
        kycNotes: j['kyc_notes']?.toString(),
      );
}

class CorpOfficer {
  CorpOfficer({
    required this.id,
    required this.personId,
    required this.role,
    required this.appointedOn,
    required this.name,
    this.identifier,
    this.resignedOn,
    this.consentReceivedOn,
    this.declarationReceivedOn,
    this.licenceNo,
    this.licenceBody,
    this.licenceExpiresOn,
    this.isAlternate = false,
  });

  final String id;
  final String personId;
  final String role;
  final DateTime appointedOn;
  final String name;
  final String? identifier;
  final DateTime? resignedOn;
  final DateTime? consentReceivedOn;
  final DateTime? declarationReceivedOn;
  final String? licenceNo;
  final String? licenceBody;
  final DateTime? licenceExpiresOn;
  final bool isAlternate;

  bool get isCurrent => resignedOn == null;

  /// s.201 consent and the s.198 declaration. A secretary who cannot
  /// produce these for a sitting director has a real problem, so the
  /// screen says so rather than leaving two empty dates.
  bool get paperworkComplete =>
      role != 'director' ||
      (consentReceivedOn != null && declarationReceivedOn != null);

  /// A secretary must be a member of a prescribed body or hold a licence
  /// from the Registrar. An expired one is a company without a valid
  /// secretary.
  bool get licenceLapsed =>
      role == 'secretary' &&
      licenceExpiresOn != null &&
      licenceExpiresOn!.isBefore(DateTime.now());

  factory CorpOfficer.fromJson(Map<String, dynamic> j) {
    final p = j['corp_persons'];
    final person = p is Map ? Map<String, dynamic>.from(p) : const {};
    return CorpOfficer(
      id: j['id'] as String,
      personId: j['person_id'] as String,
      role: j['role']?.toString() ?? 'director',
      appointedOn: Fmt.parseDate(j['appointed_on']) ?? DateTime.now(),
      name: person['full_name']?.toString() ?? '',
      identifier: person['nric']?.toString() ??
          person['passport_no']?.toString() ??
          person['registration_no']?.toString(),
      resignedOn: Fmt.parseDate(j['resigned_on']),
      consentReceivedOn: Fmt.parseDate(j['consent_received_on']),
      declarationReceivedOn: Fmt.parseDate(j['declaration_received_on']),
      licenceNo: j['licence_no']?.toString(),
      licenceBody: j['licence_body']?.toString(),
      licenceExpiresOn: Fmt.parseDate(j['licence_expires_on']),
      isAlternate: j['is_alternate'] == true,
    );
  }
}

/// A position in the register of members, computed from the share
/// events rather than stored — the way the ledger computes balances
/// from journals.
class CorpMember {
  CorpMember({
    required this.personId,
    required this.name,
    required this.shareClass,
    required this.shares,
    required this.percent,
    this.nric,
    this.registrationNo,
    this.firstAcquired,
    this.lastMovement,
  });

  final String personId;
  final String name;
  final String shareClass;
  final double shares;
  final double percent;
  final String? nric;
  final String? registrationNo;
  final DateTime? firstAcquired;
  final DateTime? lastMovement;

  String? get identifier => nric ?? registrationNo;

  /// More than 20% is one of the statutory tests for a beneficial owner
  /// under s.60B, so the register flags it rather than leaving the
  /// secretary to eyeball percentages.
  bool get triggersBeneficialOwnership => percent > 20;

  factory CorpMember.fromJson(Map<String, dynamic> j) => CorpMember(
        personId: j['person_id'] as String,
        name: j['member_name']?.toString() ?? '',
        shareClass: j['share_class']?.toString() ?? '',
        shares: Fmt.toDouble(j['shares']),
        percent: Fmt.toDouble(j['percent']),
        nric: j['nric']?.toString(),
        registrationNo: j['registration_no']?.toString(),
        firstAcquired: Fmt.parseDate(j['first_acquired']),
        lastMovement: Fmt.parseDate(j['last_movement']),
      );
}

class CorpShareEvent {
  CorpShareEvent({
    required this.id,
    required this.eventType,
    required this.eventDate,
    required this.quantity,
    this.shareClass,
    this.fromName,
    this.toName,
    this.pricePerShare,
    this.totalConsideration,
    this.instrumentRef,
    this.certificateNo,
  });

  final String id;
  final String eventType;
  final DateTime eventDate;
  final double quantity;
  final String? shareClass;
  final String? fromName;
  final String? toName;
  final double? pricePerShare;
  final double? totalConsideration;
  final String? instrumentRef;
  final String? certificateNo;

  factory CorpShareEvent.fromJson(Map<String, dynamic> j) {
    String? nameOf(String key) {
      final v = j[key];
      return v is Map ? v['full_name']?.toString() : null;
    }

    final c = j['corp_share_classes'];
    return CorpShareEvent(
      id: j['id'] as String,
      eventType: j['event_type']?.toString() ?? 'allotment',
      eventDate: Fmt.parseDate(j['event_date']) ?? DateTime.now(),
      quantity: Fmt.toDouble(j['quantity']),
      shareClass: c is Map ? c['name']?.toString() : null,
      fromName: nameOf('from_person'),
      toName: nameOf('to_person'),
      pricePerShare: j['consideration_per_share'] == null
          ? null
          : Fmt.toDouble(j['consideration_per_share']),
      totalConsideration: j['total_consideration'] == null
          ? null
          : Fmt.toDouble(j['total_consideration']),
      instrumentRef: j['instrument_ref']?.toString(),
      certificateNo: j['certificate_no']?.toString(),
    );
  }
}

/// A filing SSM expects, with the section that imposes it.
class CorpFiling {
  CorpFiling({
    required this.entityId,
    required this.entityName,
    required this.filingType,
    required this.filingName,
    required this.statuteRef,
    required this.triggerDate,
    required this.dueDate,
    required this.status,
    this.legacyForm,
    this.periodLabel,
    this.filingId,
  });

  final String entityId;
  final String entityName;
  final String filingType;
  final String filingName;
  final String statuteRef;
  final DateTime triggerDate;
  final DateTime dueDate;
  final String status;
  final String? legacyForm;
  final String? periodLabel;
  final String? filingId;

  /// Days until this is due, counted in Malaysian days.
  ///
  /// Not the device's days. A statutory deadline under CA 2016 falls on
  /// a date in Malaysia whether the person looking at it is in Kuala
  /// Lumpur, London or on a plane, and 0305 pinned the server's half of
  /// this to `Asia/Kuala_Lumpur` for the same reason. A client that
  /// went on reading the device clock would disagree with the list it
  /// is labelling, which is the defect 0305 fixed wearing a different
  /// hat.
  ///
  /// The offset is hard-coded because Malaysia has had none of the
  /// complications a time zone database exists for: a fixed UTC+8 with
  /// no daylight saving since 1982. `toUtc()` first, so the arithmetic
  /// does not pass through the device's own offset on the way.
  static DateTime _malaysianToday() {
    final kl = DateTime.now().toUtc().add(const Duration(hours: 8));
    return DateTime(kl.year, kl.month, kl.day);
  }

  int get daysLeft => dueDate.difference(_malaysianToday()).inDays;

  bool get isOverdue => daysLeft < 0;
  bool get isUrgent => daysLeft >= 0 && daysLeft <= 14;

  factory CorpFiling.fromJson(Map<String, dynamic> j) => CorpFiling(
        entityId: j['entity_id'] as String,
        entityName: j['entity_name']?.toString() ?? '',
        filingType: j['filing_type']?.toString() ?? '',
        filingName: j['filing_name']?.toString() ?? '',
        statuteRef: j['statute_ref']?.toString() ?? '',
        triggerDate: Fmt.parseDate(j['trigger_date']) ?? DateTime.now(),
        dueDate: Fmt.parseDate(j['due_date']) ?? DateTime.now(),
        status: j['status']?.toString() ?? 'due',
        legacyForm: j['legacy_form']?.toString(),
        periodLabel: j['period_label']?.toString(),
        filingId: j['filing_id'] as String?,
      );
}

class CorpBeneficialOwner {
  CorpBeneficialOwner({
    required this.id,
    required this.personId,
    required this.name,
    this.identifier,
    this.percent,
    this.holds20pcShares = false,
    this.holds20pcVoting = false,
    this.appointsDirectors = false,
    this.significantInfluence = false,
    this.otherControl,
    this.notifiedOn,
    this.ceasedOn,
  });

  final String id;
  final String personId;
  final String name;
  final String? identifier;
  final double? percent;
  final bool holds20pcShares;
  final bool holds20pcVoting;
  final bool appointsDirectors;
  final bool significantInfluence;
  final String? otherControl;
  final DateTime? notifiedOn;
  final DateTime? ceasedOn;

  bool get isCurrent => ceasedOn == null;

  /// The statutory criteria that apply, in the Act's own words.
  List<String> get grounds => [
        if (holds20pcShares) 'Holds more than 20% of the shares',
        if (holds20pcVoting) 'Holds more than 20% of the voting shares',
        if (appointsDirectors) 'Can appoint or remove a majority of directors',
        if (significantInfluence) 'Has significant control or influence',
        if (otherControl != null && otherControl!.isNotEmpty) otherControl!,
      ];

  factory CorpBeneficialOwner.fromJson(Map<String, dynamic> j) {
    final p = j['corp_persons'];
    final person = p is Map ? Map<String, dynamic>.from(p) : const {};
    return CorpBeneficialOwner(
      id: j['id'] as String,
      personId: j['person_id'] as String,
      name: person['full_name']?.toString() ?? '',
      identifier: person['nric']?.toString() ??
          person['registration_no']?.toString(),
      percent: j['shareholding_percent'] == null
          ? null
          : Fmt.toDouble(j['shareholding_percent']),
      holds20pcShares: j['holds_20pc_shares'] == true,
      holds20pcVoting: j['holds_20pc_voting'] == true,
      appointsDirectors: j['appoints_majority_directors'] == true,
      significantInfluence: j['has_significant_influence'] == true,
      otherControl: j['other_control']?.toString(),
      notifiedOn: Fmt.parseDate(j['notified_on']),
      ceasedOn: Fmt.parseDate(j['ceased_on']),
    );
  }
}

class CorpCharge {
  CorpCharge({
    required this.id,
    required this.chargeeName,
    required this.createdOn,
    this.chargeNo,
    this.chargeType,
    this.registeredOn,
    this.amountSecured,
    this.propertyCharged,
    this.satisfiedOn,
  });

  final String id;
  final String chargeeName;
  final DateTime createdOn;
  final String? chargeNo;
  final String? chargeType;
  final DateTime? registeredOn;
  final double? amountSecured;
  final String? propertyCharged;
  final DateTime? satisfiedOn;

  bool get isSatisfied => satisfiedOn != null;

  /// s.352 gives thirty days from creation. Miss it and the charge is
  /// void against the liquidator, which is not a paperwork problem.
  DateTime get registrationDue => createdOn.add(const Duration(days: 30));
  bool get registrationLate =>
      registeredOn == null && DateTime.now().isAfter(registrationDue);

  factory CorpCharge.fromJson(Map<String, dynamic> j) => CorpCharge(
        id: j['id'] as String,
        chargeeName: j['chargee_name']?.toString() ?? '',
        createdOn: Fmt.parseDate(j['created_on']) ?? DateTime.now(),
        chargeNo: j['charge_no']?.toString(),
        chargeType: j['charge_type']?.toString(),
        registeredOn: Fmt.parseDate(j['registered_on']),
        amountSecured: j['amount_secured'] == null
            ? null
            : Fmt.toDouble(j['amount_secured']),
        propertyCharged: j['property_charged']?.toString(),
        satisfiedOn: Fmt.parseDate(j['satisfied_on']),
      );
}

class CorpTemplate {
  CorpTemplate({
    required this.code,
    required this.name,
    this.category,
    this.isOwn = false,
  });

  final String code;
  final String name;
  final String? category;
  final bool isOwn;

  factory CorpTemplate.fromJson(Map<String, dynamic> j) => CorpTemplate(
        code: j['code']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        category: j['category']?.toString(),
        isOwn: j['org_id'] != null,
      );
}

/// A placeholder in a template, and whether the register can fill it.
/// Shown before generating, so a missing registered office is caught
/// before the document is signed rather than after.
class CorpPlaceholder {
  CorpPlaceholder({
    required this.name,
    required this.isFilled,
    this.value,
  });

  final String name;
  final bool isFilled;
  final String? value;

  factory CorpPlaceholder.fromJson(Map<String, dynamic> j) => CorpPlaceholder(
        name: j['placeholder']?.toString() ?? '',
        isFilled: j['is_filled'] == true,
        value: j['value']?.toString(),
      );
}

class CorpDocument {
  CorpDocument({
    required this.id,
    required this.entityId,
    required this.title,
    required this.body,
    required this.generatedAt,
    this.templateCode,
  });

  final String id;
  final String entityId;
  final String title;
  final String body;
  final DateTime generatedAt;
  final String? templateCode;

  factory CorpDocument.fromJson(Map<String, dynamic> j) => CorpDocument(
        id: j['id'] as String,
        entityId: j['entity_id'] as String,
        title: j['title']?.toString() ?? '',
        body: j['body']?.toString() ?? '',
        generatedAt: Fmt.parseDate(j['generated_at']) ?? DateTime.now(),
        templateCode: j['template_code']?.toString(),
      );
}

/// One person's line on a signature request.
///
/// This is an electronic signature under the Electronic Commerce Act
/// 2006 — a recorded act of signing, attributable to a person — and not
/// a digital signature under the Digital Signature Act 1997, which needs
/// a certificate from a licensed certification authority.
///
/// [documentUnchanged] is recomputed on every read by hashing the
/// document as it stands now against the hash taken when the person
/// signed. A stored "verified" flag would be a claim about the past that
/// nothing keeps true.
class CorpSignature {
  CorpSignature({
    required this.id,
    required this.personName,
    required this.status,
    this.capacity,
    this.signedAt,
    this.signedName,
    this.documentUnchanged,
  });

  final String id;
  final String personName;
  final String status;
  final String? capacity;
  final DateTime? signedAt;
  final String? signedName;
  final bool? documentUnchanged;

  bool get isPending => status == 'pending';
  bool get isSigned => status == 'signed';

  /// Signed, but the text has moved since. The signature no longer
  /// vouches for what is on screen.
  bool get isStale => isSigned && documentUnchanged == false;

  factory CorpSignature.fromJson(Map<String, dynamic> j) => CorpSignature(
        id: j['signature_id'] as String,
        personName: j['person_name']?.toString() ?? '',
        status: j['status']?.toString() ?? 'pending',
        capacity: j['capacity']?.toString(),
        signedAt: Fmt.parseDate(j['signed_at']),
        signedName: j['signed_name']?.toString(),
        documentUnchanged: j['document_unchanged'] as bool?,
      );
}
