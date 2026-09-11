import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';

/// The two lists the registration form offers, read with no session.
///
/// `0554`. That form is the one screen in this product with nobody
/// signed in, so neither `ref_countries` nor `salutations` can be
/// reached through a policy granted to `authenticated`. One SECURITY
/// DEFINER function answers as `anon` — the pattern `landing_page()`
/// and `may_sign_in_here()` already use — and hands back two lists of
/// public facts.
///
/// One call rather than two providers, because the form draws both
/// dropdowns at once and two round trips would draw them at different
/// moments.
final signupReferenceProvider =
    FutureProvider<({List<Map<String, dynamic>> dialCodes,
                    List<Map<String, dynamic>> salutations,
                    List<Map<String, dynamic>> states})>((ref) async {
  final data = await ref.read(supabaseProvider).rpc('signup_reference');
  final map = (data as Map?) ?? const {};
  List<Map<String, dynamic>> rows(Object? value) => [
        for (final row in (value as List? ?? const []))
          Map<String, dynamic>.from(row as Map),
      ];
  return (
    dialCodes: rows(map['dial_codes']),
    salutations: rows(map['salutations']),
    states: rows(map['states']),
  );
});
