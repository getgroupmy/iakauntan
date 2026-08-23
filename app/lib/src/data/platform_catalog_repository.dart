import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/providers.dart';
import 'repository.dart';

/// The catalogue a platform operator sells from, and how a company pays
/// for it.
///
/// Deliberately not an extension on [Repo]. A `Repo` is bound to one
/// organization, and none of this is: `platform_modules`,
/// `payment_gateways` and `platform_settings` are the platform's own
/// tables and every RPC below takes no org argument. Hanging them off
/// `Repo` cost a working console — `repoProvider` is null until an
/// organization has been resolved, so a platform administrator with no
/// company of their own, or anybody in the first second of a cold load,
/// got `?? const []` and a screen with no modules on it and nothing to
/// say why. The save paths were worse: `ref.read(repoProvider)!` threw
/// on the null.
///
/// So these take a client. What they read has nothing to do with which
/// company is open, and now the code says so.
class PlatformCatalog {
  const PlatformCatalog(this.client);

  final SupabaseClient client;

  /// Every module, whatever its state.
  ///
  /// Read from `platform_modules` rather than from any list in the app,
  /// so a module added after this screen was written appears in it
  /// without a release. Retired ones are included on purpose: the
  /// console is where a retired module is brought back, and a list that
  /// hid them would be a door that locks behind you.
  Future<List<Map<String, dynamic>>> modules() async => Repo.rows(
    await client
        .from('platform_modules')
        .select(
          'code, name, description, monthly_price, is_core, sort_order, '
          'is_active, nav_group',
        )
        .order('sort_order')
        .order('code'),
  );

  Future<void> saveModule(
    String code, {
    String? name,
    String? description,
    String? navGroup,
    double? monthlyPrice,
    int? sortOrder,
    bool? isActive,
  }) => client.rpc(
    'platform_save_module',
    params: {
      'p_code': code,
      if (name != null) 'p_name': name,
      if (description != null) 'p_description': description,
      if (navGroup != null) 'p_nav_group': navGroup,
      if (monthlyPrice != null) 'p_monthly_price': monthlyPrice,
      if (sortOrder != null) 'p_sort_order': sortOrder,
      if (isActive != null) 'p_is_active': isActive,
    },
  );

  /// Every gateway including the ones being set up, which the read
  /// policy withholds from a tenant.
  Future<List<Map<String, dynamic>>> paymentGateways() async =>
      Repo.rows(await client.rpc('platform_payment_gateways'));

  Future<void> savePaymentGateway(
    String code, {
    String? name,
    String? mode,
    String? currency,
    String? publishableKey,
    String? secretRef,
    String? checkoutUrl,
    String? instructions,
    bool? isActive,
    int? sortOrder,
  }) => client.rpc(
    'platform_save_payment_gateway',
    params: {
      'p_code': code,
      if (name != null) 'p_name': name,
      if (mode != null) 'p_mode': mode,
      if (currency != null) 'p_currency': currency,
      if (publishableKey != null) 'p_publishable_key': publishableKey,
      if (secretRef != null) 'p_secret_ref': secretRef,
      if (checkoutUrl != null) 'p_checkout_url': checkoutUrl,
      if (instructions != null) 'p_instructions': instructions,
      if (isActive != null) 'p_is_active': isActive,
      if (sortOrder != null) 'p_sort_order': sortOrder,
    },
  );

  /// Whether the side menu gathers destinations under module headings.
  Future<bool> navGrouping() async {
    final rows = Repo.rows(
      await client
          .from('platform_settings')
          .select('value')
          .eq('key', 'nav_grouping'),
    );
    if (rows.isEmpty) return false;
    final value = rows.first['value'];
    return value is Map && value['mode'] == 'by_module';
  }

  Future<void> setNavGrouping(bool grouped) => client.rpc(
    'platform_update_setting',
    params: {
      'p_key': 'nav_grouping',
      'p_value': {'mode': grouped ? 'by_module' : 'flat'},
    },
  );
}

/// The catalogue, bound to the session rather than to a company.
final platformCatalogProvider = Provider<PlatformCatalog>(
  (ref) => PlatformCatalog(ref.watch(supabaseProvider)),
);

final platformModulesAdminProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(platformCatalogProvider).modules(),
);

final platformGatewaysAdminProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(platformCatalogProvider).paymentGateways(),
);

/// True when the side menu should be gathered under module headings.
///
/// Watched by the shell as well as by the console, so switching it in
/// one place changes the other without a reload.
final navGroupingProvider = FutureProvider<bool>(
  (ref) => ref.watch(platformCatalogProvider).navGrouping(),
);

/// What each module is called and what heading it sits under, by code.
///
/// The shell needs this to group the menu, and it comes from the
/// database rather than from the destination list so that renaming a
/// module in the console renames it in every company's menu.
final moduleLabelsProvider =
    FutureProvider<Map<String, ({String name, String group})>>((ref) async {
  final rows = Repo.rows(
    await ref
        .watch(supabaseProvider)
        .from('platform_modules')
        .select('code, name, nav_group')
        .order('sort_order'),
  );
  return {
    for (final r in rows)
      '${r['code']}': (
        name: '${r['name']}',
        group: '${r['nav_group'] ?? r['name']}',
      ),
  };
});
