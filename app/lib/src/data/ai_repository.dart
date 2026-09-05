import 'repository.dart';

/// Which model answers, at whose expense, and with which key.
///
/// Until 0536 all three were a `const` in an edge function and a secret
/// in the deployment's environment. There was nowhere in the platform
/// console to key an API key in, no company could bring its own, and a
/// new model was a code change.
///
/// ## The key goes one way
///
/// Every call in here either sets a key or reads whether one is on
/// file. None of them reads a key back, because none of them can:
/// `platform_ai_providers` and `ai_status` have no column that could
/// carry one, and the only function that returns a key at all is
/// granted to the service role, which the app does not hold.
///
/// So a console that has lost the key cannot be shown it. That is the
/// intended answer — the fix is to paste a new one, which is also what
/// the provider's own console would tell you.
extension RepoAiProviders on Repo {
  /// Every provider, with whether a key is on file and when it was set.
  /// Platform staff only; the function refuses anybody else.
  Future<List<Map<String, dynamic>>> aiProviderCatalogue() async =>
      Repo.rows(await callRpc('platform_ai_providers'));

  /// The models on offer, whoever is asking. A catalogue with nothing
  /// private in it, so it is a plain table read rather than an RPC.
  Future<List<Map<String, dynamic>>> aiModels({String? provider}) async {
    var q = client
        .from('ai_models')
        .select(
          'id, provider_code, model_id, name, kind, is_free, '
          'context_tokens, notes, is_active, sort_order',
        );
    if (provider != null) q = q.eq('provider_code', provider);
    return Repo.rows(await q.order('sort_order').order('name'));
  }

  /// Every provider on offer, for a company choosing one. The catalogue
  /// again — the key columns are not in this table at all.
  Future<List<Map<String, dynamic>>> aiProviders() async => Repo.rows(
    await client
        .from('ai_providers')
        .select(
          'code, name, wire, base_url, docs_url, key_hint, needs_key, '
          'is_active, sort_order',
        )
        .order('sort_order')
        .order('name'),
  );

  Future<void> setPlatformAiKey(
    String provider,
    String apiKey, {
    String? baseUrl,
  }) async => await callRpc(
    'set_platform_ai_key',
    params: {
      'p_provider': provider,
      'p_api_key': apiKey,
      if (baseUrl != null) 'p_base_url': baseUrl,
    },
  );

  Future<void> clearPlatformAiKey(String provider) async =>
      await callRpc('clear_platform_ai_key', params: {'p_provider': provider});

  Future<void> setPlatformAiDefault(String provider, String model) async =>
      await callRpc(
        'set_platform_ai_default',
        params: {'p_provider': provider, 'p_model': model},
      );

  /// Adds a provider the catalogue does not list, or edits one.
  ///
  /// Unlike the OCR catalogue's setter this one is a plain upsert: every
  /// field is on the form, so an omission is a choice rather than an
  /// accident. The one thing it will not do is invent a code — a bad
  /// one is refused in a sentence rather than slugified into something
  /// nobody typed.
  Future<void> upsertAiProvider(
    String code, {
    required String name,
    required String wire,
    String? baseUrl,
    String? docsUrl,
    String? keyHint,
    bool needsKey = true,
    bool isActive = true,
    int sortOrder = 100,
  }) async => await callRpc(
    'upsert_ai_provider',
    params: {
      'p_code': code,
      'p_name': name,
      'p_wire': wire,
      'p_base_url': baseUrl,
      'p_docs_url': docsUrl,
      'p_key_hint': keyHint,
      'p_needs_key': needsKey,
      'p_is_active': isActive,
      'p_sort_order': sortOrder,
    },
  );

  /// Adds a model, or retires one.
  ///
  /// There is no delete. A model a company chose is named on its
  /// settings row, so it goes inactive and stops being offered rather
  /// than disappearing from under the choice somebody made.
  Future<void> upsertAiModel(
    String provider,
    String modelId, {
    required String name,
    String kind = 'chat',
    bool isFree = false,
    int? contextTokens,
    String? notes,
    bool isActive = true,
    int sortOrder = 100,
  }) async => await callRpc(
    'upsert_ai_model',
    params: {
      'p_provider': provider,
      'p_model_id': modelId,
      'p_name': name,
      'p_kind': kind,
      'p_is_free': isFree,
      'p_context_tokens': contextTokens,
      'p_notes': notes,
      'p_is_active': isActive,
      'p_sort_order': sortOrder,
    },
  );
}

/// One company's own assistant settings.
extension RepoAiSettings on Repo {
  /// Whether it is on, what it will call, and whether that call can be
  /// made. The last of those is the point: a settings screen exists to
  /// answer it, and without it an absent key is a runtime error in
  /// front of whoever asked a question.
  Future<Map<String, dynamic>> aiStatus(String orgId) async {
    final rows = Repo.rows(
      await callRpc('ai_status', params: {'p_org_id': orgId}),
    );
    return rows.isEmpty ? <String, dynamic>{} : rows.first;
  }

  /// A null provider and model mean "follow the platform", and keep
  /// following it when the platform changes its mind.
  Future<void> setAiSettings(
    String orgId, {
    required bool enabled,
    String? provider,
    String? model,
    String keySource = 'platform',
  }) async => await callRpc(
    'set_ai_settings',
    params: {
      'p_org_id': orgId,
      'p_enabled': enabled,
      'p_provider': provider,
      'p_model': model,
      'p_key_source': keySource,
    },
  );

  Future<void> setAiCredentials(
    String orgId,
    String provider,
    String apiKey, {
    String? baseUrl,
  }) async => await callRpc(
    'set_ai_credentials',
    params: {
      'p_org_id': orgId,
      'p_provider': provider,
      'p_api_key': apiKey,
      if (baseUrl != null) 'p_base_url': baseUrl,
    },
  );

  Future<void> clearAiCredentials(String orgId, String provider) async =>
      await callRpc(
        'clear_ai_credentials',
        params: {'p_org_id': orgId, 'p_provider': provider},
      );
}
