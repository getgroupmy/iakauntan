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
