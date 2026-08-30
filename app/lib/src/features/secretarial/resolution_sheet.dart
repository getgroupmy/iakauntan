import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/corp_repository.dart';
import 'person_editor.dart' show StatutoryDateField;

/// What a company resolved, and how.
///
/// `corp_resolutions` has been in `0062` since the corporate
/// secretarial module was built, with three other tables pointing at
/// it — `corp_filings`, `corp_share_events` and `corp_documents` each
/// carry a `resolution_id` — and nothing in the app could read or write
/// one. So an allotment could never name the board resolution that
/// authorised it, and a company's minute book lived somewhere else.

/// The four kinds `app.corp_resolution_kind` has, and no others.
const Map<String, String> kResolutionKinds = {
  'board': 'Directors',
  'members_ordinary': 'Members — ordinary',
  'members_special': 'Members — special',
  'written': 'Written, circulated',
};

String resolutionKindName(String? kind) =>
    kResolutionKinds[kind] ?? kind ?? '';

/// What share of the votes cast a kind of resolution needs.
///
/// A special resolution is three quarters under s.292(1) of the
/// Companies Act 2016; everything else is a simple majority. Board
/// resolutions are here as a majority because that is what the model
/// constitution provides, and a company whose own constitution says
/// otherwise is not something this screen can know.
double majorityNeeded(String kind) => kind == 'members_special' ? 0.75 : 0.5;

/// How many votes were cast.
///
/// Abstentions are not votes. A member who abstains is present and
/// counted for the quorum and is not counted in the majority — adding
/// them to the denominator is how a resolution that carried is
/// recorded as having failed.
int? votesCast(int? inFavour, int? against) {
  if (inFavour == null && against == null) return null;
  return (inFavour ?? 0) + (against ?? 0);
}

/// Whether it carried.
///
/// Null when nobody recorded the numbers — a resolution minuted
/// without a count is perfectly ordinary, and saying "it failed"
/// because the fields are empty would be inventing a fact.
bool? resolutionCarried({
  required String kind,
  int? inFavour,
  int? against,
}) {
  final cast = votesCast(inFavour, against);
  if (cast == null || cast == 0) return null;
  return (inFavour ?? 0) / cast >= majorityNeeded(kind);
}

/// Whether the votes recorded can have come from the people recorded.
///
/// For, against and abstained together cannot exceed those present.
/// Nothing in the database checks it — `present_person_ids` is an
/// array and the three counts are plain integers — and a minute that
/// says nine voted out of seven present is a minute somebody will have
/// to explain.
bool votesFitThePresent({
  required int present,
  int? inFavour,
  int? against,
  int? abstained,
}) {
  if (present <= 0) return true;
  return (inFavour ?? 0) + (against ?? 0) + (abstained ?? 0) <= present;
}

/// A written resolution is one that was circulated, not one passed at
/// a meeting. `meeting_held` is the column that says which.
bool wasCirculated(String kind, bool meetingHeld) =>
    kind == 'written' || !meetingHeld;

/// Why a resolution cannot be saved.
///
/// `title` is the only `not null` column with nothing to default to.
/// The rest are refusals this screen makes on its own, because the
/// table would take them and a minute book that contradicts itself is
/// worse than one with a gap in it.
String? resolutionBlockedBecause({
  required String title,
  required String kind,
  required bool meetingHeld,
  DateTime? passedOn,
  DateTime? effectiveOn,
  bool isSigned = false,
  DateTime? signedOn,
  int present = 0,
  int? inFavour,
  int? against,
  int? abstained,
}) {
  if (title.trim().isEmpty) return 'A resolution needs to say what it is.';
  if (kind == 'written' && meetingHeld) {
    return 'A written resolution is circulated under s.297 rather than '
        'passed at a meeting.';
  }
  if (effectiveOn != null && passedOn != null && effectiveOn.isBefore(passedOn)) {
    return 'It cannot take effect before it was passed.';
  }
  if (isSigned && signedOn == null) return 'Say when it was signed.';
  if (!votesFitThePresent(
    present: present,
    inFavour: inFavour,
    against: against,
    abstained: abstained,
  )) {
    return 'More votes than people present.';
  }
  return null;
}

