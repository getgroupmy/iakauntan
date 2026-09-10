import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/address_field.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/places_repository.dart';
import '../settings/msic_picker.dart';
import 'home_country.dart';

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

  /// Whether the picker is open.
  ///
  /// The full-screen list is still the way to change it: two hundred
  /// countries is not a dropdown, and the search box is the point.
  bool _choosingCountry = false;

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
          'p_entity_type': _entityType,
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

  void _chooseCountry(String code, String alpha2, String name) => setState(() {
    _country = code;
    _alpha2 = alpha2;
    _countryName = name;
    _choosingCountry = false;
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

  @override
  Widget build(BuildContext context) {
    final statesAsync = ref.watch(refStatesProvider);

    // Only when somebody asked for it. The answer is already there.
    if (_choosingCountry) {
      return _CountryStep(
        onChosen: _chooseCountry,
        onCancel: () => setState(() => _choosingCountry = false),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up your company'),
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
                // The question that used to stand in front of this
                // form, answered. It is first because everything below
                // follows it, and it is a line rather than a step
                // because for almost everybody the answer is already
                // right.
                Card(
                  child: ListTile(
                    key: const ValueKey('org-country'),
                    leading: const Icon(Icons.public, size: 20),
                    title: const Text(countryFieldLabel),
                    subtitle: Text('$_countryName\n$countryChangeHint'),
                    isThreeLine: true,
                    trailing: TextButton(
                      key: const ValueKey('org-country-change'),
                      onPressed: _busy
                          ? null
                          : () => setState(() => _choosingCountry = true),
                      child: const Text(countryChangeLabel),
                    ),
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
                            setupPromise(malaysian: _malaysian),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                const SectionHeader('Company details'),
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Company name *',
                    hintText: 'e.g. Sinar Teknologi Sdn Bhd',
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Enter the company name' : null,
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  value: _entityType,
                  decoration: const InputDecoration(labelText: 'Entity type'),
                  items: [
                    for (final e in _entityTypes.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() => _entityType = v ?? 'sdn_bhd'),
                ),
                const SizedBox(height: 14),
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
                      title: const Text('What the business does'),
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
                    controller: _registrationNo,
                    decoration: const InputDecoration(
                      labelText: 'SSM registration no.',
                      hintText: '202301234567',
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
                      : const Text('Create company'),
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

/// The first question: which country the company is in.
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
