import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// The company's forecasting settings.
///
/// Every field here is a number a suggestion will later be defended
/// with, so each one says what it changes rather than only what it is
/// called. The service level in particular: nobody has an opinion about
/// "0.95" and everybody has one about "we are willing to run out of
/// this one time in twenty".
///
/// Returns true when something was saved.
Future<bool> showForecastSettings(BuildContext context, WidgetRef ref) async {
  final current = await ref.read(forecastSettingsProvider.future);
  if (!context.mounted) return false;
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _ForecastSettingsDialog(current ?? const {}),
  );
  if (saved ?? false) ref.invalidate(forecastSettingsProvider);
  return saved ?? false;
}

class _ForecastSettingsDialog extends ConsumerStatefulWidget {
  const _ForecastSettingsDialog(this.current);

  final Map<String, dynamic> current;

  @override
  ConsumerState<_ForecastSettingsDialog> createState() =>
      _ForecastSettingsDialogState();
}

class _ForecastSettingsDialogState
    extends ConsumerState<_ForecastSettingsDialog> {
  final _form = GlobalKey<FormState>();

  late String _bucket = '${widget.current['bucket'] ?? 'week'}';
  late String _method = '${widget.current['default_method'] ?? 'moving_average'}';
  late final _history = _c('history_days', 365);
  late final _horizon = _c('horizon_buckets', 8);
  late final _window = _c('default_window', 4);
  late final _alpha = _c('default_alpha', 0.300);
  late final _service = _c('service_level', 0.9500);
  late final _lead = _c('default_lead_time_days', 14);
  late final _minPeriods = _c('min_periods', 4);
  late bool _transfers = widget.current['count_transfers_out'] as bool? ?? false;
  late bool _shrinkage = widget.current['count_shrinkage'] as bool? ?? false;
  bool _saving = false;

  TextEditingController _c(String key, num fallback) =>
      TextEditingController(text: '${widget.current[key] ?? fallback}');

  @override
  void dispose() {
    for (final c in [
      _history,
      _horizon,
      _window,
      _alpha,
      _service,
      _lead,
      _minPeriods,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Forecast settings'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _bucket,
                  decoration: const InputDecoration(
                    labelText: 'Read history in',
                    helperText:
                        'Weeks suit an item that sells most weeks. An item '
                        'that sells a handful of times a year is mostly '
                        'zeroes in weekly buckets; months put the signal '
                        'above the noise.',
                    helperMaxLines: 4,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'day', child: Text('Days')),
                    DropdownMenuItem(value: 'week', child: Text('Weeks')),
                    DropdownMenuItem(value: 'month', child: Text('Months')),
                  ],
                  onChanged: (v) => setState(() => _bucket = v ?? 'week'),
                ),
                const SizedBox(height: Space.md),
                _int(
                  _horizon,
                  'Buckets to forecast ahead',
                  'Also the review period: an order covers the lead time '
                      'and this, because ordering exactly up to the reorder '
                      'point means ordering again tomorrow.',
                  min: 1,
                  max: 52,
                ),
                _int(
                  _history,
                  'Days of history to read',
                  'A year lets a seasonal method have a season to copy.',
                  min: 28,
                  max: 3650,
                ),
                _int(
                  _minPeriods,
                  'Fewest periods worth forecasting',
                  'Below this the item is listed as skipped rather than '
                      'dropped, so nobody loses sight of it.',
                  min: 2,
                  max: 52,
                ),
                const SizedBox(height: Space.md),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _method,
                  decoration: const InputDecoration(labelText: 'Default method'),
                  items: const [
                    DropdownMenuItem(
                      value: 'moving_average',
                      child: Text('Moving average'),
                    ),
                    DropdownMenuItem(
                      value: 'exponential_smoothing',
                      child: Text('Exponential smoothing'),
                    ),
                    DropdownMenuItem(
                      value: 'seasonal_naive',
                      child: Text('Same period last season'),
                    ),
                  ],
                  onChanged: (v) =>
                      setState(() => _method = v ?? 'moving_average'),
                ),
                const SizedBox(height: Space.md),
                _int(
                  _window,
                  'Averaging window',
                  'How many past buckets a moving average takes, and the '
                      'season length for the seasonal method.',
                  min: 2,
                  max: 52,
                ),
                _decimal(
                  _alpha,
                  'Smoothing factor',
                  'Between 0 and 1. Higher follows recent demand more '
                      'closely and is noisier.',
                  min: 0.001,
                  max: 0.999,
                ),
                _decimal(
                  _service,
                  'Service level',
                  'The share of replenishment cycles you are willing to get '
                      'through without running out. 0.95 is one stockout in '
                      'twenty cycles; 0.99 costs a great deal more stock for '
                      'the last four points.',
                  min: 0.50,
                  max: 0.9999,
                ),
                _int(
                  _lead,
                  'Lead time when it cannot be measured',
                  'Used only for items with fewer than two receipts traced '
                      'back to a purchase order.',
                  min: 0,
                  max: 365,
                ),
                const SizedBox(height: Space.sm),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _shrinkage,
                  title: const Text('Count write-offs as demand'),
                  subtitle: const Text(
                    'Off by default. An item that keeps being written off '
                    'does not need more of itself ordered.',
                  ),
                  onChanged: (v) => setState(() => _shrinkage = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _transfers,
                  title: const Text('Count transfers out as demand'),
                  subtitle: const Text(
                    'Only meaningful when forecasting one warehouse. Across '
                    'the company a transfer out is matched by a transfer in '
                    'and nets to nothing.',
                  ),
                  onChanged: (v) => setState(() => _transfers = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
      ],
    );
  }

  Widget _int(
    TextEditingController c,
    String label,
    String help, {
    required int min,
    required int max,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: Space.md),
    child: TextFormField(
      controller: c,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 4,
      ),
      validator: (v) {
        final n = int.tryParse((v ?? '').trim());
        if (n == null) return 'A whole number';
        if (n < min || n > max) return 'Between $min and $max';
        return null;
      },
    ),
  );

  Widget _decimal(
    TextEditingController c,
    String label,
    String help, {
    required double min,
    required double max,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: Space.md),
    child: TextFormField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 4,
      ),
      validator: (v) {
        final n = double.tryParse((v ?? '').trim());
        if (n == null) return 'A number';
        if (n < min || n > max) return 'Between $min and $max';
        return null;
      },
    ),
  );

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Settings saved',
      action: () => repo.saveForecastSettings({
        'bucket': _bucket,
        'default_method': _method,
        'history_days': int.parse(_history.text.trim()),
        'horizon_buckets': int.parse(_horizon.text.trim()),
        'default_window': int.parse(_window.text.trim()),
        'default_alpha': double.parse(_alpha.text.trim()),
        'service_level': double.parse(_service.text.trim()),
        'default_lead_time_days': int.parse(_lead.text.trim()),
        'min_periods': int.parse(_minPeriods.text.trim()),
        'count_transfers_out': _transfers,
        'count_shrinkage': _shrinkage,
      }),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context, true);
  }
}
