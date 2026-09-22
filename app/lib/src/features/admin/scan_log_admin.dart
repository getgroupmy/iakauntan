import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/ocr_repository.dart';

/// Every scan the platform has run, and why the failed ones failed.
///
/// ## The screen this replaces was a SQL prompt
///
/// A scan that fails shows the person scanning:
///
///     The document could not be read. Quote this reference if you get
///     in touch. {ref: e5b6506c-…, scan_id: 6e50da40-…}
///
/// It is right to be vague. `0111` keeps the vendor's own message out
/// of the response because a Document AI failure quotes the project,
/// the processor and sometimes the page it choked on. The real reason
/// goes to `ocr_scans.error`.
///
/// And nothing read `ocr_scans`. Not the console, not Settings, not
/// the screen the scan was started from — `grep -rn ocr_scans app/lib`
/// returned nothing at all. So "get in touch" resolved to hand-written
/// SQL against production, run by the same person who was being told
/// to get in touch.
///
/// ## Both identifiers, because nobody should have to know which
///
/// That banner carries two uuids and, until `0680`, only one of them
/// could ever be looked up — and it was not the one labelled
/// "reference". `logFailure` minted `ref` after the scan had been
/// settled and wrote it to the function's stdout. It is stored now,
/// and the search box takes either.
///
/// ## The number that is not a failure
///
/// `Unsettled` counts scans still `pending` an hour after they
/// started: the function died between `ocr_begin` and `ocr_finish`, so
/// the charge was taken and the refund never ran. It is called out
/// separately because it does not look like anything — the status says
/// `pending`, which reads as "still going" for ever, and nobody goes
/// looking for a row that claims to be in progress.
class ScanLogAdminTab extends ConsumerStatefulWidget {
  const ScanLogAdminTab({super.key});

  @override
  ConsumerState<ScanLogAdminTab> createState() => _ScanLogAdminTabState();
}

class _ScanLogAdminTabState extends ConsumerState<ScanLogAdminTab> {
  final _search = TextEditingController();
  String? _status = 'failed';
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final health = ref.watch(scanHealthProvider);
    final log = ref.watch(
      scanLogProvider((
        status: _query.isNotEmpty ? null : _status,
        search: _query.isEmpty ? null : _query,
      )),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Health(health: health.value ?? ScanHealth.none),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('scan-log-search'),
                controller: _search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  labelText: 'Reference or scan id',
                  // Said, because the message somebody is quoting from
                  // carries two of them and calls only one a
                  // "reference".
                  helperText: 'Either one off the message they were '
                      'shown. The first few characters are enough.',
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
                onSubmitted: (v) => setState(() => _query = v.trim()),
              ),
              const SizedBox(height: Space.sm),
              // Hidden while searching: somebody who has pasted a
              // reference wants THAT scan, and a status filter that
              // silently excluded it would be the screen refusing to
              // answer the question it was opened for.
              if (_query.isEmpty)
                SegmentedButton<String?>(
                  key: const ValueKey('scan-log-status'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'failed', label: Text('Failed')),
                    ButtonSegment(value: 'pending', label: Text('Pending')),
                    ButtonSegment(value: 'ok', label: Text('Read')),
                    ButtonSegment(value: null, label: Text('All')),
                  ],
                  selected: {_status},
                  onSelectionChanged: (s) =>
                      setState(() => _status = s.first),
                )
              else
                Text(
                  'Showing every status, because you are looking for one '
                  'scan rather than for a pattern.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: AsyncView<List<ScanLogEntry>>(
            value: log,
            onRetry: () => ref.invalidate(scanLogProvider),
            skeleton: const ListSkeleton(rows: 6, leading: false),
            builder: (rows) {
              if (rows.isEmpty) {
                return EmptyState(
                  icon: Icons.inbox_outlined,
                  title: _query.isNotEmpty
                      ? 'Nothing matches that'
                      : 'Nothing here',
                  message: _query.isNotEmpty
                      ? 'A failure from before the reference was stored '
                            'can only be found by its scan id — try that '
                            'one instead.'
                      : 'No scan in this state. Scanning may simply be '
                            'quiet.',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.only(bottom: Space.lg),
                itemCount: rows.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => _ScanRow(scan: rows[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The three numbers, and the one of them that is money.
class _Health extends StatelessWidget {
  const _Health({required this.health});

  final ScanHealth health;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Space.md,
      runSpacing: Space.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _Stat(label: 'Read today', value: '${health.ok24h}'),
        _Stat(
          label: 'Failed today',
          value: '${health.failed24h}',
          warn: health.failed24h > 0,
        ),
        // Not "pending". A scan an hour old is not in progress, and
        // calling it that is how this went uncounted.
        _Stat(
          key: const ValueKey('scan-log-unsettled'),
          label: health.unsettledCharged > 0
              ? 'Never settled — ${Fmt.money(health.unsettledCharged)} '
                    'taken and not refunded'
              : 'Never settled',
          value: '${health.unsettled}',
          warn: health.unsettled > 0,
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    super.key,
    required this.label,
    required this.value,
    this.warn = false,
  });

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final colour = warn ? context.colors.warning : context.scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: colour,
            ),
          ),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class _ScanRow extends StatelessWidget {
  const _ScanRow({required this.scan});

  final ScanLogEntry scan;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      isThreeLine: scan.error != null,
      // A Wrap and not a Row: the company's name, a status chip and
      // "RM 0.30 not refunded" do not fit across a phone, and the
      // third of them is the one that would have gone off the edge.
      title: Wrap(
        spacing: Space.sm,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(scan.orgName),
          StatusChip(
            scan.unsettled ? 'never settled' : scan.status,
            compact: true,
          ),
          // The combination nobody finds on their own, said on the row
          // rather than only in the count above.
          if (scan.owed)
            Text(
              '${Fmt.money(scan.charged)} not refunded',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.colors.danger,
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              scan.providerName,
              // Whose key ran it decides whose problem it is: ours to
              // fix, or a conversation with the company.
              switch (scan.keySource) {
                'own' => 'their own key',
                'device' => 'on the device',
                _ => "the platform's key",
              },
              if (scan.fellBackTo != null) 'fell back to ${scan.fellBackTo}',
              if (scan.fileName != null) scan.fileName!,
              Fmt.dateTime(scan.createdAt),
            ].join(' · '),
            style: const TextStyle(fontSize: 12),
          ),
          if (scan.error != null) ...[
            const SizedBox(height: 4),
            // The whole point of the screen. Not truncated to one
            // line: the useful part of a vendor's refusal is usually
            // at the end of it.
            Text(
              scan.error!,
              style: TextStyle(fontSize: 12, color: context.colors.danger),
            ),
          ],
        ],
      ),
      trailing: IconButton(
        tooltip: 'Copy the scan id',
        icon: const Icon(Icons.copy_all_outlined, size: 18),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: scan.id));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Scan id copied')),
          );
        },
      ),
    );
  }
}
