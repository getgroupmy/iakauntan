import '../../core/format.dart';
import '../../data/corp_models.dart' show corpToday;

/// Whether a credential is a person's membership or a firm's
/// registration.
enum MiaKind { member, firm }

/// How a credential came to be recorded.
///
/// `manual` is somebody reading MIA's register and copying the row.
/// `api` is reserved: the register is a WordPress form behind
/// Cloudflare's managed bot challenge, with no API and no CORS
/// allowance, so nothing fetches it today. The value exists so a row
/// written by a real integration is distinguishable from one typed in,
/// on the day MIA grants one.
enum MiaVerifiedVia { manual, api }

/// What MIA's members and firms register said about somebody, and when
/// it was looked up.
///
/// ## What a row does not prove
///
/// MIA membership is not approval as a company auditor — that is the
/// Accountant General's Department under s.263 of the Companies Act
/// 2016 — and it is not a licensed tax agent, which is LHDN under
/// s.153 of the Income Tax Act. The card that shows this says so, and
/// it is repeated here because a field called `verifiedAt` invites more
/// weight than it can carry.
class MiaCredential {
  const MiaCredential({
    required this.id,
    required this.subjectType,
    required this.subjectId,
    required this.kind,
    required this.verifiedVia,
    required this.verifiedAt,
    this.memberNo,
    this.memberName,
    this.memberType,
    this.pcHolder,
    this.firmNo,
    this.firmName,
    this.firmType,
    this.address,
    this.tel,
    this.fax,
    this.email,
    this.website,
    this.state,
    this.verifiedByName,
    this.rawText,
  });

  final String id;

  /// `corp_officer` or `firm`. Free text rather than an enum because
  /// the database's own check constraint is the list, and a third
  /// subject added there should not need this file recompiled to be
  /// readable.
  final String subjectType;
  final String subjectId;
  final MiaKind kind;

  // A member.
  final String? memberNo;
  final String? memberName;

  /// 'CA', 'LA' or 'AM' as the register prints it. A string, not an
  /// enum: the register is somebody else's list, and a category added
  /// to it should arrive as itself rather than as a parse failure.
  final String? memberType;

  /// Whether the member holds a practising certificate. Null where the
  /// register did not say.
  final bool? pcHolder;

  // A firm.
  final String? firmNo;
  final String? firmName;

  /// 'A' or 'NA' — audit or non-audit.
  final String? firmType;
  final String? address;
  final String? tel;
  final String? fax;
  final String? email;
  final String? website;

  final String? state;

  final MiaVerifiedVia verifiedVia;
  final DateTime verifiedAt;
  final String? verifiedByName;

  /// Exactly what was pasted. An audit wants to see what the screen was
  /// shown and not only what was parsed out of it.
  final String? rawText;

  /// The number somebody would quote: a member number or a firm number.
  String get number => (kind == MiaKind.member ? memberNo : firmNo) ?? '—';

  /// The name as the register has it.
  String get registeredName =>
      (kind == MiaKind.member ? memberName : firmName) ?? '—';

  /// How long ago it was checked, in whole days.
  int get ageInDays => corpToday().difference(
        DateTime(verifiedAt.year, verifiedAt.month, verifiedAt.day),
      ).inDays;

  /// Whether it is worth looking again.
  ///
  /// A practising certificate is renewed annually, so a check made more
  /// than a year ago says what was true last year. Twelve months rather
  /// than a calendar year: the certificate year is not the same for
  /// every member and a fixed anniversary would be a different claim.
  bool get isStale => ageInDays > 365;

  factory MiaCredential.fromJson(Map<String, dynamic> j) => MiaCredential(
    id: j['id'].toString(),
    subjectType: j['subject_type']?.toString() ?? '',
    subjectId: j['subject_id']?.toString() ?? '',
    kind: j['kind']?.toString() == 'firm' ? MiaKind.firm : MiaKind.member,
    memberNo: j['member_no']?.toString(),
    memberName: j['member_name']?.toString(),
    memberType: j['member_type']?.toString(),
    pcHolder: j['pc_holder'] as bool?,
    firmNo: j['firm_no']?.toString(),
    firmName: j['firm_name']?.toString(),
    firmType: j['firm_type']?.toString(),
    address: j['address']?.toString(),
    tel: j['tel']?.toString(),
    fax: j['fax']?.toString(),
    email: j['email']?.toString(),
    website: j['website']?.toString(),
    state: j['state']?.toString(),
    verifiedVia: j['verified_via']?.toString() == 'mia_api'
        ? MiaVerifiedVia.api
        : MiaVerifiedVia.manual,
    verifiedAt: Fmt.parseDate(j['verified_at']) ?? DateTime.now(),
    verifiedByName: _verifier(j),
    rawText: j['raw_text']?.toString(),
  );
}

/// Who looked it up, out of the embedded `profiles` row.
///
/// A name where there is one, an email where the profile has no name
/// yet, and null where the account has since been deleted — the column
/// is `on delete set null`, so "verified by nobody" is a real state and
/// not a bug.
String? _verifier(Map<String, dynamic> j) {
  final p = j['verifier'];
  if (p is! Map) return null;
  for (final key in ['full_name', 'email']) {
    final v = p[key]?.toString().trim();
    if (v != null && v.isNotEmpty) return v;
  }
  return null;
}

/// What the card says about what a credential is not.
///
/// One sentence, shown wherever a credential is. Somebody looking at a
/// green tick beside the word "verified" will read it as more than it
/// is unless the limit is written next to it.
const miaCredentialCaveat =
    'MIA membership does not by itself mean approved company auditor '
    '(Accountant General’s Department) or licensed tax agent (LHDN).';
