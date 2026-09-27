import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/providers.dart';
import 'repository.dart';

/// Where a scanned paper can be turned into a record.
///
/// A module, an action within it, and the table that action writes.
/// `0681`. The table name is load-bearing: the console reads its real
/// columns out of `information_schema`, so a target naming a table
/// nobody has offers nothing rather than offering a lie.
class ScanTarget {
  const ScanTarget({
    required this.module,
    required this.action,
    required this.label,
    required this.tableName,
    this.moduleName,
    this.destination,
    this.hint,
    this.fieldCount = 0,
  });

  final String module;
  final String action;
  final String label;
  final String tableName;

  /// What the module is called on screen — "Purchasing", not
  /// `purchases`. Null where the join did not run.
  final String? moduleName;

  /// The screen this opens. `0614`'s free text, which the app still
  /// routes on; a kind pointed at this target gets it by trigger.
  final String? destination;
  final String? hint;

  /// How many of its columns are ticked. Zero means the reader is never
  /// asked about this target at all — `scan_extraction_targets` leaves
  /// it out, because a destination with nothing to fill is a choice a
  /// model can make and then have nothing to do with.
  final int fieldCount;

  String get key => '$module.$action';

  factory ScanTarget.fromJson(Map<String, dynamic> j) => ScanTarget(
    module: '${j['module_code']}',
    action: '${j['action']}',
    label: j['label']?.toString() ?? '${j['action']}',
    tableName: '${j['table_name']}',
    moduleName: j['module_name']?.toString(),
    destination: j['destination']?.toString(),
    hint: j['hint']?.toString(),
    fieldCount: (j['field_count'] as num?)?.toInt() ?? 0,
  );
}

/// One real column of a target's table, and whether the reader is asked
/// for it.
class ScanTargetColumn {
  const ScanTargetColumn({
    required this.name,
    required this.dataType,
    required this.isRequired,
    required this.isForeign,
    required this.isAsked,
    required this.stillThere,
    this.description,
    this.sortOrder = 100,
  });

  final String name;
  final String dataType;

  /// NOT NULL with no default — the record cannot be written without
  /// it, so a target whose required columns are not ticked will produce
  /// drafts somebody has to finish by hand.
  final bool isRequired;

  /// A foreign key. It cannot be read off a page — what is printed is a
  /// supplier's NAME, not a uuid — and it is offered anyway, because it
  /// is the honest place to hang "the supplier as printed, which will
  /// be matched to a contact". Hiding it would leave the one field
  /// every bill has no way of being asked for.
  final bool isForeign;

  final bool isAsked;

  /// False for a column that was ticked and has since been dropped. It
  /// is shown rather than hidden so somebody sees what happened instead
  /// of wondering where the configuration went.
  final bool stillThere;

  /// The sentence the reader is asked with. A field without one is a
  /// column name handed to a model and answered from the name alone.
  final String? description;
  final int sortOrder;

  ScanTargetColumn copyWith({
    bool? isAsked,
    String? description,
    int? sortOrder,
  }) => ScanTargetColumn(
    name: name,
    dataType: dataType,
    isRequired: isRequired,
    isForeign: isForeign,
    isAsked: isAsked ?? this.isAsked,
    stillThere: stillThere,
    description: description ?? this.description,
    sortOrder: sortOrder ?? this.sortOrder,
  );

  factory ScanTargetColumn.fromJson(Map<String, dynamic> j) =>
      ScanTargetColumn(
        name: '${j['column_name']}',
        dataType: j['data_type']?.toString() ?? '',
        isRequired: j['is_required'] == true,
        isForeign: j['is_foreign'] == true,
        isAsked: j['is_asked'] == true,
        stillThere: j['still_there'] != false,
        description: (j['description']?.toString().trim().isEmpty ?? true)
            ? null
            : j['description'].toString().trim(),
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 100,
      );
}

/// Reading and writing what a scanned paper becomes.
///
/// On the CLIENT rather than on `Repo`, for the reason `0675`'s key
/// pool is: a platform operator belongs to no company, and anything
/// under `features/admin/` built on `repoProvider` answers "Your
/// company has not finished loading" to the only people the screen
/// exists for.
class ScanTargetsRepo {
  const ScanTargetsRepo(this.client);

  final SupabaseClient client;

  Future<List<ScanTarget>> all() async => Repo.rows(
    await client
        .from('scan_targets')
        .select(
          'module_code, action, label, table_name, destination, hint, '
          'sort_order, is_active',
        )
        .eq('is_active', true)
        .order('sort_order', ascending: true)
        .order('label', ascending: true),
  ).map(ScanTarget.fromJson).toList();

  /// The real columns of a target's table, with the ticks beside them.
  Future<List<ScanTargetColumn>> columns(String module, String action) async =>
      Repo.rows(
        await client.rpc(
          'scan_target_columns',
          params: {'p_module': module, 'p_action': action},
        ),
      ).map(ScanTargetColumn.fromJson).toList();

  /// Replaces what the reader is asked for. Replaces rather than
  /// merges: the console sends what is ticked, and a merge would make
  /// unticking impossible.
  Future<void> saveFields(
    String module,
    String action,
    List<ScanTargetColumn> asked,
  ) => client.rpc(
    'set_scan_target_fields',
    params: {
      'p_module': module,
      'p_action': action,
      'p_fields': [
        for (var i = 0; i < asked.length; i++)
          {
            'column_name': asked[i].name,
            'description': asked[i].description,
            'sort_order': (i + 1) * 10,
          },
      ],
    },
  );

  /// Points a kind of document at a target, or at neither.
  Future<void> setKindTarget(String code, String? module, String? action) =>
      client.rpc(
        'set_scan_kind_target',
        params: {
          'p_code': code,
          'p_module': module,
          'p_action': action,
        },
      );
}

final scanTargetsRepoProvider = Provider<ScanTargetsRepo>(
  (ref) => ScanTargetsRepo(ref.watch(supabaseProvider)),
);

/// Every target on offer, for the module and action dropdowns.
final scanTargetsProvider = FutureProvider<List<ScanTarget>>(
  (ref) => ref.watch(scanTargetsRepoProvider).all(),
);

/// The real columns of one target's table, with the ticks.
///
/// Keyed on the pair and `autoDispose`: it reads `information_schema`
/// at the moment it is asked, and a cached answer is the one thing this
/// must not have — the whole point is that a renamed column shows up.
final scanTargetColumnsProvider = FutureProvider.autoDispose
    .family<List<ScanTargetColumn>, ({String module, String action})>(
      (ref, t) =>
          ref.watch(scanTargetsRepoProvider).columns(t.module, t.action),
    );
