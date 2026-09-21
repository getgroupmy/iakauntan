import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Composes a document number the way the server composes it.
///
/// Mirrors `app.compose_document_number` (0480): prefix, then the
/// period key and a dash when there is one, then the number padded to
/// [padding] digits -- and never cut down to them, which is what
/// `lpad` did to the hundred-thousandth invoice -- then the suffix.
/// Kept as a pure function so the dialog's preview can be asserted
/// against the numbers the migration asserts.
String composeDocumentNumber(
  String prefix,
  String? periodKey,
  int number,
  int padding,
  String suffix,
) {
  final digits = number.toString();
  final body = digits.length >= padding ? digits : digits.padLeft(padding, '0');
  final period = periodKey == null || periodKey.isEmpty ? '' : '$periodKey-';
  return '$prefix$period$body$suffix';
}

/// The period key a reset policy puts in the number: the year for
/// `yearly`, year and month for `monthly`, nothing for `never`. Mirrors
/// `app.series_period_key`.
String? seriesPeriodKey(String resetPolicy, DateTime now) {
  final yyyy = now.year.toString().padLeft(4, '0');
  switch (resetPolicy) {
    case 'yearly':
      return yyyy;
    case 'monthly':
      return '$yyyy${now.month.toString().padLeft(2, '0')}';
    default:
      return null;
  }
}

/// What the next invoice, bill, journal and so on will be called.
///
/// Every company's numbers had been drawn from a table nobody could
/// see: a series started at 1 with a prefix chosen by the migration,
/// and a company arriving with three years of invoices behind it had
/// no way to say "the next one is 413". This card lists every series
/// of the modules the company has, grouped the way the navigation is,
/// each with the number the next draw will return. An owner or admin
/// taps a row to set its prefix, suffix, padding, reset policy and
/// next number; the preview in the dialog is composed the way the
/// server composes it.
///
/// The one refusal worth knowing about is the server's: a next number
/// below the last one issued is refused while the prefix, suffix and
/// reset policy stay the same, because those numbers are on documents
/// already. Change the prefix and the count may start again.
class DocumentNumberingCard extends ConsumerWidget {
  const DocumentNumberingCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final series = ref.watch(documentNumberingProvider);
    final canAdmin = ref.watch(canAdminProvider);
    // Module names come from the catalogue the company was sold from;
    // until it arrives (or if it never does) the code is spelt out.
    final moduleNames = {
      for (final m
          in ref.watch(platformModulesProvider).value ?? const <dynamic>[])
        m.code as String: m.name as String,
    };

