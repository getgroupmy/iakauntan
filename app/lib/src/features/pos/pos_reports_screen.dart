import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// The periods a report can be saved as.
///
/// Words rather than dates, because a report saved as the first and last
/// of August is a report that is wrong in September. The server resolves
/// them; this list is only what the picker offers.
const posReportPeriods = <String, String>{
  'today': 'Today',
  'yesterday': 'Yesterday',
  'this_week': 'This week',
  'last_7': 'Last 7 days',
  'this_month': 'This month',
  'last_month': 'Last month',
  'last_30': 'Last 30 days',
  'this_year': 'This year',
};

/// One line describing what a report asks, for the list.
///
/// Pure and exported so the list and the tests read the same sentence.
String reportSentence(Map<String, dynamic> r) {
  // The labels when the server sent them, which it does — the keys are
  // what the query stores, and "average_bill" is not a thing to show
  // somebody who ticked a box marked "Average bill".
  final dims = ((r['dim_labels'] ?? r['dimensions']) as List? ?? const [])
      .map((e) => '$e')
      .toList();
  final vals = ((r['val_labels'] ?? r['measures']) as List? ?? const [])
      .map((e) => '$e')
      .toList();
  final period = posReportPeriods['${r['period']}'] ?? '${r['period']}';
  return [
    vals.join(', '),
    if (dims.isNotEmpty) 'by ${dims.join(', ')}',
    period.toLowerCase(),
  ].join(' · ');
}

/// A built report as comma-separated text, headings included.
///
/// The thing every shopkeeper does with a report is open it in a
/// spreadsheet, so the screen hands it over in the one format that
/// always works. Values with a comma or a quote in them are quoted the
/// way a spreadsheet expects.
String reportCsv(
  List<String> headings,
  List<Map<String, dynamic>> rows,
) {
  String cell(Object? v) {
    final s = '${v ?? ''}';
    return s.contains(RegExp('[",\n]'))
        ? '"${s.replaceAll('"', '""')}"'
        : s;
  }

  final out = <String>[headings.map(cell).join(',')];
  for (final r in rows) {
    final dims = ((r['dims'] as List?) ?? const []).map(cell);
    final vals = ((r['vals'] as List?) ?? const [])
        .map((v) => cell(Fmt.plain(Fmt.toDouble(v))));
    out.add([...dims, ...vals].join(','));
  }
  return out.join('\n');
}

/// Reports a shop builds for itself.
///
/// Every report we wrote answers a question we thought of. This is the
/// other half: a source, some columns to cut by, some numbers to add
/// up, and a period. What the picker offers comes from the server's own
/// allow-list, so a column can never be offered that the query would
/// then refuse.
class PosReportsScreen extends ConsumerStatefulWidget {
  const PosReportsScreen({super.key});

  @override
  ConsumerState<PosReportsScreen> createState() => _PosReportsScreenState();
}

class _PosReportsScreenState extends ConsumerState<PosReportsScreen> {
  String? _openId;

