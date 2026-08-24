import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// One block of copy on the landing page.
typedef LandingSection = ({String? icon, String title, String? body});

/// One figure in the band of numbers.
///
/// [value] is a string rather than a number on purpose: "240,000", "30",
/// "1,200+" and "RM4b" are all things a band like this carries, and the
/// moment it is numeric somebody has to decide how to format it for a
/// page that only ever displays it.
typedef LandingStat = ({String value, String label, String? icon});

/// Something a customer said, and who said it.
typedef LandingTestimonial = ({
  String quote,
  String author,
  String? company,
  String? avatarUrl,
});

/// One mark on the customer wall.
typedef LandingLogo = ({String name, String logoUrl});

/// One thing a company can hold, and what it costs a month.
typedef LandingModule = ({
  String code,
  String name,
  String? description,
  double monthlyPrice,
  bool isCore,
});

/// What a chosen set of modules comes to a month.
///
/// Core modules are counted whether they were ticked or not — they are
/// what keeping books is, not an add-on — and everything else only when
/// it was. Pure, and exported, so the figure on the front page and the
/// test agree; a quote a visitor works out for themselves and an invoice
/// a month later must not disagree, and this is the half of that which
/// runs in a browser.
double monthlyTotal(List<LandingModule> modules, Set<String> chosen) =>
    modules
        .where((m) => m.isCore || chosen.contains(m.code))
        .fold<double>(0, (sum, m) => sum + m.monthlyPrice);

/// One shop the app can be downloaded from.
typedef LandingAppLink = ({
  String storeCode,
  String label,
  String url,
  String? badgeUrl,
});

/// The corporate landing page, as `landing_page()` returns it.
///
/// [published] is false when no platform administrator has published a
/// page yet. The screen shows its built-in copy in that case rather than
/// an error: a visitor who arrives before anybody has written the site
/// should still be able to sign in.
/// What the page says about the product before anybody has written
/// anything.
///
/// The page shipped with a hero and a footer and nothing between them:
/// `sections` defaulted to an empty list, and the feature blocks only
/// existed once somebody had added rows in the console. So a platform
/// that had not been through the CMS had a front page that said what the
/// product was called and nothing about what it does.
///
/// These are that missing middle. They are replaced wholesale the moment
/// `landing_sections` holds anything — one row in the console and none of
/// this is used — so they are a starting point rather than something to
/// work around.
///
/// Written from what this repository actually implements, and no further.
/// A landing page that claims a feature the product does not have costs
/// more than an empty one: the first person to look for it is a customer
/// who has already paid.
const defaultSections = <LandingSection>[
  (
    icon: 'receipt',
    title: 'LHDN e-Invoice',
    body: 'Submit to MyInvois from the invoice screen and keep the '
        'validated document, its UUID and its QR against the invoice it '
        'came from. Consolidated submission for the counter sales nobody '
        'asked a receipt for.',
  ),
  (
    icon: 'payments',
    title: 'Double-entry accounting',
    body: 'Sales, purchases, banking and a general ledger that balances '
        'by construction. Multi-currency with realised and unrealised '
        'gain posted where it belongs, and fiscal periods that close.',
  ),
  (
    icon: 'people',
    title: 'Payroll and HR',
    body: 'EPF, SOCSO, EIS and PCB computed to the statutory tables, '
        'leave and claims that post themselves to the ledger, and a bank '
        'file the payroll run exports.',
  ),
  (
    icon: 'store',
    title: 'Point of sale',
    body: 'Retail, food and beverage, and service businesses, on a '
        'counter, a tablet or a phone. Keeps selling when the connection '
        'drops and lands the batch when it returns.',
  ),
  (
    icon: 'inventory',
    title: 'Stock that ties to the ledger',
    body: 'Serial numbers and batches, several warehouses, landed cost, '
        'and units that differ between how you buy and how you sell. '
        'Reordering off measured demand rather than a guess.',
  ),
  (
    icon: 'shield',
    title: 'Corporate secretarial',
    body: 'Registers, resolutions and the SSM deadlines a company '
        'actually owes, counted on the Malaysian calendar rather than '
        'the server\'s.',
  ),
  (
    icon: 'insights',
    title: 'The statements an auditor asks for',
    body: 'Profit and loss, balance sheet, cash flow, changes in equity, '
        'aged receivables and payables, SST summary and deferred '
        'revenue — on screen, as PDF, and as CSV you can add up.',
  ),
  (
    icon: 'cloud',
    title: 'One place, every device',
    body: 'The same books in a browser, on Android and on iOS. Roles '
        'down to the individual permission, and an audit trail of who '
        'changed what.',
  ),
];

