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
    return Repo.rows(await q.order('name')).map(CorpEntity.fromJson).toList();
  }

  Future<CorpEntity?> corpEntity(String id) async {
    final row =
        await client.from('corp_entities').select().eq('id', id).maybeSingle();
    return row == null
        ? null
        : CorpEntity.fromJson(Map<String, dynamic>.from(row));
  }

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
        .select('*, corp_persons(full_name, nric, passport_no, registration_no)')
        .eq('entity_id', entityId);
    if (!includeResigned) q = q.isFilter('resigned_on', null);
    return Repo.rows(await q.order('appointed_on', ascending: false))
        .map(CorpOfficer.fromJson)
        .toList();
  }

  Future<void> saveCorpOfficer(Map<String, dynamic> values, {String? id}) =>
      id == null
          ? client.from('corp_officers').insert({...values, 'org_id': orgId})
          : client.from('corp_officers').update(values).eq('id', id);

  Future<List<CorpPerson>> corpPersons() async => Repo.rows(await client
          .from('corp_persons')
          .select()
          .eq('org_id', orgId)
          .order('full_name'))
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
        .select('*, corp_share_classes(name), '
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
          .order('code'));

  Future<void> addCorpShareEvent(Map<String, dynamic> values) =>
      client.from('corp_share_events').insert({...values, 'org_id': orgId});

  // ------------------------------------------------------------------
  // Beneficial owners (s.60B) and charges (s.357)
  // ------------------------------------------------------------------
  Future<List<CorpBeneficialOwner>> corpBeneficialOwners(
          String entityId) async =>
      Repo.rows(await client
              .from('corp_beneficial_owners')
              .select('*, corp_persons(full_name, nric, registration_no)')
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

  Future<void> corpMarkLodged(String filingId,
          {required DateTime lodgedOn, String? reference}) =>
      client.from('corp_filings').update({
        'status': 'lodged',
        'lodged_on': Fmt.iso(lodgedOn),
        'ssm_reference': reference,
      }).eq('id', filingId);

  // ------------------------------------------------------------------
  // Documents
  // ------------------------------------------------------------------
  Future<List<CorpTemplate>> corpTemplates() async => Repo.rows(await client
          .from('corp_templates')
          .select('code, name, category, org_id')
          .eq('is_active', true)
          .order('category'))
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
  Future<void> corpSignDocument(String signatureId, String signedName) =>
      client.rpc('corp_sign_document',
          params: {'p_signature_id': signatureId, 'p_signed_name': signedName});
}
