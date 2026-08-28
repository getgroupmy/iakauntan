# Address suggestions

The company setup screen asks which country first, then suggests
addresses in it. The suggesting is Google Places; the key is not in the
app.

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

- **API restrictions** — Places API (New) only. Nothing else is called.
- **Application restrictions** — none is correct here. The caller is an
  edge function, not a browser, so there is no referrer to allow and no
  fixed egress address to allow-list.

Enable **Places API (New)**. The older Places API is a different
product with different endpoints, and this function calls the new one:
`places:autocomplete` and `places/{id}`.

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

Two other guards on the same bill: nothing is asked for fewer than
three characters, and the country the operator chose is sent as
`includedRegionCodes`, so somebody setting up a Malaysian company is
not offered a street in Ohio.

## Without a key

The function answers `{"suggestions": [], "configured": false}` and the
form keeps working: the address boxes are ordinary text fields
underneath and always were. What is missing is the suggesting. That is
deliberate — a deployment that has not bought a Places key should have
a working setup screen, not a 500 that reads like an outage.

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
