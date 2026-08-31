import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import '../secretarial/person_editor.dart' show StatutoryDateField;

/// Who is running the scheme today.
///
/// It moves developer -> JMB -> MC as the development is handed over,
/// and which one it is decides who signs. The names are the ones the
/// SMA 2013 uses, because they are the ones on the paperwork.
const Map<String, String> strataStageNames = {
  'developer': 'Developer',
  'jmb': 'Joint management body',
  'mc': 'Management corporation',
};

/// The sinking fund floor, as a percentage of the Charges.
///
/// s.25(3) for a JMB and s.51(2) for a management corporation both put
/// it at not less than ten per cent. A scheme may resolve to contribute
/// more and many do; it may not resolve to contribute less.
const double sinkingFundFloor = 10;

/// The late payment charge ceiling, per annum.
///
/// Capped by the Third Schedule of the Strata Management (Maintenance
/// and Management) Regulations 2015.
const double lateInterestCeiling = 10;

double? percentOf(String text, {required double min, required double max}) {
  final v = double.tryParse(text.trim());
  if (v == null || v < min || v > max) return null;
  return v;
}

/// Ringgit per share unit per month, as an AGM resolves it.
///
/// Six decimal places in the column, and they are used: a scheme with
/// twenty thousand share units resolves rates that only make sense to
/// the sen once multiplied out.
double? rateOf(String text) {
  final v = double.tryParse(text.trim());
  if (v == null || v < 0) return null;
  return v;
}

/// The denominator, as the Schedule of Parcels states it.
double? totalShareUnitsOf(String text) {
  final v = double.tryParse(text.trim());
  // Nought is refused here and allowed by `shareUnitsOf`, which is the
  // one character between them: every share in the scheme is
  // `share_units / total_share_units`, so a zero denominator is not a
  // scheme with nothing allocated — it is a division nobody can do.
  //
  // No empty-string guard: `double.tryParse('')` is already null.
  if (v == null || v <= 0) return null;
  return v;
}

/// Whether the Schedule of Parcels adds up to what the scheme says it
/// should.
///
/// Held separately rather than summed so that a half-entered schedule is
/// visibly incomplete instead of silently changing everyone's share. So
/// something has to do the comparing, and it is this.
bool scheduleIsComplete(double? totalShareUnits, num allocated) =>
    totalShareUnits != null && (totalShareUnits - allocated).abs() < 0.0001;

