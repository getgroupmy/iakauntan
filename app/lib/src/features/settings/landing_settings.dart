import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// Which landing pages this person may actually be offered.
///
/// Pure, and separate from the screen, so the rule can be asserted:
/// `app/test/landing_preference_test.dart`. Offering a page the company
/// has not bought would send somebody to a screen that refuses them
/// every morning, which is worse than not offering it at all.
List<({String route, String label, String? module})> landingChoicesFor(
  bool Function(String) holds,
) {
  return [
    for (final choice in landingChoices)
      if (choice.module == null || holds(choice.module!)) choice,
  ];
}

/// Where to actually send somebody, given what they asked for.
///
/// The saved route is text, and text written by a newer build — or
/// pointing at a screen since withdrawn — must not leave somebody
/// staring at nothing. This is the fallback, and it is the important
/// half of the whole feature: the landing page is the one screen a
/// person cannot navigate away from if it fails to draw.
String landingRouteFor(UserPreferences prefs, bool Function(String) holds) {
  final allowed = landingChoicesFor(holds).map((c) => c.route).toSet();
  return allowed.contains(prefs.landingRoute)
      ? prefs.landingRoute
      : '/dashboard';
}

/// Settings › Landing page.
///
/// Two questions: where you start, and what you see when you get there.
class LandingSettingsCard extends ConsumerStatefulWidget {
  const LandingSettingsCard({super.key});

  @override
  ConsumerState<LandingSettingsCard> createState() =>
      _LandingSettingsCardState();
}

class _LandingSettingsCardState extends ConsumerState<LandingSettingsCard> {
  UserPreferences? _draft;
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(userPreferencesProvider);

    return AsyncView(
      value: saved,
      onRetry: () => ref.invalidate(userPreferencesProvider),
      builder: (prefs) {
        final current = _draft ?? prefs;
        final choices = landingChoicesFor((m) => moduleEnabled(ref, m));

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(
                  'Landing page',
                  subtitle:
                      'Where you start, and what you see when you '
                      'get there. Yours alone — it follows you to every '
                      'company you keep books for.',
                ),
                DropdownButtonFormField<String>(
                  value: choices.any((c) => c.route == current.landingRoute)
                      ? current.landingRoute
                      : '/dashboard',
                  decoration: const InputDecoration(
                    labelText: 'Open this when I sign in',
                  ),
                  items: [
                    for (final choice in choices)
                      DropdownMenuItem(
                        value: choice.route,
                        child: Text(choice.label),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    _draft = UserPreferences(
                      landingRoute: v ?? '/dashboard',
                      dashboardCards: current.dashboardCards,
                    );
                  }),
                ),
                const SizedBox(height: 8),
                Text(
                  'A device pinned to the till still opens the till: that '
                  'is set on the device, not on you.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 20),
                const SectionHeader(
                  'On the dashboard',
                  subtitle: 'Turn off what you do not read.',
                ),
                for (final card in dashboardCardChoices)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: current.shows(card.code),
                    title: Text(card.label),
                    subtitle: Text(card.hint),
                    onChanged: (on) => setState(() {
                      // Kept in the catalogue's order rather than the
                      // order they were switched on, so the dashboard
                      // does not rearrange itself as somebody toggles.
                      final wanted = {...current.dashboardCards};
                      if (on) {
                        wanted.add(card.code);
                      } else {
                        wanted.remove(card.code);
                      }
                      _draft = UserPreferences(
                        landingRoute: current.landingRoute,
                        dashboardCards: [
                          for (final c in dashboardCardChoices)
                            if (wanted.contains(c.code)) c.code,
                        ],
                      );
                    }),
                  ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _draft == null || _saving ? null : _save,
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _save() async {
    final repo = ref.read(repoProvider);
    final draft = _draft;
    if (repo == null || draft == null) return;
    setState(() => _saving = true);
    try {
      await repo.saveUserPreferences(draft);
      ref.invalidate(userPreferencesProvider);
      if (mounted) {
        setState(() => _draft = null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Saved. It applies next time you '
              'sign in.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