/// Why choose this one, as against what it does.
///
/// The same shape as a feature block and a different place on the page:
/// `landing_sections.kind` is `feature` or `reason`, and the database
/// splits them. Replaced wholesale the moment somebody writes a reason
/// of their own in the console.
///
/// Every line here is checkable against this repository, which is the
/// only test a claim on a front page can be held to. What is not here
/// is anything about how many customers there are, how long the company
/// has been trading, or what any of them think — those are
/// [LandingStat] and [LandingTestimonial], they ship empty, and they
/// stay empty until an operator writes figures they can stand behind.
const defaultReasons = <LandingSection>[
  (
    icon: 'gavel',
    title: 'Built for Malaysian rules',
    body: 'e-Invoice to MyInvois, SST, EPF, SOCSO, EIS, PCB and the SSM '
        'filing calendar. Not a foreign package with a Malaysian tax '
        'code bolted on the side.',
  ),
  (
    icon: 'calculate',
    title: 'The arithmetic is tested',
    body: 'Every statutory figure the software works out has an '
        'assertion behind it that fails if the number moves. The rate '
        'tables are dated, so last year is still computed last year\'s '
        'way.',
  ),
  (
    icon: 'lock',
    title: 'Your books are yours',
    body: 'Every company\'s data is separated in the database itself, '
        'not by a filter the application remembers to apply. Roles go '
        'down to the individual permission.',
  ),
  (
    icon: 'devices',
    title: 'One system, not five',
    body: 'Accounting, CRM, payroll, point of sale, stock and corporate '
        'secretarial share one ledger. A payroll run posts itself; a '
        'sale at the counter is in the accounts before the shift ends.',
  ),
  (
    icon: 'sync_alt',
    title: 'Nothing is locked in',
    body: 'Statements, ledgers and registers export as CSV and PDF, and '
        'a customer or item list imports the same way. Leaving is a '
        'download rather than a negotiation.',
  ),
  (
    icon: 'payments',
    title: 'Pay for what you use',
    body: 'The books are the core. Everything else — payroll, POS, '
        'corporate secretarial, ticketing — is a module a company turns '
        'on when it needs it and not before.',
  ),
];

class LandingContent {
  const LandingContent({
    required this.published,
    this.logoUrl,
    this.logoDarkUrl,
    this.wordmark = 'iAkauntan',
    this.tagline,
    this.brandColour,
    this.brandColourDark,
    this.appIconUrl,
    this.themeMode = 'system',
    this.heroHeadline =
        'Accounting, CRM, payroll and e-Invoice for Malaysian business',
    this.heroSubhead,
    this.signInLabel = 'Sign in',
    this.registerLabel = 'Create an account',
    this.registerEnabled = true,
    this.companyName,
    this.companyRegNo,
    this.address,
    this.supportEmail,
    this.supportPhone,
    this.privacyUrl,
    this.termsUrl,
    this.showPricing = false,
    this.pricingHeading,
    this.pricingNote,
    this.sections = defaultSections,
    this.reasons = defaultReasons,
    this.appLinks = const [],
    this.modules = const [],
    this.stats = const [],
    this.testimonials = const [],
    this.logos = const [],
    this.ctaHeadline,
    this.ctaBody,
    this.ctaLabel,
    this.ctaUrl,
  });

  final bool published;
  final String? logoUrl;
  final String? logoDarkUrl;
  final String wordmark;
  final String? tagline;
  final String? brandColour;
  final String? brandColourDark;

  /// The square source image the favicon and PWA icons are built from.
  /// Not rendered by the app itself — the built bundle already carries
  /// the generated icons — but the console shows it, and it is what CI
  /// reads at build time.
  final String? appIconUrl;

  /// Which scheme a visitor gets before they have chosen one: `system`,
  /// `light` or `dark`. Anything else is treated as `system`, because a
  /// theme is not worth throwing a front page away over.
  final String themeMode;
  final String heroHeadline;
  final String? heroSubhead;
  final String signInLabel;
  final String registerLabel;
  final bool registerEnabled;
  final String? companyName;
  final String? companyRegNo;
  final String? address;
  final String? supportEmail;
  final String? supportPhone;
  final String? privacyUrl;
  final String? termsUrl;
  final bool showPricing;
  final String? pricingHeading;
  final String? pricingNote;
  final List<LandingSection> sections;
  final List<LandingSection> reasons;
  final List<LandingAppLink> appLinks;
  final List<LandingModule> modules;

