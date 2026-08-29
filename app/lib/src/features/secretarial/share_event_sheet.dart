import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/corp_repository.dart';
import 'person_editor.dart';
import 'share_class_sheet.dart';

/// The five ways shares move, in the words the paperwork uses.
///
/// `app.corp_share_event` is the authority on which exist. These are
/// what a secretary calls them and what each one needs, which is not
/// the same for any two of them.
const Map<String, String> shareEventNames = {
  'allotment': 'Allotment',
  'transfer': 'Transfer',
  'transmission': 'Transmission',
  'cancellation': 'Cancellation',
  'conversion': 'Conversion',
};

/// What each movement is, in one line, on the sheet.
const Map<String, String> shareEventNotes = {
  'allotment': 'New shares issued. s.78 return within fourteen days.',
  'transfer': 'Shares move between holders. Form 32A, and stamping.',
  'transmission': 'On death or bankruptcy — no instrument of transfer.',
  'cancellation': 'Buy-back or reduction. The issued capital falls.',
  'conversion': 'Between classes, by the terms the shares were issued on.',
};

/// Whether the movement has a transferor.
///
/// `corp_share_events_parties_ck` decides this, not the screen: an
/// allotment has no transferor because the shares did not exist before
/// it, and a cancellation has no transferee because they do not exist
/// after. Asking for the wrong party is a form that collects an answer
/// the database will refuse.
bool eventHasFrom(String type) => type != 'allotment';

/// Whether the movement has a transferee.
bool eventHasTo(String type) => type != 'cancellation';

/// The consideration for the whole movement.
///
/// A price per share and a quantity give a total, and the total is what
/// the s.78 return reports. Computing it here rather than asking twice
/// means the two cannot disagree — and they would, because somebody
/// changing the quantity does not think to revisit a total they typed
/// five fields ago.
///
/// Null when there is no price: shares issued for a consideration other
/// than cash have one under s.78(2), and it is a sentence rather than a
/// number.
double? considerationFor(double? pricePerShare, double quantity) {
  if (pricePerShare == null) return null;
  return double.parse((pricePerShare * quantity).toStringAsFixed(2));
}

