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
      //
      // What fills the gap changed when the shipped sections arrived:
      // an unpublished page shows those rather than nothing. The
      // property being guarded is unchanged and is the one that
      // matters — the operator's unpublished draft is not on screen.
      expect(
        c.sections.map((s) => s.title),
        isNot(contains('Draft')),
        reason: 'an unpublished draft block must not render',
      );
      expect(c.sections, equals(defaultSections));
      expect(c.appLinks, isEmpty);
    });

    test('something that is not a map at all', () {
      expect(parseLandingContent('nonsense').published, isFalse);
      expect(parseLandingContent(42).published, isFalse);
      expect(parseLandingContent(const []).published, isFalse);
    });
  });

  group('a written page', () {
    LandingContent published(Map<String, dynamic> extra) =>
        parseLandingContent({
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
      expect(
        parseLandingContent({
          'page': {'wordmark': 'x'},
        }).showPricing,
        isFalse,
      );
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
      expect(monthlyTotal(all, const {'sales'}), monthlyTotal(all, const {}));
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
      expect(
        parse({'app_icon_url': 'https://x/icon.png'}).appIconUrl,
        'https://x/icon.png',
      );
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

  /// 0316: the brand is not gated on publishing.
  ///
  /// The bug this replaces was found in production. The console saved a
  /// logo, a colour and an icon correctly, and none of them reached the
  /// app, because `landing_page()` returned the row only when the page
  /// was published — so branding your own accounting system required
  /// putting a marketing site on the internet.
  group('brand without a published page', () {
    LandingContent parse(Map<String, dynamic> page) =>
        parseLandingContent({'page': page, 'sections': const []});

    LandingContent unpublished(Map<String, dynamic> brand) =>
        parseLandingContent({'page': null, 'brand': brand});

    final brand = <String, dynamic>{
      'wordmark': 'Akaun Saya',
      'logo_url': 'https://x/logo.png',
      'logo_dark_url': 'https://x/logo-dark.png',
      'brand_colour': '#BE123C',
      'brand_colour_dark': '#7F1D1D',
      'theme_mode': 'dark',
      'app_icon_url': 'https://x/icon.png',
    };

    test('every brand field survives an unpublished page', () {
      final c = parseLandingContent({'page': null, 'brand': brand});
      expect(c.wordmark, 'Akaun Saya');
      expect(c.logoUrl, 'https://x/logo.png');
      expect(c.logoDarkUrl, 'https://x/logo-dark.png');
      expect(c.brandColour, '#BE123C');
      expect(c.brandColourDark, '#7F1D1D');
      expect(c.themeMode, 'dark');
      expect(c.appIconUrl, 'https://x/icon.png');
    });

    // The site is still not published, and that has to stay true — the
    // fix must not put anybody's draft front page up.
    test('and the page is still not published', () {
      expect(
        parseLandingContent({'page': null, 'brand': brand}).published,
        isFalse,
      );
      expect(parse({'wordmark': 'x'}).published, isTrue);
    });

    test('an unbranded platform falls back to what shipped', () {
      final c = unpublished(const {});
      expect(c.wordmark, 'iAkauntan');
      expect(c.themeMode, 'system');
      expect(c.logoUrl, isNull);
      expect(c.brandColour, isNull);
    });

    test('and so does one with no brand key at all', () {
      final c = parseLandingContent({'page': null});
      expect(c.wordmark, 'iAkauntan');
      expect(c.themeMode, 'system');
      expect(c.published, isFalse);
    });

    // A published payload written before 0316 carried these on the page.
    test('a payload from before 0316 still reads', () {
      final c = parse({'wordmark': 'Lama', 'brand_colour': '#0B7A6B'});
      expect(c.wordmark, 'Lama');
      expect(c.brandColour, '#0B7A6B');
    });

    test('and the brand key wins when both carry it', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'Stale', 'brand_colour': '#000000'},
        'brand': {'wordmark': 'Akaun Saya', 'brand_colour': '#BE123C'},
      });
      expect(c.wordmark, 'Akaun Saya');
      expect(c.brandColour, '#BE123C');
    });

    test('a published page keeps its own copy', () {
      final c = parseLandingContent({
        'page': {'hero_headline': 'Real headline'},
        'brand': brand,
      });
      expect(c.heroHeadline, 'Real headline');
      expect(c.wordmark, 'Akaun Saya');
      expect(c.published, isTrue);
    });

    test('rubbish in the brand key is not a crash', () {
      expect(
        parseLandingContent({'page': null, 'brand': 'nope'}).wordmark,
        'iAkauntan',
      );
      expect(
        parseLandingContent({'page': null, 'brand': 42}).themeMode,
        'system',
      );
    });
  });

  /// The page has something to say before anybody writes anything.
  ///
  /// `sections` used to default to an empty list, so a platform that had
  /// not been through the console had a front page with a hero, a footer
  /// and nothing in between.
  group('default sections', () {
    test('an unwritten page still describes the product', () {
      final c = parseLandingContent({'page': null, 'brand': const {}});
      expect(c.sections, isNotEmpty);
      expect(c.sections.length, defaultSections.length);
    });

    test('and so does the offline fallback', () {
      expect(LandingContent.fallback.sections, isNotEmpty);
    });

    // Replaced wholesale, not merged. An operator who wrote three blocks
    // means three blocks — not three plus five they never asked for.
    test('one row in the console replaces all of them', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'Akaun Saya'},
        'sections': [
          {'icon': 'receipt', 'title': 'Only this', 'body': 'One block.'},
        ],
      });
      expect(c.sections.length, 1);
      expect(c.sections.single.title, 'Only this');
    });

    test('and an empty list in the payload is still the defaults', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'Akaun Saya'},
        'sections': const [],
      });
      expect(c.sections.length, defaultSections.length);
    });

    // Every default has to render: the grid draws an icon for each, and
    // an unknown name silently becomes a generic tick, which is how a
    // typo survives review.
    test('every default names an icon the screen knows', () {
      const known = {
        'receipt',
        'expenses',
        'payments',
        'people',
        'inventory',
        'store',
        'insights',
        'shield',
        'cloud',
      };
      for (final s in defaultSections) {
        expect(known, contains(s.icon), reason: '${s.title} uses ${s.icon}');
        expect(s.title.trim(), isNotEmpty);
        expect(s.body, isNotNull);
        expect(s.body!.trim(), isNotEmpty);
      }
    });
  });

  // ---- 0317 ----

  group('reasons', () {
    test('an unwritten page still says why to choose it', () {
      expect(parseLandingContent(null).reasons, defaultReasons);
      expect(LandingContent.fallback.reasons, defaultReasons);
    });

    test('one row in the console replaces all of them', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'reasons': [
          {'title': 'Local support', 'body': 'In KL.', 'icon': 'support'},
        ],
      });
      expect(c.reasons.length, 1);
      expect(c.reasons.first.title, 'Local support');
    });

    test('features and reasons do not leak into one another', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'sections': [
          {'title': 'Payroll'},
        ],
        'reasons': [
          {'title': 'Local support'},
        ],
      });
      expect(c.sections.map((s) => s.title), ['Payroll']);
      expect(c.reasons.map((s) => s.title), ['Local support']);
    });

    test('every default names an icon the screen knows', () {
      const known = {
        'gavel',
        'calculate',
        'lock',
        'devices',
        'sync_alt',
        'payments',
      };
      for (final r in defaultReasons) {
        expect(known, contains(r.icon), reason: '${r.title} uses ${r.icon}');
        expect(r.body, isNotNull);
        expect(r.body!.trim(), isNotEmpty);
      }
    });
  });

  group('what it files under', () {
    test('an unwritten page still says what it files under', () {
      expect(parseLandingContent(null).badges, defaultBadges);
      expect(LandingContent.fallback.badges, defaultBadges);
    });

    test('one row in the console replaces all of them', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'badges': [
          {'title': 'ISO 27001', 'icon': 'shield'},
        ],
      });
      expect(c.badges.single.title, 'ISO 27001');
    });

    test('the three kinds do not leak into one another', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'sections': [
          {'title': 'Payroll'},
        ],
        'reasons': [
          {'title': 'Local support'},
        ],
        'badges': [
          {'title': 'SST'},
        ],
      });
      expect(c.sections.map((s) => s.title), ['Payroll']);
      expect(c.reasons.map((s) => s.title), ['Local support']);
      expect(c.badges.map((s) => s.title), ['SST']);
    });

    // The line this band must not cross. Every shipped badge names a
    // Malaysian statutory regime this repository implements — a claim
    // about the code, checkable from it. A certification is a claim
    // that an auditor examined a company and passed it, which nobody
    // here is in a position to make, and which would be a lie on a page
    // asking for money rather than a stretch.
    test('nothing shipped claims a certification nobody holds', () {
      const audits = [
        'iso',
        'soc 2',
        'soc2',
        'pci',
        'hipaa',
        'gdpr certified',
        'certified',
        'accredited',
      ];
      for (final b in defaultBadges) {
        final t = b.title.toLowerCase();
        for (final a in audits) {
          expect(
            t.contains(a),
            isFalse,
            reason: '"${b.title}" reads as a certification claim',
          );
        }
      }
    });

    test('and every one names an icon the screen knows', () {
      const known = {
        'receipt',
        'gavel',
        'people',
        'calculate',
        'shield',
        'insights',
      };
      for (final b in defaultBadges) {
        expect(known, contains(b.icon), reason: '${b.title} uses ${b.icon}');
        // The strip draws an icon and a line. A body would be stored
        // and never rendered.
        expect(b.body, isNull);
      }
    });
  });

  group('the three that ship empty', () {
    // The assertion this group exists for. A default added here later —
    // a sample stat, an example quote, a placeholder logo — is a claim
    // about the world that nobody made, on a page that asks people for
    // money. Unlike the copy above, which describes what this
    // repository does and is checkable from the source.
    test('nothing is invented when the console has written nothing', () {
      for (final c in [
        parseLandingContent(null),
        LandingContent.fallback,
        parseLandingContent({'page': <String, dynamic>{}}),
      ]) {
        expect(c.stats, isEmpty);
        expect(c.testimonials, isEmpty);
        expect(c.logos, isEmpty);
      }
    });

    test('an empty list stays an empty list', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'stats': const [],
        'testimonials': const [],
        'logos': const [],
      });
      expect(c.stats, isEmpty);
      expect(c.testimonials, isEmpty);
      expect(c.logos, isEmpty);
    });

    test('a figure keeps the formatting it was given', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'stats': [
          {'value': '240,000', 'label': 'Businesses', 'icon': 'store'},
        ],
      });
      expect(c.stats.single.value, '240,000');
      expect(c.stats.single.label, 'Businesses');
    });

    test('a figure with no label is dropped, and the rest survive', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'stats': [
          {'value': '30'},
          {'value': '12', 'label': 'Outlets'},
        ],
      });
      expect(c.stats.map((s) => s.label), ['Outlets']);
    });

    test('a quote with nobody against it is dropped, not shown', () {
      // Not rendered anonymously. An unattributed testimonial is the
      // shape a fabricated one takes, and the database refuses to store
      // one; a row that arrived without an author anyway is not
      // something to put on the page and attribute to nobody.
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'testimonials': [
          {'quote': 'Best software ever.'},
          {'quote': 'It works.', 'author': '  '},
          {'quote': 'Payroll takes an hour.', 'author': 'Lim Wei Jian'},
        ],
      });
      expect(c.testimonials.map((t) => t.author), ['Lim Wei Jian']);
    });

    test('a testimonial carries the company when there is one', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'testimonials': [
          {'quote': 'q', 'author': 'a', 'company': '  '},
          {'quote': 'q', 'author': 'b', 'company': 'Kedai Besi Maju'},
        ],
      });
      expect(c.testimonials.first.company, isNull);
      expect(c.testimonials.last.company, 'Kedai Besi Maju');
    });

    test('a logo the browser cannot fetch is dropped', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'logos': [
          {'name': 'Relative', 'logo_url': '/assets/a.png'},
          {'logo_url': 'https://cdn.test/b.png'},
          {'name': 'Sinar', 'logo_url': 'https://cdn.test/sinar.png'},
        ],
      });
      expect(c.logos.map((l) => l.name), ['Sinar']);
    });

    // Not only the three: `as List?` threw on a string, and every list
    // on this page went through it. A front page that will not open
    // because one key came back malformed is a front page nobody can
    // sign in from, which is the one thing this parser exists to
    // prevent.
    test('a list key that is not a list is no rows, not a crash', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'sections': 'nope',
        'reasons': 42,
        'app_links': {'not': 'a list'},
        'modules': 'nope',
      });
      expect(c.published, isTrue);
      // Empty means the shipped copy, which is what an absent key does.
      expect(c.sections, defaultSections);
      expect(c.reasons, defaultReasons);
      expect(c.appLinks, isEmpty);
      expect(c.modules, isEmpty);
    });

    test('rubbish in any of the three is not a crash', () {
      final c = parseLandingContent({
        'page': {'wordmark': 'x'},
        'stats': 'nope',
        'testimonials': [42, null],
        'logos': {'not': 'a list'},
      });
      expect(c.published, isTrue);
      expect(c.stats, isEmpty);
      expect(c.testimonials, isEmpty);
      expect(c.logos, isEmpty);
    });
  });

  // ---- 0318 ----

  group('the draft preview', () {
    // The preview's whole value is that it cannot disagree with the
    // page. The database half of that is asserted in
    // `supabase/tests/landing_page.sql`, where the two payloads are
    // compared field for field. This is the client half: one parser,
    // so a payload that came from `platform_landing_preview` becomes
    // the same LandingContent a payload from `landing_page()` would.
    test('a draft payload parses exactly as a published one does', () {
      const payload = {
        'page': {
          'wordmark': 'iAkauntan',
          'hero_headline': 'Perakaunan untuk perniagaan Malaysia',
          'cta_headline': 'Mula hari ini',
        },
        'sections': [
          {'title': 'e-Invoice', 'body': 'To MyInvois.', 'icon': 'receipt'},
        ],
        'reasons': [
          {'title': 'Support', 'body': 'In Bahasa Melayu.', 'icon': 'support'},
        ],
        'stats': [
          {'value': '30', 'label': 'Years', 'icon': 'schedule'},
        ],
        'testimonials': [
          {'quote': 'It works.', 'author': 'Lim Wei Jian'},
        ],
        'logos': [
          {'name': 'Sinar', 'logo_url': 'https://cdn.test/sinar.png'},
        ],
      };
      final c = parseLandingContent(payload);

      // `published` is true because a page came back, which is what the
      // preview hands over — the draft is drawn as the finished page,
      // because that is the question the operator is asking.
      expect(c.published, isTrue);
      expect(c.heroHeadline, 'Perakaunan untuk perniagaan Malaysia');
      expect(c.ctaHeadline, 'Mula hari ini');
      expect(c.sections.single.title, 'e-Invoice');
      expect(c.reasons.single.title, 'Support');
      expect(c.stats.single.value, '30');
      expect(c.testimonials.single.author, 'Lim Wei Jian');
      expect(c.logos.single.name, 'Sinar');
    });

    test('and a refused preview does not take the console down', () {
      // The provider catches nothing itself; what it must not do is
      // produce a shape the parser chokes on. An admin whose session
      // expired mid-edit gets the fallback page, not an exception.
      expect(parseLandingContent(null).published, isFalse);
      expect(parseLandingContent('42501').published, isFalse);
    });
  });

  group('the hero picture and the call to action', () {
    test('the hero image is read', () {
      // A column on `landing_page` since 0290 that nothing read until
      // the hero became two columns: the CMS wrote it and the page
      // ignored it.
      final c = parseLandingContent({
        'page': {'hero_image_url': 'https://cdn.test/hero.png'},
      });
      expect(c.heroImageUrl, 'https://cdn.test/hero.png');
    });

    test('and cleared falls back to the picture that ships', () {
      // 0321. It shipped null, and null drew the empty window frame —
      // right for a platform that has not chosen an image, wrong for
      // this one, which has a screenshot of its own dashboard sitting
      // in the web bundle. Cleared in the console, the built-in comes
      // back, which is what every other defaulted field here does.
      final c = parseLandingContent({
        'page': {'hero_image_url': '   '},
      });
      expect(c.heroImageUrl, defaultHeroImageUrl);
      expect(parseLandingContent(null).heroImageUrl, defaultHeroImageUrl);
    });

    test('the picture that ships is served from this origin', () {
      // Same origin as the page: it survives a strict connect policy
      // and does not hand a third party the referrer of every visitor
      // to the front page.
      expect(defaultHeroImageUrl, startsWith('https://iakauntan.com/'));
    });

    test('the call to action arrives whole', () {
      final c = parseLandingContent({
        'page': {
          'cta_headline': 'Mula hari ini',
          'cta_body': 'Percubaan 30 hari.',
          'cta_label': 'Cuba percuma',
          'cta_url': 'https://iakauntan.test/daftar',
        },
      });
      expect(c.ctaHeadline, 'Mula hari ini');
      expect(c.ctaBody, 'Percubaan 30 hari.');
      expect(c.ctaLabel, 'Cuba percuma');
      expect(c.ctaUrl, 'https://iakauntan.test/daftar');
    });

    test('and there is none until somebody writes a headline', () {
      // The band renders on `ctaHeadline` alone, so an unwritten one
      // has to be null rather than an empty string.
      expect(parseLandingContent(null).ctaHeadline, isNull);
      expect(
        parseLandingContent({'page': <String, dynamic>{}}).ctaHeadline,
        isNull,
      );
    });
  });

  group('the switches that take the buttons off', () {
    test('all eight are read', () {
      final c = parseLandingContent({
        'page': {
          'bar_sign_in_desktop': false,
          'bar_sign_in_mobile': false,
          'bar_register_desktop': false,
          'bar_register_mobile': false,
          'hero_sign_in_desktop': false,
          'hero_sign_in_mobile': false,
          'hero_register_desktop': false,
          'hero_register_mobile': false,
        },
      });
      expect(c.barSignInDesktop, isFalse);
      expect(c.barSignInMobile, isFalse);
      expect(c.barRegisterDesktop, isFalse);
      expect(c.barRegisterMobile, isFalse);
      expect(c.heroSignInDesktop, isFalse);
      expect(c.heroSignInMobile, isFalse);
      expect(c.heroRegisterDesktop, isFalse);
      expect(c.heroRegisterMobile, isFalse);
    });

    test('and every one is its own decision', () {
      // The reason there are eight. Turning one off must move nothing
      // else — the failure this catches is a column read into the wrong
      // field, which no amount of clicking in the console would
      // explain.
      const keys = [
        'bar_sign_in_desktop',
        'bar_sign_in_mobile',
        'bar_register_desktop',
        'bar_register_mobile',
        'hero_sign_in_desktop',
        'hero_sign_in_mobile',
        'hero_register_desktop',
        'hero_register_mobile',
      ];
      for (final off in keys) {
        final c = parseLandingContent({
          'page': {off: false},
        });
        final drawn = {
          'bar_sign_in_desktop': c.barSignInDesktop,
          'bar_sign_in_mobile': c.barSignInMobile,
          'bar_register_desktop': c.barRegisterDesktop,
          'bar_register_mobile': c.barRegisterMobile,
          'hero_sign_in_desktop': c.heroSignInDesktop,
          'hero_sign_in_mobile': c.heroSignInMobile,
          'hero_register_desktop': c.heroRegisterDesktop,
          'hero_register_mobile': c.heroRegisterMobile,
        };
        expect(
          drawn.entries.where((e) => !e.value).map((e) => e.key),
          [off],
          reason: 'turning off $off moved something else',
        );
      }
    });

    test('the four questions the page asks pick the right pair', () {
      // `barSignIn(wide:)` and the three like it are what the screen
      // calls. A desktop switch answering a phone would be invisible in
      // the console and obvious to a visitor.
      final c = parseLandingContent({
        'page': {'bar_sign_in_mobile': false, 'hero_register_desktop': false},
      });
      expect(c.barSignIn(wide: true), isTrue);
      expect(c.barSignIn(wide: false), isFalse);
      expect(c.heroRegister(wide: true), isFalse);
      expect(c.heroRegister(wide: false), isTrue);
    });

    test('registration closed places no register button anywhere', () {
      // The switches say where a register button is drawn;
      // `register_enabled` says whether there is one to draw. Folded in
      // once, in the four questions, so no caller has to remember.
      final c = parseLandingContent({
        'page': {'register_enabled': false},
      });
      expect(c.barRegister(wide: true), isFalse);
      expect(c.barRegister(wide: false), isFalse);
      expect(c.heroRegister(wide: true), isFalse);
      expect(c.heroRegister(wide: false), isFalse);
      // And the sign-in switches are untouched by it, so turning
      // registration back on finds the page as it was left.
      expect(c.barSignIn(wide: true), isTrue);
      expect(c.heroSignIn(wide: false), isTrue);
    });

    test('absent reads as on, and so does nonsense', () {
      // A payload saved before the columns existed, a fallback with no
      // page at all, or a string where a boolean belongs. Every one of
      // them has to leave the visitor a way in: a page that hides its
      // own front door because a key was missing is worse than one that
      // shows a button somebody wanted hidden.
      for (final page in <Map<String, dynamic>>[
        <String, dynamic>{},
        {'bar_sign_in_desktop': 'false', 'hero_register_mobile': 0},
      ]) {
        final c = parseLandingContent({'page': page});
        expect(c.barSignIn(wide: true), isTrue, reason: '$page');
        expect(c.heroRegister(wide: false), isTrue, reason: '$page');
      }
      expect(parseLandingContent(null).barSignIn(wide: false), isTrue);
      expect(parseLandingContent(null).heroSignIn(wide: true), isTrue);
    });
  });
}
