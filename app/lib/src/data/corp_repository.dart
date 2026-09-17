import '../core/format.dart';
import 'corp_models.dart';
import 'repository.dart';

/// Corporate secretarial reads and writes.
///
/// Anything that has to agree with a lodged return — the register of
/// members, the deadlines, a generated document — comes from a database
/// function rather than being assembled here. A register the client can
/// compute two different ways will eventually compute it two different
/// ways.
extension RepoCorp on Repo {
  Future<List<CorpEntity>> corpEntities({bool includeClosed = false}) async {
    var q = client.from('corp_entities').select().eq('org_id', orgId);
    if (!includeClosed) q = q.isFilter('disengaged_on', null);
    return Repo.rows(await q.order('name', ascending: true)).map(CorpEntity.fromJson).toList();
  }

  Future<CorpEntity?> corpEntity(String id) async {
    final row =
        await client.from('corp_entities').select().eq('id', id).maybeSingle();
    return row == null
        ? null
        : CorpEntity.fromJson(Map<String, dynamic>.from(row));
  }

  /// Renaming a company, which is an event rather than an edit.
  ///
  /// `0377` refuses a bare rename: s.28 is lodged within fourteen days
  /// and s.28(4) puts the former name on the company's documents for
  /// twelve months, so both the old name and the date have to be kept.
  /// Returns the id of the filing it opened.
  Future<String> changeCompanyName(
    String entityId,
    String newName, {
    DateTime? resolvedOn,
  }) async => (await callRpc(
    'change_company_name',
    params: {
      'p_entity': entityId,
      'p_new_name': newName,
      'p_resolved_on': resolvedOn == null ? null : Fmt.iso(resolvedOn),
    },
  )).toString();

  /// The other door: the record catching up with what was always true.
  /// No former name, no filing, no clock.
  Future<void> correctCompanyName(String entityId, String name) => callRpc(
    'correct_company_name',
    params: {'p_entity': entityId, 'p_name': name},
  );

  /// Moving the registered office. Lodged under s.46(3) within fourteen
  /// days. Returns the filing it opened.
  Future<String> changeRegisteredOffice(
    String entityId,
    String address, {
    DateTime? effectiveOn,
  }) async => (await callRpc(
    'change_registered_office',
    params: {
      'p_entity': entityId,
      'p_address': address,
      'p_effective_on': effectiveOn == null ? null : Fmt.iso(effectiveOn),
    },
  )).toString();

  Future<void> correctRegisteredOffice(String entityId, String address) =>
      callRpc(
        'correct_registered_office',
        params: {'p_entity': entityId, 'p_address': address},
      );

  /// Adopting a constitution by special resolution under s.32(1); the
  /// copy is lodged within thirty days under s.32(3).
  Future<String> adoptConstitution(
    String entityId, {
    DateTime? adoptedOn,
  }) async => (await callRpc(
    'adopt_constitution',
    params: {
      'p_entity': entityId,
      'p_adopted_on': adoptedOn == null ? null : Fmt.iso(adoptedOn),
    },
  )).toString();

  Future<String> saveCorpEntity(Map<String, dynamic> values,
      {String? id}) async {
    if (id != null) {
      await client.from('corp_entities').update(values).eq('id', id);
      return id;
    }
    final row = await client
        .from('corp_entities')
        .insert({...values, 'org_id': orgId})
        .select('id')
        .single();
    return row['id'] as String;
  }

  // ------------------------------------------------------------------
  // Register of directors, managers and secretaries (s.57)
  // ------------------------------------------------------------------
  Future<List<CorpOfficer>> corpOfficers(String entityId,
      {bool includeResigned = true}) async {
    var q = client
        .from('corp_officers')
        // corp_persons is named because 0519 added a same-org
        // composite key alongside the plain one, so it can be joined
        // two ways and PostgREST refuses an unqualified embed.
        .select('*, corp_persons!corp_officers_person_id_fkey(full_name, nric, passport_no, '
            'registration_no), '
            // Whose place an alternate acts in, by name, because "acting
            // as an alternate" without one is what `0380` is about.
            'principal:corp_officers!corp_officers_alternate_for_fkey('
            'corp_persons(full_name))')
        .eq('entity_id', entityId);
    if (!includeResigned) q = q.isFilter('resigned_on', null);
    return Repo.rows(await q.order('appointed_on', ascending: false))
        .map(CorpOfficer.fromJson)
        .toList();
  }

