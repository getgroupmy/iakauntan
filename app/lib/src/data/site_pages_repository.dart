import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/providers.dart';
import 'repository.dart';

/// One of the five pages around the product.
///
/// A heading and a body, both nullable: null means the operator has
/// not written this one and the screen uses the copy it ships with.
/// That is why they are `String?` all the way down rather than being
/// defaulted here — the fallback belongs to the screen that knows what
/// it would otherwise have said.
class SitePage {
  const SitePage({
    required this.slug,
    this.title,
    this.body,
    this.isPublished = false,
  });

  final String slug;
  final String? title;
  final String? body;
  final bool isPublished;

  static SitePage fromRow(Map<String, dynamic> row) => SitePage(
    slug: row['slug'] as String,
    title: row['title'] as String?,
    body: row['body'] as String?,
    isPublished: row['is_published'] == true,
  );
}

/// The wording on the pages beside the product.
///
/// `site_pages()` is anon-executable, so this works before anybody has
/// signed in — which is the point, since two of the five are the sign-in
/// and sign-up screens and two more are the terms and the privacy
/// policy somebody is being asked to accept.
///
/// Takes a client rather than a [Repo]: there is one set of these for
/// the whole platform and no RPC below takes an organization.
class SitePagesRepository {
  const SitePagesRepository(this.client);

  final SupabaseClient client;

  /// Every page a caller is allowed to see, keyed by slug.
  ///
  /// The two auth pages always come back. The three linked ones only
  /// once they are published, so a missing key means "not published"
  /// and the footer link is simply not drawn.
  Future<Map<String, SitePage>> pages() async {
    final rows = Repo.rows(await client.rpc('site_pages'));
    return {
      for (final row in rows) row['slug'] as String: SitePage.fromRow(row),
    };
  }

  /// The five rows as the console sees them, draft and all.
  ///
  /// Straight off the table rather than through the function, for the
  /// same reason the landing console reads `landing_page`: editing a
  /// draft is what the console is for, and the function withholds
  /// exactly the drafts it needs to show. The table admits only
  /// platform administrators, so this is empty for anybody else.
  Future<Map<String, SitePage>> drafts() async {
    final rows = Repo.rows(
      await client
          .from('site_pages')
          .select('slug, title, body, is_published')
          .order('slug'),
    );
    return {
      for (final row in rows) row['slug'] as String: SitePage.fromRow(row),
    };
  }

  /// Write one page.
  ///
  /// Every argument but the slug is optional and an omitted one is left
  /// alone, matching `platform_save_site_page`: saving the heading must
  /// not blank the body, and publishing must not disturb either. An
  /// empty string is not omission — it clears the field back to the
  /// copy the screen ships with.
  Future<void> save(
    String slug, {
    String? title,
    String? body,
    bool? isPublished,
  }) => client.rpc(
    'platform_save_site_page',
    params: {
      'p_slug': slug,
      if (title != null) 'p_title': title,
      if (body != null) 'p_body': body,
      if (isPublished != null) 'p_is_published': isPublished,
    },
  );
}

final sitePagesRepositoryProvider = Provider<SitePagesRepository>(
  (ref) => SitePagesRepository(ref.watch(supabaseProvider)),
);

/// What a visitor gets. Read by the sign-in screen and by the three
/// public pages, so it has to survive not being signed in.
///
/// Failure is an empty map rather than an error: the wording on these
/// screens is a nicety, and a sign-in form that will not draw because
/// the copy could not be fetched is a worse outcome than one drawn in
/// the words the product shipped with.
final sitePagesProvider = FutureProvider<Map<String, SitePage>>((ref) async {
  try {
    return await ref.watch(sitePagesRepositoryProvider).pages();
  } catch (_) {
    return const {};
  }
});

/// The console's view: all five, published or not.
final sitePageDraftsProvider = FutureProvider<Map<String, SitePage>>(
  (ref) => ref.watch(sitePagesRepositoryProvider).drafts(),
);
