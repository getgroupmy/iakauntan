# Address suggestions

Every box in the product that asks for an address suggests one. The
suggesting is Google Places; the key is not in the app.

## The key lives in one place

Set `GOOGLE_PLACES_KEY` under **Supabase → Edge Functions → Secrets**.
Nowhere else — not in a migration, not in a table, not in a
`--dart-define`, and not in this repository. It is the same rule the
LHDN credentials, the Resend key and the Billplz secrets follow, and
for the same reason: a key we are billed for does not travel to a
browser.

Google's own guidance is that a Maps key is public and restricted by
HTTP referrer. That is true of a key you are happy to have scraped. A
`Referer` header is one anybody can send, the bill for a leaked Places
key is ours, and the recovery is a rotation. Behind the function it is
a secret like any other: rotating it is a secret change, not a deploy
of the app.

Restrict it anyway, at **console.cloud.google.com → APIs & Services →
Credentials**:

- **API restrictions** — Places API (New) *and* Places API, since the
  second is the fallback. Nothing else is called.
- **Application restrictions** — none is correct here. The caller is an
  edge function, not a browser, so there is no referrer to allow and no
  fixed egress address to allow-list.

Enable **Places API (New)**. The older Places API is a different
product on a different host with its own switch in the console, and the
function prefers the new one: `places:autocomplete` and `places/{id}`.

## Which API answers

New first, legacy behind it.

A key that is not permitted to use Places API (New) is refused with a
`403`, and that is not a hypothetical — it is what this deployment did
on the first day: key live, old API enabled, new API not, every request
403, and an address box that suggested nothing while looking perfectly
healthy. So a refusal meaning *this key may not use this API* — `403`,
`404`, or the new API's own `429` — is retried against
`maps.googleapis.com/maps/api/place/*` rather than shown to somebody
typing.

A `400` is not retried. That is a request we built wrong, and asking a
second API the same wrong question buys a second refusal and one more
billed call.

An isolate that has been refused remembers it for five minutes, so the
wasted first call is paid once rather than once per keystroke — and
because it is only a memory and only for five minutes, turning the new
API on in the console starts being used again on its own, with no
deploy.

The reply carries `via: "new" | "legacy"`. Nothing on the screen reads
it; it is there so that *suggestions work* and *suggestions work
because the new API is off and we are on the old one* are
distinguishable without opening the logs.

Two traps live in that fallback, and `supabase/functions/places/parse.ts`
exists to keep them apart from the fetching so they can be asserted:

- the legacy API answers **HTTP 200 with the refusal in the body**.
  Code that checks `res.ok` reads `REQUEST_DENIED` as an empty result
  and shows "no such street" for a key problem;
- and the two spell the same components differently — `longText`
  against `long_name`, `suggestions` against `predictions`. Reading the
  wrong one throws nothing and yields an address with every field null,
  which looks like a place Google has no data for.

`supabase/functions/places/parse_test.ts` holds a real body of each
shape against the reader and asserts the two produce the *same*
address. It runs in CI.

## Where the box is

`AddressField` in `app/lib/src/core/address_field.dart`, on the street
line of every address the product collects:

| Screen | Address |
| --- | --- |
| Company setup | The one the new company is at |
| Settings → Company details | Business address, and the registered office when it differs |
| Settings → Branches | Where a branch trades from |
| Settings → Warehouses | Where stock is kept |
| Contacts | A customer's or supplier's address |
| Contacts → Delivery addresses | Each place you deliver to |
| Property → Site | Where the property is |
| Till → Delivery | Where the order is going |

The public menu a diner orders from is deliberately not on that list.
The `places` function requires a signed-in caller, and the whole point
of that requirement is that our Places quota is not spendable by
anybody who can load a page.

## The state box, and why it is filled with a number

`state_code` is a foreign key into `ref_states` on contacts and
warehouses. So what a suggestion writes into a state box has to be the
LHDN code — `10`, not `Selangor`. A name written there is not a
slightly wrong value, it is a row that will not save.

`stateCodeFor` does that translation, and it is not a string compare:
Google answers with the name in common English use and `ref_states`
carries the name LHDN publishes, and for five of the sixteen those are
different words — Kuala Lumpur against Wilayah Persekutuan Kuala
Lumpur, Penang against Pulau Pinang, Malacca against Melaka, and the
same for Labuan and Putrajaya. Without the aliases a company in KL —
the single likeliest answer — picks its address and watches the state
box stay empty.

A state the list does not match leaves the box as it was rather than
clearing it, for the same foreign-key reason. So does a component
Google did not return: a suggestion with no postcode does not blank the
postcode somebody typed.

The till's delivery sheet is the exception, and stores the state *name*
— that address goes on a docket a driver reads, and `10` does not tell
anybody where Selangor is.

## What it costs, and the session token

Places bills autocomplete by *session*, not by keystroke. Every
keystroke leading to one chosen address is a single billable unit if it
carries the same session token, and one unit **each** if it does not.

`AddressField` makes a token per address it is filling in, sends it with
every suggestion request and with the final details fetch — which is
what closes the session — and makes a new one afterwards. Getting this
wrong is invisible: the box works perfectly and the bill is an order of
magnitude too large. `app/test/company_country_and_address_test.dart`
asserts it, and fails if the token is renewed per keystroke or reused
after a choice.

Three other guards on the same bill: nothing is asked for fewer than
three characters; the country is sent as `includedRegionCodes`, so a
Malaysian company is not offered a street in Ohio — the country chosen
at setup on that screen, and the organization's own country
(`orgCountryAlpha2Provider`) everywhere after; and once the function
says it has no key the box stops asking altogether, rather than paying
a round trip per keystroke for the rest of the session.

## Without a key

The function answers `{"suggestions": [], "configured": false}` and the
form keeps working: the address boxes are ordinary text fields
underneath and always were. What is missing is the suggesting. That is
deliberate — a deployment that has not bought a Places key should have
working screens, not a 500 that reads like an outage.

Each box asks once and then believes the answer, so an unconfigured
deployment costs one call per box rather than one per letter.

## Which country, and what it changes

`ref_countries` has held alpha-2 and alpha-3 for 56 countries since
`0011`. The screen reads both: the column stores three letters and
Places wants two.

The answer changes the form. SSM registration, an LHDN TIN, SST and the
`ref_states` list are Malaysian instruments; a company in Singapore has
none of them and is not asked. That is why the question is a step of its
own rather than a field halfway down — a company scrolling past
questions written for somebody else has already been told the product
was not written for it.
