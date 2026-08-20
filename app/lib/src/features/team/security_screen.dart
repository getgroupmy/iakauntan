import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'audit_trail_card.dart';

/// The screen an auditor is handed.
///
/// It answers four questions the change history cannot, because none of
/// them is a row changing: who signed in and from where, who took a copy
/// of something out, who looked at the logs, and who was told no. The
/// change history is here too, at the bottom, because "what happened in
/// this company" is one question and splitting it across two screens
/// makes it two.
///
/// Owners and admins only, and the server agrees rather than being asked
/// nicely: `security_log` and `audit_trail` both refuse anybody else, so
/// the gate below is a courtesy that saves a round trip.
class SecurityScreen extends ConsumerStatefulWidget {
  const SecurityScreen({super.key});

  @override
  ConsumerState<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends ConsumerState<SecurityScreen> {
  /// Null is everything. The values are the `app.security_event` labels,
  /// not display text, because they go to the server.
  String? _kind;

  static const _kinds = <String?, String>{
    null: 'Everything',
    'sign_in': 'Sign-ins',
    'export': 'Exports',
    'sensitive_read': 'Reads',
    'denied': 'Refusals',
  };

  @override
  Widget build(BuildContext context) {
    final canAdmin = ref.watch(canAdminProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Security'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () {
              ref.invalidate(securitySummaryProvider);
              ref.invalidate(securityLogProvider);
              ref.invalidate(auditTrailProvider);
            },
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: !canAdmin
          ? const EmptyState(
              icon: Icons.lock_outline,
              title: 'Only an owner or an admin',
              message: 'The security log says where every colleague works '
                  'from, so it is not open to the whole company.',
            )
          : SingleChildScrollView(
              child: PageBody(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Summary(),
                    const SizedBox(height: 20),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(Space.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SectionHeader(
                              'Who got in, and what they took',
                              subtitle: 'Sign-ins come from the session the '
                                  'database opened, so nothing can skip '
                                  'them. Refusals are reported by the app '
                                  'and are the one line here that is a hint '
                                  'rather than a record.',
                            ),
                            Wrap(
                              spacing: 8,
                              children: [
                                for (final e in _kinds.entries)
                                  ChoiceChip(
                                    label: Text(e.value),
                                    selected: _kind == e.key,
                                    onSelected: (_) =>
                                        setState(() => _kind = e.key),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _EventList(kind: _kind),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const AuditTrailCard(),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
    );
  }
}

class _Summary extends ConsumerWidget {
  const _Summary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(securitySummaryProvider).valueOrNull ?? const {};
    int n(String key) => Fmt.toDouble(summary[key]).round();

    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 1100 ? 4 : (width >= 700 ? 2 : 1);
    final failed = n('failed_sign_ins');

    return GridView.count(
      crossAxisCount: columns,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: columns == 1 ? 3.2 : 1.75,
      children: [
        StatTile(
          label: 'Sign-ins',
          value: '${n('sign_ins')}',
          caption: '${n('people')} people, ${n('addresses')} addresses',
          icon: Icons.login,
          accent: context.colors.info,
        ),
        StatTile(
          label: 'Refused sign-ins',
          value: '$failed',
          caption: failed > 0
              ? 'Somebody could not get in'
              : 'Nobody was turned away',
          icon: Icons.gpp_maybe_outlined,
          accent: failed > 0 ? context.colors.danger : null,
        ),
        StatTile(
          label: 'Copies taken out',
          value: '${n('exports')}',
          caption: '${n('reads')} looks at a log',
          icon: Icons.download_outlined,
          accent: context.colors.warning,
        ),
        StatTile(
          label: 'Changes recorded',
          value: '${n('changes')}',
          caption: '${n('denials')} refusals reported',
          icon: Icons.edit_note,
        ),
      ],
    );
  }
}

class _EventList extends ConsumerWidget {
  const _EventList({required this.kind});

  final String? kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(securityLogProvider(kind));

    return AsyncView(
      value: events,
      onRetry: () => ref.invalidate(securityLogProvider(kind)),
      loading: const LinearProgressIndicator(),
      builder: (list) {
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.shield_outlined,
            title: 'Nothing recorded yet',
            message: 'Sign-ins, exports and refusals appear here as they '
                'happen.',
          );
        }
        return Column(
          children: [for (final e in list) _EventTile(event: e)],
        );
      },
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final SecurityEvent event;

  IconData get _icon => switch (event.kind) {
    'sign_in' => event.refused ? Icons.gpp_bad_outlined : Icons.login,
    'session_ended' => Icons.logout,
    'export' => Icons.download_outlined,
    'sensitive_read' => Icons.visibility_outlined,
    'denied' => Icons.block,
    _ => Icons.circle_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (event.target != null && event.target!.isNotEmpty) event.target!,
      if (event.detail != null && event.detail!.isNotEmpty) event.detail!,
      if (event.ipAddress != null) 'from ${event.ipAddress}',
    ].join(' · ');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        _icon,
        size: 18,
        color: event.refused ? context.colors.danger : null,
      ),
      title: Text('${event.label} · ${event.actor}'),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Text(
        Fmt.dateTime(event.at),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
