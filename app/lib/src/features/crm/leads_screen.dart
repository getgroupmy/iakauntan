import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/quick_add_dialog.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'deal_outcome.dart';

/// The top of the funnel.
///
/// `leads` has had a table and RLS since the CRM landed and no screen at
/// all, so the pipeline began at the opportunity — which is to say it
/// began after somebody had already decided the enquiry was real. Every
/// enquiry before that point lived in an inbox.
class LeadsScreen extends ConsumerStatefulWidget {
  const LeadsScreen({super.key});

  @override
  ConsumerState<LeadsScreen> createState() => _LeadsScreenState();
}

class _LeadsScreenState extends ConsumerState<LeadsScreen> {
  String _status = 'open';

  static const _filters = <String, String>{
    'open': 'Open',
    'new': 'New',
    'contacted': 'Contacted',
    'qualified': 'Qualified',
    'converted': 'Converted',
    'lost': 'Lost',
    'all': 'All',
  };

  @override
  Widget build(BuildContext context) {
    final leads = ref.watch(leadsProvider(_status));
    final canWrite = ref.watch(canWriteProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Leads'),
        actions: [
          if (canWrite)
            Padding(
              padding: const EdgeInsets.only(right: Space.md),
              child: FilledButton.icon(
                onPressed: () => _edit(null),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New lead'),
              ),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: FilterBar(
            child: SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final e in _filters.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: Space.sm),
                      child: FilterChip(
                        label: Text(e.value),
                        selected: _status == e.key,
                        onSelected: (_) => setState(() => _status = e.key),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: AsyncView(
        value: leads,
        onRetry: () => ref.invalidate(leadsProvider(_status)),
        builder: (list) => list.isEmpty
            ? EmptyState(
                icon: Icons.filter_alt_outlined,
                title: 'No leads here',
                message: 'An enquiry becomes a lead, a lead becomes a '
                    'customer and an opportunity. This is where the first '
                    'step lives.',
                action: canWrite
                    ? FilledButton.icon(
                        onPressed: () => _edit(null),
                        icon: const Icon(Icons.add),
                        label: const Text('Add lead'),
                      )
                    : null,
              )
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _LeadTile(
                  lead: list[i],
                  canWrite: canWrite,
                  onEdit: () => _edit(list[i]),
                  onConvert: () => _convert(list[i]),
                  onLose: () => _lose(list[i]),
                  onReopen: () => _reopen(list[i]),
                ),
              ),
      ),
    );
  }

  Future<void> _edit(Map<String, dynamic>? lead) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _LeadDialog(lead: lead),
    );
    if (saved == true) ref.invalidate(leadsProvider(_status));
  }

  /// Losing a lead, with the reason asked for at the moment it is known.
  ///
  /// A list of dead leads with no reasons on it is a list nobody reads
  /// twice, and `leads.lost_reason` had been a column since `0008` with
  /// nothing to write it.
  Future<void> _lose(Map<String, dynamic> lead) async {
    final reason = await promptForText(
      context,
      title: 'Why did it come to nothing?',
      label: 'Reason',
      confirmLabel: 'Mark as lost',
      // The same list a deal is closed with, so the two halves of the
      // funnel can be read together rather than in two vocabularies.
      suggestions: lostReasons,
    );
    if (reason == null || reason.trim().isEmpty || !mounted) return;
    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.closeLead(lead['id'] as String, reason),
      successMessage: 'Marked as lost',
    );
    if (ok) ref.invalidate(leadsProvider(_status));
  }

  Future<void> _reopen(Map<String, dynamic> lead) async {
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.reopenLead(lead['id'] as String),
      successMessage: 'Back on the list',
    );
    if (ok) ref.invalidate(leadsProvider(_status));
  }

  Future<void> _convert(Map<String, dynamic> lead) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _ConvertDialog(lead: lead),
    );
    if (done == true) {
      ref.invalidate(leadsProvider(_status));
      ref.invalidate(contactsProvider);
      ref.invalidate(opportunitiesProvider);
    }
  }
}

class _LeadTile extends StatelessWidget {
  const _LeadTile({
    required this.lead,
    required this.canWrite,
    required this.onLose,
    required this.onReopen,
    required this.onEdit,
    required this.onConvert,
  });

