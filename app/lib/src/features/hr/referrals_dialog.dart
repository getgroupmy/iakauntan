import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Who introduced the people the company hired.
///
/// `applicants.referred_by` has been a reference to an employee since
/// `0036` and nothing wrote it, which made an employee referral scheme
/// unpayable: the question "who introduced the people we took on this
/// quarter" had no answer in the data at all.
///
/// Both counts are shown. A list of hires alone cannot tell somebody who
/// introduced six people and had none taken on from somebody who
/// introduced nobody, and the first of those is the person a scheme is
/// meant to keep.
Future<void> showReferralHires(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _ReferralsDialog(),
  );
}

class _ReferralsDialog extends ConsumerWidget {
  const _ReferralsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(referralHiresProvider);

    return AlertDialog(
      title: const Text('Referrals'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: AsyncView(
            value: rows,
            onRetry: () => ref.invalidate(referralHiresProvider),
            builder: (list) => list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: Space.lg),
                    child: Text('Nobody has been recorded as introducing a '
                        'candidate. The referrer goes on the candidate '
                        'record, and is what a referral scheme pays on.'),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final r in list)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(r['referrer_name']?.toString() ?? '—'),
                          subtitle: Text(
                            '${r['candidates']} introduced',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Text(
                            '${r['hires']} hired',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: (r['hires'] as num? ?? 0) > 0
                                  ? context.colors.success
                                  : null,
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
