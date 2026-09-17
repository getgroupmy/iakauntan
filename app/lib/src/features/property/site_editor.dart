import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/address_field.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/places_repository.dart';
import '../../data/repository.dart';

/// Add or amend a property the company manages.
///
/// This screen did not exist. `property_screen.dart` has always had an
/// "Add property" button pointing at `/property/new`, and `/property`
/// only ever declared a `:id` child — so the button routed to the site
/// *viewer* with the literal string `new` as the id, and the page died
/// on `invalid input syntax for type uuid: "new"`. The create path for
/// the whole property module was a dead end.
///
/// `tenure` is the field to get right and the only one that cannot be
/// changed casually afterwards. It decides which half of the module a
/// site belongs to — strata schemes carry maintenance and sinking fund
/// charges against share units, non-strata carries tenancies and rent —
/// and they are separately licensed (`property_strata`,
/// `property_nonstrata`). So it is asked for once, plainly, and the
/// explanation sits next to it rather than in a manual.
class PropertySiteEditor extends ConsumerStatefulWidget {
  const PropertySiteEditor({super.key, this.siteId});

  final String? siteId;

  bool get isNew => siteId == null;

  @override
  ConsumerState<PropertySiteEditor> createState() => _PropertySiteEditorState();
}

class _PropertySiteEditorState extends ConsumerState<PropertySiteEditor> {
  final _formKey = GlobalKey<FormState>();
  final _c = <String, TextEditingController>{};

  String _tenure = 'strata';
  bool _active = true;
  bool _saving = false;
  bool _loaded = false;

  TextEditingController _ctl(String key) =>
      _c.putIfAbsent(key, () => TextEditingController());

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? _blank(String key) {
    final v = _ctl(key).text.trim();
    return v.isEmpty ? null : v;
  }

