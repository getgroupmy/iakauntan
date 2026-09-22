import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/providers.dart';
import 'repository.dart';

/// What a scanned paper can be recognised as.
///
/// `0614`. A table rather than an enum, the same shape `entity_types`
/// and `search_registers` have and for the same reason: the list of
/// things worth recognising is not knowable in advance, and a platform
/// administrator adding one should not need a migration.
///
/// The rules that CHOOSE between these live in
/// `features/shared/document_classifier.dart`, not here and not in SQL.
/// They are string matching against letterheads, and they change every
/// time a bank rewords its statement.
class ScanKind {
  const ScanKind({
    required this.code,
    required this.label,
    this.labelMy,
    this.destination,
    this.targetModule,
    this.targetAction,
    this.hint,
    this.sortOrder = 100,
    this.isActive = true,
    this.isBuiltin = false,
  });

  final String code;
  final String label;
  final String? labelMy;

  /// Where a document of this kind goes: `purchase_document`,
  /// `expense`, `bank_import`, `contact`, `goods_received`. Null means
  /// nothing here turns one into a record yet, which is honest and is
  /// not the same as the kind being useless.
  final String? destination;

  /// The module and the action a scan of this kind becomes. `0681`.
  ///
  /// [destination] still exists and the app still routes on it — a
  /// trigger keeps it in step with this — but it names a SCREEN and
  /// nothing more. These two name the record, which is what lets the
  /// console list the fields that record has and ask the reader for
  /// them. Both null for a kind that is filed and nothing else.
  final String? targetModule;
  final String? targetAction;

  /// The pair as `scan_extraction_targets` keys it, or null.
  String? get targetKey =>
      targetModule == null || targetAction == null
      ? null
      : '$targetModule.$targetAction';

  /// One line saying what will happen if it is accepted. Somebody is
  /// about to press a button and this is the only place that says what
  /// the button does.
  final String? hint;

  final int sortOrder;
  final bool isActive;
  final bool isBuiltin;

  String get display => label;

  factory ScanKind.fromJson(Map<String, dynamic> j) {
    String? text(Object? v) =>
        v == null || '$v'.trim().isEmpty ? null : '$v'.trim();
    return ScanKind(
      code: '${j['code'] ?? ''}',
      label: '${j['label'] ?? j['code'] ?? ''}',
      labelMy: text(j['label_my']),
      destination: text(j['destination']),
      targetModule: text(j['target_module']),
      targetAction: text(j['target_action']),
      hint: text(j['hint']),
      sortOrder: (j['sort_order'] as num?)?.toInt() ?? 100,
      isActive: j['is_active'] != false,
      isBuiltin: j['is_builtin'] == true,
    );
  }
}

/// Where a kind of document can be sent, and what to call each one.
///
/// The destinations are SCREENS, and a screen is not a row — which is
/// why `scan_document_kinds.destination` is free text in the database
/// and a fixed list here. The database will take anything; this list is
/// what the console offers, and it is what the app knows how to open.
///
/// A null destination is not a gap. Three of the kinds this shipped
/// with have none: the paper is worth naming and filing even where
/// nothing in this product turns one into a record.
const scanKindDestinations = <(String?, String)>[
  (null, 'Filed only — nothing is created'),
  ('purchase_document', 'A purchase document — a bill or an order'),
  ('expense', 'An expense claim'),
  ('goods_received', 'A goods received note'),
  ('bank_import', 'The bank reconciliation screen'),
  ('contact', 'A contact'),
];

/// What [destination] is called, or the raw value if it is not one this
/// app knows — a kind added by an administrator can name anything.
String scanKindDestinationLabel(String? destination) {
  for (final d in scanKindDestinations) {
    if (d.$1 == destination) return d.$2;
  }
  return destination ?? 'Filed only — nothing is created';
}

class ScanKindsRepo {
  const ScanKindsRepo(this.client);

  final SupabaseClient client;

  Future<List<ScanKind>> all() async => Repo.rows(
    await client
        .from('scan_document_kinds')
        .select(
          'code, label, label_my, destination, target_module, '
          'target_action, hint, sort_order, is_active, is_builtin',
        )
        // Said out loud, because supabase-js defaults ascending to true
        // and postgrest-dart defaults it to false.
        .order('sort_order', ascending: true)
        .order('label', ascending: true),
  ).map(ScanKind.fromJson).toList();

  Future<String> save({
    required String code,
    required String label,
    String? labelMy,
    String? destination,
    String? hint,
    int? sortOrder,
    bool? isActive,
  }) async {
    final out = await client.rpc(
      'platform_save_scan_kind',
      params: {
        'p_code': code,
        'p_label': label,
        if (labelMy != null) 'p_label_my': labelMy,
        if (destination != null) 'p_destination': destination,
        if (hint != null) 'p_hint': hint,
        if (sortOrder != null) 'p_sort_order': sortOrder,
        if (isActive != null) 'p_is_active': isActive,
      },
    );
    return '$out';
  }

  Future<void> remove(String code) =>
      client.rpc('platform_delete_scan_kind', params: {'p_code': code});
}

final scanKindsRepoProvider = Provider<ScanKindsRepo>(
  (ref) => ScanKindsRepo(ref.watch(supabaseProvider)),
);

/// Every kind, including the ones switched off. For the console.
final allScanKindsProvider = FutureProvider<List<ScanKind>>(
  (ref) => ref.watch(scanKindsRepoProvider).all(),
);

/// The kinds a scan result may be filed as, switched on and in order.
///
/// Kept apart from the console's list for the reason
/// `contactEntityTypesProvider` is: an operator needs to see what is
/// switched off in order to switch it back on, and a scan result must
/// never offer it.
final offeredScanKindsProvider = FutureProvider<List<ScanKind>>((ref) async {
  final all = await ref.watch(allScanKindsProvider.future);
  return all.where((k) => k.isActive).toList();
});
