import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'theme.dart';

/// The maintenance banner.
///
/// `0018` seeded `maintenance_mode` as "Show a maintenance banner and
/// block writes" and it did neither for five hundred migrations. `0564`
/// makes `can_write` and `can_admin` refuse, which is the enforcement.
/// This is the other half, and it is the half that stops somebody
/// concluding the product is broken: a save that fails with no
/// explanation is a bug report.

/// What the platform is saying, or null when it is saying nothing.
///
/// Granted to `anon` as well as `authenticated`, because the person who
/// most needs it is the one at the sign-in page wondering why their
/// password appears to have stopped working.
///
/// Not `autoDispose`: the banner is on every screen, and a provider
/// that disposed between navigations would ask again on every one.
/// Refreshed by [maintenanceRefresh] where a screen has reason to think
/// the answer changed.
final maintenanceNoticeProvider = FutureProvider<String?>((ref) async {
  try {
    final data = await ref.watch(supabaseProvider).rpc('maintenance_notice');
    final map = data as Map?;
    if (map == null) return null;
    final message = (map['message'] as String?)?.trim();
    return (message == null || message.isEmpty) ? null : message;
  } catch (_) {
    // A banner that could not be fetched is no banner. Deliberately
    // silent: a platform whose notice lookup fails is not a platform
    // that should start showing red boxes on every screen, and the
    // writes are refused by the database whether or not this answered.
    return null;
  }
});

/// Ask again. For the console, where somebody has just changed it.
void maintenanceRefresh(WidgetRef ref) =>
    ref.invalidate(maintenanceNoticeProvider);

/// Drawn above everything, because the screen somebody is on when the
/// shutter comes down is not predictable.
class MaintenanceBanner extends StatelessWidget {
  const MaintenanceBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colour = context.colors.warning;
    return Material(
      color: colour.withValues(alpha: 0.12),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: Space.sm,
          ),
          child: Row(
            children: [
              Icon(Icons.construction_outlined, size: 18, color: colour),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
