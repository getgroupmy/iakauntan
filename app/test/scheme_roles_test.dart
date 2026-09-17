import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/landing/landing_content.dart';

/// One role of the scheme, chosen rather than derived.
///
/// `0343`. The thing worth asserting is that an override is applied
/// *on top of* the derivation: a platform that picks its own red keeps
/// a coherent scheme with that red in it, rather than a scheme with a
/// hole where Material's answers used to be.
///
/// And the readability rule, which is the one that ships silently
/// broken: Material pairs every role with an `on` colour computed from
/// the seed, and an override cannot replace the pair — so a pale
/// Primary would keep white text on every filled button.
void main() {
  ColorScheme base(Brightness b) =>
      ColorScheme.fromSeed(seedColor: AppTheme.seed, brightness: b);

  group('applying an override', () {
    test('replaces the one role and leaves the rest derived', () {
      final derived = base(Brightness.light);
      final out = AppTheme.applyOverrides(derived, const {'error': '#B91C1C'});

      expect(out.error, const Color(0xFFB91C1C));
      expect(out.primary, derived.primary);
      expect(out.secondary, derived.secondary);
      expect(out.surface, derived.surface);
    });

    test('and nothing at all when nothing was chosen', () {
      final derived = base(Brightness.light);
      expect(AppTheme.applyOverrides(derived, const {}), derived);
    });

    test('each of the six lands on the role the console shows', () {
      final out = AppTheme.applyOverrides(base(Brightness.light), const {
        'primary': '#111111',
        'container': '#222222',
        'secondary': '#333333',
        'surface': '#444444',
        'surfaceTint': '#555555',
        'error': '#666666',
      });

      expect(out.primary, const Color(0xFF111111));
      expect(out.primaryContainer, const Color(0xFF222222));
      expect(out.secondary, const Color(0xFF333333));
      expect(out.surface, const Color(0xFF444444));
      // The tone raised surfaces use, which is the tile labelled
      // "Surface tint" — not `surfaceTint`, an elevation overlay.
      expect(out.surfaceContainerHighest, const Color(0xFF555555));
      expect(out.error, const Color(0xFF666666));
    });

    test('a colour that is not a colour is ignored, not thrown on', () {
      // The database checks the shape, but this is the path every
      // screen goes through: a value typed wrong somewhere must not be
      // a product that will not draw.
      final derived = base(Brightness.light);
      final out = AppTheme.applyOverrides(derived, const {
        'error': 'crimson',
        'primary': '#0B7A6B',
      });

      expect(out.error, derived.error);
      expect(out.primary, const Color(0xFF0B7A6B));
    });

    test('and a role nobody has heard of changes nothing', () {
      final derived = base(Brightness.light);
      expect(
        AppTheme.applyOverrides(derived, const {'tertiary': '#123456'}),
        derived,
      );
    });
  });

  group('the writing on it', () {
    test('goes dark on a pale role', () {
      // The failure that ships silently: `onPrimary` is white for this
      // product's teal, and white on a pale override is a button with
      // no label.
      final out =
          AppTheme.applyOverrides(base(Brightness.light), const {
        'primary': '#FFF8DC',
      });

      expect(out.primary, const Color(0xFFFFF8DC));
      expect(out.onPrimary, isNot(Colors.white));
    });

    test('and white on a dark one', () {
      final out = AppTheme.applyOverrides(base(Brightness.light), const {
        'primary': '#0F172A',
      });
      expect(out.onPrimary, Colors.white);
    });

    test('for every role that has a pair', () {
      final out = AppTheme.applyOverrides(base(Brightness.light), const {
        'container': '#FFF8DC',
        'secondary': '#FFF8DC',
        'surface': '#FFF8DC',
        'surfaceTint': '#FFF8DC',
        'error': '#FFF8DC',
      });

      for (final ink in [
        out.onPrimaryContainer,
        out.onSecondary,
        out.onSurface,
        out.onSurfaceVariant,
        out.onError,
      ]) {
        expect(ink, isNot(Colors.white));
      }
    });
  });

  group('the theme the product is actually built with', () {
    test('carries the override through', () {
      final theme = AppTheme.light(overrides: const {'error': '#B91C1C'});
      expect(theme.colorScheme.error, const Color(0xFFB91C1C));
    });

    test('and the dark scheme has its own set', () {
      final light = AppTheme.light(overrides: const {'primary': '#111111'});
      final dark = AppTheme.dark(overrides: const {'primary': '#EEEEEE'});

      expect(light.colorScheme.primary, const Color(0xFF111111));
      expect(dark.colorScheme.primary, const Color(0xFFEEEEEE));
    });
  });

  group('reading them out of the payload', () {
    test('only the roles somebody chose', () {
      final content = parseLandingContent(const {
        'brand': {
          'scheme_light_error': '#B91C1C',
          'scheme_dark_primary': '#93C5FD',
        },
      });

      expect(content.schemeLight, {'error': '#B91C1C'});
      expect(content.schemeDark, {'primary': '#93C5FD'});
    });

    test('and nothing when nobody has chosen any', () {
      final content = parseLandingContent(const {'brand': {}});
      expect(content.schemeLight, isEmpty);
      expect(content.schemeDark, isEmpty);
    });

    test('the column name matches the one the database uses', () {
      // Two ends of the same value: a Dart map key and a Postgres
      // column, differing in exactly one place.
      expect(
        LandingContent.schemeColumn('light', 'surfaceTint'),
        'scheme_light_surface_tint',
      );
      expect(
        LandingContent.schemeColumn('dark', 'primary'),
        'scheme_dark_primary',
      );
    });
  });
}