/// What a share movement is, given what was entered.
///
/// Pure, and apart from the sheet, because the party rules are a CHECK
/// constraint: send the wrong shape and the insert is refused with a
/// message about a constraint, which is a true thing to say and no help
/// at all to the person who typed it.
Map<String, dynamic> shareEventValues({
  required String entityId,
  required String shareClassId,
  required String eventType,
  required DateTime eventDate,
  required double quantity,
  String? fromPersonId,
  String? toPersonId,
  double? pricePerShare,
  bool isCash = true,
  String? considerationNote,
  String? certificateNo,
  String? instrumentRef,
  double? stampDuty,
  String? stampCertificateNo,
  String? notes,
}) {
  String? trimmed(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();

  final wantsFrom = eventHasFrom(eventType);
  final wantsTo = eventHasTo(eventType);

  return <String, dynamic>{
    'entity_id': entityId,
    'share_class_id': shareClassId,
    'event_type': eventType,
    'event_date': Fmt.iso(eventDate),
    'quantity': quantity,
    'from_person_id': wantsFrom ? fromPersonId : null,
    'to_person_id': wantsTo ? toPersonId : null,
    'consideration_per_share': pricePerShare,
    'total_consideration': considerationFor(pricePerShare, quantity),
    'is_cash': isCash,
    // s.78(2) wants to know what the consideration was when it was not
    // cash, and only then.
    'consideration_note': isCash ? null : trimmed(considerationNote),
    'certificate_no': trimmed(certificateNo),
    // Form 32A belongs to a transfer. A number carried over from one
    // onto an allotment is an instrument that does not exist.
    'instrument_ref': eventType == 'transfer' ? trimmed(instrumentRef) : null,
    'stamp_duty': eventType == 'transfer' ? stampDuty : null,
    'stamp_certificate_no':
        eventType == 'transfer' ? trimmed(stampCertificateNo) : null,
    'notes': trimmed(notes),
  };
}

/// Record a movement in the shares.
Future<bool> showShareEventSheet(
  BuildContext context, {
  required String entityId,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _ShareEventSheet(entityId: entityId),
    ) ??
    false;

class _ShareEventSheet extends ConsumerStatefulWidget {
  const _ShareEventSheet({required this.entityId});

  final String entityId;

  @override
  ConsumerState<_ShareEventSheet> createState() => _ShareEventSheetState();
}

class _ShareEventSheetState extends ConsumerState<_ShareEventSheet> {
  final _formKey = GlobalKey<FormState>();
  final _quantity = TextEditingController();
  final _price = TextEditingController();
  final _considerationNote = TextEditingController();
  final _certificate = TextEditingController();
  final _instrument = TextEditingController();
  final _stampDuty = TextEditingController();
  final _stampCertificate = TextEditingController();
  final _notes = TextEditingController();

  String _type = 'allotment';
  String? _classId;
  String? _fromId;
  String? _toId;
  bool _isCash = true;
  DateTime _date = DateTime.now();
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [
      _quantity,
      _price,
      _considerationNote,
      _certificate,
      _instrument,
      _stampDuty,
      _stampCertificate,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double? get _qty => double.tryParse(_quantity.text.trim());
  double? get _pricePerShare =>
      _price.text.trim().isEmpty ? null : double.tryParse(_price.text.trim());

  Future<void> _addPerson(void Function(String) assign) async {
    final id = await showPersonEditor(context);
    if (id != null && mounted) setState(() => assign(id));
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final qty = _qty;
    if (_classId == null || qty == null) return;

    setState(() => _saving = true);
    final values = shareEventValues(
      entityId: widget.entityId,
      shareClassId: _classId!,
      eventType: _type,
      eventDate: _date,
      quantity: qty,
      fromPersonId: _fromId,
      toPersonId: _toId,
      pricePerShare: _pricePerShare,
      isCash: _isCash,
      considerationNote: _considerationNote.text,
      certificateNo: _certificate.text,
      instrumentRef: _instrument.text,
      stampDuty: double.tryParse(_stampDuty.text.trim()),
      stampCertificateNo: _stampCertificate.text,
      notes: _notes.text,
    );

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.addCorpShareEvent(values),
      successMessage: 'Recorded',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(corpMembersProvider(widget.entityId));
      ref.invalidate(corpShareEventsProvider(widget.entityId));
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final classes =
        ref.watch(corpShareClassesProvider(widget.entityId)).valueOrNull ??
            const [];
    final people = ref.watch(corpPersonsProvider).valueOrNull ?? const [];
    _classId ??= classes.isEmpty ? null : classes.first['id'] as String?;

    final total = considerationFor(_pricePerShare, _qty ?? 0);

    Widget personField({
      required String label,
      required String? value,
      required ValueChanged<String?> onChanged,
      required void Function(String) assign,
    }) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              value: value,
              isExpanded: true,
              decoration: InputDecoration(labelText: label),
              items: [
                for (final p in people)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text(
                      p.identifier == null
                          ? p.fullName
                          : '${p.fullName} (${p.identifier})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _saving ? null : onChanged,
              validator: (v) => v == null ? 'Required' : null,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _saving ? null : () => _addPerson(assign),
                icon: const Icon(Icons.person_add_outlined, size: 16),
                label: const Text('Somebody not on the file'),
              ),
            ),
          ],
        );

    return AlertDialog(
      title: const Text('Record a share movement'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (classes.isEmpty)
                  // Every movement points at a class, so a company with
                  // none cannot record anything. Said here, with the way
                  // out attached, rather than leaving an empty dropdown
                  // that looks broken and sending the secretary hunting
                  // for the screen that fixes it.
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'This company has no class of shares yet. Every '
                          'movement points at one, so there is nothing to '
                          'record against until it has.',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: context.colors.warning),
                        ),
                        TextButton.icon(
                          key: const ValueKey('add-share-class'),
                          onPressed: _saving
                              ? null
                              : () => showShareClassSheet(
                                    context,
                                    entityId: widget.entityId,
                                  ),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add a class of shares'),
                        ),
                      ],
                    ),
                  ),
                DropdownButtonFormField<String>(
                  key: const ValueKey('share-event-type'),
                  value: _type,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'What happened'),
                  items: [
                    for (final e in shareEventNames.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: _saving
                      ? null
                      : (v) => setState(() {
                            _type = v ?? 'allotment';
                            // The parties the new kind does not have are
                            // cleared, so a transfer turned into an
                            // allotment cannot carry its transferor into
                            // a constraint violation.
                            if (!eventHasFrom(_type)) _fromId = null;
                            if (!eventHasTo(_type)) _toId = null;
                          }),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: Space.xs),
                  child: Text(
                    shareEventNotes[_type] ?? '',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: context.scheme.onSurfaceVariant),
                  ),
                ),

                const SizedBox(height: Space.md),
                DropdownButtonFormField<String>(
                  value: _classId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Class'),
                  items: [
                    for (final c in classes)
                      DropdownMenuItem(
                        value: c['id'] as String,
                        child: Text(
                            '${c['name'] ?? ''} (${c['code'] ?? ''})'),
                      ),
                  ],
                  onChanged:
                      _saving ? null : (v) => setState(() => _classId = v),
                  validator: (v) => v == null ? 'Choose a class' : null,
                ),

                const SizedBox(height: Space.md),
                if (eventHasFrom(_type))
                  personField(
                    label: _type == 'transmission' ? 'From (deceased)' : 'From',
                    value: _fromId,
                    onChanged: (v) => setState(() => _fromId = v),
                    assign: (id) => _fromId = id,
                  ),
                if (eventHasTo(_type))
                  personField(
                    label: 'To',
                    value: _toId,
                    onChanged: (v) => setState(() => _toId = v),
                    assign: (id) => _toId = id,
                  ),

                Row(children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('share-quantity'),
                      controller: _quantity,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      onChanged: (_) => setState(() {}),
                      decoration:
                          const InputDecoration(labelText: 'How many shares'),
                      validator: (v) {
                        final n = double.tryParse((v ?? '').trim());
                        if (n == null) return 'A number';
                        if (n <= 0) return 'More than none';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: StatutoryDateField(
                      label: 'On',
                      value: _date,
                      enabled: !_saving,
                      lastDate: DateTime.now(),
                      onChanged: (d) =>
                          setState(() => _date = d ?? DateTime.now()),
                    ),
                  ),
                ]),

                const Divider(height: Space.xl),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _isCash,
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _isCash = v),
                  title: const Text('For cash'),
                  subtitle: const Text(
                    'Shares issued otherwise than for cash must say what the '
                    'consideration was (s.78(2))',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                if (_isCash) ...[
                  TextFormField(
                    controller: _price,
                    enabled: !_saving,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Price per share',
                      helperText: 'Leave empty if there was no price',
                    ),
                  ),
                  if (total != null)
                    Padding(
                      padding: const EdgeInsets.only(top: Space.xs),
                      child: Text(
                        'Total consideration ${Fmt.money(total)} — what the '
                        's.78 return reports.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: context.scheme.onSurfaceVariant),
                      ),
                    ),
                ] else
                  TextFormField(
                    controller: _considerationNote,
                    enabled: !_saving,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'What the consideration was',
                      alignLabelWithHint: true,
                      hintText: 'Land transferred, debt capitalised, services',
                    ),
                  ),

                const Divider(height: Space.xl),
                TextFormField(
                  controller: _certificate,
                  enabled: !_saving,
                  decoration:
                      const InputDecoration(labelText: 'Certificate no.'),
                ),
                if (_type == 'transfer') ...[
                  const SizedBox(height: Space.md),
                  TextFormField(
                    controller: _instrument,
                    enabled: !_saving,
                    decoration: const InputDecoration(
                      labelText: 'Instrument',
                      hintText: 'Form 32A reference',
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _stampDuty,
                        enabled: !_saving,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration:
                            const InputDecoration(labelText: 'Stamp duty'),
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: TextFormField(
                        controller: _stampCertificate,
                        enabled: !_saving,
                        decoration: const InputDecoration(
                            labelText: 'Stamp certificate'),
                      ),
                    ),
                  ]),
                ],
                const SizedBox(height: Space.md),
                TextFormField(
                  controller: _notes,
                  enabled: !_saving,
                  decoration: const InputDecoration(labelText: 'Notes'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('share-event-save'),
          onPressed: _saving || classes.isEmpty ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Record'),
        ),
      ],
    );
  }
}
