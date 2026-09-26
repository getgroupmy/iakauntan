import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/error_text.dart';
import '../core/providers.dart';

/// Asking SSM's register who a company actually is.
///
/// `contacts.registration_no` is a number somebody keyed off a
/// letterhead, and it is what MyInvois validates a party against: one
/// transposed digit is a submission LHDN rejects, or worse, attributes
/// to another company. A number that came back from a registry search
/// is a different kind of fact, and 0589 added `ssm_verified_at` so the
/// two can be told apart.
///
/// Everything here goes through the `ssm-search` edge function, which
/// holds the login and the cache. Nothing in this file knows a
/// credential, and there is no call that could return one: the
/// ssmsearch.com email and password are Supabase dashboard secrets,
/// like `OCR_KEY_*` and `RESEND_API_KEY`. That is why the console page
/// this feeds has no credential form — see `ssm_lookup_admin.dart`.
///
/// The interim provider reaches ssmsearch.com in a way their terms of
/// service prohibit, while the official SSM Corporate API is arranged.
/// `docs/ssm-lookup.md` says so where an operator will read it, and the
/// cache and the per-minute limit are part of keeping the volume
/// modest rather than optimisations to tune away.
class SsmLookupRepository {
  const SsmLookupRepository(this._ref);

  final Ref _ref;

  /// Searches the register by name or registration number.
  ///
  /// Three characters minimum, which the function enforces too — two
  /// finds half the register and is nobody's real search.
  Future<SsmSearchPage> search(
    String query, {
    int? typeId,
    int page = 1,
    int perPage = 20,
  }) async {
    final data = await _invoke({
      'action': 'search',
      'query': query,
      if (typeId != null) 'type_id': typeId,
      'page': page,
      'per_page': perPage,
    });
    return SsmSearchPage.fromJson(data);
  }

  /// The four kinds of entity SSM registers, for the filter.
  Future<List<SsmEntityType>> entityTypes() async {
    final data = await _invoke({'action': 'entity_types'});
    return [
      for (final row in (data['items'] as List?) ?? const [])
        if (row is Map) SsmEntityType.fromJson(Map<String, dynamic>.from(row)),
    ];
  }

  /// Writes what the registry answered onto a contact.
  ///
  /// The function overwrites the name and the registration number,
  /// because that is the point of having asked; it fills `id_value`
  /// only when the contact has none, because a TIN somebody entered
  /// deliberately for e-Invoice is not ours to replace. Stamps
  /// `ssm_verified_at`.
  Future<void> saveToContact(String contactId, SsmEntity entity) async {
    try {
      await _ref
          .read(supabaseProvider)
          .rpc(
            'set_contact_ssm_entity',
            params: {
              'p_contact': contactId,
              'p_name': entity.name,
              'p_reg_no': entity.regNo,
              'p_reg_no_old': entity.regNoOld,
              'p_entity_type': entity.entityType,
              'p_slug': entity.slug,
            },
          );
    } on PostgrestException catch (e) {
      // Re-thrown as the one exception type this feature raises, so a
      // caller that already handles a refused search does not need a
      // second catch for a refused save. `42501` is `can_write` saying
      // no, and it is the likely one.
      throw SsmLookupException(e.code ?? 'DB_ERROR', e.message, status: 400);
    }
  }

  // ---- platform staff only -------------------------------------------

  /// Whether the lookup is configured, and what the session looks like.
  Future<SsmStatus> status() async =>
      SsmStatus.fromJson(await _invoke({'action': 'status'}));

  /// Signs in for real and reports who as. The only way to find out
  /// whether a dashboard secret is the right one without waiting for a
  /// user's search to fail.
  Future<String?> testLogin() async {
    final data = await _invoke({'action': 'test_login'});
    final who = data['logged_in_as'];
    return who == null ? null : '$who';
  }

