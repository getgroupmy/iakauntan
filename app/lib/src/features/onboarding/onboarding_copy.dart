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

  /// A practice keeping OTHER people's books.
  ///
  /// Not a kind of business, which is why it is a third answer rather
  /// than a row in the business-type list. What follows from it is
  /// different from what follows from "a business": Multi-Company from
  /// the start, because a firm with one company is a firm that has not
  /// started yet, and no "what kind of business?" question, because the
  /// kind of business is not what they came to tell us.
  ///
  /// Everything else about the form is the business form. A practice is
  /// a registered company with a name, an SSM number and a TIN, and its
  /// own books are a company's books.
  accountant,
}

/// Whether the company half of the form applies.
///
/// The opposite of [UseKind.personal] rather than equality with
/// [UseKind.business], said once here. Written the other way round in
/// seven places, adding a third answer would have quietly filed every
/// accounting practice as an individual -- entity type hidden, name box
/// asking for a MyKad, and LHDN told the firm was a person.
bool isCompany(UseKind? use) => use != UseKind.personal;

/// Whose books these are.
///
/// The same screen serves two people. On first run somebody is setting
/// themselves up, and the words are theirs — "your MyKad", "Open my
/// books". At `/companies/new` they are opening ANOTHER set of books on
/// the same sign-in, which an accounting practice with the
/// `multi_company` module does all day: the client is a person or a
/// company, and either way it is not the person reading the screen. A
/// form that says "your MyKad" to a bookkeeper typing in a client's
/// number is a form asking the wrong person for a number.
enum SetupAudience {
  /// The person filling the form in.
  own,

  /// Somebody else, whose books are being opened on this sign-in.
  other,
}

/// The answer somebody gave at registration, as `profiles.use_kind`
/// holds it.
///
/// Null for an account that registered before the question existed, and
/// for one created by an invitation. Those people are asked at setup,
/// exactly as everybody was before `0558`.
UseKind? useKindFrom(String? stored) {
  switch (stored) {
    case 'personal':
      return UseKind.personal;
    case 'business':
      return UseKind.business;
    case 'accountant':
      return UseKind.accountant;
    default:
      return null;
  }
}

/// The same value on its way out, for the registration metadata.
String storedUseKind(UseKind use) => switch (use) {
  UseKind.personal => 'personal',
  UseKind.business => 'business',
  UseKind.accountant => 'accountant',
};

/// The question at the top of the first step.
String useQuestion(SetupAudience audience) => audience == SetupAudience.own
    ? 'What is this for?'
    : 'Who are these books for?';

/// Personal, said in a way somebody recognises themselves in.
String personalTitle(SetupAudience audience) =>
    audience == SetupAudience.own ? 'Myself' : 'An individual';

String personalBlurb(SetupAudience audience) => audience == SetupAudience.own
    ? 'Invoicing under your own name — freelance work, rent from a '
        'property you own, tuition, commissions. Invoices carry your '
        'name and your MyKad or passport number.'
    : 'Somebody invoicing under their own name — a freelancer, a '
        'landlord, a tuition teacher, with no business registration. '
        'Invoices carry their name and their MyKad or passport number.';

/// Business, likewise. The same either way: a registered company is a
/// registered company whoever is typing.
const businessTitle = 'A business';
const businessBlurb =
    'A registered company, enterprise, partnership or society. '
    'Invoices carry the registered name and the SSM number.';

/// The practice, said in the words of somebody who keeps books for a
/// living rather than in the words of a product.
const accountantTitle = 'Accountant';
const accountantBlurb =
    'A firm keeping books for clients. Comes with Multi-Company, so '
    'each client is their own set of books on this one sign-in.';

/// What an accounting practice gets switched on without being asked.
///
/// One module, and it is the one the whole answer is about: a practice
/// that cannot open a second set of books has been sold the wrong
/// thing. Named rather than ticked silently -- the module step still
/// shows it, with its price, because it is a paid module and a charge
/// nobody saw arrive is a charge somebody disputes.
const accountantModules = ['multi_company'];

/// The heading over the form once the questions are answered.
String setupTitle(UseKind use, {SetupAudience audience = SetupAudience.own}) {
  if (audience == SetupAudience.other) {
    return use == UseKind.personal ? 'Set up these books' : 'Add a company';
  }
  return use == UseKind.accountant
      ? 'Set up your practice'
      : use == UseKind.personal
      ? 'Set up your details'
      : 'Set up your company';
}

/// What the name box is called.
///
/// LHDN matches the name on an e-Invoice against the name on the
/// identification it was filed under, so "as on MyKad" is not a
/// nicety — a shortened name and a full one are a rejected submission.
String nameLabel(
  UseKind use, {
  required bool malaysian,
  SetupAudience audience = SetupAudience.own,
}) {
  if (use == UseKind.accountant) return 'Practice name *';
  if (use == UseKind.business) return 'Company name *';
  final whose = audience == SetupAudience.own ? 'your' : 'their';
  return malaysian
      ? 'Full name, as on $whose MyKad *'
      : 'Full name, as on $whose passport *';
}