  final Map<String, dynamic> lead;
  final bool canWrite;
  final VoidCallback onEdit;
  final VoidCallback onConvert;
  final VoidCallback onLose;
  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) {
    final status = lead['status']?.toString() ?? 'new';
    final person = [lead['first_name'], lead['last_name']]
        .whereType<String>()
        .join(' ')
        .trim();
    final name = (lead['company_name'] as String?)?.trim().isNotEmpty == true
        ? lead['company_name'].toString()
        : (person.isEmpty ? lead['lead_no'].toString() : person);
    final converted = lead['converted_contact_id'] != null;
    final value = Fmt.toDouble(lead['estimated_value']);

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xs),
      onTap: canWrite ? onEdit : null,
      title: Row(children: [
        Flexible(
          child: Text(name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: Space.sm),
        StatusChip(status, compact: true),
      ]),
      subtitle: Text(
        [
          lead['lead_no'],
          if (person.isNotEmpty && lead['company_name'] != null) person,
          if (lead['source'] != null) 'via ${lead['source']}',
          if (converted) 'now ${(lead['contacts'] as Map?)?['name'] ?? 'a customer'}',
        ].whereType<Object>().join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (value > 0) Money(value, bold: true),
        // Converting is what a lead is for. A converted one has nowhere
        // left to go, and a lost one has to be reopened first — the
        // database refuses both, so the button should not offer them.
        if (canWrite && !converted && status != 'lost') ...[
          const SizedBox(width: Space.sm),
          FilledButton.tonal(
            onPressed: onConvert,
            child: const Text('Convert'),
          ),
          IconButton(
            key: const ValueKey('lose-lead'),
            tooltip: 'It came to nothing',
            icon: const Icon(Icons.do_not_disturb_on_outlined, size: 18),
            onPressed: onLose,
          ),
        ],
        // And back, because `convert_lead` has said "reopen it first"
        // since `0093` about a state nothing could leave.
        if (canWrite && status == 'lost') ...[
          const SizedBox(width: Space.sm),
          TextButton(
            key: const ValueKey('reopen-lead'),
            onPressed: onReopen,
            child: const Text('Reopen'),
          ),
        ],
      ]),
    );
  }
}

class _LeadDialog extends ConsumerStatefulWidget {
  const _LeadDialog({this.lead});

  final Map<String, dynamic>? lead;

  @override
  ConsumerState<_LeadDialog> createState() => _LeadDialogState();
}

class _LeadDialogState extends ConsumerState<_LeadDialog> {
  final _c = <String, TextEditingController>{};
  late String _status = widget.lead?['status']?.toString() ?? 'new';
  bool _saving = false;

  static const _fields = <(String, String)>[
    ('company_name', 'Company'),
    ('first_name', 'First name'),
    ('last_name', 'Last name'),
    ('designation', 'Designation'),
    ('email', 'Email'),
    ('phone', 'Phone'),
    ('mobile', 'Mobile'),
    ('source', 'Where they came from'),
    ('industry', 'Industry'),
    ('estimated_value', 'Estimated value (RM)'),
    ('notes', 'Notes'),
  ];