  Future<void> _build({Map<String, dynamic>? from}) async {
    // Which kind of question this is decides what can be asked, so it
    // is settled before the builder opens rather than inside it.
    var source = '${from?['source'] ?? ''}';
    if (source.isEmpty) {
      source =
          await showModalBottomSheet<String>(
            context: context,
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ListTile(title: Text('What are the rows?')),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: const Text('One per bill'),
                    subtitle: const Text('How many, how much, when, who'),
                    onTap: () => Navigator.of(ctx).pop('sales'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.restaurant_menu),
                    title: const Text('One per item sold'),
                    subtitle: const Text('What sells, and how much of it'),
                    onTap: () => Navigator.of(ctx).pop('lines'),
                  ),
                ],
              ),
            ),
          ) ??
          '';
      if (source.isEmpty || !mounted) return;
    }

    final fields = await ref.read(posReportFieldsProvider(source).future);
    if (!mounted) return;

    final answer = await showModalBottomSheet<_Built>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: _BuilderSheet(
          fields: fields,
          source: source,
          existing: from ?? const {},
        ),
      ),
    );
    if (answer == null || !mounted) return;

    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => repo.savePosReport(
        id: from?['id'] as String?,
        name: answer.name,
        source: answer.source,
        dimensions: answer.dimensions,
        measures: answer.measures,
        period: answer.period,
        sortBy: answer.measures.isEmpty ? null : answer.measures.first,
      ),
    );
    if (ok && mounted) {
      ref.invalidate(posReportsProvider);
      if (from != null) {
        ref
          ..invalidate(posReportRunProvider(from['id'] as String))
          ..invalidate(posReportHeadersProvider(from['id'] as String));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!moduleEnabled(ref, 'pos')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Report builder')),
        body: const EmptyState(
          icon: Icons.query_stats,
          title: 'The till is not switched on',
          message: 'These reports are built out of what a shop sold, and '
              'this company has no shop.',
        ),
      );
    }

    final reports = ref.watch(posReportsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Report builder')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _build,
        icon: const Icon(Icons.add_chart),
        label: const Text('Build one'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: reports,
        onRetry: () => ref.invalidate(posReportsProvider),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.query_stats,
              title: 'No reports yet',
              message: 'Build one: pick what the rows are cut by — day, '
                  'outlet, item — and what to add up.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final r = rows[i];
              final id = r['id'] as String;
              final open = _openId == id;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: Icon(
                      r['source'] == 'lines'
                          ? Icons.restaurant_menu
                          : Icons.receipt_long_outlined,
                    ),
                    title: Text('${r['name']}'),
                    subtitle: Text(reportSentence(r)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (r['is_shared'] != true)
                          const Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: Icon(Icons.lock_outline, size: 16),
                          ),
                        PopupMenuButton<String>(
                          onSelected: (choice) async {
                            if (choice == 'edit') {
                              await _build(from: r);
                              return;
                            }
                            final repo = ref.read(repoProvider);
                            if (repo == null || !mounted) return;
                            final ok = await runWithFeedback(
                              context,
                              successMessage: 'Deleted',
                              action: () => repo.deletePosReport(id),
                            );
                            if (ok && mounted) {
                              ref.invalidate(posReportsProvider);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Throw it away'),
                            ),
                          ],
                        ),
                      ],
                    ),
                    onTap: () => setState(() => _openId = open ? null : id),
                  ),
                  if (open) _Result(reportId: id),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _Result extends ConsumerWidget {
  const _Result({required this.reportId});

  final String reportId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final head = ref.watch(posReportHeadersProvider(reportId));
    final rows = ref.watch(posReportRunProvider(reportId));

    return AsyncView<Map<String, dynamic>>(
      value: head,
      onRetry: () => ref.invalidate(posReportHeadersProvider(reportId)),
      builder: (h) {
        final headings = [
          ...((h['dim_labels'] as List?) ?? const []).map((e) => '$e'),
          ...((h['val_labels'] as List?) ?? const []).map((e) => '$e'),
        ];
        return AsyncView<List<Map<String, dynamic>>>(
          value: rows,
          onRetry: () => ref.invalidate(posReportRunProvider(reportId)),
          builder: (data) {
            if (data.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('Nothing in that period')),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${h['from_date']} to ${h['to_date']}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: reportCsv(headings, data)),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Copied as a spreadsheet'),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.table_view_outlined, size: 18),
                        label: const Text('Copy'),
                      ),
                    ],
                  ),
                ),
                // Wide reports scroll sideways rather than squeezing the
                // numbers into a column nobody can read.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: [
                      for (final head in headings)
                        DataColumn(label: Text(head)),
                    ],
                    rows: [
                      for (final r in data)
                        DataRow(
                          cells: [
                            for (final d in (r['dims'] as List? ?? const []))
                              DataCell(Text('$d')),
                            for (final v in (r['vals'] as List? ?? const []))
                              DataCell(Text(Fmt.plain(Fmt.toDouble(v)))),
                          ],
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
            );
          },
        );
      },
    );
  }
}

typedef _Built = ({
  String name,
  String source,
  List<String> dimensions,
  List<String> measures,
  String period,
});

class _BuilderSheet extends StatefulWidget {
  const _BuilderSheet({
    required this.fields,
    required this.source,
    required this.existing,
  });

  final List<Map<String, dynamic>> fields;
  final String source;
  final Map<String, dynamic> existing;

  @override
  State<_BuilderSheet> createState() => _BuilderSheetState();
}

class _BuilderSheetState extends State<_BuilderSheet> {
  late final TextEditingController _name;
  late String _source;
  late List<String> _dims;
  late List<String> _vals;
  late String _period;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: '${e['name'] ?? ''}');
    _source = widget.source;
    _dims = ((e['dimensions'] as List?) ?? const []).cast<String>().toList();
    _vals = ((e['measures'] as List?) ?? const ['gross'])
        .cast<String>()
        .toList();
    _period = '${e['period'] ?? 'this_month'}';
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _of(String kind) => [
    for (final f in widget.fields)
      if (f['kind'] == kind) f,
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing.isEmpty ? 'A new report' : 'The report',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'What is it called',
                hintText: 'Takings by outlet',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            // Said rather than offered: what can be asked depends on it,
            // and the picker below was built from the server's list for
            // this source before the sheet opened.
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _source == 'lines' ? 'One row per item sold' : 'One row per bill',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const Divider(height: 24),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Cut it by'),
            ),
            Wrap(
              spacing: 4,
              children: [
                for (final f in _of('dimension'))
                  FilterChip(
                    label: Text('${f['label']}'),
                    selected: _dims.contains('${f['key']}'),
                    onSelected: (on) => setState(() {
                      final k = '${f['key']}';
                      on ? _dims.add(k) : _dims.remove(k);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Add up'),
            ),
            Wrap(
              spacing: 4,
              children: [
                for (final f in _of('measure'))
                  FilterChip(
                    label: Text('${f['label']}'),
                    selected: _vals.contains('${f['key']}'),
                    onSelected: (on) => setState(() {
                      final k = '${f['key']}';
                      on ? _vals.add(k) : _vals.remove(k);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _period,
              decoration: const InputDecoration(labelText: 'Over'),
              items: [
                for (final e in posReportPeriods.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _period = v ?? _period),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _name.text.trim().isEmpty || _vals.isEmpty
                  ? null
                  : () => Navigator.of(context).pop((
                      name: _name.text.trim(),
                      source: _source,
                      dimensions: _dims,
                      measures: _vals,
                      period: _period,
                    )),
              child: const Text('Save the report'),
            ),
          ],
        ),
      ),
    );
  }
}
