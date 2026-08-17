import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'rule_editor.dart';

/// The approvals screen: what is waiting on you, and what the company
/// has decided needs signing.
///
/// Two tabs because they are two jobs done by two people. The inbox is
/// daily and belongs to whoever signs; the rules are policy, set once by
/// an administrator, and the tab is hidden from everybody else — not for
/// secrecy, but because a control somebody cannot use is a control that
/// teaches them to ignore controls.
class ApprovalsScreen extends ConsumerWidget {
  const ApprovalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canAdmin = ref.watch(canAdminProvider);

    return DefaultTabController(
      length: canAdmin ? 2 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Approvals'),
          bottom: TabBar(
            tabs: [
              const Tab(text: 'My inbox'),
              if (canAdmin) const Tab(text: 'Rules'),
            ],
          ),
        ),
        body: TabBarView(
          children: [const _InboxTab(), if (canAdmin) const _RulesTab()],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// The inbox
// ---------------------------------------------------------------------

class _InboxTab extends ConsumerWidget {
  const _InboxTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(myApprovalsProvider);

    return AsyncView(
      value: inbox,
      onRetry: () => ref.invalidate(myApprovalsProvider),
      builder: (list) {
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.done_all,
            title: 'Nothing to approve',
            message: 'Documents needing your signature will appear here.',
          );
        }
        return ListView.separated(
          itemCount: list.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) => _RequestTile(row: list[i]),
        );
      },
    );
  }
}

class _RequestTile extends ConsumerWidget {
  const _RequestTile({required this.row});

  final Map<String, dynamic> row;

  /// Where the document itself lives. Journals have a list but no
  /// per-entry route, so they go to the list.
  String? _route() {
    final id = row['entity_id'] as String?;
    final type = row['doc_type'] as String?;
    if (id == null) return null;
    return switch (row['entity_kind']) {
      'sales_document' when type != null => '/sales/$type/$id',
      'purchase_document' when type != null => '/purchases/$type/$id',
      'journal' => '/journals',
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requested = Fmt.parseDate(row['requested_at']);
    final route = _route();

    return ListTile(
      leading: Icon(switch (row['entity_kind']) {
        'sales_document' => Icons.receipt_long_outlined,
        'purchase_document' => Icons.shopping_bag_outlined,
        _ => Icons.menu_book_outlined,
      }),
      title: Text(
        row['doc_no']?.toString() ?? 'Document',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          'Raised by ${row['requested_by_name'] ?? 'someone'}',
          if (requested != null) Fmt.date(requested),
          'step ${row['step_no']}',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Money(row['amount'] as num?, bold: true),
          const SizedBox(width: Space.sm),
          IconButton(
            tooltip: 'Reject',
            icon: Icon(Icons.close, color: context.colors.danger),
            onPressed: () => _decide(context, ref, approve: false),
          ),
          IconButton(
            tooltip: 'Approve',
            icon: Icon(Icons.check, color: context.colors.success),
            onPressed: () => _decide(context, ref, approve: true),
          ),
        ],
      ),
      onTap: route == null ? null : () => context.go(route),
    );
  }

  Future<void> _decide(
    BuildContext context,
    WidgetRef ref, {
    required bool approve,
  }) async {
    // A rejection ends the whole request — every remaining step falls
    // with it — so it asks for a reason. An approval does not: making
    // somebody type "ok" to sign off forty invoices produces forty notes
    // saying "ok".
    String? note;
    if (!approve) {
      note = await showDialog<String>(
        context: context,
        builder: (_) => _RejectDialog(docNo: row['doc_no']?.toString()),
      );
      if (note == null || !context.mounted) return;
    }

    // The result is the state of the *request*, not of the step just
    // decided, and the two differ on every chain longer than one. Saying
    // "Approved" while a second signature is still outstanding is how a
    // document gets left half-signed by somebody who thought they had
    // finished with it, so the message is chosen from what came back
    // rather than from what was pressed.
    String? outcome;
    final ok = await runWithFeedback(
      context,
      action: () async {
        outcome = await ref
            .read(repoProvider)!
            .decideApproval(
              row['request_id'] as String,
              approve: approve,
              note: note,
            );
      },
      successMessage: null,
    );

    ref.invalidate(myApprovalsProvider);
    if (!ok || !context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(switch (outcome) {
          'approved' => 'Approved — it can be posted now',
          'rejected' => 'Rejected',
          _ => 'Signed. Still waiting on the next approver.',
        }),
      ),
    );
  }
}

/// Why a rejection asks and an approval does not: the note is the only
/// thing the person who raised the document gets to read.
class _RejectDialog extends StatefulWidget {
  const _RejectDialog({this.docNo});

  final String? docNo;

  @override
  State<_RejectDialog> createState() => _RejectDialogState();
}

class _RejectDialogState extends State<_RejectDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Reject ${widget.docNo ?? 'this document'}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This ends the request. It can be sent round again once the '
            'document has been fixed.',
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Reason',
              hintText: 'What needs changing?',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: context.colors.danger),
          // An empty reason is still a reason to send it back; the field
          // is a courtesy, not a gate.
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Reject'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// The rules
// ---------------------------------------------------------------------

class _RulesTab extends ConsumerWidget {
  const _RulesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(approvalRulesProvider);

    return Scaffold(
      body: AsyncView(
        value: rules,
        onRetry: () => ref.invalidate(approvalRulesProvider),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.rule_outlined,
              title: 'Nothing needs approving',
              message:
                  'Until a rule is written here, every document posts '
                  'the way it does today. Add one to require a signature '
                  'above an amount.',
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) => _RuleTile(rule: list[i]),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showApprovalRuleEditor(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Rule'),
      ),
    );
  }
}

class _RuleTile extends ConsumerWidget {
  const _RuleTile({required this.rule});

  final Map<String, dynamic> rule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = rule['is_active'] != false;
    final min = rule['min_amount'] as num? ?? 0;
    final team = ref.watch(teamProvider).valueOrNull ?? const [];
    final named = rule['approver_user_id'] as String?;

    final approver = named == null
        ? roleLabel(rule['approver_role'] as String?)
        : team
                  .where((m) => m.userId == named)
                  .map((m) => m.displayName)
                  .firstOrNull ??
              'a named person';

    return ListTile(
      leading: CircleAvatar(
        radius: 14,
        child: Text('${rule['step_no']}', style: const TextStyle(fontSize: 12)),
      ),
      title: Text(
        approvalEntityLabel(rule['entity_kind'] as String?, rule['doc_type']),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          decoration: active ? null : TextDecoration.lineThrough,
        ),
      ),
      subtitle: Text(
        min > 0
            ? '${Fmt.money(min)} and above · $approver'
            : 'Every one · $approver',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: IconButton(
        tooltip: 'Delete',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _delete(context, ref),
      ),
      onTap: () => showApprovalRuleEditor(context, ref, rule: rule),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Delete this rule?',
      message:
          'Documents already sent for approval keep the chain they '
          'were given. New ones will not need this signature.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.deleteApprovalRule(rule['id'] as String),
      successMessage: 'Deleted',
    );
    ref.invalidate(approvalRulesProvider);
  }
}