  /// Asks the provider which of a short list of paths are routes.
  ///
  /// Exists because the paths this shipped with were a guess and the
  /// first live sign-in proved them wrong. No credentials are sent —
  /// a login route answers an empty body with 422 or 401 and a path
  /// that is not a route answers 404, which is the whole distinction.
  Future<SsmProbe> probe() async =>
      SsmProbe.fromJson(await _invoke({'action': 'probe'}));

  /// Throws the held token away. The next search signs in again.
  Future<void> clearSession() => _invoke({'action': 'clear_session'});

  /// Empties the answer cache. A company that has just changed its name
  /// is the reason this exists.
  Future<void> clearCache() => _invoke({'action': 'clear_cache'});

  // ---- internals ------------------------------------------------------

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    try {
      final res = await _ref
          .read(supabaseProvider)
          .functions
          .invoke('ssm-search', body: body);
      final data = _asMap(res.data);
      if (res.status >= 400 || data['ok'] == false) {
        throw SsmLookupException.from(data, res.status);
      }
      return data;
    } on FunctionException catch (e) {
      // supabase_flutter throws rather than returning a 4xx, and the
      // function's own `{ error: { code, message } }` is on `details`.
      // Caught here and re-thrown as one exception type so no caller
      // has to know both shapes.
      throw SsmLookupException.from(_asMap(e.details), e.status);
    }
  }

  static Map<String, dynamic> _asMap(Object? v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    // A gateway error, or the function dying before it could answer in
    // JSON. Kept as a message rather than swallowed, because "the
    // registry is not answering" is something somebody can act on.
    if (v is String && v.trim().isNotEmpty) {
      return {
        'error': {'code': 'HTTP', 'message': v},
      };
    }
    return const {};
  }
}

final ssmLookupProvider = Provider<SsmLookupRepository>(
  SsmLookupRepository.new,
);

/// What the console asks for when it opens.
///
/// `autoDispose`, so leaving the page and coming back asks again rather
/// than showing a session state from ten minutes ago — the whole value
/// of the screen is that it is current.
final ssmStatusProvider = FutureProvider.autoDispose<SsmStatus>(
  (ref) => ref.watch(ssmLookupProvider).status(),
);

/// One entity as the register describes it.
class SsmEntity {
  const SsmEntity({
    required this.name,
    this.regNo,
    this.regNoOld,
    this.entityType,
    this.entityTypeId,
    this.slug,
  });

  /// The registered name, e.g. `KABEER HOLDINGS SDN. BHD.`
  final String name;

  /// The twelve-digit number issued since 2019, e.g. `201901030189`.
  final String? regNo;

  /// The older form, e.g. `1339519-K`. A letterhead usually shows both,
  /// and an older number already on file is still true.
  final String? regNoOld;

  /// Company, Business, Audit Firm or Limited Liability Partnership.
  final String? entityType;
  final int? entityTypeId;

  /// The registry's own handle for the entity, kept so a later lookup
  /// can go straight back to the same record.
  final String? slug;

  factory SsmEntity.fromJson(Map<String, dynamic> j) => SsmEntity(
    name: '${j['name'] ?? ''}'.trim(),
    regNo: _str(j['reg_no']),
    regNoOld: _str(j['reg_no_old']),
    entityType: _str(j['entity_type']),
    entityTypeId: _int(j['entity_type_id']),
    slug: _str(j['slug']),
  );

  /// `201901030189 (1339519-K)`, or whichever half is known.
  String get registrationDisplay {
    final parts = [
      if (regNo != null) regNo!,
      if (regNoOld != null) '($regNoOld)',
    ];
    return parts.isEmpty ? 'No registration number' : parts.join(' ');
  }
}

/// One row of the register's own list of entity kinds.
class SsmEntityType {
  const SsmEntityType(this.id, this.title);

  final int id;
  final String title;

  factory SsmEntityType.fromJson(Map<String, dynamic> j) =>
      SsmEntityType(_int(j['id']) ?? 0, '${j['title'] ?? ''}');
}

/// One page of matches.
class SsmSearchPage {
  const SsmSearchPage({
    required this.items,
    required this.total,
    required this.page,
    required this.perPage,
    required this.cached,
  });

