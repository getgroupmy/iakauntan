import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/providers.dart';
import '../features/landing/landing_content.dart';
import 'repository.dart';

/// The landing page, from the platform console's side.
///
/// The public page reads `landing_page()`, which withholds anything
/// unpublished. The console reads the tables, because editing a draft is
/// the whole point of it — that is why the select policies admit
/// `authenticated` while the write path is platform-admin RPCs.
///
/// Takes a client rather than a [Repo], because none of this belongs to
/// an organization: there is one landing page for the whole platform and
/// every RPC below takes no org argument. Hung off `Repo` it read as an
/// empty page for anybody whose organization had not resolved yet — and
/// a platform administrator with no company of their own never resolves
/// one at all.
class LandingAdmin {
  const LandingAdmin(this.client);

  final SupabaseClient client;

  Future<dynamic> _rpc(String fn, {Map<String, dynamic>? params}) =>
      client.rpc(fn, params: params);

  /// The single page row, or null before anybody has written one.
  Future<Map<String, dynamic>?> landingPage() async {
    final rows = Repo.rows(await client.from('landing_page').select());
    return rows.isEmpty ? null : rows.first;
  }

  /// The blocks of one kind — `feature` for the grid of what the
  /// product does, `reason` for the short list of why to choose it.
  /// One table, because they are the same shape and a second would be
  /// two savers and two tabs to keep in step.
  Future<List<Map<String, dynamic>>> landingSections({
    String kind = 'feature',
  }) async => Repo.rows(
    await client
        .from('landing_sections')
        .select('id, sort_order, icon, title, body, is_active, kind')
        .eq('kind', kind)
        .order('sort_order')
        .order('title'),
  );

  Future<List<Map<String, dynamic>>> landingStats() async => Repo.rows(
    await client
        .from('landing_stats')
        .select('id, sort_order, value, label, icon, is_active')
        .order('sort_order')
        .order('label'),
  );

  Future<List<Map<String, dynamic>>> landingTestimonials() async => Repo.rows(
    await client
        .from('landing_testimonials')
        .select('id, sort_order, quote, author, company, avatar_url, is_active')
        .order('sort_order'),
  );

  Future<List<Map<String, dynamic>>> landingLogos() async => Repo.rows(
    await client
        .from('landing_logos')
        .select('id, sort_order, name, logo_url, is_active')
        .order('sort_order')
        .order('name'),
  );

  Future<List<Map<String, dynamic>>> landingAppLinks() async => Repo.rows(
    await client
        .from('landing_app_links')
        .select('id, store_code, label, url, badge_url, sort_order, is_active')
        .order('sort_order')
        .order('store_code'),
  );

  /// The page as it will look once published, draft and all.
  ///
  /// `platform_landing_preview` returns the same payload
  /// `landing_page()` will return after publishing — same body, two
  /// doors — so what the console draws here is the page rather than an
  /// approximation of it. Refused to anybody who is not a platform
  /// administrator, because it is the one route to an ungated draft.
  Future<dynamic> landingPreview() => _rpc('platform_landing_preview');

  /// Save only what the form changed.
  ///
  /// The function reads an absent key as "leave it alone", which is the
  /// reason it takes a patch rather than a row: correcting the tagline
  /// must not blank the address somebody else set five minutes ago.
  Future<void> saveLandingPage(Map<String, dynamic> patch) =>
      _rpc('platform_save_landing_page', params: {'p_patch': patch});

  Future<String> saveLandingSection({
    String? id,
    String? title,
    String? body,
    String? icon,
    int? sortOrder,
    bool? isActive,
    String? kind,
  }) async {
    final out = await _rpc(
      'platform_save_landing_section',
      params: {
        if (id != null) 'p_id': id,
        if (title != null) 'p_title': title,
        if (body != null) 'p_body': body,
        if (icon != null) 'p_icon': icon,
        if (sortOrder != null) 'p_sort_order': sortOrder,
        if (isActive != null) 'p_is_active': isActive,
        if (kind != null) 'p_kind': kind,
      },
    );
    return '$out';
  }

  Future<void> deleteLandingSection(String id) =>
      _rpc('platform_delete_landing_section', params: {'p_id': id});

  /// One figure in the band of numbers.
  ///
  /// [value] is a string all the way down — "240,000", "1,200+", "RM4b".
  /// Nothing adds these up, and making them numeric would only move the
  /// question of how to format them somewhere less obvious.
  Future<String> saveLandingStat({
    String? id,
    String? value,
    String? label,
    String? icon,
    int? sortOrder,
    bool? isActive,
  }) async {
    final out = await _rpc(
      'platform_save_landing_stat',
      params: {
        if (id != null) 'p_id': id,
        if (value != null) 'p_value': value,
        if (label != null) 'p_label': label,
        if (icon != null) 'p_icon': icon,
        if (sortOrder != null) 'p_sort_order': sortOrder,
        if (isActive != null) 'p_is_active': isActive,
      },
    );
    return '$out';
  }

  Future<void> deleteLandingStat(String id) =>
      _rpc('platform_delete_landing_stat', params: {'p_id': id});