  /// Who at this company can be stood in for: sitting officers who are
  /// not themselves standing in for somebody. From the database rather
  /// than filtered here, because the same list is what
  /// `app.corp_officer_alternate_guard` will accept.
  Future<List<Map<String, dynamic>>> corpPrincipalsForAlternate(
    String entityId, {
    String? exclude,
  }) async =>
      Repo.rows(await callRpc('corp_principals_for_alternate', params: {
        'p_entity': entityId,
        'p_exclude': exclude,
      }));

  /// Records a CDD check as what it is: this document, seen by this
  /// individual, on this day. `id_verified_by` is stamped from the
  /// session, which is why the date cannot be typed into the person
  /// editor any more.
  Future<void> verifyPersonIdentity(
    String personId, {
    required String documentType,
    DateTime? verifiedOn,
    String? notes,
  }) =>
      callRpc('verify_person_identity', params: {
        'p_person': personId,
        'p_document_type': documentType,
        'p_verified_on': verifiedOn == null ? null : Fmt.iso(verifiedOn),
        'p_notes': notes,
      });

  Future<void> unverifyPersonIdentity(String personId) =>
      callRpc('unverify_person_identity', params: {'p_person': personId});

  Future<void> saveCorpOfficer(Map<String, dynamic> values, {String? id}) =>
      id == null
          ? client.from('corp_officers').insert({...values, 'org_id': orgId})
          : client.from('corp_officers').update(values).eq('id', id);

  Future<List<CorpPerson>> corpPersons() async => Repo.rows(await client
          .from('corp_persons')
          .select()
          .eq('org_id', orgId)
          .order('full_name', ascending: true))
      .map(CorpPerson.fromJson)
      .toList();

  Future<String> saveCorpPerson(Map<String, dynamic> values,
      {String? id}) async {
    if (id != null) {
      await client.from('corp_persons').update(values).eq('id', id);
      return id;
    }
    final row = await client
        .from('corp_persons')
        .insert({...values, 'org_id': orgId})
        .select('id')
        .single();
    return row['id'] as String;
  }

  // ------------------------------------------------------------------
  // Shares
  // ------------------------------------------------------------------
  /// Positions, computed from the events by the database.
  Future<List<CorpMember>> corpRegisterOfMembers(String entityId) async {
    final rows = await client
        .rpc('corp_register_of_members', params: {'p_entity_id': entityId});
    return Repo.rows(rows).map(CorpMember.fromJson).toList();
  }

  Future<List<CorpShareEvent>> corpShareEvents(String entityId) async {
    final rows = await client
        .from('corp_share_events')
        // Named because 0521 added a same-org composite key alongside
        // the plain one, so 'corp_share_classes' can now be joined two ways and
        // PostgREST refuses an unqualified embed with PGRST201.
        .select('*, corp_share_classes!corp_share_events_share_class_id_fkey(name), '
            'from_person:corp_persons!corp_share_events_from_person_id_fkey(full_name), '
            'to_person:corp_persons!corp_share_events_to_person_id_fkey(full_name)')
        .eq('entity_id', entityId)
        .order('event_date', ascending: false);
    return Repo.rows(rows).map(CorpShareEvent.fromJson).toList();
  }

  Future<List<Map<String, dynamic>>> corpShareClasses(String entityId) async =>
      Repo.rows(await client
          .from('corp_share_classes')
          .select()
          .eq('entity_id', entityId)
          .order('code', ascending: true));

  /// A class of shares. Every movement points at one, so a company
  /// with none cannot allot anything -- which is why this is here and
  /// not only in a settings screen somebody has to find first.
  Future<void> saveCorpShareClass(Map<String, dynamic> values, {String? id}) =>
      id == null
          ? client
              .from('corp_share_classes')
              .insert({...values, 'org_id': orgId})
          : client.from('corp_share_classes').update(values).eq('id', id);

