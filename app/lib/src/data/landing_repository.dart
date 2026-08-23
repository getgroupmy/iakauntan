import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import 'repository.dart';

/// The landing page, from the platform console's side.
///
/// The public page reads `landing_page()`, which withholds anything
/// unpublished. The console reads the tables, because editing a draft is
/// the whole point of it — that is why the select policies admit
/// `authenticated` while the write path is platform-admin RPCs.
extension RepoLanding on Repo {
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
      callRpc('platform_save_landing_page', params: {'p_patch': patch});

  Future<String> saveLandingSection({
    String? id,
    String? title,
    String? body,
    String? icon,
    int? sortOrder,
    bool? isActive,
  }) async {
    final out = await callRpc(
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
      callRpc('platform_delete_landing_section', params: {'p_id': id});

  Future<void> saveLandingAppLink({
    required String storeCode,
    String? label,
    String? url,
    String? badgeUrl,
    int? sortOrder,
    bool? isActive,
  }) => callRpc(
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

  Future<void> deleteLandingAppLink(String storeCode) => callRpc(
    'platform_delete_landing_app_link',
    params: {'p_store_code': storeCode},
  );

  /// Put a logo in the public bucket and hand back the address to store.
  ///
  /// `logos` is already public, which is what makes this work at all: an
  /// unauthenticated visitor has to be able to fetch the image, and
  /// nothing about a logo is private. The name carries a timestamp so a
  /// replacement is not served from a cache of the old one.
  Future<String> uploadLandingLogo(Uint8List bytes, String fileName) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    final path = 'landing/$stamp-$safe';
    await client.storage.from('logos').uploadBinary(path, bytes);
    return client.storage.from('logos').getPublicUrl(path);
  }
}

/// The page row as the console sees it, draft and all.
final landingPageAdminProvider = FutureProvider<Map<String, dynamic>?>(
  (ref) async => await ref.watch(repoProvider)?.landingPage(),
);

final landingSectionsAdminProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) async => await ref.watch(repoProvider)?.landingSections() ?? const [],
);

final landingAppLinksAdminProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) async => await ref.watch(repoProvider)?.landingAppLinks() ?? const [],
);
