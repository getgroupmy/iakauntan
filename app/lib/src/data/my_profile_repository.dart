import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';

/// The signed-in person's own profile row.
///
/// What this product knows about a PERSON — their name, how to address
/// them, how to ring them, where they are, and what they said they were
/// here for — as distinct from what it knows about a company's books.
///
/// Read straight from `profiles`, which `profiles_select` already
/// allows for `id = auth.uid()`. Null before anybody has signed in, and
/// null for the moment between signing in and the row arriving.
final myProfileProvider =
    FutureProvider<Map<String, dynamic>?>((ref) async {
  final client = ref.watch(supabaseProvider);
  final id = client.auth.currentUser?.id;
  if (id == null) return null;
  final row = await client
      .from('profiles')
      // The two `signup_` columns are 0590's: what a business typed at
      // registration, kept so setup can offer it back rather than ask
      // again. Named here because `check_query_columns.py` checks this
      // list against the schema, and because a `*` would hand the app
      // columns nothing reads.
      .select(
        'id, full_name, email, salutation, phone, country_code, '
        'state_code, use_kind, signup_business_name, signup_entity_type',
      )
      .eq('id', id)
      .maybeSingle();
  return row == null ? null : Map<String, dynamic>.from(row);
});

/// Change the parts of your own profile that are yours to change.
///
/// Through `update_my_profile` (0649) rather than a PATCH on the table.
/// `profiles_update` is `id = auth.uid()` in both USING and WITH CHECK,
/// which is the right rule about ROWS and cannot be a rule about
/// COLUMNS -- so a PATCH from here could also write `email`, which is a
/// copy of the auth address and would make "Signed in as" disagree with
/// what actually signs somebody in, and `deleted_at`, which four
/// membership guards read and nothing in the schema writes.
///
/// A null leaves a column alone; an empty string clears it. That is
/// what lets the screen send only what it has AND still let somebody
/// empty their telephone box.
///
/// Invalidates [myProfileProvider] on the way out, because the row it
/// holds is now the old one.
/// Takes a `WidgetRef` rather than a `Ref`: every caller is a screen,
/// and the point of the argument is the `invalidate` at the end.
Future<Map<String, dynamic>> saveMyProfile(
  WidgetRef ref, {
  String? fullName,
  String? salutation,
  String? phone,
  String? avatarUrl,
}) async {
  final data = await ref.read(supabaseProvider).rpc(
    'update_my_profile',
    params: {
      if (fullName != null) 'p_full_name': fullName,
      if (salutation != null) 'p_salutation': salutation,
      if (phone != null) 'p_phone': phone,
      if (avatarUrl != null) 'p_avatar_url': avatarUrl,
    },
  );
  ref.invalidate(myProfileProvider);
  return Map<String, dynamic>.from(data as Map);
}
