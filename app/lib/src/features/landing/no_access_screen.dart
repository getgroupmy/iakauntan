import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/router.dart';
import '../../data/reserved_names_repository.dart';

/// What an address confined to a module says when the company has not
/// got that module.
///
/// `0342` lets an operator point an address at one part of the product.
/// The entitlement is a separate fact and it can lapse — a subscription
/// ends, or somebody puts the module away in settings — and when it
/// does, the address still resolves and there is nothing behind it.
///
/// Saying so in a sentence rather than by failing. The alternatives are
/// all worse: a blank screen, a redirect loop onto a page that will not
/// render, or the whole app opening as if the restriction were never
/// set, which would be the one outcome the operator was trying to
/// prevent.
///
/// It offers Sign out and nothing else. Somebody standing at a counter
/// tablet cannot fix a subscription, and pointing them at a settings
/// screen this address does not open would be a second dead end.
class NoAccessScreen extends ConsumerWidget {
  const NoAccessScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final door = confinementFor(
      ref.watch(workspaceLookupProvider).valueOrNull?.workspace,
    );
    final name = _moduleName(ref, door?.module);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline, size: 40, color: scheme.outline),
                const SizedBox(height: 20),
                Text(
                  name == null
                      ? 'This address is not open to you'
                      : '$name is not part of your subscription',
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(
                  'This web address opens one part of the product, and '
                  'your company does not have it — either it was never '
                  'subscribed to, or somebody has turned it off in '
                  'settings. Ask whoever looks after your account.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 28),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        ref.read(supabaseProvider).auth.signOut(),
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('Sign out'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The module's own name, as the catalogue spells it.
  ///
  /// Null while the catalogue is loading, or for a code nobody sells any
  /// more — and the sentence above falls back to one that names nothing
  /// rather than printing a code like `property_strata` at somebody.
  String? _moduleName(WidgetRef ref, String? code) {
    if (code == null) return null;
    final modules = ref.watch(platformModulesProvider).valueOrNull;
    if (modules == null) return null;
    for (final m in modules) {
      if (m.code == code) return m.name.isEmpty ? null : m.name;
    }
    return null;
  }
}
