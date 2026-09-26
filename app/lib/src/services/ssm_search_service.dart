// lib/services/ssm_search_service.dart
//
// Flutter-side client for the `ssm-api` edge function. One method per SSM Search API
// endpoint (13) plus the three convenience actions the UI flow uses (search, searchAll, profile).
// The API key/secret never reach the app — every call goes through the edge function with the
// signed-in user's JWT, which supabase_flutter attaches automatically.
//
// Usage:
//   final ssm = SsmSearchService(Supabase.instance.client, orgId: currentOrgId);
//   final hits = await ssm.search(name: 'MAJU', entityType: SsmEntityType.company);
//   // → pick one → save hit.name, hit.newRegNo, hit.oldRegNo, hit.entityType
//   final profile = await ssm.profile(entityType: hit.entityType, newRegNo: hit.newRegNo, oldRegNo: hit.oldRegNo);

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/error_text.dart';

/// Values documented for the search request's `entityType`.
abstract final class SsmEntityType {
  static const company = 'company';
  static const business = 'business';
  static const auditFirm = 'audit_firm';
  static const llp = 'limited_liability_partnerships';
  static const all = [company, business, auditFirm, llp];

  static String label(String v) => switch (v) {
        company => 'Company (Sdn Bhd / Bhd)',
        business => 'Business (Enterprise / Partnership)',
        auditFirm => 'Audit Firm',
        llp => 'LLP (PLT)',
        _ => v,
      };
}

/// The four fields iAkauntan stores from a search result.
class SsmSearchHit {
  const SsmSearchHit({required this.name, required this.newRegNo, required this.oldRegNo, required this.entityType});

  final String name;
  final String newRegNo;
  final String oldRegNo;
  final String entityType;