  void _hydrate(Map<String, dynamic> site) {
    if (_loaded) return;
    _loaded = true;
    for (final key in const [
      'code',
      'name',
      'address_line1',
      'address_line2',
      'postcode',
      'city',
      'state_code',
      'local_authority',
      'land_title_no',
      'lot_no',
      'quit_rent_account_no',
      'assessment_account_no',
      'notes',
    ]) {
      _ctl(key).text = (site[key] ?? '').toString();
    }
    _tenure = (site['tenure'] ?? 'strata').toString();
    _active = site['is_active'] != false;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final values = <String, dynamic>{
      'code': _ctl('code').text.trim(),
      'name': _ctl('name').text.trim(),
      'tenure': _tenure,
      'address_line1': _blank('address_line1'),
      'address_line2': _blank('address_line2'),
      'postcode': _blank('postcode'),
      'city': _blank('city'),
      'state_code': _blank('state_code'),
      'local_authority': _blank('local_authority'),
      'land_title_no': _blank('land_title_no'),
      'lot_no': _blank('lot_no'),
      'quit_rent_account_no': _blank('quit_rent_account_no'),
      'assessment_account_no': _blank('assessment_account_no'),
      'notes': _blank('notes'),
      'is_active': _active,
    };

    String? newId;
    final ok = await runWithFeedback(
      context,
      action: () async {
        newId = await ref
            .read(repoProvider)!
            .savePropertySite(values, id: widget.siteId);
      },
      successMessage: widget.isNew ? 'Property added' : 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      // Both tenures are invalidated rather than the one just saved:
      // amending a site can move it between them, and the list the user
      // came from is whichever one they had open.
      ref.invalidate(propertySitesProvider);
      if (widget.siteId != null) {
        ref.invalidate(propertySiteProvider(widget.siteId!));
      }
      // Straight into the site that was just created, because a new
      // property is useless until it has units, and that is the screen
      // where they are added.
      context.go(newId == null ? '/property' : '/property/$newId');
    }
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.isNew
        ? const AsyncValue<Map<String, dynamic>?>.data(null)
        : ref.watch(propertySiteProvider(widget.siteId!));

    // Watched rather than read, so the reference list is on its way
    // before anybody picks a suggestion.
    final states = ref.watch(refStatesProvider).valueOrNull ?? const [];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/property'),
        ),
        title: Text(widget.isNew ? 'Add property' : 'Edit property'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check, size: 18),
              label: const Text('Save'),
            ),
          ),
        ],
      ),
      body: AsyncView<Map<String, dynamic>?>(
        value: existing,
        builder: (site) {
          if (site != null) _hydrate(site);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(Space.lg),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _section('The property'),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              controller: _ctl('code'),
                              decoration: const InputDecoration(
                                labelText: 'Code',
                                helperText: 'Short reference, e.g. VP-01',
                              ),
                              textCapitalization:
                                  TextCapitalization.characters,
                              validator: (v) => (v ?? '').trim().isEmpty
                                  ? 'A code is needed'
                                  : null,
                            ),
                          ),
                          const SizedBox(width: Space.md),
                          Expanded(
                            flex: 5,
                            child: TextFormField(
                              controller: _ctl('name'),
                              decoration: const InputDecoration(
                                labelText: 'Name',
                              ),
                              validator: (v) => (v ?? '').trim().isEmpty
                                  ? 'A name is needed'
                                  : null,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.md),
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _tenure,
                        decoration: const InputDecoration(
                          labelText: 'Tenure',
                          helperText:
                              'Strata keeps maintenance and sinking fund '
                              'charges against share units. Non-strata keeps '
                              'tenancies and rent. This decides which half of '
                              'the module the property uses.',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'strata',
                            child: Text('Strata — a scheme with share units'),
                          ),
                          DropdownMenuItem(
                            value: 'non_strata',
                            child: Text('Non-strata — let to tenants'),
                          ),
                        ],
                        onChanged: _saving
                            ? null
                            : (v) => setState(() => _tenure = v ?? 'strata'),
                      ),

                      _section('Where it is'),
                      AddressField(
                        controller: _ctl('address_line1'),
                        label: 'Address line 1',
                        enabled: !_saving,
                        country: ref.watch(orgCountryAlpha2Provider),
                        onChosen: (a) => fillAddressBoxes(
                          a,
                          states,
                          postcode: _ctl('postcode'),
                          city: _ctl('city'),
                          stateCode: _ctl('state_code'),
                        ),
                      ),
                      const SizedBox(height: Space.md),
                      TextFormField(
                        controller: _ctl('address_line2'),
                        decoration:
                            const InputDecoration(labelText: 'Address line 2'),
                      ),
                      const SizedBox(height: Space.md),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _ctl('postcode'),
                              decoration: const InputDecoration(
                                labelText: 'Postcode',
                              ),
                            ),
                          ),
                          const SizedBox(width: Space.md),
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              controller: _ctl('city'),
                              decoration:
                                  const InputDecoration(labelText: 'City'),
                            ),
                          ),
                          const SizedBox(width: Space.md),
                          Expanded(
                            child: TextFormField(
                              controller: _ctl('state_code'),
                              decoration: const InputDecoration(
                                labelText: 'State',
                                // LHDN's numeric state codes, which is
                                // what ref_states holds and what the
                                // foreign key checks — not the postal
                                // abbreviations. 10 is Selangor, 14 is
                                // Kuala Lumpur.
                                helperText: 'LHDN code, e.g. 10',
                              ),
                              keyboardType: TextInputType.number,
                            ),
                          ),
                        ],
                      ),

                      // The land office and local council references. Not
                      // decoration: quit rent is charged by the state and
                      // assessment by the council, both against these
                      // account numbers, and a managing agent chasing a
                      // bill has nowhere else to look them up.
                      _section('Land and local authority'),
                      TextFormField(
                        controller: _ctl('local_authority'),
                        decoration: const InputDecoration(
                          labelText: 'Local authority',
                          helperText: 'The council that levies assessment',
                        ),
                      ),
                      const SizedBox(height: Space.md),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _ctl('land_title_no'),
                              decoration: const InputDecoration(
                                labelText: 'Land title no.',
                              ),
                            ),
                          ),
                          const SizedBox(width: Space.md),
                          Expanded(
                            child: TextFormField(
                              controller: _ctl('lot_no'),
                              decoration:
                                  const InputDecoration(labelText: 'Lot no.'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.md),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _ctl('quit_rent_account_no'),
                              decoration: const InputDecoration(
                                labelText: 'Quit rent account no.',
                              ),
                            ),
                          ),
                          const SizedBox(width: Space.md),
                          Expanded(
                            child: TextFormField(
                              controller: _ctl('assessment_account_no'),
                              decoration: const InputDecoration(
                                labelText: 'Assessment account no.',
                              ),
                            ),
                          ),
                        ],
                      ),

                      _section('Anything else'),
                      TextFormField(
                        controller: _ctl('notes'),
                        decoration: const InputDecoration(labelText: 'Notes'),
                        maxLines: 3,
                      ),
                      const SizedBox(height: Space.md),
                      SwitchListTile(
                        value: _active,
                        onChanged: _saving
                            ? null
                            : (v) => setState(() => _active = v),
                        title: const Text('Active'),
                        subtitle: const Text(
                          'Inactive properties stay in the books and drop out '
                          'of the list.',
                        ),
                        contentPadding: EdgeInsets.zero,
                      ),
                      const SizedBox(height: Space.lg),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: Space.lg, bottom: Space.sm),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
}