/// What the identification box is called.
///
/// The same column either way — `organizations.registration_no`, which
/// `prepare_einvoice` sends as the party identification. What changes
/// is which number belongs in it, and a box labelled "SSM registration
/// no." in front of somebody who has never had one is a box left empty.
String identificationLabel(UseKind use, {required bool malaysian}) {
  if (isCompany(use)) return 'SSM registration no.';
  return malaysian ? 'MyKad number' : 'Passport number';
}

/// The example under it.
String identificationHint(UseKind use, {required bool malaysian}) {
  if (isCompany(use)) return '202301234567';
  return malaysian ? '900101015555' : 'A12345678';
}

/// What the identification is for, said once where it is asked.
String identificationHelp(
  UseKind use, {
  SetupAudience audience = SetupAudience.own,
}) {
  final whose = audience == SetupAudience.own ? 'your' : 'their';
  return isCompany(use)
      ? 'Goes on $whose invoices and to LHDN'
      : 'Goes on $whose invoices and to LHDN, in place of a business '
          'registration number';
}

/// The legal forms `app.entity_type` recognises, in the words a
/// Malaysian company would use for itself.
///
/// Here rather than in a screen because two screens ask for it now --
/// registration and setup -- and the danger of a second copy is not
/// that the words drift but that the KEYS do: these are enum labels,
/// and one that is not a label is a company that cannot be created,
/// discovered at the last press of the last screen.
///
/// `individual` and `government` are deliberately absent. A person is
/// filed as `individual` by answering "Myself", which is a different
/// question, and nobody sets a government body up through a self-serve
/// form.
const entityTypes = <String, String>{
  'sdn_bhd': 'Sendirian Berhad (Sdn Bhd)',
  'bhd': 'Berhad (Bhd)',
  'enterprise': 'Enterprise',
  'sole_proprietor': 'Sole Proprietor',
  'partnership': 'Partnership',
  'llp': 'Limited Liability Partnership',
  'association': 'Association / Society',
  'other': 'Other',
};

/// The one a form starts on.
const defaultEntityType = 'sdn_bhd';

/// The kinds of business to offer, given what the server sent.
///
/// Public and pure, and the reason this is a function rather than a
/// `??`: `0607` made the list a table, and the two screens that draw it
/// have to keep working against a deployment whose `signup_reference()`
/// predates that. An empty or absent list is the constant above; a list
/// that came back is used in the order it came back in, which is the
/// table's own `sort_order`.
///
/// Rows with no `code` are dropped rather than drawn as a blank line:
/// a dropdown item whose value is the empty string is one somebody can
/// select, and it would be saved.
Map<String, String> signupEntityTypes(List<Map<String, dynamic>>? rows) {
  if (rows == null || rows.isEmpty) return entityTypes;
  final out = <String, String>{};
  for (final row in rows) {
    final code = '${row['code'] ?? ''}'.trim();
    if (code.isEmpty) continue;
    final label = '${row['label'] ?? ''}'.trim();
    out[code] = label.isEmpty ? code : label;
  }
  return out.isEmpty ? entityTypes : out;
}

/// The number the register issued BEFORE 2019, which half the country
/// still has on file.
///
/// A company incorporated before the Companies Act 2016 numbering
/// change carries two: `200201003726` and `(571389-H)`. A business
/// registered under ROB likewise -- `JM0167410-V`. Both are printed on
/// the letterhead, and a counterparty searching for one will not find
/// the other.
///
/// Never required, and the helper says so where somebody is looking at
/// the box. A company incorporated after 2019 has never had one, and a
/// mandatory box in front of somebody with nothing to put in it is a
/// box that gets a made-up number -- which then goes out on an invoice.
const oldIdentificationLabel = 'Old SSM registration no.';
const oldIdentificationHint = '571389-H';
const oldIdentificationHelp = 'Only if registered before 2019. Optional.';

/// The entity type a personal setup files under.
///
/// `app.entity_type` has carried this value since `0001` and nothing
/// ever set it. `0553`'s trigger reads it and files the person under
/// NRIC or passport rather than BRN.
const personalEntityType = 'individual';

/// What the setup promises to build, which is not the same everywhere
/// and not the same for one person as for a company.
String setupPromise({
  required bool malaysian,
  required UseKind use,
  SetupAudience audience = SetupAudience.own,
}) {
  final chart = malaysian
      ? 'a Malaysian chart of accounts, SST tax codes'
      : 'a chart of accounts';
  final own = audience == SetupAudience.own;
  if (use == UseKind.accountant) {
    return 'We will create $chart, a fiscal calendar and a sales '
        'pipeline for the practice itself. Client books are added '
        'afterwards, one company at a time.';
  }
  return use == UseKind.personal
      ? 'We will create $chart and a fiscal calendar, so '
          '${own ? 'you' : 'they'} can invoice and be paid under '
          '${own ? 'your' : 'their'} own name.'
      : 'We will create $chart, a fiscal calendar and a sales pipeline '
          '${own ? 'for you' : 'for them'}.';
}

