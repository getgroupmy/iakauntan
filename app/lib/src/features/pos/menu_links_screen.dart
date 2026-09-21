import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/safe_link.dart';
import '../../core/skeletons.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// The address a published menu lives at.
///
/// Pure and exported so the list, the copy button and the tests all
/// produce the same string. The token is the whole credential, so the
/// URL is the whole of what a shop has to print.
String menuLinkUrl(String origin, String token) =>
    '$origin/#/menu/${Uri.encodeComponent(token)}';

/// What a published link is for, in the words a shop uses.
String menuLinkKind(Map<String, dynamic> row) {
  final table = '${row['table_code'] ?? ''}';
  return switch ('${row['kind']}') {
    'table' => table.isEmpty ? 'A table' : 'Table $table',
    'delivery' => 'Delivery',
    _ => 'Takeaway',
  };
}

/// Why a link is not working, or null when it is.
///
/// A sticker that has quietly stopped working is found by a customer
/// holding a phone, so the list says which of the three reasons it is.
String? menuLinkDead(Map<String, dynamic> row, DateTime now) {
  if (row['is_active'] != true) return 'Switched off';
  final expires = row['expires_at'];
  if (expires != null && DateTime.parse('$expires').isBefore(now)) {
    return 'Expired';
  }
  if (row['single_use'] == true && row['used_at'] != null) return 'Used';
  return null;
}

/// Publishing the menu: a QR for each table, a poster by the door, a
/// link to text somebody.
class MenuLinksScreen extends ConsumerWidget {
  const MenuLinksScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final outlets = await ref.read(posOutletsProvider.future);
    if (!context.mounted || outlets.isEmpty) return;
    final outlet = outlets.first['id'] as String;
    final tables = await ref.read(posFloorPlanProvider(outlet).future);
    if (!context.mounted) return;

    final answer = await showModalBottomSheet<({String kind, String? table, String label})>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Publish a menu')),
            const Divider(height: 1),
            for (final t in tables)
              ListTile(
                dense: true,
                leading: const Icon(Icons.table_restaurant_outlined, size: 18),
                title: Text('Table ${t['code']}'),
                onTap: () => Navigator.of(ctx).pop((
                  kind: 'table',
                  table: t['id'] as String?,
                  label: 'Table ${t['code']}',
                )),
              ),
            ListTile(
              leading: const Icon(Icons.shopping_bag_outlined),
              title: const Text('Takeaway'),
              subtitle: const Text('A poster by the door'),
              onTap: () => Navigator.of(
                ctx,
              ).pop((kind: 'takeaway', table: null, label: 'Takeaway')),
            ),
            ListTile(
              leading: const Icon(Icons.moped_outlined),
              title: const Text('Delivery'),
              subtitle: const Text('Asks for an address'),
              onTap: () => Navigator.of(
                ctx,
              ).pop((kind: 'delivery', table: null, label: 'Delivery')),
            ),
          ],
        ),
      ),
    );
    if (answer == null || !context.mounted) return;

    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Published',
      action: () => repo.savePosMenuLink(
        outletId: outlet,
        kind: answer.kind,
        tableId: answer.table,
        label: answer.label,
      ),
    );
    if (ok && context.mounted) ref.invalidate(posMenuLinksProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final links = ref.watch(posMenuLinksProvider);
    final now = DateTime.now();

    return Scaffold(
      appBar: AppBar(title: const Text('Published menus')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context, ref),
        icon: const Icon(Icons.qr_code_2),
        label: const Text('Publish'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: links,
        onRetry: () => ref.invalidate(posMenuLinksProvider),
        skeleton: const ListSkeleton(rows: 6),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.qr_code_2,
              title: 'Nothing published',
              message: 'Publish a menu and print the link as a QR: a sticker '
                  'on each table, a poster by the door, or a one-time link '
                  'to text somebody.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final l = rows[i];
              final dead = menuLinkDead(l, now);
              final url = menuLinkUrl(shareOrigin(), '${l['token']}');
              return ListTile(
                isThreeLine: true,
                leading: const Icon(Icons.qr_code_2),
                title: Text(
                  [
                    menuLinkKind(l),
                    if ('${l['label'] ?? ''}'.isNotEmpty) '${l['label']}',
                  ].join(' · '),
                  style: dead == null
                      ? null
                      : const TextStyle(
                          decoration: TextDecoration.lineThrough,
                        ),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      [
                        if (dead != null) dead,
                        '${l['outlet_name']}',
                        '${Fmt.toInt(l['orders'])} order(s)',
                      ].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (choice) async {
                    if (choice == 'copy') {
                      await Clipboard.setData(ClipboardData(text: url));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copied')),
                        );
                      }
                      return;
                    }
                    final repo = ref.read(repoProvider);
                    if (repo == null || !context.mounted) return;
                    final ok = await runWithFeedback(
                      context,
                      successMessage: 'Switched off',
                      action: () => repo.retirePosMenuLink(l['id'] as String),
                    );
                    if (ok && context.mounted) {
                      ref.invalidate(posMenuLinksProvider);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'copy',
                      child: Text('Copy the link'),
                    ),
                    if (l['is_active'] == true)
                      const PopupMenuItem(
                        value: 'retire',
                        child: Text('Switch it off'),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
