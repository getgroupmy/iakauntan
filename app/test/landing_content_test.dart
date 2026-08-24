import 'package:flutter_test/flutter_test.dart';

import 'package:flutter/material.dart' show ThemeMode;

import 'package:iakauntan/src/app.dart' show themeModeFor;
import 'package:iakauntan/src/features/landing/landing_content.dart';

/// The landing page, on the screen side.
///
/// What a stranger may reach, and that an unpublished page stays
/// unpublished, is asserted in `supabase/tests/landing_page.sql` where
/// it belongs — those are policies and a SECURITY DEFINER function, and
/// a screen cannot weaken them.
///
/// What is asserted here is the thing the screen decides on its own:
/// that it survives whatever comes back. This page is the only route a
/// signed-out visitor has to the sign-in button, so a parser that throws
/// on an unexpected shape locks everybody out of their books.
void main() {
  group('an unwritten page', () {
    test('nothing at all still gives a page to draw', () {
      final c = parseLandingContent(null);
      expect(c.published, isFalse);
      expect(c.wordmark, 'iAkauntan');
      expect(c.signInLabel, 'Sign in');
      // The built-in copy, not a blank screen: somebody arriving before
      // anybody has written the site can still sign in.
      expect(c.heroHeadline, isNotEmpty);
    });

    test('a null page is unpublished, whatever else came with it', () {
      final c = parseLandingContent({
        'page': null,
        'sections': [
          {'title': 'Draft'},
        ],
        'app_links': [
          {'store_code': 'play_store', 'url': 'https://play.google.com/x'},
        ],
      });
      expect(c.published, isFalse);
      // And the draft does not leak in through the lists. The database
      // withholds them too; this is the second lock on the same door.
      expect(c.sections, isEmpty);
      expect(c.appLinks, isEmpty);
    });

    test('something that is not a map at all', () {
      expect(parseLandingContent('nonsense').published, isFalse);
      expect(parseLandingContent(42).published, isFalse);
      expect(parseLandingContent(const []).published, isFalse);
    });
  });

  group('a written page', () {
    LandingContent published(Map<String, dynamic> extra) => parseLandingContent({
          'page': {'wordmark': 'iAkauntan', ...extra},
          'sections': const [],
          'app_links': const [],
        });

    test('the fields it carries', () {
      final c = published({
        'tagline': 'Kira, bukan agak',
        'hero_headline': 'Perakaunan untuk perniagaan Malaysia',
        'logo_url': 'https://cdn.test/mark.png',
        'register_enabled': false,
      });
      expect(c.published, isTrue);
      expect(c.tagline, 'Kira, bukan agak');
      expect(c.heroHeadline, 'Perakaunan untuk perniagaan Malaysia');
      expect(c.logoUrl, 'https://cdn.test/mark.png');
      expect(c.registerEnabled, isFalse);
    });

    test('an empty string is as good as absent', () {
      // The console saves what the form holds, and a field somebody
      // cleared arrives as '' rather than as null. Drawn as absent, or
      // the page shows a heading with nothing under it.
      final c = published({'tagline': '   ', 'hero_headline': ''});
      expect(c.tagline, isNull);
      expect(c.heroHeadline, isNotEmpty);
    });

    test('a field of the wrong type does not take the page down', () {
      final c = published({'tagline': 42, 'register_enabled': 'yes'});
      expect(c.published, isTrue);
      expect(c.tagline, isNull);
      // Not 'yes': anything that is not a boolean leaves registration
      // as it was, which is on. Refusing to let anybody sign up because
      // a field arrived malformed is the worse failure.
      expect(c.registerEnabled, isTrue);
    });
  });

  group('sections', () {
    test('kept in the order they arrived', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'sections': [
          {'title': 'One', 'body': 'First', 'icon': 'receipt'},
          {'title': 'Two', 'body': 'Second'},
        ],
      });
      expect(c.sections.map((s) => s.title), ['One', 'Two']);
      expect(c.sections.first.icon, 'receipt');
    });

    test('one without a title is dropped, and the rest survive', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'sections': [
          {'body': 'No title'},
          {'title': '   '},
          {'title': 'Real'},
          'not a map',
        ],
      });
      expect(c.sections.map((s) => s.title), ['Real']);
    });
  });

  group('store buttons', () {
    test('a button with nowhere to go is dropped', () {
      // Worse than an absent one: the visitor taps it, nothing happens,
      // and they decide the product is broken.
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'app_links': [
          {'store_code': 'play_store', 'url': 'play.google.com/store'},
          {'store_code': 'app_store', 'url': 'https://apps.apple.com/my/app/x'},
          {'store_code': '', 'url': 'https://example.test'},
          {'url': 'https://example.test'},
        ],
      });
      expect(c.appLinks.map((l) => l.storeCode), ['app_store']);
    });

    test('a button with no label is labelled by its shop', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'app_links': [
          {'store_code': 'appgallery', 'url': 'https://appgallery.test/x'},
        ],
      });
      expect(c.appLinks.single.label, 'appgallery');
    });
  });

  group('the price list', () {
    LandingContent priced(List<Object?> modules) => parseLandingContent({
          'page': {'wordmark': 'x', 'show_pricing': true},
          'modules': modules,
        });

    test('what the page says about showing it', () {
      // Off unless the database said on. A parser that defaulted this to
      // true would publish a rate card the platform never agreed to.
      expect(parseLandingContent({'page': {'wordmark': 'x'}}).showPricing,
          isFalse);
      expect(priced(const []).showPricing, isTrue);
    });

    test('a module carries its price and whether it is included', () {
      final c = priced([
        {
          'code': 'accounting',
          'name': 'General Ledger',
          'description': 'Double-entry books',
          'monthly_price': 0,
          'is_core': true,
        },
        {
          'code': 'einvoice',
          'name': 'LHDN e-Invoice',
          'monthly_price': 49,
          'is_core': false,
        },
      ]);
      expect(c.modules.map((m) => m.code), ['accounting', 'einvoice']);
      expect(c.modules.first.isCore, isTrue);
      expect(c.modules.last.monthlyPrice, 49);
      expect(c.modules.last.description, isNull);
    });

    test('a price that arrived as a string is still a price', () {
      // numeric(18,2) comes back as a JSON string through some drivers
      // and as a number through others. Both are the same 49 ringgit.
      expect(
        priced([
          {'code': 'einvoice', 'name': 'e-Invoice', 'monthly_price': '49.00'},
        ]).modules.single.monthlyPrice,
        49,
      );
    });

    test('an unparseable price is nothing rather than a crash', () {
      final c = priced([
        {'code': 'einvoice', 'name': 'e-Invoice', 'monthly_price': 'RM49'},
        {'code': 'payroll', 'name': 'Payroll'},
      ]);
      expect(c.modules.map((m) => m.monthlyPrice), [0, 0]);
    });

    test('an entry with no code or no name is dropped', () {
      final c = priced([
        {'name': 'Nameless code'},
        {'code': 'x'},
        'not a map',
        {'code': 'payroll', 'name': 'Payroll', 'monthly_price': 39},
      ]);
      expect(c.modules.map((m) => m.code), ['payroll']);
    });
  });

  group('what a visitor is quoted', () {
    const LandingModule core = (
      code: 'accounting',
      name: 'General Ledger',
      description: null,
      monthlyPrice: 0.0,
      isCore: true,
    );
    const LandingModule paidCore = (
      code: 'sales',
      name: 'Sales & Invoicing',
      description: null,
      monthlyPrice: 79.0,
      isCore: true,
    );
    const LandingModule einvoice = (
      code: 'einvoice',
      name: 'LHDN e-Invoice',
      description: null,
      monthlyPrice: 49.0,
      isCore: false,
    );
    const LandingModule payroll = (
      code: 'payroll',
      name: 'Payroll',
      description: null,
      monthlyPrice: 39.0,
      isCore: false,
    );
    const all = <LandingModule>[core, paidCore, einvoice, payroll];

    test('nothing ticked still costs what the core costs', () {
      // The figure a visitor sees before touching anything is not zero,
      // because the core is not an add-on. Quoting zero and invoicing 79
      // a month later is the disagreement this function exists to stop.
      expect(monthlyTotal(all, const {}), 79);
    });

    test('ticking an add-on adds it', () {
      expect(monthlyTotal(all, const {'einvoice'}), 128);
      expect(monthlyTotal(all, const {'einvoice', 'payroll'}), 167);
    });

    test('a core module is counted whether it was ticked or not', () {
      // Untickable on the screen, so the two have to agree; if a core
      // module could be dropped from the sum by not appearing in the
      // set, a stale set would quote a price nobody sells.
      expect(monthlyTotal(all, const {'sales'}),
          monthlyTotal(all, const {}));
    });

    test('a code nobody offers is not charged for', () {
      // The set outlives the catalogue: somebody ticks a module, an
      // administrator retires it, and the page reloads. The quote has to
      // fall back to what is still on sale rather than keep charging.
      expect(monthlyTotal(all, const {'einvoice', 'telepathy'}), 128);
    });

    test('an empty catalogue quotes nothing', () {
      expect(monthlyTotal(const [], const {'einvoice'}), 0);
    });
  });

  /// The two fields 0314 added.
  ///
  /// Both ride in on `landing_page()`'s `to_jsonb(p)`, so nothing had to
  /// be taught they exist — which is exactly why the parser needs a test
  /// saying it reads them, and what it does when they are absent.
  group('branding', () {
    LandingContent parse(Map<String, dynamic> page) =>
        parseLandingContent({'page': page, 'sections': const []});

    test('the scheme is read', () {
      expect(parse({'theme_mode': 'dark'}).themeMode, 'dark');
      expect(parse({'theme_mode': 'light'}).themeMode, 'light');
    });

    // Every page written before 0314 has no such column, and neither
    // does the fallback the app uses when the network is down.
    test('and defaults to system when it is not there', () {
      expect(parse(const {}).themeMode, 'system');
      expect(LandingContent.fallback.themeMode, 'system');
    });

    test('the icon source is read, and is null when unset', () {
      expect(parse({'app_icon_url': 'https://x/icon.png'}).appIconUrl,
          'https://x/icon.png');
      expect(parse(const {}).appIconUrl, isNull);
    });

    test('the stored scheme becomes the Flutter one', () {
      expect(themeModeFor('light'), ThemeMode.light);
      expect(themeModeFor('dark'), ThemeMode.dark);
      expect(themeModeFor('system'), ThemeMode.system);
    });

    // A database column reaching a switch expression. The front page is
    // not worth throwing away over a value nobody implemented.
    test('and anything else is the visitor\'s own preference', () {
      expect(themeModeFor(null), ThemeMode.system);
      expect(themeModeFor(''), ThemeMode.system);
      expect(themeModeFor('midnight'), ThemeMode.system);
      expect(themeModeFor('Dark'), ThemeMode.system);
    });
  });
}
