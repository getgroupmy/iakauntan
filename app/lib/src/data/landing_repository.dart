import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/providers.dart';
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

  Future<List<Map<String, dynamic>>> landingSections() async => Repo.rows(
    await client
        .from('landing_sections')
        .select('id, sort_order, icon, title, body, is_active')
        .order('sort_order')
        .order('title'),
  );

  Future<List<Map<String, dynamic>>> landingAppLinks() async => Repo.rows(
    await client
        .from('landing_app_links')
        .select('id, store_code, label, url, badge_url, sort_order, is_active')
        .order('sort_order')
        .order('store_code'),
  );

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
      },
    );
    return '$out';
  }

  Future<void> deleteLandingSection(String id) =>
      _rpc('platform_delete_landing_section', params: {'p_id': id});

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

final landingAppLinksAdminProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(landingAdminProvider).landingAppLinks(),
);
