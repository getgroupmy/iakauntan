import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';

/// One address suggestion: a line to show, and a line under it.
typedef PlaceSuggestion = ({String id, String line, String detail});

/// The pieces a form has boxes for. Every one is nullable because
/// plenty of real addresses have no postcode, and a missing component
/// is not a failure.
typedef PlaceAddress = ({
  String? line1,
  String? city,
  String? postcode,
  String? state,
  String? country,
  String? formatted,
});

/// Address suggestions, through our own function rather than Google.
///
/// The key is in the `places` edge function's environment and never in
/// this bundle — the rule every provider key on this platform follows,
/// and the reason a scraped build cannot spend the quota. See that
/// function's own comment for why a referrer restriction was not
/// considered enough.
///
/// [configured] is what a deployment with no key answers. The address
/// boxes are ordinary text fields underneath, so the form still works;
/// what is missing is the suggesting, and the screen says so rather
/// than showing an empty list that looks like "no such street".
class PlacesRepository {
  const PlacesRepository(this._ref);

  final Ref _ref;

  Future<({List<PlaceSuggestion> suggestions, bool configured})> suggest(
    String query, {
    String? country,
    String? session,
  }) async {
    final res = await _ref.read(supabaseProvider).functions.invoke(
      'places',
      body: {
        'q': query,
        if (country != null) 'country': country,
        if (session != null) 'session': session,
      },
    );
    final data = (res.data as Map?) ?? const {};
    final raw = (data['suggestions'] as List?) ?? const [];
    return (
      suggestions: [
        for (final s in raw.cast<Map>())
          (
            id: '${s['id'] ?? ''}',
            line: '${s['line'] ?? ''}',
            detail: '${s['detail'] ?? ''}',
          ),
      ],
      configured: data['configured'] != false,
    );
  }

  /// The address behind a suggestion.
  ///
  /// The same session token as the keystrokes that led here: Places
  /// bills a session as one unit, and this call is what closes it.
  Future<PlaceAddress?> address(String placeId, {String? session}) async {
    final res = await _ref.read(supabaseProvider).functions.invoke(
      'places',
      body: {'place': placeId, if (session != null) 'session': session},
    );
    final a = ((res.data as Map?) ?? const {})['address'] as Map?;
    if (a == null) return null;
    return (
      line1: a['line1'] as String?,
      city: a['city'] as String?,
      postcode: a['postcode'] as String?,
      state: a['state'] as String?,
      country: a['country'] as String?,
      formatted: a['formatted'] as String?,
    );
  }
}

final placesProvider = Provider<PlacesRepository>(PlacesRepository.new);

/// Every country the platform knows, for the question the setup screen
/// asks first.
///
/// `ref_countries` since `0011`, carrying alpha-2 and alpha-3 on every
/// row: the column stores the three-letter code and Google Places wants
/// the two-letter one, so the picker needs both and there is no second
/// list to keep in step.
final countriesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final data = await ref
      .watch(supabaseProvider)
      .from('ref_countries')
      .select('code, name, alpha2')
      .eq('is_active', true)
      .order('name');
  return (data as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
});