    Future<void> edit(Map<String, dynamic> row) async {
      final saved = await showDialog<bool>(
        context: context,
        builder: (_) => _SeriesDialog(row: row),
      );
      if (saved == true) ref.invalidate(documentNumberingProvider);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Document numbering',
              subtitle: canAdmin
                  ? 'What the next invoice, bill and journal will be '
                        'called. Tap a series to set it.'
                  : 'What the next invoice, bill and journal will be '
                        'called.',
            ),
            AsyncView(
              value: series,
              onRetry: () => ref.invalidate(documentNumberingProvider),
              // Collapsed module headers, each with a count underneath.
              // The sales group opens on its own once the rows land,
              // which the outline does not try to predict.
              skeleton: const ListSkeleton(rows: 5, leading: false),
              builder: (rows) {
                // Grouped by module in the order the server lists them,
                // which is the order the navigation shows them: sales
                // first, because the invoice is the number most people
                // came to see.
                final modules = <String>[];
                final byModule = <String, List<Map<String, dynamic>>>{};
                for (final row in rows) {
                  final module = row['module'] as String? ?? '';
                  if (!byModule.containsKey(module)) {
                    modules.add(module);
                    byModule[module] = [];
                  }
                  byModule[module]!.add(row);
                }
                if (modules.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No series to show.'),
                  );
                }
                return Column(
                  children: [
                    for (final module in modules)
                      _ModuleGroup(
                        module: module,
                        name: moduleNames[module] ?? Fmt.label(module),
                        rows: byModule[module]!,
                        canAdmin: canAdmin,
                        onEdit: edit,
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ModuleGroup extends StatelessWidget {
  const _ModuleGroup({
    required this.module,
    required this.name,
    required this.rows,
    required this.canAdmin,
    required this.onEdit,
  });

  final String module;
  final String name;
  final List<Map<String, dynamic>> rows;
  final bool canAdmin;
  final Future<void> Function(Map<String, dynamic>) onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      key: ValueKey('numbering-$module'),
      tilePadding: EdgeInsets.zero,
      // The invoice is what most people came to see, so the sales
      // group opens on its own; the rest are a tap away.
      initiallyExpanded: module == 'sales',
      title: Text(name),
      subtitle: Text('${rows.length} series', style: theme.textTheme.bodySmall),
      children: [
        for (final row in rows)
          ListTile(
            key: ValueKey('series-${row['doc_type']}'),
            dense: true,
            contentPadding: const EdgeInsets.only(left: 8),
            onTap: canAdmin ? () => onEdit(row) : null,
            title: Text(row['label'] as String? ?? ''),
            subtitle: Text(
              _lastIssued(row),
              style: const TextStyle(fontSize: 11),
            ),
            trailing: Text(
              row['sample'] as String? ?? '',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
      ],
    );
  }

  /// "Last issued INV-2026-00412", or that none has been. Composed here
  /// from the parts the server returns, the way it composes the sample.
  static String _lastIssued(Map<String, dynamic> row) {
    final last = row['last_issued'];
    if (last == null) return 'None issued yet';
    return 'Last issued ${composeDocumentNumber(row['prefix'] as String? ?? '', row['period_key'] as String?, (last as num).toInt(), (row['padding'] as num?)?.toInt() ?? 5, row['suffix'] as String? ?? '')}';
  }
}

class _SeriesDialog extends ConsumerStatefulWidget {
  const _SeriesDialog({required this.row});

  final Map<String, dynamic> row;

  @override
  ConsumerState<_SeriesDialog> createState() => _SeriesDialogState();
}

class _SeriesDialogState extends ConsumerState<_SeriesDialog> {
  late final TextEditingController _prefix = TextEditingController(
    text: widget.row['prefix'] as String? ?? '',
  );
  late final TextEditingController _suffix = TextEditingController(
    text: widget.row['suffix'] as String? ?? '',
  );
  late final TextEditingController _padding = TextEditingController(
    text: ((widget.row['padding'] as num?)?.toInt() ?? 5).toString(),
  );
  late final TextEditingController _next = TextEditingController(
    text: ((widget.row['next_value'] as num?)?.toInt() ?? 1).toString(),
  );
  late String _reset = widget.row['reset_policy'] as String? ?? 'yearly';

  static const _resets = {
    'yearly': 'Every year',
    'monthly': 'Every month',
    'never': 'Never',
  };

  @override
  void initState() {
    super.initState();
    for (final c in [_prefix, _suffix, _padding, _next]) {
      c.addListener(_changed);
    }
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _prefix.dispose();
    _suffix.dispose();
    _padding.dispose();
    _next.dispose();
    super.dispose();
  }

  String get _label => widget.row['label'] as String? ?? 'series';

  /// The number the next draw will return with the fields as typed.
  /// Composed the way the server composes it; the server's answer on
  /// save replaces it, so a disagreement would show.
  String get _preview {
    final padding = int.tryParse(_padding.text.trim()) ?? 0;
    final next = int.tryParse(_next.text.trim()) ?? 0;
    return composeDocumentNumber(
      _prefix.text.trim(),
      seriesPeriodKey(_reset, DateTime.now()),
      next,
      padding.clamp(1, 12),
      _suffix.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final last = widget.row['last_issued'];
    return AlertDialog(
      title: Text(_label),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('series-prefix'),
                      controller: _prefix,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Prefix',
                        helperText: 'Up to 12 letters, digits, / _ . # -',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('series-suffix'),
                      controller: _suffix,
                      decoration: const InputDecoration(
                        labelText: 'Suffix',
                        helperText: 'Usually none',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      isExpanded: true,
                      key: const ValueKey('series-reset'),
                      initialValue:
                          _resets.containsKey(_reset) ? _reset : 'yearly',
                      decoration: const InputDecoration(
                        labelText: 'Count starts again',
                      ),
                      items: [
                        for (final e in _resets.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) => setState(() => _reset = v ?? 'yearly'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 100,
                    child: TextField(
                      key: const ValueKey('series-padding'),
                      controller: _padding,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Digits',
                        helperText: '1 to 12',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('series-next'),
                controller: _next,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Next number',
                  helperText: last == null
                      ? 'None issued yet in this series.'
                      : 'The last issued was number $last. The next '
                            'cannot be lower unless the prefix, suffix '
                            'or reset policy changes.',
                  helperMaxLines: 3,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'The next ${_label.toLowerCase()} will be',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                _preview,
                key: const ValueKey('series-preview'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  Future<void> _save() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final padding = int.tryParse(_padding.text.trim());
    final next = int.tryParse(_next.text.trim());
    if (padding == null || next == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Digits and the next number must be whole numbers.'),
        ),
      );
      return;
    }

    String? sample;
    final done = await runWithFeedback(
      context,
      doing: 'set the document numbering',
      // The confirmation is the server's sample, said after the fact,
      // because the number is the server's to compose.
      successMessage: null,
      action: () async {
        sample = await repo.setDocumentNumbering(
          docType: widget.row['doc_type'] as String,
          prefix: _prefix.text.trim(),
          suffix: _suffix.text.trim(),
          padding: padding,
          resetPolicy: _reset,
          nextValue: next,
        );
      },
    );
    if (!done || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Next ${_label.toLowerCase()}: $sample')),
    );
    Navigator.pop(context, true);
  }
}