/// What removing one takes with it.
///
/// A resolution once passed is a matter of record and this is not an
/// undo — it is for one typed by mistake. `corp_documents`,
/// `corp_filings` and `corp_share_events` all reference it `on delete
/// set null`, so anything generated from it stays and quietly stops
/// naming what authorised it. That is worth saying before it happens.
String resolutionDeletionWarning(Map<String, dynamic> row) {
  final signed = row['is_signed'] == true;
  return signed
      ? 'This one has been signed. Anything generated from it stays, and '
            'stops naming the resolution that authorised it.'
      : 'Anything generated from it stays, and stops naming the '
            'resolution that authorised it.';
}

/// What a resolution's row says under its title.
String resolutionLine(Map<String, dynamic> row) {
  final parts = <String>[resolutionKindName(row['kind'] as String?)];
  final passed = Fmt.parseDate(row['passed_on']);
  parts.add(passed == null ? 'not yet passed' : Fmt.date(passed));
  final carried = resolutionCarried(
    kind: '${row['kind']}',
    inFavour: row['in_favour'] as int?,
    against: row['against'] as int?,
  );
  if (carried != null) parts.add(carried ? 'carried' : 'not carried');
  if (row['is_signed'] == true) parts.add('signed');
  return parts.join(' · ');
}

