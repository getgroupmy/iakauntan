/// The country this product is for, and what that means for the form
/// that asks.
///
/// iAkauntan is a Malaysian product: SSM registration, an LHDN TIN, SST,
/// EPF, SOCSO, EIS, MBRS. Asking every company where it is before it can
/// begin — with no answer offered, against a list of two hundred — puts
/// the rarest case in front of the commonest one.
///
/// So Malaysia is the answer already filled in, and the question stays
/// on the form for whoever it is not the answer for. That is the whole
/// change: a default, not a decision taken away. The country still
/// governs which half of the form is drawn, and a company in Singapore
/// still gets a form that fits it — it just has to say so.
///
/// The words and the ordering live here rather than in the screen for
/// the reason `module_offer.dart` gives: a sentence assembled inside a
/// `build` method is a sentence nobody can assert.
library;

/// Three letters, which is what `organizations.country_code` stores.
const homeCountryCode = 'MYS';

/// The same country in the two-letter form Google Places wants.
///
/// Carried rather than derived: alpha-3 is not alpha-2 plus a letter —
/// Portugal is PRT and PT, and PR is Puerto Rico.
const homeCountryAlpha2 = 'MY';

/// What to call it before `ref_countries` has loaded.
///
/// The row is the authority on the name once it arrives; this is what
/// the line says in the moment before it does, and the two agree.
const homeCountryName = 'Malaysia';

/// The label over the country line on the setup form.
const countryFieldLabel = 'Country';

/// What the line offers.
const countryChangeLabel = 'Change';

/// Why the line is there at all, said once.
const countryChangeHint =
    'The rest of the form follows this — the tax numbers a company is '
    'asked for are not the same everywhere.';

/// The country list with Malaysia first.
///
/// The rest keep the order they came in, which is alphabetical. Pinning
/// rather than sorting to the top by hand, so a search that filters the
/// list still filters this one: the caller filters, then pins.
///
/// Nothing is added and nothing is dropped — if Malaysia is not in the
/// list, because a search has excluded it, the list comes back
/// unchanged.
List<Map<String, dynamic>> countriesWithHomeFirst(
  List<Map<String, dynamic>> rows,
) {
  final home = <Map<String, dynamic>>[];
  final rest = <Map<String, dynamic>>[];
  for (final row in rows) {
    (row['code'] == homeCountryCode ? home : rest).add(row);
  }
  return [...home, ...rest];
}