/// What a strata scheme is, given what was entered.
Map<String, dynamic> strataSchemeValues({
  required String siteId,
  required String stage,
  String? cobReference,
  String? mcRegistrationNo,
  DateTime? establishedOn,
  DateTime? firstAgmOn,
  DateTime? financialYearEnd,
  double? totalShareUnits,
}) {
  String? trimmed(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();

  return <String, dynamic>{
    'site_id': siteId,
    'stage': stage,
    'cob_reference': trimmed(cobReference),
    // A management corporation has a registration number because it is
    // registered; a JMB and a developer are not, and a number carried
    // over from a template would assert a registration that does not
    // exist.
    'mc_registration_no': stage == 'mc' ? trimmed(mcRegistrationNo) : null,
    'established_on': establishedOn == null ? null : Fmt.iso(establishedOn),
    'first_agm_on': firstAgmOn == null ? null : Fmt.iso(firstAgmOn),
    'financial_year_end':
        financialYearEnd == null ? null : Fmt.iso(financialYearEnd),
    'total_share_units': totalShareUnits,
  };
}

/// What an AGM resolved.
///
/// Added and never edited: a charge raised for January stays raised at
/// January's rate however many times it is reprinted.
Map<String, dynamic> chargeRateValues({
  required DateTime effectiveFrom,
  required double ratePerShareUnit,
  double sinkingFundPercent = sinkingFundFloor,
  double lateInterestPercent = lateInterestCeiling,
  String? resolutionReference,
  String? notes,
}) {
  String? trimmed(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();

  return <String, dynamic>{
    'effective_from': Fmt.iso(effectiveFrom),
    'rate_per_share_unit': ratePerShareUnit,
    'sinking_fund_percent': sinkingFundPercent,
    'late_interest_percent': lateInterestPercent,
    'resolution_reference': trimmed(resolutionReference),
    'notes': trimmed(notes),
  };
}

/// Set up the scheme, or amend its particulars.
Future<bool> showStrataSchemeSheet(
  BuildContext context, {
  required String siteId,
  Map<String, dynamic>? scheme,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _SchemeSheet(siteId: siteId, scheme: scheme),
    ) ??
    false;

/// Record the rate an AGM resolved.
Future<bool> showChargeRateSheet(
  BuildContext context, {
  required String siteId,
  required String schemeId,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _RateSheet(siteId: siteId, schemeId: schemeId),
    ) ??
    false;

class _SchemeSheet extends ConsumerStatefulWidget {
  const _SchemeSheet({required this.siteId, this.scheme});

  final String siteId;
  final Map<String, dynamic>? scheme;

  @override
  ConsumerState<_SchemeSheet> createState() => _SchemeSheetState();
}

class _SchemeSheetState extends ConsumerState<_SchemeSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _cob;
  late final TextEditingController _mcNo;
  late final TextEditingController _totalShare;

  late String _stage;
  DateTime? _established;
  DateTime? _firstAgm;
  DateTime? _yearEnd;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = widget.scheme;
    _cob = TextEditingController(text: s?['cob_reference'] as String? ?? '');
    _mcNo =
        TextEditingController(text: s?['mc_registration_no'] as String? ?? '');
    _totalShare = TextEditingController(
      text: s?['total_share_units'] == null ? '' : '${s!['total_share_units']}',
    );
    _stage = s?['stage'] as String? ?? 'jmb';
    _established = s?['established_on'] == null
        ? null
        : DateTime.parse(s!['established_on'] as String);
    _firstAgm = s?['first_agm_on'] == null
        ? null
        : DateTime.parse(s!['first_agm_on'] as String);
    _yearEnd = s?['financial_year_end'] == null
        ? null
        : DateTime.parse(s!['financial_year_end'] as String);
  }

  @override
  void dispose() {
    for (final c in [_cob, _mcNo, _totalShare]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    final values = strataSchemeValues(
      siteId: widget.siteId,
      stage: _stage,
      cobReference: _cob.text,
      mcRegistrationNo: _mcNo.text,
      establishedOn: _established,
      firstAgmOn: _firstAgm,
      financialYearEnd: _yearEnd,
      totalShareUnits: totalShareUnitsOf(_totalShare.text),
    );

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveStrataScheme(values, id: widget.scheme?['id'] as String?),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(strataSchemeProvider(widget.siteId));
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final units =
        ref.watch(propertyUnitsProvider(widget.siteId)).valueOrNull ??
            const <Map<String, dynamic>>[];
    final allocated = units.fold<num>(
      0,
      (a, u) => a + ((u['share_units'] as num?) ?? 0),
    );
    final stated = totalShareUnitsOf(_totalShare.text);

    return AlertDialog(
      title: Text(widget.scheme == null
          ? 'Set up the scheme'
          : 'Amend the scheme'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  key: const ValueKey('strata-stage'),
                  value: _stage,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Managed by',
                    helperText: 'Developer, then JMB, then MC as the '
                        'development is handed over. It decides who signs.',
                  ),
                  items: [
                    for (final e in strataStageNames.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged:
                      _saving ? null : (v) => setState(() => _stage = v!),
                ),
                const SizedBox(height: Space.md),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _cob,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        labelText: 'COB reference',
                        helperText: 'Commissioner of Buildings',
                      ),
                    ),
                  ),
                  if (_stage == 'mc') ...[
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: TextFormField(
                        controller: _mcNo,
                        enabled: !_saving,
                        textCapitalization: TextCapitalization.characters,
                        decoration:
                            const InputDecoration(labelText: 'MC registration'),
                      ),
                    ),
                  ],
                ]),
                const SizedBox(height: Space.md),
                Row(children: [
                  Expanded(
                    child: StatutoryDateField(
                      label: 'Established',
                      value: _established,
                      enabled: !_saving,
                      onChanged: (d) => setState(() => _established = d),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: StatutoryDateField(
                      label: 'First AGM',
                      value: _firstAgm,
                      enabled: !_saving,
                      onChanged: (d) => setState(() => _firstAgm = d),
                    ),
                  ),
                ]),
                const SizedBox(height: Space.md),
                StatutoryDateField(
                  label: 'Financial year end',
                  value: _yearEnd,
                  enabled: !_saving,
                  onChanged: (d) => setState(() => _yearEnd = d),
                ),
                const SizedBox(height: Space.md),
                TextFormField(
                  key: const ValueKey('total-share-units'),
                  controller: _totalShare,
                  enabled: !_saving,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Total share units',
                    helperText: 'The denominator, as the Schedule of Parcels '
                        'states it.',
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty || totalShareUnitsOf(v) != null)
                          ? null
                          : 'A number greater than zero',
                ),
                const SizedBox(height: Space.sm),
                // The comparison the schedule is held separately for.
                Text(
                  stated == null
                      ? '$allocated share units allocated so far.'
                      : scheduleIsComplete(stated, allocated)
                          ? 'The Schedule of Parcels is complete: '
                              '$allocated of $stated allocated.'
                          : 'Incomplete: $allocated of $stated allocated. '
                              'Charges raised now would be levied against a '
                              'denominator the parcels do not add up to.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: stated != null &&
                                !scheduleIsComplete(stated, allocated)
                            ? context.colors.warning
                            : context.scheme.onSurfaceVariant,
                      ),
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
          key: const ValueKey('strata-scheme-save'),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

class _RateSheet extends ConsumerStatefulWidget {
  const _RateSheet({required this.siteId, required this.schemeId});

  final String siteId;
  final String schemeId;

  @override
  ConsumerState<_RateSheet> createState() => _RateSheetState();
}

class _RateSheetState extends ConsumerState<_RateSheet> {
  final _formKey = GlobalKey<FormState>();
  final _rate = TextEditingController();
  final _sinking = TextEditingController(text: '$sinkingFundFloor');
  final _late = TextEditingController(text: '$lateInterestCeiling');
  final _resolution = TextEditingController();
  final _notes = TextEditingController();

  DateTime? _from;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_rate, _sinking, _late, _resolution, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final rate = rateOf(_rate.text);
    if (rate == null || _from == null) return;

    setState(() => _saving = true);
    final values = chargeRateValues(
      effectiveFrom: _from!,
      ratePerShareUnit: rate,
      sinkingFundPercent:
          percentOf(_sinking.text, min: sinkingFundFloor, max: 100) ??
              sinkingFundFloor,
      lateInterestPercent:
          percentOf(_late.text, min: 0, max: lateInterestCeiling) ??
              lateInterestCeiling,
      resolutionReference: _resolution.text,
      notes: _notes.text,
    );

    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.addStrataChargeRate(widget.schemeId, values),
      successMessage: 'Recorded',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(strataSchemeProvider(widget.siteId));
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Record the rate resolved'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'A rate is what an AGM resolved, so it is added and never '
                  'edited. A charge raised for January stays raised at '
                  "January's rate however many times it is reprinted.",
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Space.md),
                StatutoryDateField(
                  label: 'Effective from',
                  value: _from,
                  enabled: !_saving,
                  onChanged: (d) => setState(() => _from = d),
                ),
                const SizedBox(height: Space.md),
                TextFormField(
                  key: const ValueKey('rate-per-share-unit'),
                  controller: _rate,
                  enabled: !_saving,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Rate per share unit, a month',
                    helperText: 'What the AGM voted on. Multiplied by a '
                        "parcel's share units to give its Charges.",
                  ),
                  validator: (v) =>
                      rateOf(v ?? '') == null ? 'An amount' : null,
                ),
                const SizedBox(height: Space.md),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('sinking-fund'),
                      controller: _sinking,
                      enabled: !_saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Sinking fund %',
                        helperText: 'Not less than 10',
                      ),
                      validator: (v) => percentOf(v ?? '',
                                  min: sinkingFundFloor, max: 100) ==
                              null
                          ? '10 to 100'
                          : null,
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: TextFormField(
                      controller: _late,
                      enabled: !_saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Late charge % a year',
                        helperText: 'Capped at 10',
                      ),
                      validator: (v) => percentOf(v ?? '',
                                  min: 0, max: lateInterestCeiling) ==
                              null
                          ? '0 to 10'
                          : null,
                    ),
                  ),
                ]),
                const SizedBox(height: Space.md),
                TextFormField(
                  controller: _resolution,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Resolution reference',
                    helperText: 'The AGM minute this came from.',
                  ),
                ),
                const SizedBox(height: Space.md),
                TextFormField(
                  controller: _notes,
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 3,
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
          key: const ValueKey('rate-save'),
          onPressed: _saving || _from == null ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Record'),
        ),
      ],
    );
  }
}
