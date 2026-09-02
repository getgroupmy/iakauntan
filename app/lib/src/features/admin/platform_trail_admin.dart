import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// What was changed about the platform itself, and by whom.
///
/// 0442 put an audit trigger on `statutory_schedules` and
/// `statutory_rates` — the EPF, SOCSO, EIS and PCB tables every
/// tenant's payroll is measured against — and widened the read policy so
/// a platform administrator could see the rows. It stopped there, and
/// the rows stayed unreachable: `audit_trail` takes an organization and
/// filters on it, so nothing anybody could type reached a row whose
/// `org_id` is null.
///
/// 0444 added the pair of functions this screen calls. The trail says
/// what the data did; the log below it says what the people did,
/// including the record of somebody opening this screen. Reading an
/// audit trail is itself an event, and a log that does not record who
/// read it is the one record an insider has no reason to avoid.
class PlatformTrailAdminTab extends ConsumerStatefulWidget {
  const PlatformTrailAdminTab({super.key});

  @override
  ConsumerState<PlatformTrailAdminTab> createState() =>
      _PlatformTrailAdminTabState();
}

class _PlatformTrailAdminTabState extends ConsumerState<PlatformTrailAdminTab> {
  /// Null is every table. The two on offer are the only two that can
  /// write here — since 0443 `app.write_audit_log` refuses to file a
  /// tenant's row without a tenant, so nothing else reaches this trail.
  String? _table;

  static const _tables = <String?, String>{
    null: 'Everything',
    'statutory_schedules': 'Rate tables',
    'statutory_rates': 'The rates in them',
  };

  @override
  Widget build(BuildContext context) {
    final trail = ref.watch(platformAuditTrailProvider(_table));
    final events = ref.watch(platformSecurityLogProvider);

    return ListView(
      padding: const EdgeInsets.all(Space.lg),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeader(
                  'What changed',
                  subtitle:
                      'Changes to the tables shared by every tenant. A '
                      'company’s own trail is not here and cannot be.',
                  action: IconButton(
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: 'Refresh',
                    onPressed: () =>
                        ref.invalidate(platformAuditTrailProvider(_table)),
                  ),
                ),
                Wrap(
                  spacing: Space.sm,
                  children: [
                    for (final entry in _tables.entries)
                      ChoiceChip(
                        label: Text(entry.value),
                        selected: _table == entry.key,
                        onSelected: (_) => setState(() => _table = entry.key),
                      ),
                  ],
                ),
                const SizedBox(height: Space.md),
                AsyncView<List<AuditEntry>>(
                  value: trail,
                  onRetry: () =>
                      ref.invalidate(platformAuditTrailProvider(_table)),
                  builder: (rows) {
                    if (rows.isEmpty) {
                      return const EmptyState(
                        icon: Icons.gavel_outlined,
                        title: 'Nothing has been changed here yet',
                        message:
                            'Publishing a rate table from the Statutory '
                            'rates tab writes the first row.',
                      );
                    }
                    return Column(
                      children: [
                        for (var i = 0; i < rows.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _TrailTile(entry: rows[i]),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Space.lg),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader(
                  'Who looked',
                  subtitle:
                      'Reads and refusals recorded against no company '
                      '— including this screen being opened.',
                ),
                AsyncView<List<SecurityEvent>>(
                  value: events,
                  onRetry: () => ref.invalidate(platformSecurityLogProvider),
                  builder: (rows) {
                    if (rows.isEmpty) {
                      return const EmptyState(
                        icon: Icons.visibility_outlined,
                        title: 'Nothing recorded yet',
                        message: 'Opening this screen writes the first row.',
                      );
                    }
                    return Column(
                      children: [
                        for (var i = 0; i < rows.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _EventTile(event: rows[i]),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One change. Deliberately plainer than the tenant trail's tile: these
/// rows are rate tables, so the interesting part is which body and from
/// when, not a field-by-field diff of a schedule nobody edits in place.
class _TrailTile extends StatelessWidget {
  const _TrailTile({required this.entry});

  final AuditEntry entry;

  static const _tableNames = <String, String>{
    'statutory_schedules': 'a rate table',
    'statutory_rates': 'a rate',
  };

  String get _verb => switch (entry.action) {
    'insert' => 'published',
    'delete' => 'withdrew',
    _ => 'changed',
  };

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant);
    final body = entry.after['body'] ?? entry.before['body'];
    final from =
        entry.after['effective_from'] ?? entry.before['effective_from'];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: entry.actor,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                TextSpan(text: ' $_verb '),
                TextSpan(
                  text:
                      _tableNames[entry.tableName] ??
                      Fmt.label(entry.tableName).toLowerCase(),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (body != null)
                  TextSpan(text: ' — ${body.toString().toUpperCase()}'),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            [
              Fmt.dateTime(entry.at),
              if (from != null) 'effective $from',
            ].join(' · '),
            style: muted,
          ),
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final SecurityEvent event;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        event.refused ? Icons.block_outlined : Icons.visibility_outlined,
        color: event.refused
            ? context.colors.danger
            : context.scheme.onSurfaceVariant,
      ),
      title: Text('${event.actor} — ${event.label}'),
      subtitle: Text(
        [
          Fmt.dateTime(event.at),
          if (event.target != null) event.target!,
          if (event.ipAddress != null) event.ipAddress!,
        ].join(' · '),
      ),
    );
  }
}