/// The values a resolution is, given what was entered.
Map<String, dynamic> resolutionValues({
  required String entityId,
  required String title,
  required String kind,
  required bool meetingHeld,
  String? reference,
  String? body,
  DateTime? passedOn,
  DateTime? effectiveOn,
  String? venue,
  String? chairmanId,
  List<String> present = const [],
  int? inFavour,
  int? against,
  int? abstained,
  bool isSigned = false,
  DateTime? signedOn,
}) {
  String? trimmed(String? v) {
    final t = v?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  final circulated = wasCirculated(kind, meetingHeld);
  return <String, dynamic>{
    'entity_id': entityId,
    'title': title.trim(),
    'kind': kind,
    'reference': trimmed(reference),
    'body': trimmed(body),
    'passed_on': passedOn == null ? null : Fmt.iso(passedOn),
    'effective_on': effectiveOn == null ? null : Fmt.iso(effectiveOn),
    'meeting_held': !circulated,
    // A resolution circulated on paper has no venue, and one carried
    // over from an earlier edit would say a meeting happened that did
    // not.
    'meeting_venue': circulated ? null : trimmed(venue),
    'chairman_person_id': circulated ? null : chairmanId,
    'present_person_ids': circulated || present.isEmpty ? null : present,
    'in_favour': inFavour,
    'against': against,
    'abstained': abstained,
    'is_signed': isSigned,
    'signed_on': isSigned && signedOn != null ? Fmt.iso(signedOn) : null,
  };
}

/// Record a resolution.
Future<bool> showResolutionSheet(
  BuildContext context, {
  required String entityId,
  Map<String, dynamic>? resolution,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _ResolutionSheet(
        entityId: entityId,
        resolution: resolution,
      ),
    ) ??
    false;

class _ResolutionSheet extends ConsumerStatefulWidget {
  const _ResolutionSheet({required this.entityId, this.resolution});

  final String entityId;
  final Map<String, dynamic>? resolution;

  @override
  ConsumerState<_ResolutionSheet> createState() => _ResolutionSheetState();
}

class _ResolutionSheetState extends ConsumerState<_ResolutionSheet> {
  late final _title = TextEditingController(
    text: '${widget.resolution?['title'] ?? ''}',
  );
  late final _reference = TextEditingController(
    text: '${widget.resolution?['reference'] ?? ''}',
  );
  late final _body = TextEditingController(
    text: '${widget.resolution?['body'] ?? ''}',
  );
  late final _venue = TextEditingController(
    text: '${widget.resolution?['meeting_venue'] ?? ''}',
  );
  late final _for = TextEditingController(
    text: '${widget.resolution?['in_favour'] ?? ''}',
  );
  late final _against = TextEditingController(
    text: '${widget.resolution?['against'] ?? ''}',
  );
  late final _abstained = TextEditingController(
    text: '${widget.resolution?['abstained'] ?? ''}',
  );

  late String _kind = '${widget.resolution?['kind'] ?? 'board'}';
  late bool _meetingHeld = widget.resolution?['meeting_held'] == true;
  late bool _signed = widget.resolution?['is_signed'] == true;
  late DateTime? _passedOn = Fmt.parseDate(widget.resolution?['passed_on']);
  late DateTime? _effectiveOn =
      Fmt.parseDate(widget.resolution?['effective_on']);
  late DateTime? _signedOn = Fmt.parseDate(widget.resolution?['signed_on']);
  late String? _chairmanId =
      widget.resolution?['chairman_person_id'] as String?;
  late final Set<String> _present = {
    ...?(widget.resolution?['present_person_ids'] as List?)?.map((v) => '$v'),
  };
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final c in [_title, _for, _against, _abstained]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [
      _title,
      _reference,
      _body,
      _venue,
      _for,
      _against,
      _abstained,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _count(TextEditingController c) => int.tryParse(c.text.trim());

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Recorded',
      doing: 'Record a resolution',
      action: () => ref.read(repoProvider)!.saveCorpResolution(
        resolutionValues(
          entityId: widget.entityId,
          title: _title.text,
          kind: _kind,
          meetingHeld: _meetingHeld,
          reference: _reference.text,
          body: _body.text,
          passedOn: _passedOn,
          effectiveOn: _effectiveOn,
          venue: _venue.text,
          chairmanId: _chairmanId,
          present: _present.toList(),
          inFavour: _count(_for),
          against: _count(_against),
          abstained: _count(_abstained),
          isSigned: _signed,
          signedOn: _signedOn,
        ),
        id: widget.resolution?['id'] as String?,
      ),
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(corpResolutionsProvider(widget.entityId));
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _remove() async {
    final row = widget.resolution;
    if (row == null) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${row['title']}?'),
        content: Text(resolutionDeletionWarning(row)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _saving = true);
    final done = await runWithFeedback(
      context,
      successMessage: 'Removed',
      doing: 'Remove a resolution',
      action: () =>
          ref.read(repoProvider)!.deleteCorpResolution(row['id'] as String),
    );
    if (mounted) setState(() => _saving = false);
    if (done && mounted) {
      ref.invalidate(corpResolutionsProvider(widget.entityId));
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = ref.watch(corpPersonsProvider).valueOrNull ?? const [];
    final circulated = wasCirculated(_kind, _meetingHeld);
    final blocked = resolutionBlockedBecause(
      title: _title.text,
      kind: _kind,
      meetingHeld: _meetingHeld,
      passedOn: _passedOn,
      effectiveOn: _effectiveOn,
      isSigned: _signed,
      signedOn: _signedOn,
      present: _present.length,
      inFavour: _count(_for),
      against: _count(_against),
      abstained: _count(_abstained),
    );
    final carried = resolutionCarried(
      kind: _kind,
      inFavour: _count(_for),
      against: _count(_against),
    );
    final small = Theme.of(context).textTheme.bodySmall;

    return AlertDialog(
      title: Text(
        widget.resolution == null ? 'A resolution' : 'The resolution',
      ),
      content: SizedBox(
        width: 560,
        height: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('resolution-title'),
                controller: _title,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'What it resolves',
                ),
              ),
              TextField(
                controller: _reference,
                enabled: !_saving,
                decoration: const InputDecoration(labelText: 'Reference'),
              ),
              const SizedBox(height: Space.md),
              DropdownButtonFormField<String>(
                value: _kind,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Passed by'),
                items: [
                  for (final e in kResolutionKinds.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: _saving
                    ? null
                    : (v) => setState(() {
                        _kind = v ?? 'board';
                        if (_kind == 'written') _meetingHeld = false;
                      }),
              ),
              if (_kind == 'members_special')
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Text(
                    'A special resolution needs three quarters of the votes '
                    'cast — s.292(1).',
                    style: small,
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _meetingHeld,
                title: const Text('Passed at a meeting'),
                subtitle: Text(
                  circulated
                      ? 'Circulated for signature under s.297 rather than '
                            'put to a meeting.'
                      : 'A meeting was held.',
                ),
                onChanged: _saving || _kind == 'written'
                    ? null
                    : (v) => setState(() => _meetingHeld = v),
              ),
              Row(children: [
                Expanded(
                  child: StatutoryDateField(
                    label: 'Passed on',
                    value: _passedOn,
                    enabled: !_saving,
                    onChanged: (d) => setState(() => _passedOn = d),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: StatutoryDateField(
                    label: 'Effective from',
                    value: _effectiveOn,
                    enabled: !_saving,
                    onChanged: (d) => setState(() => _effectiveOn = d),
                  ),
                ),
              ]),
              if (!circulated) ...[
                const SizedBox(height: Space.md),
                TextField(
                  controller: _venue,
                  enabled: !_saving,
                  decoration: const InputDecoration(labelText: 'Where'),
                ),
                DropdownButtonFormField<String?>(
                  value: _chairmanId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'In the chair'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Nobody recorded'),
                    ),
                    for (final p in people)
                      DropdownMenuItem<String?>(
                        value: p.id,
                        child: Text(p.fullName, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged:
                      _saving ? null : (v) => setState(() => _chairmanId = v),
                ),
                const SizedBox(height: Space.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Present', style: small),
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final p in people)
                      FilterChip(
                        label: Text(p.fullName),
                        selected: _present.contains(p.id),
                        onSelected: _saving
                            ? null
                            : (on) => setState(() {
                                on ? _present.add(p.id) : _present.remove(p.id);
                              }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: Space.md),
              Row(children: [
                Expanded(child: _CountField(label: 'For', controller: _for,
                    enabled: !_saving)),
                const SizedBox(width: Space.sm),
                Expanded(child: _CountField(label: 'Against',
                    controller: _against, enabled: !_saving)),
                const SizedBox(width: Space.sm),
                Expanded(child: _CountField(label: 'Abstained',
                    controller: _abstained, enabled: !_saving)),
              ]),
              if (carried != null)
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Text(
                    carried
                        ? 'Carried. Abstentions are not votes cast, so they '
                              'do not count against it.'
                        : 'Not carried on those numbers.',
                    style: small?.copyWith(
                      color: carried ? null : context.colors.warning,
                    ),
                  ),
                ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _body,
                enabled: !_saving,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(labelText: 'The resolution'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _signed,
                title: const Text('Signed'),
                onChanged:
                    _saving ? null : (v) => setState(() => _signed = v),
              ),
              if (_signed)
                StatutoryDateField(
                  label: 'Signed on',
                  value: _signedOn,
                  enabled: !_saving,
                  onChanged: (d) => setState(() => _signedOn = d),
                ),
              if (blocked != null)
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Text(
                    blocked,
                    style: small?.copyWith(color: context.colors.danger),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.resolution != null)
          TextButton(
            key: const ValueKey('resolution-delete'),
            onPressed: _saving ? null : _remove,
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('resolution-save'),
          onPressed: _saving || blocked != null ? null : _save,
          child: const Text('Record'),
        ),
      ],
    );
  }
}

class _CountField extends StatelessWidget {
  const _CountField({
    required this.label,
    required this.controller,
    required this.enabled,
  });

  final String label;
  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        enabled: enabled,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
      );
}