/// What the button at the bottom of the form does.
///
/// A person setting up for themselves is not creating a company, and a
/// button that says so is the form telling them they are in the wrong
/// place at the last moment. What they are doing is opening a set of
/// books in their own name, which is also what the row in
/// `organizations` is: the table is how this product holds a tenant,
/// and a tenant can be one person.
String createButtonLabel(
  UseKind use, {
  SetupAudience audience = SetupAudience.own,
}) {
  if (use == UseKind.accountant) return 'Create practice';
  if (use == UseKind.business) return 'Create company';
  return audience == SetupAudience.own ? 'Open my books' : 'Open these books';
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

/// Which question is in front of somebody.
///
/// Public, and the transitions below are functions rather than lines
/// inside a `setState`, because "going back does not lose what you
/// already said" is a rule with a right answer and a wrong one — and
/// the wrong one is invisible until somebody has answered four
/// questions and is asked all four again.
enum SetupStep {
  /// Myself or a business, and the country.
  use,

  /// What kind of business, out of `business_types`.
  businessType,

  /// The modules, ticked.
  modules,

  /// The form itself.
  form,

  /// The country list, which is a screen of its own because two hundred
  /// countries is not a dropdown.
  country,
}

/// Where answering the first question leads.
///
/// A person goes straight to the modules: there is no business type to
/// choose, because they are not a business. A business goes to the type
/// list — unless it has already chosen one, in which case answering the
/// same question the same way must not make it answer the next one
/// again.
SetupStep stepAfterUse(UseKind use, {String? businessType}) {
  // A practice is not asked what kind of business it is. The question
  // exists to decide which modules to offer, and the answer for a firm
  // keeping other people's books is already known -- see
  // `accountantModules`. Asking anyway would be asking somebody to
  // classify themselves as a restaurant or a workshop before being
  // shown a list that had nothing to do with either answer.
  if (use != UseKind.business) return SetupStep.modules;
  return businessType == null ? SetupStep.businessType : SetupStep.form;
}

/// Where choosing a business type leads.
///
/// "Something else" carries no modules, so it goes to the list rather
/// than to the form — every other answer has already made that choice.
/// Re-picking "Something else" goes back to the list too: somebody who
/// chooses it a second time is asking to change what they ticked.
SetupStep stepAfterBusinessType(String code) =>
    code == otherBusinessType ? SetupStep.modules : SetupStep.form;

/// Whether changing the answer to the first question throws away the
/// business type.
///
/// It does when the answer becomes "myself", because a person has no
/// business type and leaving a stale one would file them as a
/// restaurant. It does not otherwise — and re-picking the same answer
/// changes nothing at all, which is the difference between a back
/// button and starting again.
bool clearsBusinessType(UseKind use) => use != UseKind.business;

/// Whether choosing a business type replaces the ticks.
///
/// Only when it is a different type. The ticks are what somebody was
/// shown and may have moved, so re-confirming the same answer must
/// leave them where they were put.
bool replacesTicks({required String? current, required String chosen}) =>
    current != chosen;

/// The lines at the top of the form saying what was answered on the way
/// here, each with a way back to the question.
const useFieldLabel = 'What this is for';
const businessTypeFieldLabel = 'Business type';
const modulesFieldLabel = 'Add-ons';

/// Whether the form's summary carries a "Business type" line, with a
/// way back to the screen that set it.
///
/// Only for a business. A person has no business type; a practice is
/// never asked for one, and the line read "Business type \u2014" with a
/// Change button beside it \u2014 an answer nobody gave, and a door back
/// into a question they were deliberately not shown.
///
/// Here rather than in the widget because it is a rule with a right
/// answer, and the version inside `build` was `!_personal`, which was
/// correct while there were two answers and silently wrong the moment
/// there were three.
bool showsBusinessTypeLine(UseKind? use) => use == UseKind.business;

/// Which answer was given to the first question.
String useAnswer(UseKind use, [SetupAudience audience = SetupAudience.own]) =>
    switch (use) {
      UseKind.personal => personalTitle(audience),
      UseKind.business => businessTitle,
      UseKind.accountant => accountantTitle,
    };

/// What the add-ons line says.
///
/// Counted here rather than named, because by this point the names have
/// been read on the screen that offered them and what somebody wants
/// from a summary line is whether it is the number they expected.
String modulesSummary(int chosen) => chosen == 0
    ? 'None — the books, contacts and invoicing are always on'
    : '$chosen chosen';
