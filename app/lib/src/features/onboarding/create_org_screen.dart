import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// First-run setup. One call to create_organization() stands up the whole
/// tenant: chart of accounts, SST codes, fiscal calendar and pipeline.
class CreateOrgScreen extends ConsumerStatefulWidget {
  const CreateOrgScreen({super.key});

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
  final _phone = TextEditingController();
  final _email = TextEditingController();

  String _entityType = 'sdn_bhd';
  String? _stateCode;
  String? _msicCode;
  bool _sstRegistered = false;
  int _fiscalYearEndMonth = 12;
  bool _busy = false;
  String? _error;

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
      _address, _city, _postcode, _phone, _email,
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
          'p_state_code': _stateCode,
          'p_city': _emptyToNull(_city.text),
          'p_postcode': _emptyToNull(_postcode.text),
          'p_address_line1': _emptyToNull(_address.text),
          'p_phone': _emptyToNull(_phone.text),
          'p_email': _emptyToNull(_email.text),
          'p_is_sst_registered': _sstRegistered,
          'p_sst_registration_no': _emptyToNull(_sstNo.text),
          'p_fiscal_year_end_month': _fiscalYearEndMonth,
        },
      );

      // Refresh the org list so the router lets us out of onboarding.
      ref.invalidate(organizationsProvider);
      await ref.read(organizationsProvider.future);
      if (orgId is String) {
        ref.read(currentOrgIdProvider.notifier).select(orgId);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String? _emptyToNull(String value) =>
      value.trim().isEmpty ? null : value.trim();

  @override
  Widget build(BuildContext context) {
    final statesAsync = ref.watch(_statesProvider);

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
                            'We will create a Malaysian chart of accounts, SST tax '
                            'codes, a fiscal calendar and a sales pipeline for you.',
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
                TextFormField(
                  controller: _address,
                  decoration: const InputDecoration(labelText: 'Address'),
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

/// States are reference data, readable before an org exists.
final _statesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final data = await ref
      .watch(supabaseProvider)
      .from('ref_states')
      .select()
      .order('code');
  return (data as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
});

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
