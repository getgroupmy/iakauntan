import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/ocr_repository.dart';

/// Where a bank statement comes in. `0710`-era; asked for by name.
///
/// Importing one has worked for a long time and nothing said so. It was
/// an icon on the Reconcile screen — `upload_file_outlined`, no label,
/// disabled until an account was picked — and a person who had never
/// found it had no way to know the product could take a statement at
/// all.
///
/// This is the front door, under General Ledger where somebody looks
/// for it. It does NOT import anything itself: the parse, the balance
/// chain, the duplicate skip and the closing balance all live on the
/// Reconcile screen and work, and a second copy of that would be a
/// second set of answers to drift. What this does is show the accounts,
/// show what has already been read, and open the thing that does the
/// work with the account already chosen.
class BankStatementsScreen extends ConsumerWidget {
  const BankStatementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(bankAccountsProvider);
    final canPost = ref.watch(canPostProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Bank statements')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(bankAccountsProvider);
          ref.invalidate(scanInboxProvider);
        },
        child: ListView(
          padding: const EdgeInsets.all(Space.lg),
          children: [
            Text(
              'Upload a statement and its lines are matched against what '
              'is already in the books. CSV and MT940 from online '
              'banking, or a photograph or PDF, which AI SmartScan '
              'reads.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: Space.lg),

            const SectionHeader('Accounts'),
            AsyncView<List<Map<String, dynamic>>>(
              value: accounts,
              onRetry: () => ref.invalidate(bankAccountsProvider),
              skeleton: const ListSkeleton(rows: 3),
              builder: (rows) {
                if (rows.isEmpty) {
                  return const EmptyState(
                    icon: Icons.account_balance_outlined,
                    title: 'No bank account yet',
                    message: 'Add one on the chart of accounts, and its '
                        'statements can be brought in here.',
                  );
                }
                return Column(
                  children: [
                    for (final a in rows)
                      _AccountTile(account: a, canPost: canPost),
                  ],
                );
              },
            ),

            const SizedBox(height: Space.lg),
            const SectionHeader('Statements read'),
            const _Read(),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.account, required this.canPost});

  final Map<String, dynamic> account;
  final bool canPost;

  @override
  Widget build(BuildContext context) {
    final id = account['id']?.toString() ?? '';
    final name = account['name']?.toString() ?? 'Bank account';
    final bank = account['bank_name']?.toString() ?? '';
    final last4 = account['account_number']?.toString() ?? '';
    final balance = Fmt.toDouble(account['current_balance']);

    return Card(
      child: ListTile(
        key: ValueKey('bank-statement-account-$id'),
        leading: const Icon(Icons.account_balance_outlined),
        title: Text(name),
        subtitle: Text(
          [
            if (bank.isNotEmpty) bank,
            if (last4.isNotEmpty) last4,
            'book balance ${Fmt.money(balance)}',
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        // The import itself is on Reconcile, with the account already
        // chosen. Hidden rather than disabled for somebody who cannot
        // post: a greyed button is a question the screen will not
        // answer.
        trailing: canPost
            ? FilledButton.icon(
                key: ValueKey('bank-statement-upload-$id'),
                icon: const Icon(Icons.upload_file_outlined, size: 18),
                label: const Text('Upload'),
                onPressed: () =>
                    context.go('/reconcile?account=$id&import=1'),
              )
            : null,
        onTap: () => context.go('/reconcile?account=$id'),
      ),
    );
  }
}

/// What has already been read, so an upload does not vanish.
///
/// Off the scan inbox rather than a table of its own: a statement that
/// was photographed IS a scan, and `0694` already records what each one
/// became. Filtered to the ones that went to `bank_transactions`, which
/// is where a statement's lines land.
class _Read extends ConsumerWidget {
  const _Read();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(scanInboxProvider('all'));
    return AsyncView<List<ScanInboxEntry>>(
      value: inbox,
      onRetry: () => ref.invalidate(scanInboxProvider),
      skeleton: const ListSkeleton(rows: 3),
      builder: (all) {
        final statements = all.where(isBankStatementScan).toList();
        if (statements.isEmpty) {
          return const EmptyState(
            icon: Icons.description_outlined,
            title: 'Nothing read yet',
            message: 'A statement photographed or uploaded through AI '
                'SmartScan shows here, with what became of it.',
          );
        }
        return Column(
          children: [
            for (final s in statements)
              Card(
                child: ListTile(
                  key: ValueKey('bank-statement-scan-${s.scanId}'),
                  leading: const Icon(Icons.description_outlined),
                  title: Text(s.fileName ?? 'Statement'),
                  subtitle: Text(
                    [
                      Fmt.dateTime(s.scannedAt),
                      s.provider,
                      if (s.becameSomething)
                        'brought in'
                      else
                        'not brought in yet',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Whether a scan is a bank statement.
///
/// Either it was FILED as one -- `record_scan_posting` writes
/// `bank_transactions` for a statement, which `scan_targets.repeats`
/// exists for -- or somebody said so on the sheet and it has not been
/// brought in yet. The second is the half worth showing: a statement
/// read and never imported is exactly what this screen is for.
bool isBankStatementScan(ScanInboxEntry entry) =>
    entry.postedTable == 'bank_transactions' ||
    entry.documentKind == 'bank_statement';
