import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/csv.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Bringing the customer and item lists across from whatever was in use
/// before.
///
/// The preview is not a courtesy. Nothing is written unless every row is
/// good, so a file with one bad line imports nothing at all — and the
/// only humane way to run something with that rule is to be able to see
/// what it will say first. Both buttons call the same database function;
/// the preview one just tells it not to write.
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

/// What each importer accepts, and the column headings it answers to.
///
/// A file exported from another system has its own names for things, so
/// the common ones are listed rather than making somebody rename
/// columns before they can start.
const _contactAliases = <String, List<String>>{
  'code': ['customer code', 'supplier code', 'account code', 'no', 'id'],
  'name': ['customer name', 'supplier name', 'company', 'company name'],
  'contact_type': ['type', 'kind'],
  'legal_name': ['registered name'],
  'tin': ['tax identification number', 'lhdn tin'],
  'registration_no': ['ssm', 'ssm no', 'company no', 'brn'],
  'sst_registration_no': ['sst no'],
  'email': ['e-mail', 'email address'],
  'phone': ['telephone', 'tel'],
  'mobile': ['handphone', 'hp'],
  'website': ['url'],
  'address_line1': ['address', 'address 1'],
  'address_line2': ['address 2'],
  'address_line3': ['address 3'],
  'postcode': ['post code', 'poskod', 'zip'],
  'city': ['town'],
  'state_code': ['state'],
  'country_code': ['country'],
  'currency': ['ccy'],
  'credit_limit': ['limit'],
  'notes': ['remarks'],
};

const _itemAliases = <String, List<String>>{
  'code': ['item code', 'product code', 'sku', 'no', 'id'],
  'name': ['item name', 'product name', 'description short'],
  'description': ['long description', 'details'],
  'item_type': ['type'],
  'barcode': ['ean', 'upc'],
  'uom_code': ['uom', 'unit', 'unit of measure'],
  'classification_code': ['classification', 'myinvois code'],
  'unit_price': ['price', 'selling price', 'sales price'],
  'cost_price': ['cost', 'purchase price'],
  'currency': ['ccy'],
  'track_inventory': ['stock', 'stocked', 'track stock'],
  'reorder_level': ['reorder', 'minimum stock'],
  'reorder_quantity': ['reorder qty'],
};

class _ImportScreenState extends ConsumerState<ImportScreen> {
  final _text = TextEditingController();

  bool _contacts = true;
  bool _busy = false;
  CsvTable? _table;
  List<Map<String, dynamic>>? _verdict;
  String? _failure;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Map<String, List<String>> get _aliases =>
      _contacts ? _contactAliases : _itemAliases;

  int get _errorCount =>
      (_verdict ?? const []).where((r) => r['status'] == 'error').length;