  /// Something a customer said, and who said it.
  ///
  /// The database refuses a quote with no name against it. That is not
  /// a form-validation nicety: an unattributed testimonial is exactly
  /// the shape a fabricated one takes, and the operator putting it on
  /// their front page is the one who has to stand behind it.
  Future<String> saveLandingTestimonial({
    String? id,
    String? quote,
    String? author,
    String? company,
    String? avatarUrl,
    int? sortOrder,
    bool? isActive,
  }) async {
    final out = await _rpc(
      'platform_save_landing_testimonial',
      params: {
        if (id != null) 'p_id': id,
        if (quote != null) 'p_quote': quote,
        if (author != null) 'p_author': author,
        if (company != null) 'p_company': company,
        if (avatarUrl != null) 'p_avatar_url': avatarUrl,
        if (sortOrder != null) 'p_sort_order': sortOrder,
        if (isActive != null) 'p_is_active': isActive,
      },
    );
    return '$out';
  }

  Future<void> deleteLandingTestimonial(String id) =>
      _rpc('platform_delete_landing_testimonial', params: {'p_id': id});

  Future<String> saveLandingLogo({
    String? id,
    String? name,
    String? logoUrl,
    int? sortOrder,
    bool? isActive,
  }) async {
    final out = await _rpc(
      'platform_save_landing_logo',
      params: {
        if (id != null) 'p_id': id,
        if (name != null) 'p_name': name,
        if (logoUrl != null) 'p_logo_url': logoUrl,
        if (sortOrder != null) 'p_sort_order': sortOrder,
        if (isActive != null) 'p_is_active': isActive,
      },
    );
    return '$out';
  }

  Future<void> deleteLandingLogo(String id) =>
      _rpc('platform_delete_landing_logo', params: {'p_id': id});

  Future<void> saveLandingAppLink({
    required String storeCode,
    String? label,
    String? url,
    String? badgeUrl,
    int? sortOrder,
    bool? isActive,
  }) => _rpc(
    'platform_save_landing_app_link',
    params: {
      'p_store_code': storeCode,
      if (label != null) 'p_label': label,
      if (url != null) 'p_url': url,
      if (badgeUrl != null) 'p_badge_url': badgeUrl,
      if (sortOrder != null) 'p_sort_order': sortOrder,
      if (isActive != null) 'p_is_active': isActive,
    },
  );

  Future<void> deleteLandingAppLink(String storeCode) => _rpc(
    'platform_delete_landing_app_link',
    params: {'p_store_code': storeCode},
  );

  /// Put the platform's logo in the public bucket and hand back the
  /// address to store.
  ///
  /// `logos` is already public, which is what makes this work at all: an
  /// unauthenticated visitor has to be able to fetch the image, and
  /// nothing about a logo is private.
  ///
  /// Two fixed paths rather than timestamped names, for the reason 0073
  /// gives about the company logo: a bucket that keeps every logo
  /// anybody ever uploaded is a bucket nobody ever tidies. A fixed path
  /// makes the second upload an update, which is why 0291 gave the
  /// landing prefix an update policy as well as an insert one, and the
  /// browser cache is dealt with by the version parameter instead.
  ///
  /// The prefix is load-bearing: `landing/` is the only path a platform
  /// administrator may write here, because every other path in this
  /// bucket belongs to the organization named by its first segment.
  Future<String> uploadLandingLogo(
    Uint8List bytes,
    String field, {
    String? contentType,
  }) async {
    final path = switch (field) {
      'logo_dark_url' => 'landing/logo-dark',
      // The square source CI generates the favicon and the PWA icons
      // from. A fixed name, like the logos: `landing/` is the prefix
      // only a platform admin may write, and one file per role means
      // the bucket does not accumulate a copy per upload.
      'app_icon_url' => 'landing/app-icon',
      _ => 'landing/logo',
    };
    await client.storage
        .from('logos')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(upsert: true, contentType: contentType),
        );
    final url = client.storage.from('logos').getPublicUrl(path);
    return '$url?v=${DateTime.now().millisecondsSinceEpoch}';
  }
}

/// The console's view of the landing page, bound to the session.
final landingAdminProvider = Provider<LandingAdmin>(
  (ref) => LandingAdmin(ref.watch(supabaseProvider)),
);

/// The page row as the console sees it, draft and all.
final landingPageAdminProvider = FutureProvider<Map<String, dynamic>?>(
  (ref) => ref.watch(landingAdminProvider).landingPage(),
);

final landingSectionsAdminProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(landingAdminProvider).landingSections(),
);

final landingReasonsAdminProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(landingAdminProvider).landingSections(kind: 'reason'),
);

/// The bullets beside the sign-in form (`0336`). Same table as the
/// landing page's bands, a fourth `kind` to keep them apart.
final landingSigninPointsAdminProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(landingAdminProvider).landingSections(kind: 'signin'),
);

/// The bullets beside a company's own door (`0350`). A fifth `kind`,
/// for the reason the fourth exists: the login page is dressed
/// separately from the sign-in page, so its list is its own.
final landingLoginPointsAdminProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(landingAdminProvider).landingSections(kind: 'login'),
);

final landingBadgesAdminProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(landingAdminProvider).landingSections(kind: 'badge'),
);

final landingStatsAdminProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(landingAdminProvider).landingStats(),
);

final landingTestimonialsAdminProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(landingAdminProvider).landingTestimonials(),
);

final landingLogosAdminProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(landingAdminProvider).landingLogos(),
);

/// The draft, parsed by the same function the live page is parsed by.
///
/// Deliberately `parseLandingContent` and not a second parser: the
/// preview is worth having only if it cannot disagree with the page,
/// and that holds end to end — one payload from the database, one
/// parser here, one set of widgets to draw it.
final landingPreviewProvider = FutureProvider<LandingContent>(
  (ref) async =>
      parseLandingContent(await ref.watch(landingAdminProvider).landingPreview()),
);

final landingAppLinksAdminProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(landingAdminProvider).landingAppLinks(),
);
