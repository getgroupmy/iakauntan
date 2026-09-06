import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/format.dart';
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

  /// Every promotion, active or not, with the module and company it
  /// names resolved.
  ///
  /// Through the RPC rather than the table: the read policy shows a
  /// tenant its own promotions and the ones open to everybody, which is
  /// the wrong list for a console -- an operator has to see what every
  /// customer was given, including the promotions that have ended.
  Future<List<Map<String, dynamic>>> promotions() async =>
      Repo.rows(await client.rpc('platform_promotions'));

  /// Create one ([id] null) or change one.
  ///
  /// Every argument but [id] is optional and omitted when null, which
  /// is what lets the dialog send only what somebody actually changed.
  Future<String?> savePromotion({
    String? id,
    String? name,
    String? moduleCode,
    String? orgId,
    String? kind,
    int? trialDays,
    double? percentOff,
    double? fixedPrice,
    DateTime? startsOn,
    DateTime? endsOn,
    bool? isActive,
    String? notes,
  }) async => await client.rpc(
    'platform_save_promotion',
    params: {
      if (id != null) 'p_id': id,
      if (name != null) 'p_name': name,
      if (moduleCode != null) 'p_module_code': moduleCode,
      if (orgId != null) 'p_org_id': orgId,
      if (kind != null) 'p_kind': kind,
      if (trialDays != null) 'p_trial_days': trialDays,
      if (percentOff != null) 'p_percent_off': percentOff,
      if (fixedPrice != null) 'p_fixed_price': fixedPrice,
      if (startsOn != null) 'p_starts_on': Fmt.iso(startsOn),
      if (endsOn != null) 'p_ends_on': Fmt.iso(endsOn),
      if (isActive != null) 'p_is_active': isActive,
      if (notes != null) 'p_notes': notes,
    },
  ) as String?;

  /// Stop one, today, for everybody at once. There is no delete: a
  /// promotion that has priced an invoice is part of why that invoice
  /// says what it says.
  Future<void> endPromotion(String id) =>
      client.rpc('platform_end_promotion', params: {'p_id': id});

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
    List<String>? countries,
    List<String>? methods,
    String? docsUrl,
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
      // Sent when the caller passed one, omitted when it did not, which
      // is the difference `0352` turns on: null leaves the column
      // alone and `[]` means the gateway sells everywhere. A screen
      // that always sent `countries` would empty the coverage list of
      // every gateway somebody merely switched on.
      if (countries != null) 'p_countries': countries,
      if (methods != null) 'p_methods': methods,
      if (docsUrl != null) 'p_docs_url': docsUrl,
    },
  );

  /// The gateways this platform has switched on that sell where a
  /// company is.
  ///
  /// Takes the country in either spelling. `organizations.country_code`
  /// is alpha-3 and `payment_gateways.countries` is alpha-2, and `0352`
  /// resolves between them in the database rather than leaving every
  /// caller to remember — the failure when one forgets is an empty list
  /// rather than an error, which reads as "there is no way to pay us".
  ///
  /// Unlike [paymentGateways] this runs as the caller, so the read
  /// policy withholds a gateway still being set up. That is the whole
  /// difference between the two: this is what a tenant may see.
  Future<List<Map<String, dynamic>>> gatewaysFor(String? country) async =>
      Repo.rows(
        await client.rpc(
          'payment_gateways_for',
          params: {'p_country': country},
        ),
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

/// Every promotion, for the console's list.
final platformPromotionsAdminProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(platformCatalogProvider).promotions(),
);

final platformGatewaysAdminProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(platformCatalogProvider).paymentGateways(),
);

/// The ways a company in a given country may pay.
///
/// A family on the country rather than a read of the current
/// organization, because the console shows the same list for a country
/// an operator picked and the settings screen shows it for the one the
/// company is registered in. One provider, two questions with the same
/// shape.
final gatewaysForCountryProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String?>(
  (ref, country) => ref.watch(platformCatalogProvider).gatewaysFor(country),
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