  Future<void> _run({required bool commit}) async {
    final table = parseCsvTable(_text.text, headerMapper(_aliases));
    setState(() {
      _table = table;
      _verdict = null;
      _failure = null;
    });
    if (table.isEmpty) return;

    setState(() => _busy = true);
    final repo = ref.read(repoProvider)!;
    try {
      final rows = await repo.importRows(
        contacts: _contacts,
        rows: table.rows,
        commit: commit,
      );
      setState(() => _verdict = rows);
      if (commit) {
        ref.invalidate(contactsProvider);
        ref.invalidate(itemsProvider);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Imported ${rows.length} '
                '${_contacts ? 'contacts' : 'items'}'),
          ));
        }
      }
    } catch (err) {
      // The database refuses the whole file when a row is wrong, and the
      // message says how many. Shown as it came rather than reduced to
      // "import failed".
      setState(() => _failure = '$err');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final table = _table;
    final canWrite = ref.watch(canWriteProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.sm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: true, label: Text('Contacts')),
                  ButtonSegment(value: false, label: Text('Items')),
                ],
                selected: {_contacts},
                onSelectionChanged: (s) => setState(() {
                  _contacts = s.first;
                  _table = null;
                  _verdict = null;
                  _failure = null;
                }),
              ),
            ),
          ),
        ),
      ),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 980,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SectionHeader(
                        _contacts ? 'Customers and suppliers' : 'Items',
                        subtitle: 'Paste the file with its header row. '
                            'Nothing is written until every row is good.',
                      ),
                      const SizedBox(height: Space.sm),
                      _Columns(aliases: _aliases, required: const ['code', 'name']),
                      const SizedBox(height: Space.md),
                      TextField(
                        controller: _text,
                        maxLines: 10,
                        minLines: 6,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          hintText: _contacts
                              ? 'code,name,contact_type,email\n'
                                  'C-001,Alpha Trading Sdn Bhd,customer,ap@alpha.com'
                              : 'code,name,unit_price,uom_code\n'
                                  'ITEM-1,Widget,12.50,C62',
                        ),
                      ),
                      const SizedBox(height: Space.md),
                      Row(children: [
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => _run(commit: false),
                          icon: const Icon(Icons.fact_check_outlined, size: 18),
                          label: const Text('Check it'),
                        ),
                        const SizedBox(width: Space.md),
                        FilledButton.icon(
                          // Only once it has been checked and come back
                          // clean: the import would refuse it anyway,
                          // and refusing it here says why sooner.
                          onPressed: _busy ||
                                  !canWrite ||
                                  _verdict == null ||
                                  _errorCount > 0
                              ? null
                              : () => _run(commit: true),
                          icon: const Icon(Icons.upload, size: 18),
                          label: const Text('Import'),
                        ),
                        const Spacer(),
                        if (_busy)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ]),
                    ],
                  ),
                ),
              ),
              if (table != null && table.problems.isNotEmpty) ...[
                const SizedBox(height: Space.lg),
                _Panel(
                  danger: true,
                  title: 'The file could not be read',
                  lines: table.problems,
                ),
              ],
              if (_failure != null) ...[
                const SizedBox(height: Space.lg),
                _Panel(danger: true, title: 'Nothing was imported',
                    lines: [_failure!]),
              ],
              if (_verdict != null) ...[
                const SizedBox(height: Space.lg),
                _Verdict(rows: _verdict!, errors: _errorCount),
              ],
              const SizedBox(height: Space.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the file may contain, so somebody can arrange their spreadsheet
/// before pasting rather than by trial and error.
class _Columns extends StatelessWidget {
  const _Columns({required this.aliases, required this.required});

  final Map<String, List<String>> aliases;
  final List<String> required;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final field in aliases.keys)
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text(field,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: required.contains(field)
                      ? FontWeight.w700
                      : FontWeight.w400,
                )),
            side: required.contains(field)
                ? BorderSide(color: context.colors.success)
                : null,
          ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.lines, this.danger = false});

  final String title;
  final List<String> lines;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colour = danger ? context.colors.danger : context.colors.success;
    return Container(
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          for (final l in lines)
            Text(l, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// The per-row answer. Errors first, because with a hundred rows and two
/// mistakes the two are what somebody came for.
class _Verdict extends StatelessWidget {
  const _Verdict({required this.rows, required this.errors});

  final List<Map<String, dynamic>> rows;
  final int errors;

  @override
  Widget build(BuildContext context) {
    final imported = rows.where((r) => r['status'] == 'imported').length;
    final bad = rows.where((r) => r['status'] == 'error').toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              imported > 0
                  ? 'Imported $imported rows'
                  : errors == 0
                      ? '${rows.length} rows, all of them fine'
                      : '$errors of ${rows.length} rows need fixing',
              subtitle: imported > 0
                  ? null
                  : errors == 0
                      ? 'Nothing has been written yet. Import writes them.'
                      : 'Nothing will be written until these are fixed.',
            ),
            if (bad.isNotEmpty)
              ...bad.map((r) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.error_outline,
                        size: 18, color: context.colors.danger),
                    title: Text(
                      'Row ${r['row_no']}'
                      '${(r['code'] as String?)?.isNotEmpty == true ? ' · ${r['code']}' : ''}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(r['message']?.toString() ?? ''),
                  )),
          ],
        ),
      ),
    );
  }
}
