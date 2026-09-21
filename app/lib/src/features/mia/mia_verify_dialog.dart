import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/safe_link.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'mia_credential.dart';
import 'mia_service.dart';

/// Look somebody up on MIA's register and record what it said.
///
/// Returns true when something was saved.
Future<bool> showMiaVerifyDialog(
  BuildContext context, {
  required String subjectType,
  required String subjectId,
  required String subjectName,
  List<MiaKind> kinds = const [MiaKind.member, MiaKind.firm],
  MiaKind? initialKind,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => MiaVerifyDialog(
        subjectType: subjectType,
        subjectId: subjectId,
        subjectName: subjectName,
        kinds: kinds,
        initialKind: initialKind,
      ),
    ) ??
    false;

/// Public so a widget test can drive it without a route.
class MiaVerifyDialog extends ConsumerStatefulWidget {
  const MiaVerifyDialog({
    super.key,
    required this.subjectType,
    required this.subjectId,
    required this.subjectName,
    this.kinds = const [MiaKind.member, MiaKind.firm],
    this.initialKind,
  });

  final String subjectType;
  final String subjectId;
  final String subjectName;
  final List<MiaKind> kinds;
  final MiaKind? initialKind;

  @override
  ConsumerState<MiaVerifyDialog> createState() => MiaVerifyDialogState();
}

/// The fields a credential of this kind has, in the order the register
/// prints them, keyed by the column they are saved to.
///
/// Public, and a pure function of the kind, because the dialog's one
/// real rule lives here: a member row and a firm row do not share a
/// single field, so a dialog that showed both would offer twelve boxes
/// of which seven are always wrong.
Map<String, String> miaFieldLabels(MiaKind kind) => kind == MiaKind.member
    ? const {
        'member_no': 'Member no.',
        'member_name': 'Member’s name',
        'member_type': 'Member type',
        'state': 'State',
      }
    : const {
        'firm_no': 'Firm no.',
        'firm_name': 'Firm’s name',
        'address': 'Address',
        'state': 'State',
        'tel': 'Tel',
        'fax': 'Fax',
        'email': 'Email',
        'website': 'Website',
      };

/// Why this cannot be saved yet, in the words to show — or null.
///
/// The number is the credential. A row with a name and no number is a
/// note, and saving it would put a green "checked on" stamp beside
/// nothing that can be looked up again.
String? miaSaveProblem({
  required MiaKind kind,
  required Map<String, String> values,
}) {
  final key = kind == MiaKind.member ? 'member_no' : 'firm_no';
  if ((values[key] ?? '').trim().isEmpty) {
    return kind == MiaKind.member
        ? 'A member number is what the register is searched by. Fill it in.'
        : 'A firm number is what the register is searched by. Fill it in.';
  }
  return null;
}

class MiaVerifyDialogState extends ConsumerState<MiaVerifyDialog> {
  final _paste = TextEditingController();
  final Map<String, TextEditingController> _fields = {};

  late MiaKind _kind =
      widget.initialKind ?? widget.kinds.first;

  /// Null until the register says, and a tri-state on purpose: "the row
  /// did not have that column" is not "no".
  bool? _pcHolder;
  String? _firmType;

  /// What was pasted, kept exactly. The parser only prefills; this is
  /// what an audit is shown.
  String _raw = '';

  /// Set once a paste has been read, so the form can say it did
  /// something rather than silently filling boxes.
  String? _parseNote;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final key in _allKeys) {
      _fields[key] = TextEditingController();
    }
  }

  static const _allKeys = [
    'member_no',
    'member_name',
    'member_type',
    'firm_no',
    'firm_name',
    'address',
    'tel',
    'fax',
    'email',
    'website',
    'state',
  ];

  @override
  void dispose() {
    _paste.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _openRegister() async {
    final ok = await launchExternal(miaSearchUrl);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open MIA’s search.')),
      );
    }
  }

  void _read() {
    final text = _paste.text;
    final row = ref.read(miaServiceProvider).parsePaste(text);
    if (row == null) {
      setState(() {
        _parseNote = 'That does not look like a row from the register. '
            'Copy the whole row, or fill the boxes in by hand.';
      });
      return;
    }

    setState(() {
      _kind = widget.kinds.contains(row.kind) ? row.kind : _kind;
      _raw = row.raw;
      for (final key in _allKeys) {
        final v = row[key];
        if (v != null) _fields[key]!.text = v;
      }
      final pc = row['pc_holder'];
      if (pc != null) _pcHolder = pc == 'true';
      _parseNote = 'Read as a ${row.kind == MiaKind.firm ? 'firm' : 'member'}. '
          'Check it, then save.';
    });
  }

  Map<String, String> get _values => {
        for (final e in _fields.entries) e.key: e.value.text,
      };

  Future<void> _save() async {
    final problem = miaSaveProblem(kind: _kind, values: _values);
    if (problem != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problem)));
      return;
    }

    setState(() => _saving = true);
    final fields = <String, String?>{
      for (final key in miaFieldLabels(_kind).keys) key: _fields[key]!.text,
      if (_kind == MiaKind.member && _pcHolder != null)
        'pc_holder': '$_pcHolder',
      if (_kind == MiaKind.firm && _firmType != null) 'firm_type': _firmType,
    };

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(miaServiceProvider).save(
            subjectType: widget.subjectType,
            subjectId: widget.subjectId,
            kind: _kind,
            fields: fields,
            // What was pasted, or what was typed if nothing was. Either
            // way the row records where it came from.
            rawText: _raw.isEmpty ? 'Entered by hand' : _raw,
          ),
      successMessage: 'Recorded',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(miaServiceProvider);
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: context.scheme.onSurfaceVariant,
        );

    return AlertDialog(
      title: Text('Check ${widget.subjectName} on MIA'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // There is no live search and the seam says so rather
              // than the screen assuming. `canSearch` is false for the
              // only provider that exists; when one that can search
              // arrives this branch is where its box goes.
              if (!service.canSearch)
                Text(
                  'MIA publishes no API, so this cannot search for you. '
                  'Open the register, find the row, and copy it.',
                  style: muted,
                ),
              const SizedBox(height: Space.md),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const ValueKey('mia-open-register'),
                  onPressed: _saving ? null : _openRegister,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Open MIA search'),
                ),
              ),
              const SizedBox(height: Space.lg),
              TextField(
                key: const ValueKey('mia-paste'),
                controller: _paste,
                enabled: !_saving,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Paste the row',
                  hintText: 'Select the matching row on MIA and paste it here',
                ),
              ),
              const SizedBox(height: Space.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('mia-read'),
                  onPressed: _saving ? null : _read,
                  child: const Text('Read it'),
                ),
              ),
              if (_parseNote != null)
                Text(
                  _parseNote!,
                  key: const ValueKey('mia-parse-note'),
                  style: muted,
                ),
              const Divider(height: Space.xl),
              if (widget.kinds.length > 1)
                SegmentedButton<MiaKind>(
                  key: const ValueKey('mia-kind'),
                  segments: const [
                    ButtonSegment(value: MiaKind.member, label: Text('Member')),
                    ButtonSegment(value: MiaKind.firm, label: Text('Firm')),
                  ],
                  selected: {_kind},
                  onSelectionChanged: _saving
                      ? null
                      : (s) => setState(() => _kind = s.first),
                ),
              const SizedBox(height: Space.md),
              for (final e in miaFieldLabels(_kind).entries) ...[
                TextField(
                  key: ValueKey('mia-field-${e.key}'),
                  controller: _fields[e.key],
                  enabled: !_saving,
                  decoration: InputDecoration(labelText: e.value),
                ),
                const SizedBox(height: Space.sm),
              ],
              if (_kind == MiaKind.member)
                DropdownButtonFormField<bool?>(
                  key: const ValueKey('mia-pc-holder'),
                  initialValue: _pcHolder,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Practising certificate',
                  ),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('Not recorded')),
                    DropdownMenuItem(value: true, child: Text('Yes')),
                    DropdownMenuItem(value: false, child: Text('No')),
                  ],
                  onChanged:
                      _saving ? null : (v) => setState(() => _pcHolder = v),
                )
              else
                DropdownButtonFormField<String?>(
                  key: const ValueKey('mia-firm-type'),
                  initialValue: _firmType,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Type of firm'),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('Not recorded')),
                    DropdownMenuItem(value: 'A', child: Text('Audit')),
                    DropdownMenuItem(value: 'NA', child: Text('Non-audit')),
                  ],
                  onChanged:
                      _saving ? null : (v) => setState(() => _firmType = v),
                ),
              const SizedBox(height: Space.md),
              Text(miaCredentialCaveat, style: muted),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('mia-save'),
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
