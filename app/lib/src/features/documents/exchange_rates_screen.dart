import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// What rate the ledger would apply today, and where it came from.
///
/// The question this answers is not "what are rates doing" — nobody runs
/// an accounting system for that. It is "why will this euro invoice not
/// post?", and the answer is on the row with nothing in it. Posting
/// refuses a currency it cannot price rather than assuming par, so a
/// missing rate is a hard stop and worth seeing before month end rather
/// than during it.
///
/// A rate somebody typed and a rate Bank Negara published are shown as
/// the different things they are. The typed one wins for its own date
/// and can be overwritten here; the published one cannot be touched from
/// the app at all.
class ExchangeRatesScreen extends ConsumerStatefulWidget {
  const ExchangeRatesScreen({super.key});

  @override
  ConsumerState<ExchangeRatesScreen> createState() =>
      _ExchangeRatesScreenState();
}

class _ExchangeRatesScreenState extends ConsumerState<ExchangeRatesScreen> {
  DateTime _asAt = DateTime.now();
  Future<List<Map<String, dynamic>>>? _board;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() {
      _board = repo.exchangeRateBoard(_asAt);
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _asAt,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      _asAt = picked;
      _reload();
    }
  }

  Future<void> _type(Map<String, dynamic> row) async {
    final code = row['currency'] as String;
    final base = ref.read(currentOrgProvider).valueOrNull?.baseCurrency ?? 'MYR';
    final entered = await showDialog<double>(
      context: context,
      builder: (_) => _RateDialog(
        currency: code,
        base: base,
        date: _asAt,
        initial: row['rate'] == null ? null : Fmt.toDouble(row['rate']),
      ),
    );
    if (entered == null || !mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveExchangeRate(
            from: code,
            to: base,
            rate: entered,
            date: _asAt,
          ),
      successMessage: 'Rate for $code saved for ${Fmt.date(_asAt)}',
      pendingMessage: 'Saving rate…',
    );
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final canWrite = ref.watch(canWriteProvider);
    final base = ref.watch(currentOrgProvider).valueOrNull?.baseCurrency ?? 'MYR';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Exchange rates'),
        actions: [
          TextButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Text('As at ${Fmt.date(_asAt)}'),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: Space.sm),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _board,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('${snap.error}'));
          }
          final rows = snap.data ?? const [];
          final missing = rows.where((r) => r['rate'] == null).length;

          return SingleChildScrollView(
            child: PageBody(
              maxWidth: 860,
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
                            'One $base buys',
                            subtitle: missing == 0
                                ? 'Every currency has a rate on ${Fmt.date(_asAt)}.'
                                : '$missing ${missing == 1 ? 'currency has' : 'currencies have'} '
                                    'no rate on ${Fmt.date(_asAt)}. A document in '
                                    '${missing == 1 ? 'it' : 'one of them'} will not post.',
                          ),
                          const SizedBox(height: Space.sm),
                          for (final r in rows)
                            _Row(
                              row: r,
                              base: base,
                              onType: canWrite ? () => _type(r) : null,
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.lg),
                  const _Provenance(),
                  const SizedBox(height: Space.xxl),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row, required this.base, this.onType});

  final Map<String, dynamic> row;
  final String base;
  final VoidCallback? onType;

  @override
  Widget build(BuildContext context) {
    final code = row['currency'] as String;
    final raw = row['rate'];
    final rate = raw == null ? null : Fmt.toDouble(raw);
    final isOwn = row['is_own'] == true;
    final source = row['source'] as String?;
    final on = row['rate_date'];

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Row(children: [
        SizedBox(
          width: 56,
          child: Text(code,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontFamily: 'monospace')),
        ),
        Expanded(child: Text(row['name']?.toString() ?? '')),
        if (rate == null)
          Text('no rate',
              style: TextStyle(
                  color: context.colors.danger, fontWeight: FontWeight.w600))
        else
          Text('1 $code = ${Fmt.rate(rate)} $base',
              style: const TextStyle(fontWeight: FontWeight.w600)),
      ]),
      subtitle: rate == null
          ? const Text('Nothing on file. Enter one, or wait for the feed.')
          : Text(isOwn
              ? 'Entered here · ${Fmt.date(DateTime.parse(on.toString()))}'
              : '${source == 'bnm' ? 'Bank Negara Malaysia' : 'Published'} '
                  '· ${Fmt.date(DateTime.parse(on.toString()))}'),
      trailing: onType == null
          ? null
          : TextButton(
              onPressed: onType,
              child: Text(isOwn ? 'Change' : 'Override'),
            ),
    );
  }
}

/// Said once, on the screen, rather than left for somebody to work out
/// from two rows that disagree.
class _Provenance extends StatelessWidget {
  const _Provenance();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Which rate the ledger uses',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'The most recent rate on or before the document date. Where a '
            'rate you entered and a published one share a date, yours is '
            'used — so an override sticks for its day without freezing '
            'every day after it. Published rates arrive overnight and are '
            'never altered by anything in this app.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _RateDialog extends StatefulWidget {
  const _RateDialog({
    required this.currency,
    required this.base,
    required this.date,
    this.initial,
  });

  final String currency;
  final String base;
  final DateTime date;
  final double? initial;

  @override
  State<_RateDialog> createState() => _RateDialogState();
}

class _RateDialogState extends State<_RateDialog> {
  late final TextEditingController _c =
      TextEditingController(text: widget.initial == null ? '' : Fmt.rate(widget.initial!));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parsed = double.tryParse(_c.text.trim());
    return AlertDialog(
      title: Text('${widget.currency} on ${Fmt.date(widget.date)}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _c,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'One ${widget.currency} in ${widget.base}',
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Space.sm),
          Text(
            'Applies to this date only. Later dates keep using whatever '
            'is most recent, published or entered.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: parsed == null || parsed <= 0
              ? null
              : () => Navigator.pop(context, parsed),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
