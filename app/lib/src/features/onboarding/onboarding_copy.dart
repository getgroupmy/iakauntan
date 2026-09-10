/// The three questions setup asks before the form, and what the form
/// says once they are answered.
///
/// Setup used to ask for a company name and an entity type and then
/// hand over a product with thirty modules in it and no opinion about
/// which of them the person in front of it needs. It now asks what this
/// is for, and what the business is, and offers what that answer needs
/// — `0553` holds the catalogue.
///
/// The words live here rather than in the screen for the reason
/// `module_offer.dart` gives: a sentence assembled inside a `build`
/// method is a sentence nobody can assert. The shaping rules live here
/// too, because "which label does an identification field get" is a
/// decision with a right answer and a wrong one, and the wrong one goes
/// to LHDN.
library;

/// What somebody is setting this up for.
///
/// Not a synonym for entity type. A sole proprietor IS a business —
/// registered, with an SSM number and an MSIC code — and a freelancer
/// invoicing under their own name is not. The difference decides which
/// number identifies them, and LHDN accepts a different one for each.
enum UseKind {
  /// One person, invoicing under their own name.
  personal,

  /// A registered business, whatever its legal form.
  business,
}

/// The question at the top of the first step.
const useQuestion = 'What is this for?';

/// Personal, said in a way somebody recognises themselves in.
const personalTitle = 'Myself';
const personalBlurb =
    'Invoicing under your own name — freelance work, rent from a '
    'property you own, tuition, commissions. Invoices carry your name '
    'and your MyKad or passport number.';

/// Business, likewise.
const businessTitle = 'A business';
const businessBlurb =
    'A registered company, enterprise, partnership or society. '
    'Invoices carry the registered name and the SSM number.';

/// The heading over the form once the questions are answered.
String setupTitle(UseKind use) =>
    use == UseKind.personal ? 'Set up your details' : 'Set up your company';

/// What the name box is called.
///
/// LHDN matches the name on an e-Invoice against the name on the
/// identification it was filed under, so "as on MyKad" is not a
/// nicety — a shortened name and a full one are a rejected submission.
String nameLabel(UseKind use, {required bool malaysian}) {
  if (use == UseKind.business) return 'Company name *';
  return malaysian
      ? 'Full name, as on your MyKad *'
      : 'Full name, as on your passport *';
}

/// What the identification box is called.
///
/// The same column either way — `organizations.registration_no`, which
/// `prepare_einvoice` sends as the party identification. What changes
/// is which number belongs in it, and a box labelled "SSM registration
/// no." in front of somebody who has never had one is a box left empty.
String identificationLabel(UseKind use, {required bool malaysian}) {
  if (use == UseKind.business) return 'SSM registration no.';
  return malaysian ? 'MyKad number' : 'Passport number';
}

/// The example under it.
String identificationHint(UseKind use, {required bool malaysian}) {
  if (use == UseKind.business) return '202301234567';
  return malaysian ? '900101015555' : 'A12345678';
}

/// What the identification is for, said once where it is asked.
String identificationHelp(UseKind use) => use == UseKind.business
    ? 'Goes on your invoices and to LHDN'
    : 'Goes on your invoices and to LHDN, in place of a business '
        'registration number';

/// The entity type a personal setup files under.
///
/// `app.entity_type` has carried this value since `0001` and nothing
/// ever set it. `0553`'s trigger reads it and files the person under
/// NRIC or passport rather than BRN.
const personalEntityType = 'individual';

/// What the setup promises to build, which is not the same everywhere
/// and not the same for one person as for a company.
String setupPromise({required bool malaysian, required UseKind use}) {
  final chart = malaysian
      ? 'a Malaysian chart of accounts, SST tax codes'
      : 'a chart of accounts';
  return use == UseKind.personal
      ? 'We will create $chart and a fiscal calendar, so you can invoice '
          'and be paid under your own name.'
      : 'We will create $chart, a fiscal calendar and a sales pipeline '
          'for you.';
}

/// The question on the second step.
const businessTypeQuestion = 'What kind of business?';
const businessTypeBlurb =
    'This decides what we switch on for you. Everything here can be '
    'changed later, in Settings.';

/// The row that means "ask me instead".
const otherBusinessType = 'other';

/// The question on the step after "Something else".
const modulesQuestion = 'Anything else you need?';
const modulesBlurb =
    'None of these are required — the books, contacts and invoicing are '
    'always on. Add what you need now, or add it later in Settings.';

/// What a business type says it will switch on.
///
/// Named rather than counted: "adds 3 modules" tells somebody nothing
/// about whether the answer is right for them, and the whole point of
/// the step is that they can tell.
String modulesAdded(List<String> names) {
  if (names.isEmpty) return 'Nothing extra — you choose';
  if (names.length == 1) return 'Adds ${names.single}';
  return 'Adds ${names.sublist(0, names.length - 1).join(', ')} '
      'and ${names.last}';
}

/// A month's charge, said plainly.
///
/// Zero is "free" rather than "RM 0.00": a module that costs nothing
/// should read as one, and a column of RM 0.00 beside RM 79.00 reads as
/// an oversight.
String monthlyPrice(num? price) {
  final value = price ?? 0;
  if (value <= 0) return 'Free';
  return 'RM ${value.toStringAsFixed(0)} a month';
}

/// What the whole selection comes to.
String monthlyTotal(num total) => total <= 0
    ? 'Nothing extra to pay'
    : 'RM ${total.toStringAsFixed(0)} a month on top of the base plan';

/// Business types grouped by sector, each sector keeping the order the
/// rows arrived in.
///
/// The picker is long — forty trades — and a flat list of forty is a
/// list nobody reads to the end of. The sectors come out in the order
/// their first row appears, which is `sort_order`, so the commonest
/// sector is at the top and `other` is last.
Map<String, List<Map<String, dynamic>>> bySector(
  List<Map<String, dynamic>> rows,
) {
  final out = <String, List<Map<String, dynamic>>>{};
  for (final row in rows) {
    out.putIfAbsent('${row['sector']}', () => []).add(row);
  }
  return out;
}
