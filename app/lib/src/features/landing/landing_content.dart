import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// One block of copy on the landing page.
typedef LandingSection = ({String? icon, String title, String? body});

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
class LandingContent {
  const LandingContent({
    required this.published,
    this.logoUrl,
    this.logoDarkUrl,
    this.wordmark = 'iAkauntan',
    this.tagline,
    this.brandColour,
    this.brandColourDark,
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
    this.sections = const [],
    this.appLinks = const [],
    this.modules = const [],
  });

  final bool published;
  final String? logoUrl;
  final String? logoDarkUrl;
  final String wordmark;
  final String? tagline;
  final String? brandColour;
  final String? brandColourDark;
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
  final List<LandingAppLink> appLinks;
  final List<LandingModule> modules;

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
  if (page is! Map) return LandingContent.fallback;

  String? str(String key) {
    final v = page[key];
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  final sections = <LandingSection>[];
  for (final e in (raw['sections'] as List? ?? const [])) {
    if (e is! Map) continue;
    final title = e['title'];
    if (title is! String || title.trim().isEmpty) continue;
    sections.add((
      icon: e['icon'] is String ? e['icon'] as String : null,
      title: title.trim(),
      body: e['body'] is String ? (e['body'] as String).trim() : null,
    ));
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
    logoUrl: str('logo_url'),
    logoDarkUrl: str('logo_dark_url'),
    wordmark: str('wordmark') ?? 'iAkauntan',
    tagline: str('tagline'),
    brandColour: str('brand_colour'),
    brandColourDark: str('brand_colour_dark'),
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
    sections: sections,
    appLinks: links,
    modules: modules,
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
