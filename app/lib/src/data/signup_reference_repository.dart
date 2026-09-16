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
/// `0563` adds two fields that are not lists: whether registration is
/// open at all, and what to say if it is not. The form asks once,
/// before it draws, rather than finding out by being refused after
/// eight fields have been filled in.
///
/// Open unless the answer says otherwise. A call that came back
/// malformed, or a deployment whose function predates `0563`, must not
/// close registration by accident — the database is what enforces the
/// setting, and this is only what saves somebody the typing.
///
/// `0607` adds the kinds of business. That list was an enum until
/// `0605`, so the form had it hardcoded; it is a table an administrator
/// adds to now, and `entity_types` is granted to `authenticated`, which
/// nobody on this screen is. It comes through here for the same reason
/// the salutations do — and empty where it does not, so a deployment
/// whose function predates this falls back to the constant rather than
/// drawing an empty dropdown.
final signupReferenceProvider =
    FutureProvider<({List<Map<String, dynamic>> dialCodes,
                    List<Map<String, dynamic>> salutations,
                    List<Map<String, dynamic>> states,
                    List<Map<String, dynamic>> entityTypes,
                    bool signupsOpen,
                    String? closedMessage})>((ref) async {
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
    entityTypes: rows(map['entity_types']),
    signupsOpen: map['signups_open'] != false,
    closedMessage: map['signups_closed_message'] as String?,
  );
});
