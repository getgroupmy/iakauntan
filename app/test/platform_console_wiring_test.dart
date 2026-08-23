import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The platform console reads the platform's own tables, not a company's.
///
/// This is a source-level assertion rather than a widget one, and it is
/// here because the bug it guards against had no symptom worth the name.
/// `repoProvider` is null until an organization has been resolved, so a
/// data layer hung off it returned `?? const []` and the Modules &
/// pricing tab drew an empty list — no error, no spinner, nothing to say
/// why, for every platform administrator who did not happen to own a
/// company. The save paths did worse: `ref.read(repoProvider)!` threw on
/// the null.
///
/// None of what these files read belongs to an organization.
/// `platform_modules`, `payment_gateways`, `platform_settings` and the
/// landing page are the platform's own, and every RPC behind them takes
/// no org argument. So the rule is simply that they must not reach for a
/// tenant repository, and a rule that is not checked is a rule that
/// comes back.
void main() {
  const files = [
    'lib/src/data/platform_catalog_repository.dart',
    'lib/src/data/landing_repository.dart',
    'lib/src/features/admin/modules_admin.dart',
    'lib/src/features/admin/payment_gateways_admin.dart',
    'lib/src/features/admin/landing_cms.dart',
  ];

  for (final path in files) {
    test('$path does not bind platform data to one company', () {
      final file = File(path);
      expect(file.existsSync(), isTrue,
          reason: '$path moved; this guard has to move with it');
      final source = file.readAsStringSync();

      // Comments may name it — the ones in these files explain the bug.
      final code = source
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');

      expect(code.contains('repoProvider'), isFalse,
          reason: 'the platform console must not wait on an organization');
      // The null-assert that turned a missing organization into a crash
      // on save rather than a message.
      expect(code.contains('ref.read(repoProvider)!'), isFalse);
    });
  }

  test('the console reads through providers bound to the session', () {
    final catalogue =
        File('lib/src/data/platform_catalog_repository.dart').readAsStringSync();
    final landing =
        File('lib/src/data/landing_repository.dart').readAsStringSync();
    // supabaseProvider is the session's client and exists from the first
    // frame; that is the whole point of using it here.
    expect(catalogue.contains('ref.watch(supabaseProvider)'), isTrue);
    expect(landing.contains('ref.watch(supabaseProvider)'), isTrue);
  });
}
