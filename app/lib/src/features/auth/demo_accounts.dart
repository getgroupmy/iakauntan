import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// One-tap access to a seeded demo login.
///
/// **This ships the demo password inside the bundle.** Anyone who opens
/// the app can read it, which is fine for exactly as long as the demo
/// accounts are the only thing it opens — they hold invented books in a
/// demo company and nothing else.
///
/// It stops being fine the moment this project carries somebody's real
/// ledger, because these are ordinary auth users with ordinary roles, and
/// the owner account can see the whole company. So the panel is off
/// unless a build asks for it:
///
///   flutter build web --dart-define=DEMO_MODE=true
///
/// turns it on, and the demo users should be deleted before real books
/// arrive either way (README, "Before real books"). The switch is
/// compile-time rather than a setting because a door that can be
/// reopened by editing a row is not closed.
///
/// It used to default to `true`, which meant a build that simply forgot
/// the flag shipped a one-tap login to a seeded owner account. A default
/// that is safe only when somebody remembers is not a default.
const demoModeEnabled = bool.fromEnvironment('DEMO_MODE');

/// Overridable so a fork can seed its own demo data without editing code.
const demoPassword = String.fromEnvironment(
  'DEMO_PASSWORD',
  defaultValue: 'Demo!Akaun2026',
);

/// A demo login, described by what the person tapping it will actually
/// see rather than by the name of its role — "Auditor" means nothing to
/// somebody deciding which button to press.
class DemoAccount {
  const DemoAccount({
    required this.email,
    required this.role,
    required this.sees,
    required this.icon,
  });

  final String email;
  final String role;
  final String sees;
  final IconData icon;
}

/// Ordered by how much of the product each one shows, so the first tap is
/// the one most people want.
const demoAccounts = <DemoAccount>[
  DemoAccount(
    email: 'demo@iakauntan.my',
    role: 'Owner',
    sees: 'The whole company — books, payroll, everything',
    icon: Icons.workspace_premium_outlined,
  ),
  DemoAccount(
    email: 'clerk@iakauntan.my',
    role: 'Accounts clerk',
    sees: 'Can prepare documents, cannot post to the ledger',
    icon: Icons.edit_note_outlined,
  ),
  DemoAccount(
    email: 'auditor@iakauntan.my',
    role: 'Auditor',
    sees: 'Reads the ledger, writes nothing',
    icon: Icons.fact_check_outlined,
  ),
  DemoAccount(
    email: 'secretary@iakauntan.my',
    role: 'Company secretary',
    sees: 'A practice and the client companies it files for',
    icon: Icons.domain_outlined,
  ),
];

/// Not offered: `superadmin@iakauntan.my`, the platform operator.
///
/// Every other account here is scoped to a demo company, so the worst a
/// visitor can do is scribble on invented books. The operator console is
/// not scoped to anything — it lists every tenant on the deployment and
/// can change their status, which would include a real company the day
/// one signs up. Handing that to whoever loads the page is a different
/// kind of offer, and not one a demo needs to make.
///
/// The account still exists and still signs in by typing its credentials.
/// Removing it from this list is not the same as closing it: rotate its
/// password before this deployment is anything but a demo.

/// The picker itself.
///
/// Takes its accounts and its callback rather than reaching for them, so
/// a test can drive it without a Supabase client behind it.
class DemoAccountPicker extends StatelessWidget {
  const DemoAccountPicker({
    super.key,
    required this.onPick,
    this.accounts = demoAccounts,
    this.busyEmail,
    this.enabled = true,
  });

  final ValueChanged<DemoAccount> onPick;
  final List<DemoAccount> accounts;

  /// The account currently signing in, so the row that was tapped is the
  /// one that shows a spinner.
  final String? busyEmail;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Divider(color: scheme.outlineVariant)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'or look around a demo',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(child: Divider(color: scheme.outlineVariant)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Signs in immediately. The figures are invented and everyone '
          'shares the same demo company, so anything you change is there '
          'for the next visitor.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        for (final account in accounts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _AccountTile(
              account: account,
              // Only the row being signed in shows a spinner, but every
              // row goes dead, so a second tap cannot start a second
              // sign-in over the top of the first.
              busy: busyEmail == account.email,
              onTap: enabled && busyEmail == null
                  ? () => onPick(account)
                  : null,
            ),
          ),
      ],
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.busy,
    required this.onTap,
  });

  final DemoAccount account;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(account.icon, size: 20, color: scheme.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      account.role,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      account.sees,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (busy)
                const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.arrow_forward, size: 16, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
