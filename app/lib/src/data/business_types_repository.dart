import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import 'repository.dart';

/// What setup offers, and what happens when somebody picks one.
///
/// `0553`. The catalogue is a table rather than a list in this bundle so
/// that a trade added to it appears in the picker without a release,
/// which is the same reasoning `platform_modules` already uses.

/// Every business type on offer, in the order the picker draws them.
///
/// Ordered by `sort_order`, which puts the sectors in a deliberate
/// order and `other` last. Read straight from the table rather than
/// through the org repository, because this runs before there is an
/// organization to be a member of.
final businessTypesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async => Repo.rows(
          await ref
              .watch(supabaseProvider)
              .from('business_types')
              .select('code, name, sector, module_codes')
              .eq('is_active', true)
              .order('sort_order', ascending: true),
        ));

/// The modules somebody may add at setup: everything on sale that is
/// not already part of the product.
///
/// Core modules are left out because they are on for everybody and a
/// tick nobody can untick is furniture. Retired modules are left out
/// too — the console keeps them visible for the opposite reason, but
/// offering one to somebody signing up would be selling something that
/// has been withdrawn.
final onboardingModulesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async => Repo.rows(
          await ref
              .watch(supabaseProvider)
              .from('platform_modules')
              .select('code, name, description, monthly_price, nav_group')
              .eq('is_active', true)
              .eq('is_core', false)
              .order('sort_order', ascending: true)
              .order('name', ascending: true),
        ));

/// Record what the company said it is, and switch on what it was shown.
///
/// One call rather than one per module: a company that is half set up
/// because the fourth request failed has modules that do not match what
/// it agreed to. The server does the same in one transaction.
Future<int> applyBusinessType(
  WidgetRef ref, {
  required String orgId,
  String? businessType,
  required List<String> modules,
}) async {
  final n = await ref.read(supabaseProvider).rpc(
    'apply_business_type',
    params: {
      'p_org_id': orgId,
      'p_business_type': businessType,
      'p_modules': modules,
    },
  );
  return n is int ? n : 0;
}
