import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/widgets.dart';

/// The practice keeping this company's books, seen from the client's
/// side, and the button that ends the arrangement.
///
/// Ending it is the client's to do, not the firm's, which is why it
/// lives here rather than on the practice screen. Detaching removes
/// exactly the rows the firm brought — anybody the company invited
/// itself keeps their place, including somebody who happens also to
/// work at that firm.
class BookkeepersCard extends ConsumerWidget {
  const BookkeepersCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final practice = ref.watch(ourPracticeProvider);
    final canAdmin = ref.watch(canAdminProvider);

    return practice.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (row) {
        if (row == null) return const SizedBox.shrink();
        final firm = Map<String, dynamic>.from(row['firms'] as Map);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader(
              'Who keeps our books',
              subtitle:
                  'Their staff reach this company as ordinary members, '
                  'at the role agreed below',
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.apartment_outlined),
                title: Text('${firm['name']}'),
                subtitle: Text(
                  [
                    'here as ${'${row['firm_member_role']}'.replaceAll('_', ' ')}',
                    if (firm['email'] != null) '${firm['email']}',
                    if (firm['phone'] != null) '${firm['phone']}',
                  ].join(' · '),
                ),
                trailing: canAdmin
                    ? TextButton(
                        onPressed: () => _end(context, ref, '${firm['name']}'),
                        child: const Text('End the arrangement'),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  Future<void> _end(BuildContext context, WidgetRef ref, String name) async {
    final ok = await confirm(
      context,
      title: 'End the arrangement with $name?',
      message:
          'Everybody there loses access to this company immediately. '
          'Nothing is exported and nothing moves — the books were never '
          'anywhere but here. Anyone you invited yourself keeps their '
          'place.',
      confirmLabel: 'End it',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final orgId = ref.read(currentOrgIdProvider);
    if (orgId == null) return;
    final repo = ref.read(firmsRepoProvider);
    await runWithFeedback(
      context,
      doing: 'end an arrangement with a practice',
      successMessage: 'Ended',
      action: () => repo.detach(orgId),
    );
    ref.invalidate(ourPracticeProvider);
    ref.invalidate(teamProvider);
  }
}