  /// The band of figures, and the two collections that go with it.
  ///
  /// Empty by default and empty until an operator writes rows in the
  /// console — no built-in copy, unlike [sections] and [reasons]. A
  /// customer count, a quote with somebody's name on it and another
  /// company's mark are claims about the world rather than descriptions
  /// of the software, and inventing them would put fabricated evidence
  /// on a page that asks people for money. The screen renders nothing
  /// where they are empty.
  final List<LandingStat> stats;
  final List<LandingTestimonial> testimonials;
  final List<LandingLogo> logos;

  /// The band partway down, for somebody who has read enough. Nothing
  /// renders unless [ctaHeadline] is set.
  final String? ctaHeadline;
  final String? ctaBody;
  final String? ctaLabel;
  final String? ctaUrl;

  /// The page nobody has written yet.
  ///
  /// Not an empty object: the defaults above are the copy the product
  /// ships with, so an unpublished site is a plain one rather than a
  /// blank one.
  static const LandingContent fallback = LandingContent(published: false);
}

/// Turn what the database returned into a page.
///
/// Kept separate from the widget and from the provider so the shapes
/// that actually arrive — a null page, a page with every optional field
/// missing, a list with a malformed entry in it — can be asserted
/// without a browser. A landing page that throws is a landing page
/// nobody can sign in from.
LandingContent parseLandingContent(Object? raw) {
  if (raw is! Map) return LandingContent.fallback;

  final page = raw['page'];

  // `0316`. The brand arrives in its own key and is never gated on
  // publishing: putting your own logo on your own accounting system
  // should not require putting a marketing site on the internet. Read
  // before the early return below, because that return is exactly the
  // unpublished case the brand still has to survive.
  final brand = raw['brand'] is Map ? raw['brand'] as Map : const {};

  String? from(Map m, String key) {
    final v = m[key];
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  // Brand first, then the page. The fallback is for a payload written
  // before 0316, where these fields only ever lived on the page.
  String? brandStr(String key) =>
      from(brand, key) ?? (page is Map ? from(page, key) : null);

  if (page is! Map) {
    return LandingContent(
      // Nobody has published a site, and that is still true — what
      // changed is that it no longer costs the operator their colours.
      published: false,
      logoUrl: brandStr('logo_url'),
      logoDarkUrl: brandStr('logo_dark_url'),
      wordmark: brandStr('wordmark') ?? 'iAkauntan',
      brandColour: brandStr('brand_colour'),
      brandColourDark: brandStr('brand_colour_dark'),
      appIconUrl: brandStr('app_icon_url'),
      themeMode: brandStr('theme_mode') ?? 'system',
    );
  }

  String? str(String key) => from(page, key);

  // `sections` and `reasons` are the same shape from the same table,
  // split by `landing_sections.kind`, so they are read the same way.
  List<LandingSection> blocks(String key) {
    final out = <LandingSection>[];
    for (final e in (raw[key] as List? ?? const [])) {
      if (e is! Map) continue;
      final title = e['title'];
      if (title is! String || title.trim().isEmpty) continue;
      out.add((
        icon: e['icon'] is String ? e['icon'] as String : null,
        title: title.trim(),
        body: e['body'] is String ? (e['body'] as String).trim() : null,
      ));
    }
    return out;
  }

  final sections = blocks('sections');
  final reasons = blocks('reasons');

  // The three that ship empty. No defaults to fall back to and none
  // wanted: an absent band is the correct rendering of "the operator
  // has not said", and anything else here would be this file inventing
  // a customer count.
  final stats = <LandingStat>[];
  for (final e in (raw['stats'] as List? ?? const [])) {
    if (e is! Map) continue;
    final value = e['value'];
    final label = e['label'];
    if (value is! String || value.trim().isEmpty) continue;
    if (label is! String || label.trim().isEmpty) continue;
    stats.add((
      value: value.trim(),
      label: label.trim(),
      icon: e['icon'] is String ? e['icon'] as String : null,
    ));
  }

  final testimonials = <LandingTestimonial>[];
  for (final e in (raw['testimonials'] as List? ?? const [])) {
    if (e is! Map) continue;
    final quote = e['quote'];
    final author = e['author'];
    // Dropped rather than shown anonymously. The saver refuses to store
    // a quote with nobody against it; a row that arrived without one
    // anyway is not something to put on the page and attribute to
    // nobody.
    if (quote is! String || quote.trim().isEmpty) continue;
    if (author is! String || author.trim().isEmpty) continue;
    testimonials.add((
      quote: quote.trim(),
      author: author.trim(),
      company: e['company'] is String && (e['company'] as String).trim().isNotEmpty
          ? (e['company'] as String).trim()
          : null,
      avatarUrl: e['avatar_url'] is String ? e['avatar_url'] as String : null,
    ));
  }

  final logos = <LandingLogo>[];
  for (final e in (raw['logos'] as List? ?? const [])) {
    if (e is! Map) continue;
    final name = e['name'];
    final url = e['logo_url'];
    // A broken image on a wall of customer marks reads as a customer
    // who left, so an address the browser cannot fetch is no row.
    if (name is! String || name.trim().isEmpty) continue;
    if (url is! String || !url.startsWith('http')) continue;
    logos.add((name: name.trim(), logoUrl: url));
  }

  final links = <LandingAppLink>[];
  for (final e in (raw['app_links'] as List? ?? const [])) {
    if (e is! Map) continue;
    final url = e['url'];
    final code = e['store_code'];
    // A button with nowhere to go is worse than an absent one: the
    // visitor taps it and decides the product is broken. The database
    // refuses a relative address; this refuses one that arrived any
    // other way.
    if (url is! String || !url.startsWith('http')) continue;
    if (code is! String || code.trim().isEmpty) continue;
    links.add((
      storeCode: code.trim(),
      label: e['label'] is String && (e['label'] as String).trim().isNotEmpty
          ? (e['label'] as String).trim()
          : code.trim(),
      url: url,
      badgeUrl: e['badge_url'] is String ? e['badge_url'] as String : null,
    ));
  }

  final modules = <LandingModule>[];
  for (final e in (raw['modules'] as List? ?? const [])) {
    if (e is! Map) continue;
    final code = e['code'];
    final name = e['name'];
    if (code is! String || name is! String) continue;
    modules.add((
      code: code,
      name: name,
      description:
          e['description'] is String ? (e['description'] as String) : null,
      // The price arrives as a JSON number or a string depending on the
      // driver; either way an unparseable one is nothing rather than a
      // crash, because a landing page that throws is a landing page
      // nobody can sign in from.
      monthlyPrice: e['monthly_price'] is num
          ? (e['monthly_price'] as num).toDouble()
          : double.tryParse('${e['monthly_price']}') ?? 0,
      isCore: e['is_core'] == true,
    ));
  }

  return LandingContent(
    published: true,
    logoUrl: brandStr('logo_url'),
    logoDarkUrl: brandStr('logo_dark_url'),
    wordmark: brandStr('wordmark') ?? 'iAkauntan',
    tagline: str('tagline'),
    brandColour: brandStr('brand_colour'),
    brandColourDark: brandStr('brand_colour_dark'),
    appIconUrl: brandStr('app_icon_url'),
    themeMode: brandStr('theme_mode') ?? 'system',
    heroHeadline: str('hero_headline') ??
        'Accounting, CRM, payroll and e-Invoice for Malaysian business',
    heroSubhead: str('hero_subhead'),
    signInLabel: str('sign_in_label') ?? 'Sign in',
    registerLabel: str('register_label') ?? 'Create an account',
    registerEnabled: page['register_enabled'] is bool
        ? page['register_enabled'] as bool
        : true,
    companyName: str('company_name'),
    companyRegNo: str('company_reg_no'),
    address: str('address'),
    supportEmail: str('support_email'),
    supportPhone: str('support_phone'),
    privacyUrl: str('privacy_url'),
    termsUrl: str('terms_url'),
    showPricing: page['show_pricing'] == true,
    pricingHeading: str('pricing_heading'),
    pricingNote: str('pricing_note'),
    // The console's rows win outright when there are any; the shipped
    // copy fills the page until somebody writes their own. Not merged:
    // an operator who has written three blocks means three blocks, not
    // three plus five they did not ask for.
    sections: sections.isEmpty ? defaultSections : sections,
    reasons: reasons.isEmpty ? defaultReasons : reasons,
    appLinks: links,
    modules: modules,
    // Not `?? default`: there is no default, and that is the design.
    stats: stats,
    testimonials: testimonials,
    logos: logos,
    ctaHeadline: str('cta_headline'),
    ctaBody: str('cta_body'),
    ctaLabel: str('cta_label'),
    ctaUrl: str('cta_url'),
  );
}

/// The landing page, fetched without a session.
///
/// `landing_page()` is one of the functions open to an unauthenticated
/// caller, so this works before anybody has signed in — which is the
/// whole point of it.
final landingContentProvider = FutureProvider<LandingContent>((ref) async {
  try {
    final data = await ref.watch(supabaseProvider).rpc('landing_page');
    return parseLandingContent(data);
  } catch (_) {
    // A front door that will not open because the network hiccupped is
    // worse than a plain one. Fall back to the built-in copy, which
    // still carries the sign-in button.
    return LandingContent.fallback;
  }
});