  final List<SsmEntity> items;
  final int total;
  final int page;
  final int perPage;

  /// Answered from the cache rather than from the registry. Worth
  /// showing: it is why a search that just failed can suddenly succeed.
  final bool cached;

  bool get hasMore => page * perPage < total;

  factory SsmSearchPage.fromJson(Map<String, dynamic> j) => SsmSearchPage(
    items: [
      for (final row in (j['items'] as List?) ?? const [])
        if (row is Map) SsmEntity.fromJson(Map<String, dynamic>.from(row)),
    ],
    total: _int(j['total']) ?? 0,
    page: _int(j['page']) ?? 1,
    perPage: _int(j['per_page']) ?? 20,
    cached: j['cached'] == true,
  );
}

/// What the console shows about the lookup.
///
/// Deliberately has no credential on it. The function cannot return
/// one — it reads the dashboard secrets and answers whether they are
/// set, never what they are.
class SsmStatus {
  const SsmStatus({
    required this.configured,
    required this.cacheRows,
    required this.searches24h,
    this.chosenProvider = 'ssmsearch_web',
    this.provider,
    this.loggedInAs,
    this.loginUrl,
    this.searchUrl,
    this.obtainedAt,
    this.lastUsedAt,
    this.lastError,
    this.lastErrorAt,
  });

  /// Both dashboard secrets are set. False means every search answers
  /// "not set up yet" rather than failing.
  final bool configured;

  final int cacheRows;
  final int searches24h;

  /// Which of the two lookups `SSM_PROVIDER` has switched on:
  /// `ssmsearch_web` for the interim web session, `ssm_api` for SSM's
  /// own Search API.
  ///
  /// On the page because every other line means something different
  /// depending on the answer. A held session and a signed-in name
  /// belong to the web provider and are always empty under the API one,
  /// which has no session at all — so a console that did not say which
  /// was live would read as a broken lookup.
  final String chosenProvider;

  /// Whether the official API is the one answering searches.
  bool get onOfficialApi => chosenProvider == 'ssm_api';

  final String? provider;
  final String? loggedInAs;

  /// Where the function actually sends its requests.
  ///
  /// On the page because the defaults are a guess at ssmsearch.com's
  /// own API and each one is overridable by a dashboard secret -- so
  /// "which URL did it ask for" stops being answerable from the
  /// repository, and a failed sign-in raises it first.
  final String? loginUrl;
  final String? searchUrl;
  final DateTime? obtainedAt;
  final DateTime? lastUsedAt;
  final String? lastError;
  final DateTime? lastErrorAt;

  /// A token is held, so the next search does not have to sign in.
  bool get signedIn => obtainedAt != null;

  factory SsmStatus.fromJson(Map<String, dynamic> j) {
    final s = Map<String, dynamic>.from((j['session'] as Map?) ?? const {});
    final r = Map<String, dynamic>.from((j['routes'] as Map?) ?? const {});
    final root = (_str(r['apiRoot']) ?? '').replaceAll(RegExp(r'/+$'), '');
    String? at(Object? path) {
      final p = _str(path);
      if (root.isEmpty || p == null) return null;
      return p.startsWith('/') ? '$root$p' : '$root/$p';
    }

    return SsmStatus(
      configured: j['configured'] == true,
      chosenProvider: _str(j['chosen_provider']) ?? 'ssmsearch_web',
      cacheRows: _int(j['cache_rows']) ?? 0,
      searches24h: _int(j['searches_24h']) ?? 0,
      provider: _str(s['provider']),
      loggedInAs: _str(s['logged_in_as']),
      loginUrl: at(r['loginPath']),
      searchUrl: at(r['searchPath']),
      obtainedAt: _date(s['obtained_at']),
      lastUsedAt: _date(s['last_used_at']),
      lastError: _str(s['last_error']),
      lastErrorAt: _date(s['last_error_at']),
    );
  }
}

