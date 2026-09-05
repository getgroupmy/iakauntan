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
/// None of what the console reads belongs to an organization.
/// `platform_modules`, `payment_gateways`, `platform_settings`, the
/// landing page, the AI provider catalogue and the reader catalogue are
/// the platform's own, and every RPC behind them takes no org argument.
/// So the rule is that the console must not reach for a tenant
/// repository, and a rule that is not checked is a rule that comes back.
///
/// IT DID COME BACK. The first version of this file named five paths by
/// hand. `ai_providers_admin.dart` and `ocr_catalog_admin.dart` were
/// written afterwards, were not on the list, and reproduced the bug
/// exactly — an operator who belongs to no company got "Your company has
/// not finished loading" on the AI providers screen with no way past it,
/// which is the same failure wearing `requireRepo`'s politer face. A
/// guard that has to be extended by hand every time a screen is added is
/// a guard that only covers the screens somebody remembered.
///
/// So it enumerates instead of listing. Both arms matter:
///
///  1. No file under `features/admin/` may name a tenant repository.
///  2. No provider one of those files WATCHES may be built on one —
///     which is where this hid, because `aiProviderCatalogueProvider`
///     lives in `core/providers.dart` among hundreds of providers that
///     are quite correctly bound to a company.
void main() {
  final adminDir = Directory('lib/src/features/admin');

  List<String> codeLines(String source) => source
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//') &&
                    !l.trimLeft().startsWith('///'))
      .toList();

  final adminFiles = adminDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('there are admin panes to check', () {
    // A glob that matches nothing passes every assertion under it.
    expect(adminFiles.length, greaterThan(8));
  });

  // ------------------------------------------------------------------
  // 1. The panes themselves
  // ------------------------------------------------------------------
  for (final file in adminFiles) {
    test('${file.path} does not bind platform data to one company', () {
      // Comments may name it — the ones in these files explain the bug.
      final code = codeLines(file.readAsStringSync()).join('\n');

      expect(code.contains('repoProvider'), isFalse,
          reason: 'the platform console must not wait on an organization');
      expect(code.contains('requireRepo'), isFalse,
          reason: 'requireRepo throws OrgNotReady, which reaches an '
              'operator with no company as "Your company has not '
              'finished loading" and no way past it');
    });
  }

  // ------------------------------------------------------------------
  // 2. The providers those panes read through
  // ------------------------------------------------------------------
  //
  // This is the arm that would have caught the AI providers screen. The
  // pane itself was clean; the provider it watched was four hundred
  // lines deep in `core/providers.dart` and read `requireRepo(ref)`.
  final sources = <String, String>{};
  for (final f in Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))) {
    sources[f.path] = f.readAsStringSync();
  }

  /// The whole `final name = ...;` declaration, brace- and paren-aware,
  /// so a provider spanning ten lines is read whole rather than to the
  /// first semicolon inside it.
  String? declarationOf(String name) {
    for (final entry in sources.entries) {
      final m = RegExp('^final $name\\b', multiLine: true)
          .firstMatch(entry.value);
      if (m == null) continue;
      var depth = 0;
      for (var i = m.start; i < entry.value.length; i++) {
        final ch = entry.value[i];
        if ('([{'.contains(ch)) depth++;
        if (')]}'.contains(ch)) depth--;
        if (ch == ';' && depth == 0) {
          return entry.value.substring(m.start, i + 1);
        }
      }
    }
    return null;
  }

  final watched = <String>{};
  for (final file in adminFiles) {
    final code = codeLines(file.readAsStringSync()).join('\n');
    for (final m in RegExp(r'ref\.(?:watch|read)\((\w+Provider)')
        .allMatches(code)) {
      watched.add(m.group(1)!);
    }
  }

  test('the console watches something', () {
    expect(watched.length, greaterThan(10));
  });

  for (final name in watched.toList()..sort()) {
    test('$name is not built on a tenant repository', () {
      final decl = declarationOf(name);
      expect(decl, isNotNull,
          reason: '$name is watched by the console and has no top-level '
              'declaration this guard can read');
      final code = codeLines(decl!).join('\n');
      expect(code.contains('requireRepo'), isFalse,
          reason: '$name is read by the platform console, so it must not '
              'throw OrgNotReady at an operator who belongs to no '
              'company');
      expect(code.contains('repoProvider'), isFalse,
          reason: '$name is read by the platform console, so it must not '
              'be null until a company resolves');
    });
  }

  // ------------------------------------------------------------------
  // 3. What they are bound to instead
  // ------------------------------------------------------------------
  test('the console reads through repositories bound to the session', () {
    for (final path in const [
      'lib/src/data/platform_catalog_repository.dart',
      'lib/src/data/landing_repository.dart',
    ]) {
      // supabaseProvider is the session's client and exists from the
      // first frame; that is the whole point of using it here.
      expect(sources[path]!.contains('ref.watch(supabaseProvider)'), isTrue,
          reason: '$path should read through the session, not a company');
    }
  });

  test('the AI and reader catalogues hang off the platform', () {
    // Neither extension takes an org id in any method — that is what
    // made hanging them off `Repo` a mistake rather than a trade-off.
    expect(sources['lib/src/data/ai_repository.dart']!
        .contains('extension PlatformAiProviders on PlatformRepo'), isTrue);
    expect(sources['lib/src/data/ocr_repository.dart']!
        .contains('extension PlatformOcrCatalog on PlatformRepo'), isTrue);
  });
}