  /// Events are inserted and never amended.
  ///
  /// The register is computed from them the way the ledger computes
  /// balances from journals, and `0061` says why: a register that can
  /// be edited directly is one that will drift from the returns already
  /// lodged. A movement entered wrongly is corrected by a movement the
  /// other way, which is also what the paperwork does.
  Future<void> addCorpShareEvent(Map<String, dynamic> values) =>
      client.from('corp_share_events').insert({...values, 'org_id': orgId});

  // ------------------------------------------------------------------
  // Beneficial owners (s.60B) and charges (s.357)
  // ------------------------------------------------------------------
  Future<List<CorpBeneficialOwner>> corpBeneficialOwners(
          String entityId) async =>
      Repo.rows(await client
              .from('corp_beneficial_owners')
              // corp_persons is named because 0519 added a same-org
              // composite key alongside the plain one, so it can be
              // joined two ways and PostgREST refuses an unqualified
              // embed.
              .select('*, corp_persons!corp_beneficial_owners_person_id_fkey(full_name, nric, registration_no)')
              .eq('entity_id', entityId)
              .order('entered_on', ascending: false))
          .map(CorpBeneficialOwner.fromJson)
          .toList();

  Future<void> saveCorpBeneficialOwner(Map<String, dynamic> values,
          {String? id}) =>
      id == null
          ? client
              .from('corp_beneficial_owners')
              .insert({...values, 'org_id': orgId})
          : client.from('corp_beneficial_owners').update(values).eq('id', id);

  /// The resolutions a company has passed.
  ///
  /// `corp_resolutions` has been in 0062 since the corporate
  /// secretarial module was built, with three other tables pointing at
  /// it -- a filing, a share event and a generated document each carry
  /// a `resolution_id` -- and nothing in the app could read or write
  /// one. So an allotment could never name the board resolution that
  /// authorised it.
  Future<List<Map<String, dynamic>>> corpResolutions(String entityId) async =>
      Repo.rows(await client
          .from('corp_resolutions')
          .select()
          .eq('entity_id', entityId)
          .order('passed_on', ascending: false));

  Future<void> saveCorpResolution(
    Map<String, dynamic> values, {
    String? id,
  }) => id == null
      ? client.from('corp_resolutions').insert({...values, 'org_id': orgId})
      : client.from('corp_resolutions').update(values).eq('id', id);

  Future<void> deleteCorpResolution(String id) =>
      client.from('corp_resolutions').delete().eq('id', id);

  Future<List<CorpCharge>> corpCharges(String entityId) async =>
      Repo.rows(await client
              .from('corp_charges')
              .select()
              .eq('entity_id', entityId)
              .order('created_on', ascending: false))
          .map(CorpCharge.fromJson)
          .toList();

  Future<void> saveCorpCharge(Map<String, dynamic> values, {String? id}) =>
      id == null
          ? client.from('corp_charges').insert({...values, 'org_id': orgId})
          : client.from('corp_charges').update(values).eq('id', id);

  // ------------------------------------------------------------------
  // Deadlines and filings
  // ------------------------------------------------------------------
  /// Computed from the entity's own dates and the statutory periods, not
  /// stored — so a change in the law shows up immediately rather than in
  /// whatever was written down last year.
  Future<List<CorpFiling>> corpUpcomingFilings({int withinDays = 120}) async {
    final rows = await client.rpc('corp_upcoming_filings',
        params: {'p_org_id': orgId, 'p_within_days': withinDays});
    return Repo.rows(rows).map(CorpFiling.fromJson).toList();
  }

  Future<String> corpOpenFiling(
          String entityId, String filingType, DateTime triggerDate) async =>
      await client.rpc('corp_open_filing', params: {
        'p_entity_id': entityId,
        'p_filing_type': filingType,
        'p_trigger_date': Fmt.iso(triggerDate),
      }) as String;

  /// Records a lodgement.
  ///
  /// A function rather than a table update since `0378`: the only check
  /// this ever had — that the date is not in the future — lived here in
  /// Dart, and it now records who lodged it and what SSM charged, which
  /// nothing did.
  Future<void> corpMarkLodged(
    String filingId, {
    required DateTime lodgedOn,
    String? reference,
    num? feePaid,
  }) =>
      callRpc('corp_mark_lodged', params: {
        'p_filing': filingId,
        'p_lodged_on': Fmt.iso(lodgedOn),
        'p_reference': reference,
        'p_fee_paid': feePaid,
      });