/// One path, and whether anything is listening at it.
class SsmProbeHit {
  const SsmProbeHit({
    required this.path,
    required this.method,
    required this.status,
    required this.said,
    required this.exists,
  });

  final String path;
  final String method;
  final int status;

  /// Whatever the provider said, which is the useful half: a
  /// validation complaint names the field a real login wants.
  final String said;

  /// Not a 404. A refusal, a complaint, even a 500 all mean something
  /// is there, which is what is being looked for.
  final bool exists;

  factory SsmProbeHit.fromJson(Map<String, dynamic> j) => SsmProbeHit(
    path: '${j['path'] ?? ''}',
    method: '${j['method'] ?? ''}',
    status: _int(j['status']) ?? 0,
    said: '${j['said'] ?? ''}',
    exists: j['exists'] == true,
  );
}

/// What the probe found.
class SsmProbe {
  const SsmProbe({
    required this.apiRoot,
    required this.login,
    required this.search,
  });

  final String apiRoot;
  final List<SsmProbeHit> login;
  final List<SsmProbeHit> search;

  /// The paths worth putting in a secret. Empty means the list of
  /// guesses was wrong all the way through, which is itself an answer:
  /// the API is not shaped like any of them.
  List<SsmProbeHit> get found => [
    ...login.where((h) => h.exists),
    ...search.where((h) => h.exists),
  ];

  factory SsmProbe.fromJson(Map<String, dynamic> j) {
    List<SsmProbeHit> hits(Object? v) => [
      for (final row in (v as List?) ?? const [])
        if (row is Map) SsmProbeHit.fromJson(Map<String, dynamic>.from(row)),
    ];
    return SsmProbe(
      apiRoot: _str(j['api_root']) ?? '',
      login: hits(j['login']),
      search: hits(j['search']),
    );
  }
}

/// What the function refused, in words worth showing somebody.
class SsmLookupException implements Exception, Explained {
  const SsmLookupException(this.code, this.message, {this.status = 500});

  final String code;
  @override
  final String message;
  final int status;

  factory SsmLookupException.from(Map<String, dynamic> payload, int status) {
    final err = payload['error'];
    if (err is Map) {
      return SsmLookupException(
        '${err['code'] ?? 'ERROR'}',
        '${err['message'] ?? 'The lookup failed.'}',
        status: status,
      );
    }
    return SsmLookupException(
      'HTTP_$status',
      'The lookup failed.',
      status: status,
    );
  }

  /// Nobody has set the dashboard secrets. Not a failure to retry, and
  /// the screens say so differently for that reason.
  bool get notConfigured => code == 'SSM_NOT_CONFIGURED';

  /// What to put in front of somebody.
  ///
  /// The function's own messages are written for people and are used as
  /// they are; these are the codes where the plain message would say
  /// less than the situation deserves.
  String get userMessage => switch (code) {
    'SSM_NOT_CONFIGURED' =>
      'The SSM lookup is not switched on yet. A platform '
          'administrator sets it up.',
    'RATE_LIMITED' =>
      'That is a lot of searches in a minute. Try again shortly.',
    'QUERY_TOO_SHORT' => 'Type at least three characters.',
    'SSM_LOGIN_FAILED' =>
      'The lookup could not sign in to the registry service. A '
          'platform administrator can check it.',
    'SSM_UNREACHABLE' =>
      'The registry service is not answering. Try again shortly.',
    'UNAUTHENTICATED' => 'Sign in again and retry.',
    'FORBIDDEN' => 'This part is for platform staff.',
    '42501' => 'You are not allowed to change this contact for this company.',
    _ => message,
  };

  @override
  String toString() => 'SsmLookupException($code): $message';
}

int? _int(Object? v) => v is int
    ? v
    : v is num
    ? v.toInt()
    : int.tryParse('${v ?? ''}');

String? _str(Object? v) {
  final s = '${v ?? ''}'.trim();
  return s.isEmpty ? null : s;
}

DateTime? _date(Object? v) => DateTime.tryParse('${v ?? ''}')?.toLocal();
