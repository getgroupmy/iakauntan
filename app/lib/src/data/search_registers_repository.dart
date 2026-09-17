import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/providers.dart';
import 'repository.dart';

/// One register Entity Search can offer.
///
/// `0606`. SSM registers companies and businesses, MIA registers
/// accountants and audit firms, the Malaysian Bar registers advocates
/// and solicitors — and the button used to know about one of them.
class SearchRegister {
  const SearchRegister({
    required this.code,
    required this.name,
    this.registers,
    this.canSearch = false,
    this.url,
    this.sortOrder = 100,
    this.isActive = true,
    this.isBuiltin = false,
  });

  final String code;

  /// What it is called in front of somebody: 'SSM', 'MIA'.
  final String name;

  /// What it registers, which is the half that tells somebody whether
  /// to pick it.
  final String? registers;

  /// Whether this application can ASK it.
  ///
  /// False is a fact about the register rather than unfinished work.
  /// MIA's is a form behind Cloudflare's bot challenge with no API;
  /// nobody has established what the Bar offers. A register that
  /// cannot be searched is still worth offering — it opens its own
  /// site, which is what somebody would do anyway.
  final bool canSearch;

  /// Where a person goes when it cannot be searched from here. The
  /// database refuses a register with neither, because that would be a
  /// choice that does nothing.
  final String? url;

  final int sortOrder;
  final bool isActive;
  final bool isBuiltin;

  factory SearchRegister.fromJson(Map<String, dynamic> j) => SearchRegister(
    code: '${j['code'] ?? ''}',
    name: '${j['name'] ?? j['code'] ?? ''}',
    registers: (j['registers'] as String?)?.trim().isEmpty ?? true
        ? null
        : '${j['registers']}'.trim(),
    canSearch: j['can_search'] == true,
    url: (j['url'] as String?)?.trim().isEmpty ?? true
        ? null
        : '${j['url']}'.trim(),
    sortOrder: (j['sort_order'] as num?)?.toInt() ?? 100,
    isActive: j['is_active'] != false,
    isBuiltin: j['is_builtin'] == true,
  );
}

class SearchRegistersRepo {
  const SearchRegistersRepo(this.client);

  final SupabaseClient client;

  Future<List<SearchRegister>> all() async => Repo.rows(
    await client
        .from('search_registers')
        .select(
          'code, name, registers, can_search, url, sort_order, '
          'is_active, is_builtin',
        )
        // Said out loud: supabase-js defaults ascending to true and
        // postgrest-dart defaults it to false.
        .order('sort_order', ascending: true)
        .order('name', ascending: true),
  ).map(SearchRegister.fromJson).toList();

  Future<String> save({
    required String code,
    required String name,
    String? registers,
    bool? canSearch,
    String? url,
    int? sortOrder,
    bool? isActive,
  }) async {
    final out = await client.rpc(
      'platform_save_search_register',
      params: {
        'p_code': code,
        'p_name': name,
        if (registers != null) 'p_registers': registers,
        if (canSearch != null) 'p_can_search': canSearch,
        if (url != null) 'p_url': url,
        if (sortOrder != null) 'p_sort_order': sortOrder,
        if (isActive != null) 'p_is_active': isActive,
      },
    );
    return '$out';
  }

  Future<void> remove(String code) => client.rpc(
    'platform_delete_search_register',
    params: {'p_code': code},
  );
}

final searchRegistersRepoProvider = Provider<SearchRegistersRepo>(
  (ref) => SearchRegistersRepo(ref.watch(supabaseProvider)),
);

/// Every register, including the ones switched off. For the console.
final allSearchRegistersProvider = FutureProvider<List<SearchRegister>>(
  (ref) => ref.watch(searchRegistersRepoProvider).all(),
);

/// The registers Entity Search offers, switched on, in order.
final offeredSearchRegistersProvider = FutureProvider<List<SearchRegister>>((
  ref,
) async {
  final all = await ref.watch(allSearchRegistersProvider.future);
  return all.where((r) => r.isActive).toList();
});
