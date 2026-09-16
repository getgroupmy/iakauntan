import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/providers.dart';
import 'repository.dart';

/// One kind of business a contact or a company can be.
///
/// `0605` made this a table. It was the `app.entity_type` enum from
/// `0001` until then, which meant an eleventh kind — a co-operative, a
/// trust, a foreign branch — needed a migration and a deploy.
class EntityType {
  const EntityType({
    required this.code,
    required this.label,
    this.labelMy,
    this.sortOrder = 100,
    this.isActive = true,
    this.isPublicCompany = false,
    this.forContacts = true,
    this.forOrganizations = true,
    this.isBuiltin = false,
  });

  /// The value stored on the contact. Was a member of the enum.
  final String code;
  final String label;

  /// Bahasa Malaysia where somebody has written one; the app falls back
  /// to [label], which is what every other translated string here does.
  final String? labelMy;

  final int sortOrder;

  /// Retired rather than deleted. A contact filed under a kind that is
  /// no longer offered is still filed under it.
  final bool isActive;

  /// The MBRS answer. `0172` decides whether a company files its
  /// accounts as a public company, and until `0605` it did so by
  /// comparing against the string `bhd`. A new kind has to say.
  final bool isPublicCompany;

  final bool forContacts;
  final bool forOrganizations;

  /// One of the ten this shipped with. They may be renamed and retired
  /// but not deleted: `organizations.entity_type` is still the enum and
  /// still holds these values.
  final bool isBuiltin;

  /// What to show. The Malay label where there is one and the interface
  /// is in Malay is a later question; today every screen shows [label].
  String get display => label;

  factory EntityType.fromJson(Map<String, dynamic> j) => EntityType(
    code: '${j['code'] ?? ''}',
    label: '${j['label'] ?? j['code'] ?? ''}',
    labelMy: (j['label_my'] as String?)?.trim().isEmpty ?? true
        ? null
        : '${j['label_my']}'.trim(),
    sortOrder: (j['sort_order'] as num?)?.toInt() ?? 100,
    isActive: j['is_active'] != false,
    isPublicCompany: j['is_public_company'] == true,
    forContacts: j['for_contacts'] != false,
    forOrganizations: j['for_organizations'] != false,
    isBuiltin: j['is_builtin'] == true,
  );
}

/// The kinds of business, read by anybody and written by platform
/// staff.
///
/// A plain table read rather than an RPC: there is nothing private on
/// the row, and every signed-in user needs it to draw a dropdown.
class EntityTypesRepo {
  const EntityTypesRepo(this.client);

  final SupabaseClient client;

  Future<List<EntityType>> all() async => Repo.rows(
    await client
        .from('entity_types')
        .select(
          'code, label, label_my, sort_order, is_active, '
          'is_public_company, for_contacts, for_organizations, is_builtin',
        )
        // Said out loud, because supabase-js defaults ascending to true
        // and postgrest-dart defaults it to false: an order with no
        // direction means the opposite in the two halves of this
        // application.
        .order('sort_order', ascending: true)
        .order('label', ascending: true),
  ).map(EntityType.fromJson).toList();

  /// Adds or amends one. An absent argument means "leave it alone", so
  /// correcting a label cannot switch a kind off.
  Future<String> save({
    required String code,
    required String label,
    String? labelMy,
    int? sortOrder,
    bool? isActive,
    bool? isPublicCompany,
    bool? forContacts,
    bool? forOrganizations,
  }) async {
    final out = await client.rpc(
      'platform_save_entity_type',
      params: {
        'p_code': code,
        'p_label': label,
        if (labelMy != null) 'p_label_my': labelMy,
        if (sortOrder != null) 'p_sort_order': sortOrder,
        if (isActive != null) 'p_is_active': isActive,
        if (isPublicCompany != null) 'p_is_public_company': isPublicCompany,
        if (forContacts != null) 'p_for_contacts': forContacts,
        if (forOrganizations != null) 'p_for_organizations': forOrganizations,
      },
    );
    return '$out';
  }

  /// Removes one nothing is filed as. The function refuses a built-in
  /// and refuses one in use, naming how many — both are cases where
  /// switching it off is what was wanted.
  Future<void> remove(String code) =>
      client.rpc('platform_delete_entity_type', params: {'p_code': code});
}

final entityTypesRepoProvider = Provider<EntityTypesRepo>(
  (ref) => EntityTypesRepo(ref.watch(supabaseProvider)),
);

/// Every kind, including the ones switched off. For the console.
final allEntityTypesProvider = FutureProvider<List<EntityType>>(
  (ref) => ref.watch(entityTypesRepoProvider).all(),
);

/// The kinds a CONTACT may be, switched on, in the order they should
/// appear.
///
/// Kept apart from the console's list because the two want different
/// things: an operator needs to see what is switched off in order to
/// switch it back on, and a contact form must never offer it.
final contactEntityTypesProvider = FutureProvider<List<EntityType>>((
  ref,
) async {
  final all = await ref.watch(allEntityTypesProvider.future);
  return all.where((e) => e.isActive && e.forContacts).toList();
});
