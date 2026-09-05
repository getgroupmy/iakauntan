import 'repository.dart';

/// The fields a company added for itself, and where they may live.
///
/// Eleven tables have carried `custom_fields jsonb` since 0003 and
/// nothing ever wrote one. 0542 gave them definitions and a guard; this
/// is the half that lets somebody name one and fill it in.
///
/// ## The key is not the label
///
/// `key` is what the value is stored under and never changes. `label`
/// is what a person reads and changes whenever they like. Renaming a
/// field moves the label and leaves the key where the values are, which
/// is why `upsertCustomField` takes both.
class CustomFieldDef {
  const CustomFieldDef({
    required this.id,
    required this.entity,
    required this.key,
    required this.label,
    required this.kind,
    required this.isRequired,
    required this.isActive,
    required this.showOnList,
    required this.sortOrder,
    this.helpText,
    this.options = const [],
    this.targetEntity,
    this.minValue,
    this.maxValue,
    this.maxLength,
  });

  final String id;
  final String entity;
  final String key;
  final String label;

  /// One of text, number, date, boolean, select, lookup.
  final String kind;
  final bool isRequired;

  /// An archived field keeps its values and its type; it is simply no
  /// longer offered on the form and no longer demanded.
  final bool isActive;
  final bool showOnList;
  final int sortOrder;
  final String? helpText;

  /// For a select, the values that may be chosen. Empty otherwise.
  final List<String> options;

  /// For a lookup, the kind of record it points at. Null otherwise.
  final String? targetEntity;
  final num? minValue;
  final num? maxValue;
  final int? maxLength;

  bool get isLookup => kind == 'lookup';

  factory CustomFieldDef.fromJson(Map<String, dynamic> j) => CustomFieldDef(
    id: '${j['id']}',
    entity: '${j['entity']}',
    key: '${j['key']}',
    label: '${j['label']}',
    kind: '${j['kind']}',
    isRequired: j['is_required'] == true,
    isActive: j['is_active'] == true,
    showOnList: j['show_on_list'] == true,
    sortOrder: (j['sort_order'] as num?)?.toInt() ?? 100,
    helpText: j['help_text']?.toString(),
    options: ((j['options'] as List?) ?? const [])
        .map((o) => '$o')
        .toList(growable: false),
    targetEntity: j['target_entity']?.toString(),
    minValue: j['min_value'] as num?,
    maxValue: j['max_value'] as num?,
    maxLength: (j['max_length'] as num?)?.toInt(),
  );
}

/// Where a field may be attached, and what a lookup may point at. A
/// platform catalogue: a twelfth carrier needs a jsonb column and the
/// guard trigger, both of which are a migration.
class CustomFieldEntity {
  const CustomFieldEntity({
    required this.entity,
    required this.label,
    required this.canCarry,
    required this.canTarget,
    required this.isLineLevel,
    required this.sortOrder,
  });

  final String entity;
  final String label;
  final bool canCarry;
  final bool canTarget;

  /// A line on a document rather than the document itself. Filled in
  /// once per line, which is a different thing to ask of somebody.
  final bool isLineLevel;
  final int sortOrder;

  factory CustomFieldEntity.fromJson(Map<String, dynamic> j) =>
      CustomFieldEntity(
        entity: '${j['entity']}',
        label: '${j['label']}',
        canCarry: j['can_carry'] == true,
        canTarget: j['can_target'] == true,
        isLineLevel: j['is_line_level'] == true,
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 100,
      );
}

/// One row a lookup field may be filled in with.
typedef LookupOption = ({String id, String label});

extension RepoCustomFields on Repo {
  /// The catalogue of what may carry a field and what may be pointed
  /// at. The same for every company, so no org filter.
  Future<List<CustomFieldEntity>> customFieldEntities() async =>
      Repo.rows(
        await client
            .from('custom_field_entities')
            .select(
              'entity, table_name, label, can_carry, can_target, '
              'is_line_level, label_column, sort_order',
            )
            .order('sort_order'),
      ).map(CustomFieldEntity.fromJson).toList();

  /// This company's fields for one kind of record, archived ones last.
  /// A form shows the active ones; the setup screen shows both, which
  /// is why the archived are not filtered out here.
  Future<List<CustomFieldDef>> customFields(String entity) async => Repo.rows(
    await client
        .from('custom_fields_def')
        .select(
          'id, org_id, entity, key, label, help_text, kind, is_required, '
          'is_active, options, target_entity, min_value, max_value, '
          'max_length, show_on_list, sort_order',
        )
        .eq('org_id', orgId)
        .eq('entity', entity)
        .order('is_active', ascending: false)
        .order('sort_order')
        .order('label'),
  ).map(CustomFieldDef.fromJson).toList();

  /// Name a field, or change one. Pass `key` to edit an existing field:
  /// without it the key is derived from the label, which is what makes
  /// a second call with a new label a rename rather than a new field.
  Future<String> upsertCustomField({
    required String entity,
    required String label,
    String? key,
    String kind = 'text',
    bool isRequired = false,
    List<String>? options,
    String? targetEntity,
    String? helpText,
    num? minValue,
    num? maxValue,
    int? maxLength,
    bool showOnList = false,
    int sortOrder = 100,
  }) async =>
      '${await callRpc(
        'upsert_custom_field',
        params: {
          'p_org_id': orgId,
          'p_entity': entity,
          'p_label': label,
          'p_key': key,
          'p_kind': kind,
          'p_is_required': isRequired,
          'p_options': options,
          'p_target_entity': targetEntity,
          'p_help_text': helpText,
          'p_min_value': minValue,
          'p_max_value': maxValue,
          'p_max_length': maxLength,
          'p_show_on_list': showOnList,
          'p_sort_order': sortOrder,
        },
      )}';

  /// Put a field away, or bring it back. Archived rather than deleted:
  /// the definition is what keeps the values already written readable
  /// and correctly typed.
  Future<void> setCustomFieldActive(
    String entity,
    String key,
    bool active,
  ) async => await callRpc(
    'set_custom_field_active',
    params: {
      'p_org_id': orgId,
      'p_entity': entity,
      'p_key': key,
      'p_active': active,
    },
  );

  /// What a lookup field may be filled in with. Read through the same
  /// function the guard's rule is written beside, so that the picker
  /// cannot offer a record the database will refuse.
  Future<List<LookupOption>> customFieldLookupOptions(
    String targetEntity, {
    String? search,
    int limit = 50,
  }) async =>
      Repo.rows(
        await callRpc(
          'custom_field_lookup_options',
          params: {
            'p_org_id': orgId,
            'p_target_entity': targetEntity,
            'p_search': search,
            'p_limit': limit,
          },
        ),
      )
          .map((r) => (id: '${r['id']}', label: '${r['label']}'))
          .toList(growable: false);
}
