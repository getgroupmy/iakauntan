import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/address_field.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/business_types_repository.dart';
import '../../data/my_profile_repository.dart';
import '../../data/places_repository.dart';
import '../settings/msic_picker.dart';
import 'home_country.dart';
import 'onboarding_copy.dart';

/// First-run setup. One call to create_organization() stands up the whole
/// tenant: chart of accounts, SST codes, fiscal calendar and pipeline.
class CreateOrgScreen extends ConsumerStatefulWidget {
  const CreateOrgScreen({super.key, this.returnTo});

  /// Where to go once the company exists.
  ///
  /// Null is first-run: the router is watching `hasOrg` and lets the
  /// person out of `/onboarding` by itself the moment there is a
  /// company. Reached from `/companies/new` by somebody who already has
  /// one, no redirect fires — they would be left looking at the form
  /// they have just submitted — so that address says where to go.
  final String? returnTo;

  @override
  ConsumerState<CreateOrgScreen> createState() => _CreateOrgScreenState();
}

class _CreateOrgScreenState extends ConsumerState<CreateOrgScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _registrationNo = TextEditingController();
  final _tin = TextEditingController();
  final _sstNo = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController();
  final _postcode = TextEditingController();
  /// Only drawn outside Malaysia, where the state list does not apply.
  final _state = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();

  /// The country, answered in advance.
  ///
  /// This used to be a question with no answer offered, standing in
  /// front of the form against a list of two hundred. It is a Malaysian
  /// product, so it starts on Malaysia and the question moves onto the
  /// form, where whoever it is wrong for can change it. What it governs
  /// has not changed: a company in Singapore filling in an SSM number
  /// is still being asked the wrong question, so the form still follows
  /// the answer.
  ///
  /// Three letters, which is what `organizations.country_code` stores.
  /// [_alpha2] is the same country in the two-letter form Google Places
  /// wants, carried separately rather than derived — `ref_countries`
  /// holds both and a mapping written here would be a second list.
  String _country = homeCountryCode;
  String _alpha2 = homeCountryAlpha2;

  /// What to call it on the line that says what it is.
  String _countryName = homeCountryName;

  /// Which of the three steps before the form is showing, if any.
  ///
  /// A step rather than a route because all of it is one answer being
  /// assembled: somebody who backs out of the module list has not left
  /// setup, they have changed their mind about a business type, and a
  /// router would have to carry the half-made answer between pages to
  /// say so.
  SetupStep _step = SetupStep.use;

  /// The steps walked through to get here, newest last.
  ///
  /// A stack rather than a single "came from", because these screens
  /// are reachable from more than one place and from each other: the
  /// module list is opened from a business type, from personal use and
  /// from the form, and back has to mean the one it was actually opened
  /// from. A single remembered step gets that right until somebody goes
  /// two deep, and then sends them round in a circle.
  final List<SetupStep> _trail = [];

  /// What this is being set up for. Null until the first step is
  /// answered, which is why the form is not drawn before then.
  ///
  /// Filled from the profile where registration already asked (`0558`),
  /// so somebody who has just said "a business" is not asked again one
  /// screen later. Still changeable from the summary card on the form:
  /// an accountant who registered for themselves may well be opening a
  /// company's books.
  UseKind? _use;

  /// Whether the answer has been taken off the profile yet.
  ///
  /// Once only. A rebuild after somebody has changed their mind must
  /// not put the registration's answer back.
  bool _tookProfileAnswer = false;

  /// The business type chosen, and the modules that go with it.
  ///
  /// `_ticked` starts as the type's own list and is whatever the person
  /// leaves it as: what is shown is what is sent, and what is sent is
  /// what is charged.
  String? _businessType;

  /// What to call it on the line that says what was chosen. The row's
  /// own name rather than the code, and carried rather than looked up
  /// again, so the summary reads the same whether or not the catalogue
  /// is still in the cache.
  String? _businessTypeName;

  final Set<String> _ticked = {};

  String _entityType = 'sdn_bhd';
  String? _stateCode;
  String? _msicCode;
  bool _sstRegistered = false;
  int _fiscalYearEndMonth = 12;
  bool _busy = false;
  String? _error;

  /// Whether the Malaysian half of this form applies.
  ///
  /// SSM registration, an LHDN TIN, SST and the state list are
  /// Malaysian instruments, and a company in Singapore has none of
  /// them. Asking anyway is how a form teaches somebody that it was not
  /// written for them.
  bool get _malaysian => _country == 'MYS';

  static const _entityTypes = {
    'sdn_bhd': 'Sendirian Berhad (Sdn Bhd)',
    'bhd': 'Berhad (Bhd)',
    'enterprise': 'Enterprise',
    'sole_proprietor': 'Sole Proprietor',
    'partnership': 'Partnership',
    'llp': 'Limited Liability Partnership',
    'association': 'Association / Society',
    'other': 'Other',
  };

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  @override
  void dispose() {
    for (final c in [
      _name, _registrationNo, _tin, _sstNo,
      _address, _city, _postcode, _state, _phone, _email,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final orgId = await ref.read(supabaseProvider).rpc(
        'create_organization',
        params: {
          'p_name': _name.text.trim(),
          // Personal use has no entity type to choose: the person IS
          // the entity, and `0553`'s trigger reads this value to file
          // them under NRIC or passport rather than under a business
          // registration number MyInvois would reject.
          'p_entity_type':
              _personal ? personalEntityType : _entityType,
          'p_registration_no': _emptyToNull(_registrationNo.text),
          'p_tin': _emptyToNull(_tin.text),
          'p_msic_code': _msicCode,
          // One argument, two sources: inside Malaysia it is a code
          // from `ref_states`, and outside it is whatever was typed.
          // The column is free text, so both are honest; what would not
          // be is storing a Malaysian code for a Thai province.
          'p_state_code': _malaysian ? _stateCode : _emptyToNull(_state.text),
          'p_city': _emptyToNull(_city.text),
          'p_postcode': _emptyToNull(_postcode.text),
          'p_address_line1': _emptyToNull(_address.text),
          'p_phone': _emptyToNull(_phone.text),
          'p_email': _emptyToNull(_email.text),
          'p_is_sst_registered': _sstRegistered,
          'p_sst_registration_no': _emptyToNull(_sstNo.text),
          'p_fiscal_year_end_month': _fiscalYearEndMonth,
          'p_country_code': _country,
        },
      );

      // What the company said it is, and the modules it was shown.
      // After the company exists, because both are recorded against it
      // — and inside the same try, so a failure here is a failure of
      // setup rather than a company that quietly has none of what it
      // asked for.
      if (orgId is String) {
        await applyBusinessType(
          ref,
          orgId: orgId,
          businessType: _businessType,
          modules: _ticked.toList(),
        );
      }

      // Refresh the org list so the router lets us out of onboarding.
      ref.invalidate(organizationsProvider);
      await ref.read(organizationsProvider.future);
      if (orgId is String) {
        ref.read(currentOrgIdProvider.notifier).select(orgId);
      }
      final to = widget.returnTo;
      if (to != null && mounted) context.go(to);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The `ref_states` code for a state name Google returned, or null.
  ///
  /// Matched on the name because that is all Places gives — and left
  /// null when nothing matches rather than guessed, since a wrong state
  /// on a company record is worse than an empty one somebody fills in.
  String? _stateFor(String? name) => stateCodeFor(
    ref.read(refStatesProvider).valueOrNull ?? const [],
    name,
  );

  /// Go to a step, remembering where from.
  ///
  /// Every move goes through here, so a back button always lands where
  /// somebody came from rather than where the flow would have gone
  /// next. Opening the module list from the form and pressing back is
  /// the case that made this necessary: it used to land on the business
  /// type list, a question already answered, as though the form had
  /// been abandoned.
  void _goTo(SetupStep target) => setState(() {
    _trail.add(_step);
    _step = target;
  });

  /// Back to whatever opened the step showing now.
  ///
  /// Nothing is thrown away on the way back. That is the whole point:
  /// every answer already given is still given, and the form's fields
  /// are still typed, because none of this is a route being popped.
  void _goBack() => setState(() {
    if (_trail.isNotEmpty) _step = _trail.removeLast();
  });

  void _openCountries() => _goTo(SetupStep.country);

  void _chooseCountry(String code, String alpha2, String name) => setState(() {
    _country = code;
    _alpha2 = alpha2;
    _countryName = name;
    if (_trail.isNotEmpty) _step = _trail.removeLast();
    // Nothing else is thrown away. The country changes what the form
    // ASKS, not what somebody has already answered about themselves.
    // A state chosen for one country means nothing in another, and the
    // list itself is Malaysian. Cleared rather than carried.
    _stateCode = null;
    if (!_malaysian) {
      _sstRegistered = false;
      _sstNo.clear();
    }
  });

  static String? _emptyToNull(String value) =>
      value.trim().isEmpty ? null : value.trim();

  /// Whether this is one person rather than a business.
  bool get _personal => _use == UseKind.personal;

  /// Whose books these are.
  ///
  /// `/onboarding` is first-run and these are the reader's own.
  /// `/companies/new` is another set of books on the same sign-in —
  /// which is what an accounting practice with `multi_company` does all
  /// day, for clients who are companies AND for clients who are one
  /// person — so the words there are about somebody else. `returnTo` is
  /// the marker because it is exactly what distinguishes the two
  /// routes.
  SetupAudience get _audience =>
      widget.returnTo == null ? SetupAudience.own : SetupAudience.other;

  /// The answer to the first question, and where it leads.
  ///
  /// A person setting up for themselves is not asked what kind of
  /// business they are, because they are not one. They are asked what
  /// else they need, which is the same module list.
  ///
  /// Coming back and giving the same answer again changes nothing at
  /// all, and coming back to change it keeps everything the new answer
  /// can still be true of. Somebody who chose "a business", picked
  /// restaurant, reached the form and then went back to look at the
  /// first question has not asked to start again.
  void _chooseUse(UseKind use) {
    setState(() {
      _use = use;
      // A person has no business type, and leaving a stale one would
      // file them as a restaurant. The ticks stay either way: they are
      // things somebody said they wanted, and that does not stop being
      // true because they are doing it under their own name.
      if (clearsBusinessType(use)) {
        _businessType = null;
        _businessTypeName = null;
      }
    });
    _goTo(stepAfterUse(use, businessType: _businessType));
  }

  /// A business type, and the modules it brings with it.
  ///
  /// The ticks are replaced only when the type actually changes. A law
  /// firm that unticked timesheets, went back to check the list, and
  /// tapped "Law firm" again would otherwise find timesheets ticked
  /// once more.
  void _chooseBusinessType(String code, String name, List<String> modules) {
    setState(() {
      if (replacesTicks(current: _businessType, chosen: code)) {
        _ticked
          ..clear()
          ..addAll(modules);
      }
      _businessType = code;
      _businessTypeName = name;
    });
    _goTo(stepAfterBusinessType(code));
  }

  /// Start from what registration was told, where it was told
  /// anything.
  ///
  /// An account made before the question existed, or by an invitation,
  /// has no answer on its profile and is asked here exactly as
  /// everybody was before.
  void _takeProfileAnswer() {
    if (_tookProfileAnswer || _use != null) return;
    final profile = ref.watch(myProfileProvider).valueOrNull;
    if (profile == null) return;
    _tookProfileAnswer = true;

    final said = useKindFrom(profile['use_kind'] as String?);
    if (said == null) return;

    // Where the PERSON said they are, as the company's starting
    // country. A better guess than Malaysia for somebody who told us
    // they are in Singapore, and still changeable on the form.
    //
    // Only when the reference list can name it, so the code and the
    // words on the country line move together — a line reading
    // "Malaysia" over a form asking Singaporean questions would be
    // worse than not adopting it at all.
    final theirCountry = '${profile['country_code'] ?? ''}'.trim();
    Map<String, dynamic>? theirRow;
    for (final c in ref.read(countriesProvider).valueOrNull ?? const []) {
      if (c['code'] == theirCountry) theirRow = c;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _use = said;
        if (theirRow != null) {
          _country = theirCountry;
          _alpha2 = '${theirRow['alpha2']}';
          _countryName = '${theirRow['name']}';
          if (!_malaysian) {
            _stateCode = null;
            _sstRegistered = false;
          }
        }
        _step = stepAfterUse(said, businessType: _businessType);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final statesAsync = ref.watch(refStatesProvider);
    _takeProfileAnswer();

    switch (_step) {
      case SetupStep.country:
        return _CountryStep(onChosen: _chooseCountry, onCancel: _goBack);
      case SetupStep.use:
        return _UseStep(
          countryName: _countryName,
          audience: _audience,
          chosen: _use,
          onCountry: _openCountries,
          onChosen: _chooseUse,
          // Only once there is somewhere to go back TO. On the first
          // screen of setup there is not.
          onBack: _trail.isEmpty ? null : _goBack,
        );
      case SetupStep.businessType:
        return _BusinessTypeStep(
          chosen: _businessType,
          onChosen: _chooseBusinessType,
          onUse: () => _goTo(SetupStep.use),
          onBack: _goBack,
        );
      case SetupStep.modules:
        return _ModulesStep(
          ticked: _ticked,
          onToggle: (code, on) => setState(() {
            if (on) {
              _ticked.add(code);
            } else {
              _ticked.remove(code);
            }
          }),
          onDone: () => _goTo(SetupStep.form),
          onBack: _goBack,
        );
      case SetupStep.form:
        break;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(setupTitle(_use ?? UseKind.business,
            audience: _audience)),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await ref.read(supabaseProvider).auth.signOut();
            },
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Sign out'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 720,
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // What was answered on the way here, and a way back to
                // each of them. Somebody who realises at the address
                // box that they picked the wrong trade should not have
                // to abandon a half-filled form to fix it — and coming
                // back from one of these lands here again with
                // everything still typed.
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        key: const ValueKey('org-country'),
                        leading: const Icon(Icons.public, size: 20),
                        title: const Text(countryFieldLabel),
                        subtitle: Text('$_countryName\n$countryChangeHint'),
                        isThreeLine: true,
                        trailing: TextButton(
                          key: const ValueKey('org-country-change'),
                          onPressed: _busy ? null : _openCountries,
                          child: const Text(countryChangeLabel),
                        ),
                      ),
                      ListTile(
                        key: const ValueKey('org-use'),
                        leading: Icon(
                          _personal ? Icons.person_outline : Icons.storefront,
                          size: 20,
                        ),
                        title: const Text(useFieldLabel),
                        subtitle: Text(
                            useAnswer(_use ?? UseKind.business, _audience)),
                        trailing: TextButton(
                          key: const ValueKey('org-use-change'),
                          onPressed:
                              _busy ? null : () => _goTo(SetupStep.use),
                          child: const Text(countryChangeLabel),
                        ),
                      ),
                      // A person has no business type, so there is no
                      // line for one.
                      if (!_personal)
                        ListTile(
                          key: const ValueKey('org-business-type'),
                          leading: const Icon(Icons.category_outlined,
                              size: 20),
                          title: const Text(businessTypeFieldLabel),
                          subtitle: Text(_businessTypeName ?? '—'),
                          trailing: TextButton(
                            key: const ValueKey('org-business-type-change'),
                            onPressed: _busy
                                ? null
                                : () => _goTo(SetupStep.businessType),
                            child: const Text(countryChangeLabel),
                          ),
                        ),
                      ListTile(
                        key: const ValueKey('org-modules'),
                        leading: const Icon(Icons.widgets_outlined, size: 20),
                        title: const Text(modulesFieldLabel),
                        subtitle: Text(modulesSummary(_ticked.length)),
                        trailing: TextButton(
                          key: const ValueKey('org-modules-change'),
                          onPressed:
                              _busy ? null : () => _goTo(SetupStep.modules),
                          child: const Text(countryChangeLabel),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Row(
                      children: [
                        Icon(Icons.auto_awesome,
                            color: context.colors.success, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            setupPromise(
                              malaysian: _malaysian,
                              use: _use ?? UseKind.business,
                              audience: _audience,
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                SectionHeader(_personal ? 'Your details' : 'Company details'),
                TextFormField(
                  key: const ValueKey('org-name'),
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: nameLabel(
                      _use ?? UseKind.business,
                      malaysian: _malaysian,
                      audience: _audience,
                    ),
                    hintText: _personal
                        ? 'e.g. Nurul Aisyah binti Rahman'
                        : 'e.g. Sinar Teknologi Sdn Bhd',
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? (_personal
                          ? 'Enter your full name'
                          : 'Enter the company name')
                      : null,
                ),
                const SizedBox(height: 14),
                // A person has no entity type to choose. They are filed
                // as `individual`, which is what makes LHDN see a
                // person, and a dropdown offering Sdn Bhd to somebody
                // invoicing under their own name is a dropdown with one
                // right answer hidden in it.
                if (!_personal) ...[
                  DropdownButtonFormField<String>(
                    value: _entityType,
                    decoration: const InputDecoration(labelText: 'Entity type'),
                    items: [
                      for (final e in _entityTypes.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) =>
                        setState(() => _entityType = v ?? 'sdn_bhd'),
                  ),
                  const SizedBox(height: 14),
                ],
                // `_msicCode` was declared here and sent to
                // `create_organization`, and nothing ever set it — so
                // every company created through this form was
                // registered with no business activity at all, against
                // a list of them seeded in 0011.
                Consumer(
                  builder: (context, ref, _) {
                    final all =
                        ref.watch(msicCodesProvider).valueOrNull ??
                        const <Map<String, dynamic>>[];
                    return ListTile(
                      key: const ValueKey('org-msic'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(_personal
                          ? 'What you do'
                          : 'What the business does'),
                      subtitle: Text(msicSummary(all, _msicCode)),
                      trailing: const Icon(Icons.search, size: 18),
                      onTap: _busy
                          ? null
                          : () async {
                              final picked = await pickMsicCode(
                                context,
                                current: _msicCode,
                              );
                              if (picked != null) {
                                setState(() => _msicCode = picked);
                              }
                            },
                    );
                  },
                ),
                const SizedBox(height: 14),
                _Row2(
                  left: TextFormField(
                    key: const ValueKey('org-registration'),
                    controller: _registrationNo,
                    decoration: InputDecoration(
                      // The same column either way, and a different
                      // number in it. A box labelled "SSM registration
                      // no." in front of somebody who has never had one
                      // is a box left empty, and an empty
                      // identification is a rejected e-Invoice.
                      labelText: identificationLabel(
                        _use ?? UseKind.business,
                        malaysian: _malaysian,
                      ),
                      hintText: identificationHint(
                        _use ?? UseKind.business,
                        malaysian: _malaysian,
                      ),
                      helperText: identificationHelp(
                        _use ?? UseKind.business,
                        audience: _audience,
                      ),
                      helperMaxLines: 2,
                    ),
                  ),
                  right: TextFormField(
                    controller: _tin,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'LHDN TIN',
                      hintText: 'C12345678900',
                      helperText: 'Required for e-Invoice',
                    ),
                  ),
                ),

                const SizedBox(height: 24),
                const SectionHeader('Address'),
                AddressField(
                  controller: _address,
                  country: _alpha2,
                  // What a chosen suggestion fills in. The street line
                  // goes in the box somebody was typing in; the rest
                  // land in their own boxes, which is the point of
                  // suggesting rather than pasting one long string.
                  onChosen: (a) => setState(() {
                    if (a.city != null) _city.text = a.city!;
                    if (a.postcode != null) _postcode.text = a.postcode!;
                    if (_malaysian) _stateCode = _stateFor(a.state);
                  }),
                ),
                const SizedBox(height: 14),
                _Row2(
                  left: TextFormField(
                    controller: _postcode,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Postcode'),
                  ),
                  right: TextFormField(
                    controller: _city,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'City'),
                  ),
                ),
                const SizedBox(height: 14),
                // `ref_states` is the thirteen states and three federal
                // territories of Malaysia. Offering that list to a
                // company in Thailand would be offering it a wrong
                // answer, so elsewhere the box is a box.
                if (_malaysian)
                  statesAsync.when(
                    data: (states) => DropdownButtonFormField<String>(
                      value: _stateCode,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'State'),
                      items: [
                        for (final s in states)
                          DropdownMenuItem(
                            value: s['code'] as String,
                            child: Text(s['name'] as String),
                          ),
                      ],
                      onChanged: (v) => setState(() => _stateCode = v),
                    ),
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text('Could not load states: $e'),
                  )
                else
                  TextFormField(
                    controller: _state,
                    textCapitalization: TextCapitalization.words,
                    decoration:
                        const InputDecoration(labelText: 'State or province'),
                  ),

                const SizedBox(height: 24),
                const SectionHeader('Contact'),
                _Row2(
                  left: TextFormField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Phone',
                      hintText: '+60312345678',
                    ),
                  ),
                  right: TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                ),

                const SizedBox(height: 24),
                const SectionHeader('Tax and accounting'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _sstRegistered,
                  onChanged: (v) => setState(() => _sstRegistered = v),
                  title: const Text('Registered for SST'),
                  subtitle: const Text(
                    'Turn on if you charge sales tax or service tax',
                  ),
                ),
                if (_sstRegistered) ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _sstNo,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'SST registration no.',
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                DropdownButtonFormField<int>(
                  value: _fiscalYearEndMonth,
                  decoration: const InputDecoration(
                    labelText: 'Financial year end',
                    helperText: 'Most Malaysian SMEs use December',
                  ),
                  items: [
                    for (var i = 0; i < 12; i++)
                      DropdownMenuItem(value: i + 1, child: Text(_months[i])),
                  ],
                  onChanged: (v) =>
                      setState(() => _fiscalYearEndMonth = v ?? 12),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(Space.md),
                    decoration: BoxDecoration(
                      color: context.colors.danger.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(color: context.colors.danger),
                    ),
                  ),
                ],

                const SizedBox(height: 28),
                FilledButton(
                  onPressed: _busy ? null : _create,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(createButtonLabel(_use ?? UseKind.business,
                          audience: _audience)),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Two fields side by side on wide screens, stacked on phones.
class _Row2 extends StatelessWidget {
  const _Row2({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 600) {
      return Column(children: [left, const SizedBox(height: 14), right]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 14),
        Expanded(child: right),
      ],
    );
  }
}

/// The first question: who this is for.
///
/// Before anything else, because it decides which of two products the
/// rest of setup is. A person invoicing under their own name is asked
/// for a full name and a MyKad number and is never shown a list of
/// business types; a company is asked what kind of business it is and
/// offered what that needs.
///
/// The country sits on this step rather than in front of it. It is
/// answered already — Malaysia — and everything after it follows the
/// answer, so it belongs where somebody can see it and change it
/// without being stopped by it.
class _UseStep extends ConsumerWidget {
  const _UseStep({
    required this.countryName,
    required this.audience,
    required this.chosen,
    required this.onCountry,
    required this.onChosen,
    required this.onBack,
  });

  final String countryName;

  /// Whose books these are, which decides whether the personal answer
  /// is "Myself" or "An individual".
  final SetupAudience audience;

  /// What was answered last time, if this is a second visit. Marked
  /// rather than merely remembered: somebody who comes back to check
  /// what they said should be able to see it and leave it alone.
  final UseKind? chosen;

  final VoidCallback onCountry;
  final void Function(UseKind) onChosen;

  /// Null on the first screen of setup, where there is nowhere back to.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: Text(useQuestion(audience)),
        leading: onBack == null
            ? null
            : BackButton(
                key: const ValueKey('use-back'),
                onPressed: onBack,
              ),
        actions: [
          TextButton.icon(
            onPressed: () => ref.read(supabaseProvider).auth.signOut(),
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Sign out'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: ListTile(
                  key: const ValueKey('use-country'),
                  leading: const Icon(Icons.public, size: 20),
                  title: const Text(countryFieldLabel),
                  subtitle: Text(countryName),
                  trailing: TextButton(
                    key: const ValueKey('use-country-change'),
                    onPressed: onCountry,
                    child: const Text(countryChangeLabel),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _UseCard(
                tileKey: const ValueKey('use-business'),
                icon: Icons.storefront,
                title: businessTitle,
                blurb: businessBlurb,
                current: chosen == UseKind.business,
                onTap: () => onChosen(UseKind.business),
              ),
              const SizedBox(height: 12),
              _UseCard(
                tileKey: const ValueKey('use-personal'),
                icon: Icons.person_outline,
                title: personalTitle(audience),
                blurb: personalBlurb(audience),
                current: chosen == UseKind.personal,
                onTap: () => onChosen(UseKind.personal),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the two answers, big enough to read before choosing.
class _UseCard extends StatelessWidget {
  const _UseCard({
    required this.tileKey,
    required this.icon,
    required this.title,
    required this.blurb,
    required this.current,
    required this.onTap,
  });

  final Key tileKey;
  final IconData icon;
  final String title;
  final String blurb;

  /// Whether this is the answer already given.
  final bool current;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      key: tileKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: context.colors.success),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(blurb, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            Icon(
              current ? Icons.check_circle : Icons.chevron_right,
              size: 20,
              color: current ? context.colors.success : null,
            ),
          ],
        ),
      ),
    ),
  );
}

/// The second question: what kind of business.
///
/// Forty trades, grouped by sector, each saying what it switches on.
/// Named rather than counted — "adds 3 modules" tells nobody whether
/// the answer is right for them, and being able to tell is the whole
/// point of asking.
class _BusinessTypeStep extends ConsumerWidget {
  const _BusinessTypeStep({
    required this.chosen,
    required this.onChosen,
    required this.onUse,
    required this.onBack,
  });

  /// The type already chosen, marked in the list.
  final String? chosen;

  final void Function(String code, String name, List<String> modules) onChosen;

  /// Back to the first question. Somebody who opens this list and
  /// realises they are not a business at all should be able to say so
  /// from here, rather than having to pick a trade they are not in
  /// order to reach a screen that lets them.
  final VoidCallback onUse;

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final types = ref.watch(businessTypesProvider);
    final modules = ref.watch(onboardingModulesProvider).valueOrNull ??
        const <Map<String, dynamic>>[];
    final names = {
      for (final m in modules) '${m['code']}': '${m['name']}',
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text(businessTypeQuestion),
        leading: BackButton(
          key: const ValueKey('business-type-back'),
          onPressed: onBack,
        ),
      ),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                businessTypeBlurb,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  key: const ValueKey('business-type-use'),
                  leading: const Icon(Icons.person_outline, size: 20),
                  title: const Text(useFieldLabel),
                  subtitle: const Text(businessTitle),
                  trailing: TextButton(
                    key: const ValueKey('business-type-use-change'),
                    onPressed: onUse,
                    child: const Text(countryChangeLabel),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              AsyncView<List<Map<String, dynamic>>>(
                value: types,
                onRetry: () => ref.invalidate(businessTypesProvider),
                builder: (rows) {
                  final groups = bySector(rows);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final entry in groups.entries) ...[
                        SectionHeader(entry.key),
                        Card(
                          child: Column(
                            children: [
                              for (final t in entry.value)
                                ListTile(
                                  key: ValueKey('business-type-${t['code']}'),
                                  title: Text('${t['name']}'),
                                  subtitle: Text(modulesAdded([
                                    for (final c
                                        in (t['module_codes'] as List? ??
                                            const []))
                                      names['$c'] ?? '$c',
                                  ])),
                                  trailing: Icon(
                                    chosen == '${t['code']}'
                                        ? Icons.check_circle
                                        : Icons.chevron_right,
                                    size: 18,
                                    color: chosen == '${t['code']}'
                                        ? context.colors.success
                                        : null,
                                  ),
                                  onTap: () => onChosen(
                                    '${t['code']}',
                                    '${t['name']}',
                                    [
                                      for (final c
                                          in (t['module_codes'] as List? ??
                                              const []))
                                        '$c',
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      const SizedBox(height: 32),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The module list, ticked.
///
/// Reached three ways: from "Something else", from personal use, and
/// from the Change beside what a business type offered. Nothing here is
/// required, and the screen says so — the books, contacts and invoicing
/// are on for everybody, and this is the part that costs money.
class _ModulesStep extends ConsumerWidget {
  const _ModulesStep({
    required this.ticked,
    required this.onToggle,
    required this.onDone,
    required this.onBack,
  });

  final Set<String> ticked;
  final void Function(String code, bool on) onToggle;
  final VoidCallback onDone;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modules = ref.watch(onboardingModulesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(modulesQuestion),
        leading: BackButton(
          key: const ValueKey('modules-back'),
          onPressed: onBack,
        ),
      ),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(modulesBlurb, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 16),
              AsyncView<List<Map<String, dynamic>>>(
                value: modules,
                onRetry: () => ref.invalidate(onboardingModulesProvider),
                builder: (rows) {
                  // What the ticks come to, before anything is agreed
                  // to rather than on the first bill.
                  final total = rows.fold<num>(
                    0,
                    (sum, m) => ticked.contains('${m['code']}')
                        ? sum + ((m['monthly_price'] as num?) ?? 0)
                        : sum,
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        child: Column(
                          children: [
                            for (final m in rows)
                              CheckboxListTile(
                                key: ValueKey('module-${m['code']}'),
                                value: ticked.contains('${m['code']}'),
                                onChanged: (v) =>
                                    onToggle('${m['code']}', v ?? false),
                                title: Text('${m['name']}'),
                                subtitle: Text(
                                  monthlyPrice(m['monthly_price'] as num?),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        monthlyTotal(total),
                        key: const ValueKey('modules-total'),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        key: const ValueKey('modules-done'),
                        onPressed: onDone,
                        child: const Text('Continue'),
                      ),
                      const SizedBox(height: 40),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which country the company is in.
///
/// Its own screen rather than a field at the top of the form, because
/// the answer changes what the form asks. A company in Singapore
/// scrolling past SSM registration and an LHDN TIN before reaching the
/// country box has already been told the product was not written for
/// it; asking first is the difference between a form that adapts and
/// one that apologises.
///
/// Reached from the country line on the form, which already says
/// Malaysia. Malaysia is first in the list here too, because the
/// commonest reason to open this screen and then change nothing is
/// having opened it to check.
class _CountryStep extends ConsumerStatefulWidget {
  const _CountryStep({required this.onChosen, required this.onCancel});

  /// Called with the three-letter code the column stores, the
  /// two-letter one Google Places wants, and the name to show.
  final void Function(String code, String alpha2, String name) onChosen;

  /// Leaving without changing anything, which is a thing somebody who
  /// opened this to look at it has to be able to do.
  final VoidCallback onCancel;

  @override
  ConsumerState<_CountryStep> createState() => _CountryStepState();
}

class _CountryStepState extends ConsumerState<_CountryStep> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final countries = ref.watch(countriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Where is your company?'),
        leading: BackButton(
          key: const ValueKey('country-back'),
          onPressed: widget.onCancel,
        ),
        actions: [
          TextButton.icon(
            onPressed: () => ref.read(supabaseProvider).auth.signOut(),
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Sign out'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 520,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'The rest of the setup depends on this — the tax numbers '
                'a company is asked for are not the same everywhere.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Search',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
              const SizedBox(height: 12),
              AsyncView<List<Map<String, dynamic>>>(
                value: countries,
                onRetry: () => ref.invalidate(countriesProvider),
                builder: (rows) {
                  final wanted = _query.toLowerCase();
                  // Filter first, then pin: a search that excludes
                  // Malaysia should not have it put back at the top.
                  final shown = countriesWithHomeFirst([
                    for (final c in rows)
                      if (wanted.isEmpty ||
                          '${c['name']}'.toLowerCase().contains(wanted) ||
                          '${c['alpha2']}'.toLowerCase() == wanted ||
                          '${c['code']}'.toLowerCase() == wanted)
                        c,
                  ]);
                  if (shown.isEmpty) {
                    return const EmptyState(
                      icon: Icons.public_off,
                      title: 'No country by that name',
                      message: 'Try the country in English, or its two '
                          'letter code.',
                    );
                  }
                  return Card(
                    child: Column(
                      children: [
                        for (final c in shown)
                          ListTile(
                            title: Text('${c['name']}'),
                            trailing: Text(
                              '${c['alpha2']}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            onTap: () => widget.onChosen(
                              '${c['code']}',
                              '${c['alpha2']}',
                              '${c['name']}',
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
