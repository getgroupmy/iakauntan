import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/corp_models.dart';
import 'person_editor.dart';

/// Everybody the firm holds a file on.
///
/// One list, because `corp_persons` is one table: the same row is a
/// director of one company, a member of another and a beneficial owner
/// of a third. Somebody who moves house moves once here rather than in
/// each register they appear on, which is the whole reason the schema
/// keeps people apart from the appointments that point at them.
class CorpPeopleScreen extends ConsumerWidget {
  const CorpPeopleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(corpPersonsProvider);
    final canWrite = ref.watch(canWriteProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('People and bodies corporate'),
        actions: [
          if (canWrite)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              child: FilledButton.icon(
                key: const ValueKey('add-person'),
                onPressed: () => showPersonEditor(context),
                icon: const Icon(Icons.person_add_outlined, size: 18),
                label: const Text('Add'),
              ),
            ),
        ],
      ),
      body: AsyncView(
        value: people,
        onRetry: () => ref.invalidate(corpPersonsProvider),
        skeleton: const ListSkeleton(rows: 6, leading: false),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.badge_outlined,
              title: 'Nobody on file',
              message: 'Directors, secretaries, members and beneficial '
                  'owners are all recorded here once, then appointed to '
                  'the companies they serve.',
            );
          }

          return SingleChildScrollView(
            child: PageBody(
              maxWidth: 900,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(Space.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < list.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _PersonRow(
                              person: list[i],
                              onTap: canWrite
                                  ? () => showPersonEditor(context,
                                      person: list[i])
                                  : null,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.xxl),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.person, this.onTap});

  final CorpPerson person;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              person.isCorporate
                  ? Icons.apartment_outlined
                  : Icons.person_outline,
              size: 18,
              color: context.scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(person.fullName,
                          style:
                              const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    // A politically exposed person carries enhanced due
                    // diligence under the AMLA for as long as they are
                    // on the file, so it is on the row rather than two
                    // clicks inside it.
                    if (person.isPep) ...[
                      const SizedBox(width: Space.sm),
                      const StatusChip('PEP', compact: true),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    person.identifier ?? 'no identifier on file',
                    style: muted,
                  ),
                  if (person.address?.isNotEmpty ?? false)
                    Text(person.address!, style: muted),
                ],
              ),
            ),
            // Whether the firm has actually sighted a document, which is
            // the question an AMLA inspection asks first.
            if (person.isVerified)
              Tooltip(
                message: 'Identity verified ${Fmt.date(person.idVerifiedOn)}',
                child: Icon(Icons.verified_outlined,
                    size: 18, color: context.colors.success),
              )
            else
              Tooltip(
                message: 'No identity document sighted',
                child: Icon(Icons.gpp_maybe_outlined,
                    size: 18, color: context.colors.warning),
              ),
          ],
        ),
      ),
    );
  }
}
