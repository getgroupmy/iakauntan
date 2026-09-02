import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../shared/scan_intake.dart';
import 'contact_editor.dart';
import 'convert_contact.dart';

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key, this.initialType});

  /// Which tab to open on. The sidebar has an entry per kind of contact
  /// as well as All Contacts, and they are all this screen — a separate
  /// list widget per type would be three copies of the same search box
  /// drifting apart.
  final String? initialType;

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  final _search = TextEditingController();
  late String _type = widget.initialType ?? 'customer';
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contacts =
        ref.watch(contactsProvider((type: _type, search: _query)));
    final canWrite = ref.watch(canWriteProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          // From the paper, which is how a customer or supplier
          // actually arrives: a letterhead on an invoice, a name card
          // at a meeting. Typing a company's registration number off a
          // card is the part people get wrong.
          if (canWrite)
            IconButton(
              tooltip: 'Scan a letterhead or name card',
              icon: const Icon(Icons.document_scanner_outlined),
              onPressed: () => _scanContact(context, ref, _type),
            ),
          if (canWrite)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: () => context.go('/contacts/new?type=$_type'),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New'),
              ),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: 'Search name, code or email',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _search.clear();
                                setState(() => _query = '');
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'customer', label: Text('Customers')),
                    ButtonSegment(value: 'supplier', label: Text('Suppliers')),
                    ButtonSegment(value: 'prospect', label: Text('Prospects')),
                    ButtonSegment(value: 'all', label: Text('All')),
                  ],
                  selected: {_type},
                  onSelectionChanged: (s) => setState(() => _type = s.first),
                ),
              ],
            ),
          ),
        ),
      ),
      body: AsyncView(
        value: contacts,
        onRetry: () => ref.invalidate(contactsProvider),
        builder: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.people_outline,
              title: _query.isEmpty ? 'No contacts yet' : 'No matches',
              message: _query.isEmpty
                  ? 'Add the customers and suppliers you trade with.'
                  : 'Try a different search term.',
              action: canWrite && _query.isEmpty
                  ? FilledButton.icon(
                      onPressed: () => context.go('/contacts/new?type=$_type'),
                      icon: const Icon(Icons.add),
                      label: const Text('Add contact'),
                    )
                  : null,
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
            itemBuilder: (context, i) => _ContactTile(contact: list[i]),
          );
        },
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact});

  final Contact contact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      onTap: () => context.go('/contacts/${contact.id}'),
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Text(
          Fmt.initials(contact.name),
          style: TextStyle(
            color: scheme.onPrimaryContainer,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              contact.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          if (contact.isTinVerified) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'TIN verified with LHDN',
              child: Icon(Icons.verified, size: 15, color: context.colors.success),
            ),
          ],
        ],
      ),
      subtitle: Text(
        [
          contact.code,
          if ((contact.tin ?? '').isNotEmpty) 'TIN ${contact.tin}',
          if ((contact.email ?? '').isNotEmpty) contact.email!,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!contact.readyForEinvoice)
            Tooltip(
              message: 'Missing TIN or registration number for e-Invoice',
              child: Icon(Icons.warning_amber_rounded,
                  size: 18, color: context.colors.warning),
            ),
          const SizedBox(width: 8),
          // The chip is the type, so the way to change the type is on
          // the chip. Tapping it opens the sheet; tapping anywhere else
          // on the row still opens the contact.
          InkWell(
            key: ValueKey('convert-${contact.id}'),
            borderRadius: BorderRadius.circular(20),
            onTap: () => showConvertContact(context, contact.id),
            child: Tooltip(
              message: 'Change what this contact is',
              child: StatusChip(contact.contactType, compact: true),
            ),
          ),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
    );
  }
}

/// A customer or supplier read off the paper they arrived on.
///
/// The same reader the bills go through. It was written for a purchase
/// document and a letterhead is most of one — a name, a registration
/// number, a tax number, an address, a telephone — so nothing new is
/// needed to read a name card or the top of an invoice.
///
/// What comes back opens the ordinary editor with those fields filled,
/// rather than saving anything: a contact is checked before it is
/// created, because a duplicate customer is a mistake that surfaces
/// months later in an aged listing.
Future<void> _scanContact(
  BuildContext context,
  WidgetRef ref,
  String type,
) async {
  final staged = await showScanIntake(
    context,
    ref,
    // Parked against `contacts` until the contact it belongs to exists.
    table: 'contacts',
    title: 'Scan a letterhead or name card',
  );
  if (staged?.read == null || !context.mounted) return;

  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ContactEditor(contactType: type, scanned: staged!.read),
    ),
  );
}