  @override
  void initState() {
    super.initState();
    for (final (key, _) in _fields) {
      _c[key] = TextEditingController(text: widget.lead?[key]?.toString() ?? '');
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.lead == null ? 'New lead' : 'Edit lead'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A lead may be a company, a person, or a person at a
              // company; it needs one of the two names and the database
              // refuses conversion without either.
              Text(
                'A lead needs either a company or a person. Both is better.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              for (final (key, label) in _fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.md),
                  child: TextField(
                    controller: _c[key],
                    autofocus: key == 'company_name',
                    maxLines: key == 'notes' ? 3 : 1,
                    keyboardType: key == 'estimated_value'
                        ? const TextInputType.numberWithOptions(decimal: true)
                        : key == 'email'
                            ? TextInputType.emailAddress
                            : TextInputType.text,
                    decoration: InputDecoration(labelText: label),
                  ),
                ),
              DropdownButtonFormField<String>(
                value: _status,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Status'),
                items: const [
                  DropdownMenuItem(value: 'new', child: Text('New')),
                  DropdownMenuItem(
                      value: 'contacted', child: Text('Contacted')),
                  DropdownMenuItem(
                      value: 'qualified', child: Text('Qualified')),
                  DropdownMenuItem(
                      value: 'unqualified', child: Text('Unqualified')),
                  // `lost` is not offered here. Setting it from a
                  // dropdown left `leads.lost_reason` empty for every
                  // lead a company ever gave up on — see `0373`. Losing
                  // one is done from the list, where the reason can be
                  // asked for with it.
                ],
                onChanged: (v) => setState(() => _status = v ?? 'new'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final company = _c['company_name']!.text.trim();
    final person = [_c['first_name']!.text, _c['last_name']!.text]
        .join(' ')
        .trim();
    if (company.isEmpty && person.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Give the lead a company or a person'),
      ));
      return;
    }
    setState(() => _saving = true);

    final values = <String, dynamic>{
      'status': _status,
      for (final (key, _) in _fields)
        key: key == 'estimated_value'
            ? (double.tryParse(_c[key]!.text.trim()) ?? 0)
            : (_c[key]!.text.trim().isEmpty ? null : _c[key]!.text.trim()),
    };

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveLead(values, id: widget.lead?['id'] as String?),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}

class _ConvertDialog extends ConsumerStatefulWidget {
  const _ConvertDialog({required this.lead});

  final Map<String, dynamic> lead;

  @override
  ConsumerState<_ConvertDialog> createState() => _ConvertDialogState();
}

class _ConvertDialogState extends ConsumerState<_ConvertDialog> {
  late final _amount = TextEditingController(
      text: Fmt.toDouble(widget.lead['estimated_value']).toStringAsFixed(2));
  bool _opportunity = true;
  String? _pipelineId;
  DateTime? _close;
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pipelines = ref.watch(pipelinesProvider).valueOrNull ?? const [];
    if (_pipelineId == null && pipelines.isNotEmpty) {
      _pipelineId = pipelines.first['id'] as String;
    }

    return AlertDialog(
      title: const Text('Convert lead'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The lead is kept, not consumed. It is how "where did
              // this customer come from" gets answered a year later.
              Text(
                'A customer is created from this lead, and the named person '
                'becomes their main contact. The lead itself is kept and '
                'marked converted.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _opportunity && pipelines.isNotEmpty,
                onChanged: pipelines.isEmpty
                    ? null
                    : (v) => setState(() => _opportunity = v),
                title: const Text('Open an opportunity too'),
                subtitle: Text(pipelines.isEmpty
                    ? 'No pipeline has been set up to open one in'
                    : 'Starts in the first open stage of the pipeline'),
              ),
              if (_opportunity && pipelines.isNotEmpty) ...[
                SearchablePicker<String>(
                  options: [
                    for (final p in pipelines)
                      PickerOption<String>(
                        value: p['id'] as String,
                        label: p['name']?.toString() ?? '',
                      ),
                  ],
                  value: _pipelineId,
                  label: 'Pipeline',
                  createLabel: 'Add pipeline',
                  onCreate: (typed) => quickAdd(
                    context,
                    title: 'New pipeline',
                    // No code box: `pipelines` has no code column, and
                    // asking for one would teach a rule that is not
                    // there.
                    blurb: 'Not on the list yet. Its stages are set up '
                        'on the Pipeline screen afterwards.',
                    nameHint: 'Enterprise sales',
                    seed: typed,
                    save: ({required name, code}) async {
                      final id = await ref.read(repoProvider)!.createQuickRow(
                            QuickAddList.pipeline,
                            name: name,
                          );
                      ref.invalidate(pipelinesProvider);
                      return id;
                    },
                  ),
                  onChanged: (v) => setState(() => _pipelineId = v),
                ),
                const SizedBox(height: Space.md),
                TextField(
                  controller: _amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Opportunity value', prefixText: 'RM '),
                ),
                const SizedBox(height: Space.md),
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate:
                          _close ?? DateTime.now().add(const Duration(days: 30)),
                      firstDate: DateTime(DateTime.now().year - 1),
                      lastDate: DateTime(DateTime.now().year + 5),
                      helpText: 'Expected to close',
                    );
                    if (picked != null) setState(() => _close = picked);
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Expected close',
                      suffixIcon: Icon(Icons.calendar_today, size: 18),
                    ),
                    child: Text(_close == null ? 'Not set' : Fmt.date(_close)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _convert,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Convert'),
        ),
      ],
    );
  }

  Future<void> _convert() async {
    setState(() => _saving = true);
    final wantOpportunity =
        _opportunity && (ref.read(pipelinesProvider).valueOrNull ?? []).isNotEmpty;

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.convertLead(
            widget.lead['id'] as String,
            createOpportunity: wantOpportunity,
            pipelineId: wantOpportunity ? _pipelineId : null,
            amount: double.tryParse(_amount.text.trim()),
            expectedClose: _close,
          ),
      successMessage: wantOpportunity
          ? 'Converted — customer and opportunity created'
          : 'Converted to a customer',
      pendingMessage: 'Converting…',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}
