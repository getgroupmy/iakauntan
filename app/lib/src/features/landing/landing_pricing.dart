import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import 'landing_content.dart';
import 'landing_motion.dart';

/// Tick what you need and watch the month add up.
///
/// The thing on this page somebody can actually use before they have any
/// reason to trust us. The prices are the real ones from
/// `platform_modules`, which is the table the billing reads, so a figure
/// worked out here and an invoice a month later cannot disagree.
///
/// Only shown when a platform operator has published the catalogue —
/// 0294's `show_pricing`, off by default, because a rate card on the
/// front page is a commercial decision.
class LandingPricing extends StatefulWidget {
  const LandingPricing({super.key, required this.content});

  final LandingContent content;

  @override
  State<LandingPricing> createState() => _LandingPricingState();
}

class _LandingPricingState extends State<LandingPricing> {
  final _chosen = <String>{};

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final modules = widget.content.modules;
    final core = modules.where((m) => m.isCore).toList();
    final addOns = modules.where((m) => !m.isCore).toList();
    final total = monthlyTotal(modules, _chosen);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.content.pricingHeading ?? 'Build your plan',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.content.pricingNote ??
              'Keeping books is included. Add only what your business '
                  'actually does.',
          style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        if (core.isNotEmpty) ...[
          _IncludedRow(names: core.map((m) => m.name).toList()),
          const SizedBox(height: 20),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth > 820
                ? 3
                : constraints.maxWidth > 520
                    ? 2
                    : 1;
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final m in addOns)
                  SizedBox(
                    width: width,
                    child: _ModuleTile(
                      module: m,
                      chosen: _chosen.contains(m.code),
                      onToggle: () => setState(() {
                        if (!_chosen.remove(m.code)) _chosen.add(m.code);
                      }),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        _Total(total: total, chosen: _chosen.length),
      ],
    );
  }
}

class _IncludedRow extends StatelessWidget {
  const _IncludedRow({required this.names});

  final List<String> names;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'Always included:',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
        for (final n in names)
          Chip(
            label: Text(n),
            avatar: Icon(Icons.check, size: 16, color: scheme.primary),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

class _ModuleTile extends StatelessWidget {
  const _ModuleTile({
    required this.module,
    required this.chosen,
    required this.onToggle,
  });

  final LandingModule module;
  final bool chosen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return HoverLift(
      onTap: onToggle,
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: chosen
              ? scheme.primaryContainer.withValues(alpha: 0.55)
              : scheme.surfaceContainerLowest,
          border: Border.all(
            color: chosen
                ? scheme.primary
                : hovered
                    ? scheme.outline
                    : scheme.outlineVariant,
            width: chosen ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // A checkbox rather than a tick, because the whole tile
                // is tappable and somebody has to be able to see that
                // before they try it.
                Checkbox(
                  value: chosen,
                  onChanged: (_) => onToggle(),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    module.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (module.description != null) ...[
              const SizedBox(height: 6),
              Text(
                module.description!,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              module.monthlyPrice == 0
                  ? 'No extra charge'
                  : '${Fmt.money(module.monthlyPrice)} / month',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.total, required this.chosen});

  final double total;
  final int chosen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: scheme.primaryContainer.withValues(alpha: 0.4),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 16,
        spacing: 16,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                chosen == 0
                    ? 'Just the books'
                    : '$chosen add-on${chosen == 1 ? '' : 's'}',
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              // The figure animates rather than jumping, so a tick reads
              // as having changed something.
              TweenAnimationBuilder<double>(
                tween: Tween(begin: total, end: total),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOut,
                builder: (context, value, _) => Text(
                  '${Fmt.money(value)} / month',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          FilledButton.icon(
            onPressed: () => context.go('/signin?mode=register'),
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Start with this'),
          ),
        ],
      ),
    );
  }
}