  // ------------------------------------------------------------------
  // Documents
  // ------------------------------------------------------------------
  Future<List<CorpTemplate>> corpTemplates() async => Repo.rows(await client
          .from('corp_templates')
          .select('code, name, category, org_id')
          .eq('is_active', true)
          .order('category', ascending: true))
      .map(CorpTemplate.fromJson)
      .toList();

  /// What the template asks for, and what the register can answer.
  Future<List<CorpPlaceholder>> corpPlaceholders(
      String entityId, String templateCode) async {
    final rows = await client.rpc('corp_template_placeholders', params: {
      'p_entity_id': entityId,
      'p_template_code': templateCode,
    });
    return Repo.rows(rows).map(CorpPlaceholder.fromJson).toList();
  }

  Future<String> corpGenerateDocument(String entityId, String templateCode,
          {Map<String, dynamic> extra = const {}}) async =>
      await client.rpc('corp_generate_document', params: {
        'p_entity_id': entityId,
        'p_template_code': templateCode,
        'p_extra': extra,
      }) as String;

  /// Amends the text of a generated document.
  ///
  /// Generated text is a starting point, not a finished deed. The
  /// database refuses once anybody has signed it — enforced by a trigger
  /// rather than here, so going around this call does not go around the
  /// rule.
  Future<void> corpUpdateDocument(
          String documentId, String title, String body) async =>
      await client.rpc('corp_update_document', params: {
        'p_document_id': documentId,
        'p_title': title,
        'p_body': body,
      });

  Future<List<CorpDocument>> corpDocuments(String entityId) async =>
      Repo.rows(await client
              .from('corp_documents')
              .select()
              .eq('entity_id', entityId)
              .order('generated_at', ascending: false)
              .limit(50))
          .map(CorpDocument.fromJson)
          .toList();
}

/// Collecting signatures on a generated document.
extension RepoCorpSignatures on Repo {
  Future<List<CorpSignature>> corpSignatures(String documentId) async {
    final rows = await client
        .rpc('corp_signature_state', params: {'p_document_id': documentId});
    return Repo.rows(rows).map(CorpSignature.fromJson).toList();
  }

  Future<void> corpRequestSignatures(
    String documentId,
    List<String> personIds, {
    List<String>? capacities,
    DateTime? dueOn,
    String? note,
  }) =>
      client.rpc('corp_request_signatures', params: {
        'p_document_id': documentId,
        'p_person_ids': personIds,
        'p_capacities': capacities,
        'p_due_on': dueOn == null ? null : Fmt.iso(dueOn),
        'p_note': note,
      });

  /// The database records the time, the hash and the caller. Nothing
  /// about the evidence comes from here, because a signature record the
  /// signer can write is not evidence of anything.
  /// Refusing to sign, with the reason.
  ///
  /// `declined` has been in `app.signature_status` since `0069` and
  /// nothing could produce it, so a director who would not sign looked
  /// exactly like one who had not opened the email — and the difference
  /// is whether to chase or to redo the resolution.
  Future<void> corpDeclineSignature(String signatureId, String reason) =>
      callRpc(
        'corp_decline_signature',
        params: {'p_signature_id': signatureId, 'p_reason': reason},
      );

  Future<void> corpSignDocument(String signatureId, String signedName) =>
      client.rpc('corp_sign_document',
          params: {'p_signature_id': signatureId, 'p_signed_name': signedName});
}

/// Signing links: a credential for somebody who has no account.
extension RepoCorpSigningLinks on Repo {
  /// Returns the raw token exactly once. The database stores only a
  /// hash, so this is the only moment the link can be produced — after
  /// this it can be recognised but never reconstructed.
  Future<String> corpCreateSigningLink(String signatureId,
          {int validDays = 14, String? email}) async =>
      await client.rpc('corp_create_signing_link', params: {
        'p_signature_id': signatureId,
        'p_valid_days': validDays,
        'p_email': email,
      }) as String;
}
