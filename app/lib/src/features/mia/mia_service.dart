import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/repository.dart';
import 'mia_credential.dart';
import 'mia_parser.dart';

/// Where a MIA lookup could come from.
///
/// One implementation today and it cannot search. The interface exists
/// so that a live provider can be added without the screens changing:
/// the verify dialog asks `canSearch` and draws a search box or a paste
/// box, and nothing above this file knows which.
///
/// Why there is no live one: mia.org.my is a WordPress form behind
/// Cloudflare's managed bot challenge. It has no API, no `wp-json`
/// route and no CORS allowance, so the browser cannot read it and a
/// server-side fetch from a cloud address is answered with
/// `cf-mitigated: challenge`. Getting past a bot challenge is not
/// something this product does. A real integration needs MIA to grant
/// one, which is a conversation rather than a patch.
abstract class MiaVerificationProvider {
  /// Whether this provider can look somebody up without a human.
  bool get canSearch;

  Future<List<MiaParsedRow>> search({
    required String searchBy,
    required String keyword,
    String? firmType,
  });
}

/// Somebody reads the register and copies the row.
class ManualMiaProvider implements MiaVerificationProvider {
  const ManualMiaProvider();

  @override
  bool get canSearch => false;

  @override
  Future<List<MiaParsedRow>> search({
    required String searchBy,
    required String keyword,
    String? firmType,
  }) =>
      throw UnsupportedError('Live MIA search is not available');
}

/// Reading, parsing and recording a MIA credential.
class MiaVerificationService {
  const MiaVerificationService(this._ref, {this.provider = const ManualMiaProvider()});

  final Ref _ref;
  final MiaVerificationProvider provider;

  static const parser = MiaResultParser();

  /// Whether the screens should offer a search box at all.
  bool get canSearch => provider.canSearch;

  /// A pasted row, read into fields. Null where it cannot be read, and
  /// the form then asks rather than guessing.
  MiaParsedRow? parsePaste(String text) => parser.parse(text);

  Future<List<MiaCredential>> load({
    required String subjectType,
    required String subjectId,
  }) => _ref.read(repoProvider)!.miaCredentials(
        subjectType: subjectType,
        subjectId: subjectId,
      );

  /// Records what the register said.
  ///
  /// The org or firm is not passed: `upsert_mia_credential` reads it
  /// off the subject, because a caller that could name the owner would
  /// be choosing which permission check to face.
  Future<void> save({
    required String subjectType,
    required String subjectId,
    required MiaKind kind,
    required Map<String, String?> fields,
    required String rawText,
  }) => _ref.read(repoProvider)!.saveMiaCredential(
        subjectType: subjectType,
        subjectId: subjectId,
        kind: kind == MiaKind.firm ? 'firm' : 'member',
        fields: {
          for (final e in fields.entries)
            if (e.value != null && e.value!.trim().isNotEmpty)
              e.key: _typed(e.key, e.value!),
          'raw_text': rawText,
        },
      );

  Future<void> remove(String id) =>
      _ref.read(repoProvider)!.deleteMiaCredential(id);

  /// `pc_holder` is the one field the register answers with a word and
  /// the column holds as a boolean. Everything else is text.
  static Object _typed(String key, String value) =>
      key == 'pc_holder' ? value.toLowerCase() == 'true' : value;
}

final miaServiceProvider = Provider<MiaVerificationService>(
  MiaVerificationService.new,
);

/// What the register says about one subject.
final miaCredentialsProvider = FutureProvider.autoDispose
    .family<List<MiaCredential>, ({String subjectType, String subjectId})>((
      ref,
      arg,
    ) {
      return ref.watch(miaServiceProvider).load(
            subjectType: arg.subjectType,
            subjectId: arg.subjectId,
          );
    });

/// Where MIA's own search lives, for the button that opens it.
const miaSearchUrl = 'https://mia.org.my/members-firm-search/';