  factory SsmSearchHit.fromJson(Map<String, dynamic> j) => SsmSearchHit(
        name: (j['name'] ?? '') as String,
        newRegNo: (j['newRegNo'] ?? '') as String,
        oldRegNo: (j['oldRegNo'] ?? '') as String,
        entityType: (j['entityType'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {'name': name, 'newRegNo': newRegNo, 'oldRegNo': oldRegNo, 'entityType': entityType};

  /// e.g. "MAJU SDN. BHD. — 199301012345 (123456-X)"
  String get display => '$name — $newRegNo${oldRegNo.isNotEmpty ? ' ($oldRegNo)' : ''}';

  @override
  String toString() => 'SsmSearchHit($display, $entityType)';
}

/// One page of search results.
class SsmSearchPage {
  const SsmSearchPage({required this.hits, required this.currentPage, required this.nextPage, required this.cached, required this.raw});
  final List<SsmSearchHit> hits;
  final String currentPage;
  final String nextPage;
  final bool cached;
  final Map<String, dynamic> raw;
  bool get hasMore => nextPage.isNotEmpty && nextPage != currentPage && nextPage != '0';
}

/// Result of `searchAll` (several pages merged).
class SsmSearchAllResult {
  const SsmSearchAllResult({required this.hits, required this.pagesFetched, required this.exhausted, required this.cached});
  final List<SsmSearchHit> hits;
  final int pagesFetched;
  final bool exhausted;
  final bool cached;
}

/// One lodged document from `imageView`.
class SsmDocumentInfo {
  const SsmDocumentInfo({required this.verId, required this.formType, required this.documentDate, required this.totalPage, required this.raw});
  final String verId;
  final String formType;
  final String documentDate;
  final String totalPage;
  final Map<String, dynamic> raw;

  factory SsmDocumentInfo.fromJson(Map<String, dynamic> j) => SsmDocumentInfo(
        verId: (j['verId'] ?? '') as String,
        formType: (j['formType'] ?? '') as String,
        documentDate: (j['documentDate'] ?? '') as String,
        totalPage: (j['totalPage'] ?? '') as String,
        raw: j,
      );
}

/// Error surfaced by the edge function (or transport failure).
class SsmApiException implements Exception, Explained {
  const SsmApiException({required this.kind, required this.message, this.code, this.status, this.path, this.clientRefNo});
  final String kind; // validation | unauthorized | forbidden | rate_limited | auth | http | route | payload | upstream | network | parse | internal | transport
  @override
  final String message;
  final Object? code;
  final int? status;
  final String? path;
  final String? clientRefNo;

  factory SsmApiException.fromJson(Map<String, dynamic>? j, {int? httpStatus}) => SsmApiException(
        kind: (j?['kind'] ?? 'internal') as String,
        message: (j?['message'] ?? 'SSM request failed') as String,
        code: j?['code'],
        status: (j?['status'] as num?)?.toInt() ?? httpStatus,
        path: j?['path'] as String?,
        clientRefNo: j?['client_ref_no'] as String?,
      );

  bool get isRateLimited => kind == 'rate_limited';
  bool get isCredentialProblem => kind == 'auth';

  /// Text safe to show in a SnackBar.
  String get userMessage => switch (kind) {
        'rate_limited' => 'Too many SSM lookups — please wait a minute and try again.',
        'auth' => 'SSM Search is not configured yet. Ask your platform admin to add the API key.',
        'network' => 'SSM Search did not respond. Please try again.',
        'upstream' => 'SSM returned an error: $message',
        _ => message,
      };

  @override
  String toString() => 'SsmApiException($kind, $status, $message, ref=$clientRefNo)';
}

/// How a body reaches the edge function.
///
/// One line of indirection, and it is the only way the thirteen
/// endpoints can be asserted at all: `SupabaseClient.functions.invoke`
/// is a method on a concrete class, so a test double cannot stand in
/// for it and every method below would otherwise be provable only
/// against a deployed function.
///
/// What a test replaces this with records the action and the params —
/// which is the half of "wired end to end" that lives on this side.
typedef SsmInvoker = Future<FunctionResponse> Function(
  String functionName,
  Map<String, dynamic> body,
);

class SsmSearchService {
  SsmSearchService(
    this._supabase, {
    this.orgId,
    this.functionName = 'ssm-api',
    SsmInvoker? invoker,
  }) : _invoker = invoker;

  final SupabaseClient _supabase;
  final SsmInvoker? _invoker;
  final String? orgId;
  final String functionName;

  /// Every action name this service sends, in the order the handoff
  /// numbers the endpoints.
  ///
  /// Public because it is half of a contract whose other half is in
  /// another language: `supabase/functions/ssm-api/index.ts` decides
  /// which names exist, and a name that is on one list and not the
  /// other is an endpoint the app cannot reach. Asserted across the two
  /// files rather than trusted.
  static const actions = <String>[
    'search',
    'searchAll',
    'profile',
    'searchEntity',
    'businessProfile',
    'companyProfile',
    'directorsOfficers',
    'shareCapital',
    'shareholders',
    'registeredAddressChanges',
    'companySecretary',
    'companyCharges',
    'auditFirmProfile',
    'llpCurrentProfile',
    'imageView',
    'image',
  ];

  // ---------------------------------------------------------------------------
  // Convenience actions (what the UI flow uses)
  // ---------------------------------------------------------------------------

  /// One page of results. Pass either [name] or [regNo] (old or new number).
  Future<SsmSearchPage> search({String? name, String? regNo, String? entityType, int page = 1, bool force = false}) async {
    final res = await _invoke('search', {
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      if (regNo != null && regNo.trim().isNotEmpty) 'regNo': regNo.trim(),
      if (entityType != null && entityType.isNotEmpty) 'entityType': entityType,
      'page': '$page',
      if (force) 'force': true,
    });
    final data = res.data;
    return SsmSearchPage(
      hits: _hits(data['hits']),
      currentPage: (data['currentPage'] ?? '$page') as String,
      nextPage: (data['nextPage'] ?? '') as String,
      cached: res.cached,
      raw: (data['raw'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  /// Follows nextPage up to [maxPages] (each page is a paid call in production).
  Future<SsmSearchAllResult> searchAll({String? name, String? regNo, String? entityType, int maxPages = 3, bool force = false}) async {
    final res = await _invoke('searchAll', {
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      if (regNo != null && regNo.trim().isNotEmpty) 'regNo': regNo.trim(),
      if (entityType != null && entityType.isNotEmpty) 'entityType': entityType,
      'maxPages': maxPages,
      if (force) 'force': true,
    });
    return SsmSearchAllResult(
      hits: _hits(res.data['hits']),
      pagesFetched: (res.data['pagesFetched'] as num?)?.toInt() ?? 0,
      exhausted: res.data['exhausted'] == true,
      cached: res.cached,
    );
  }

  /// The right profile document for the entity type (company / business / LLP / audit firm).
  Future<Map<String, dynamic>> profile({required String entityType, String? newRegNo, String? oldRegNo, bool force = false}) =>
      _raw('profile', {'entityType': entityType, if (newRegNo != null) 'newRegNo': newRegNo, if (oldRegNo != null) 'oldRegNo': oldRegNo, if (force) 'force': true});

  // ---------------------------------------------------------------------------
  // The 13 endpoints, 1:1 (raw upstream payloads as maps — see the handoff doc §6 for shapes)
  // ---------------------------------------------------------------------------

  /// 1. POST /get-search-entity (raw `getSearchEntity` payload).
  Future<Map<String, dynamic>> searchEntity({String? name, String? regNo, String? entityType, String? page, bool force = false}) =>
      _raw('searchEntity', {if (name != null) 'name': name, if (regNo != null) 'regNo': regNo, if (entityType != null) 'entityType': entityType, if (page != null) 'page': page, if (force) 'force': true});

  /// 2. POST /get-bizprofile-document → `getBizProfile`.
  Future<Map<String, dynamic>> businessProfile(String regNo, {bool force = false}) => _raw('businessProfile', {'regNo': regNo, if (force) 'force': true});

  /// 3. POST /get-company-profile-document → `getCompProfile`.
  Future<Map<String, dynamic>> companyProfile(String regNo, {bool force = false}) => _raw('companyProfile', {'regNo': regNo, if (force) 'force': true});

  /// 4. POST /get-company-roc-business-officers → `getRocBusinessOfficers`.
  Future<Map<String, dynamic>> directorsOfficers(String regNo, {bool force = false}) => _raw('directorsOfficers', {'regNo': regNo, if (force) 'force': true});

  /// 5. POST /get-company-sharecapital-particular → `getDetailsOfShareCapital`.
  Future<Map<String, dynamic>> shareCapital(String regNo, {bool force = false}) => _raw('shareCapital', {'regNo': regNo, if (force) 'force': true});

  /// 6. POST /get-company-shareholder-particular → `getDetailsOfShareholders`.
  Future<Map<String, dynamic>> shareholders(String regNo, {bool force = false}) => _raw('shareholders', {'regNo': regNo, if (force) 'force': true});

  /// 7. POST /get-company-roc-changes-registered-address → `getRocChangesRegisteredAddress`.
  Future<Map<String, dynamic>> registeredAddressChanges(String regNo, {bool force = false}) => _raw('registeredAddressChanges', {'regNo': regNo, if (force) 'force': true});

  /// 8. POST /get-company-cosec-particular → `getParticularsOfCosec`.
  Future<Map<String, dynamic>> companySecretary(String regNo, {bool force = false}) => _raw('companySecretary', {'regNo': regNo, if (force) 'force': true});

  /// 9. POST /get-company-charges → `getInfoCharges`.
  Future<Map<String, dynamic>> companyCharges(String regNo, {bool force = false}) => _raw('companyCharges', {'regNo': regNo, if (force) 'force': true});

  /// 10. POST /get-auditfirm-particular → `getParticularsOfAdtFirm` (adtFirmNo e.g. AF0301).
  Future<Map<String, dynamic>> auditFirmProfile(String adtFirmNo, {bool force = false}) => _raw('auditFirmProfile', {'adtFirmNo': adtFirmNo, if (force) 'force': true});

  /// 11. POST /get-llp-current-profile → `getLlpCurrentProfile` (OLD-format number e.g. LLP0012345-LGN).
  Future<Map<String, dynamic>> llpCurrentProfile(String entityNoOldFormat, {bool force = false}) => _raw('llpCurrentProfile', {'entityNoOldFormat': entityNoOldFormat, if (force) 'force': true});

  /// 12. POST /get-image-view → list of lodged documents.
  Future<List<SsmDocumentInfo>> imageView(String regNo, {bool force = false}) async {
    final data = await _raw('imageView', {'regNo': regNo, if (force) 'force': true});
    final list = ((data['documentInfos'] as Map?)?['documentInfos'] as List?) ?? const [];
    return list.map((e) => SsmDocumentInfo.fromJson((e as Map).cast<String, dynamic>())).toList();
  }

  /// 13. POST /get-image → `docContent` (string; format to be confirmed — likely base64).
  Future<String> image(String regNo, String verId, {bool force = false}) async {
    final data = await _raw('image', {'regNo': regNo, 'verId': verId, if (force) 'force': true});
    return (data['docContent'] ?? '') as String;
  }

  // ---------------------------------------------------------------------------
  // transport
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>> _raw(String action, Map<String, dynamic> params) async => (await _invoke(action, params)).data;

  Future<_Envelope> _invoke(String action, Map<String, dynamic> params) async {
    final body = <String, dynamic>{
      'action': action,
      'params': params,
      // `org_id`, not `orgId`. The bundle used camelCase on both sides
      // and was consistent with itself; this repository is snake_case
      // on the wire everywhere else -- `_shared/context.ts` reads
      // `body.org_id` for every MyInvois call -- and one convention
      // beats two.
      if (orgId != null) 'org_id': orgId,
    };
    FunctionResponse res;
    try {
      res = await (_invoker == null
          ? _supabase.functions.invoke(functionName, body: body)
          : _invoker(functionName, body));
    } on FunctionException catch (e) {
      // non-2xx: the edge function still returns our JSON envelope in `details`
      final details = e.details;
      final map = details is Map ? details.cast<String, dynamic>() : null;
      throw SsmApiException.fromJson((map?['error'] as Map?)?.cast<String, dynamic>(), httpStatus: e.status);
    } catch (e) {
      throw SsmApiException(kind: 'transport', message: e.toString());
    }
    final answer = res.data;
    if (answer is! Map) {
      throw const SsmApiException(
        kind: 'internal',
        message: 'unexpected response from ssm-api',
      );
    }
    final map = answer.cast<String, dynamic>();
    if (map['ok'] != true) throw SsmApiException.fromJson((map['error'] as Map?)?.cast<String, dynamic>(), httpStatus: res.status);
    final data = map['data'];
    return _Envelope(
      data: data is Map ? data.cast<String, dynamic>() : <String, dynamic>{'value': data},
      cached: map['cached'] == true,
    );
  }

  static List<SsmSearchHit> _hits(Object? v) => ((v as List?) ?? const []).map((e) => SsmSearchHit.fromJson((e as Map).cast<String, dynamic>())).toList();
}

/// A successful answer, and whether it was paid for.
///
/// No `clientRefNo`. The bundle carried one here and nothing ever read
/// it: the reference matters when a call FAILS, where it reaches the
/// caller on `SsmApiException`, and it is on `ssm_api_log` server-side
/// where the bill is actually reconciled. A field nothing reads is a
/// field nothing can notice going wrong — this one was being read under
/// the wrong name and no test could see it.
class _Envelope {
  const _Envelope({required this.data, required this.cached});
  final Map<String, dynamic> data;
  final bool cached;
}
