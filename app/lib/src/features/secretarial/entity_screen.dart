import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/download.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/corp_models.dart';
import '../../data/corp_repository.dart';
import '../shared/attachments_card.dart';

/// One company's file: the statutory registers the Companies Act 2016
/// requires a secretary to keep, and the documents drawn from them.
class CorpEntityScreen extends ConsumerWidget {
  const CorpEntityScreen({super.key, required this.entityId});

  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entity = ref.watch(corpEntityProvider(entityId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/secretarial'),
        ),
        title: Text(entity.valueOrNull?.name ?? 'Company'),
        actions: [
          if (ref.watch(canWriteProvider))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              child: OutlinedButton.icon(
                onPressed: () => context.go('/secretarial/$entityId/edit'),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit'),
              ),
            ),
        ],
      ),
      body: AsyncView(
        value: entity,
        onRetry: () => ref.invalidate(corpEntityProvider(entityId)),
        builder: (e) {
          if (e == null) {
            return const EmptyState(
                icon: Icons.error_outline, title: 'Company not found');
          }
          return DefaultTabController(
            length: 6,
            child: Column(
              children: [
                const TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    Tab(text: 'Particulars'),
                    Tab(text: 'Officers'),
                    Tab(text: 'Members'),
                    Tab(text: 'Beneficial owners'),
                    Tab(text: 'Charges'),
                    Tab(text: 'Documents'),
                  ],
                ),
                Expanded(
                  child: TabBarView(children: [
                    _Particulars(entity: e),
                    _Officers(entityId: entityId),
                    _Members(entityId: entityId),
                    _BeneficialOwners(entityId: entityId),
                    _Charges(entityId: entityId),
                    _Documents(entityId: entityId),
                  ]),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Particulars extends StatelessWidget {
  const _Particulars({required this.entity});

  final CorpEntity entity;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: PageBody(
        maxWidth: 800,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader('Particulars'),
                _Row('Registration number', entity.registrationNo ?? '—'),
                if (entity.oldRegistrationNo != null)
                  _Row('Former number', entity.oldRegistrationNo!),
                _Row('Type', entity.typeLabel),
                _Row('Status', Fmt.label(entity.status)),
                _Row('Incorporated', Fmt.date(entity.incorporatedOn)),
                _Row('Financial year end', entity.fyeLabel),
                _Row('Registered office', entity.registeredOffice ?? '—'),
                _Row('Business address', entity.businessAddress ?? '—'),
                _Row('Nature of business', entity.natureOfBusiness ?? '—'),
                _Row('Constitution',
                    entity.hasConstitution ? 'Adopted' : 'None adopted'),
                _Row('Audit', entity.isAuditExempt
                    ? 'Exempt under the Registrar’s practice directive'
                    : 'Audited'),
                if (entity.clientRef != null)
                  _Row('Our reference', entity.clientRef!),
                const SizedBox(height: Space.md),
                Text(
                  entity.mustHoldAgm
                      ? 'A public company must lay its accounts at an annual '
                          'general meeting within six months of the year end '
                          '(s.340).'
                      : 'The Companies Act 2016 removed the requirement for a '
                          'private company to hold an annual general meeting, '
                          'so none is tracked here.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 180,
          child: Text(label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant)),
        ),
        Expanded(child: Text(value)),
      ]),
    );
  }
}

class _Officers extends ConsumerWidget {
  const _Officers({required this.entityId});

  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final officers = ref.watch(corpOfficersProvider(entityId));

    return AsyncView(
      value: officers,
      onRetry: () => ref.invalidate(corpOfficersProvider(entityId)),
      builder: (list) {
        final current = list.where((o) => o.isCurrent).toList();
        final past = list.where((o) => !o.isCurrent).toList();

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
                        const SectionHeader(
                          'Register of directors, managers and secretaries',
                          subtitle: 'Companies Act 2016, section 57',
                        ),
                        if (current.isEmpty)
                          const Text('No officers on the register.')
                        else
                          for (var i = 0; i < current.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _OfficerRow(officer: current[i]),
                          ],
                      ],
                    ),
                  ),
                ),
                if (past.isNotEmpty) ...[
                  const SizedBox(height: Space.lg),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(Space.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SectionHeader('Ceased'),
                          for (final o in past) _OfficerRow(officer: o),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: Space.xxl),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _OfficerRow extends StatelessWidget {
  const _OfficerRow({required this.officer});

  final CorpOfficer officer;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(officer.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          decoration: officer.isCurrent
                              ? null
                              : TextDecoration.lineThrough,
                        )),
                  ),
                  const SizedBox(width: Space.sm),
                  StatusChip(officer.role, compact: true),
                ]),
                const SizedBox(height: 2),
                Text(
                  '${officer.identifier ?? 'no identifier on file'} · '
                  'appointed ${Fmt.date(officer.appointedOn)}'
                  '${officer.resignedOn == null ? '' : ' · ceased ${Fmt.date(officer.resignedOn)}'}',
                  style: muted,
                ),
                if (officer.licenceNo != null)
                  Text(
                    '${officer.licenceBody ?? 'Licence'} ${officer.licenceNo}'
                    '${officer.licenceExpiresOn == null ? '' : ' · expires ${Fmt.date(officer.licenceExpiresOn)}'}',
                    style: muted,
                  ),
                // The two things a secretary must be able to produce for
                // any sitting director, called out rather than left as
                // two empty date fields nobody looks at.
                if (officer.isCurrent && !officer.paperworkComplete)
                  _Flag(
                    'No s.201 consent or s.198 declaration on file',
                    colour: context.colors.warning,
                  ),
                if (officer.licenceLapsed)
                  _Flag(
                    'Secretary’s licence has expired — the company has no '
                    'validly appointed secretary',
                    colour: context.colors.danger,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Flag extends StatelessWidget {
  const _Flag(this.text, {required this.colour});

  final String text;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.warning_amber_rounded, size: 14, color: colour),
        const SizedBox(width: 4),
        Expanded(
          child: Text(text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colour)),
        ),
      ]),
    );
  }
}

class _Members extends ConsumerWidget {
  const _Members({required this.entityId});

  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(corpMembersProvider(entityId));
    final events = ref.watch(corpShareEventsProvider(entityId));

    return SingleChildScrollView(
      child: PageBody(
        maxWidth: 1000,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(Space.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeader(
                      'Register of members',
                      subtitle: 'Section 50. Computed from the share '
                          'movements, so it cannot drift from the returns '
                          'already lodged.',
                    ),
                    AsyncView(
                      value: members,
                      onRetry: () =>
                          ref.invalidate(corpMembersProvider(entityId)),
                      loading: const LinearProgressIndicator(),
                      builder: (list) => list.isEmpty
                          ? const Text('No shares in issue.')
                          : Column(children: [
                              for (var i = 0; i < list.length; i++) ...[
                                if (i > 0) const Divider(height: 1),
                                _MemberRow(member: list[i]),
                              ],
                            ]),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Space.lg),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(Space.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeader('Share movements'),
                    AsyncView(
                      value: events,
                      onRetry: () =>
                          ref.invalidate(corpShareEventsProvider(entityId)),
                      loading: const LinearProgressIndicator(),
                      builder: (list) => list.isEmpty
                          ? const Text('Nothing recorded.')
                          : Column(children: [
                              for (final e in list) _EventRow(event: e),
                            ]),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Space.xxl),
          ],
        ),
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member});

  final CorpMember member;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(member.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                '${member.identifier ?? '—'} · ${member.shareClass}'
                '${member.firstAcquired == null ? '' : ' · since ${Fmt.date(member.firstAcquired)}'}',
                style: muted,
              ),
              // Above 20% is one of the statutory tests for beneficial
              // ownership, so the register says so rather than leaving
              // the secretary to eyeball percentages.
              if (member.triggersBeneficialOwnership)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Over 20% — consider the s.60B register',
                    style: muted?.copyWith(color: context.colors.info),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: Text(Fmt.shares(member.shares), textAlign: TextAlign.right),
        ),
        SizedBox(
          width: 90,
          child: Text('${Fmt.plain(member.percent)}%',
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final CorpShareEvent event;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    final who = switch (event.eventType) {
      'allotment' => 'to ${event.toName}',
      'cancellation' => 'from ${event.fromName}',
      _ => '${event.fromName} → ${event.toName}',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(children: [
        SizedBox(width: 96, child: Text(Fmt.date(event.eventDate), style: muted)),
        SizedBox(
          width: 110,
          child: Align(
            alignment: Alignment.centerLeft,
            child: StatusChip(event.eventType, compact: true),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${Fmt.shares(event.quantity)} ${event.shareClass ?? ''} $who'),
              if (event.instrumentRef != null)
                Text('Instrument ${event.instrumentRef}', style: muted),
            ],
          ),
        ),
        if (event.totalConsideration != null)
          SizedBox(width: 120, child: Money(event.totalConsideration)),
      ]),
    );
  }
}

class _BeneficialOwners extends ConsumerWidget {
  const _BeneficialOwners({required this.entityId});

  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owners = ref.watch(corpBeneficialOwnersProvider(entityId));

    return SingleChildScrollView(
      child: PageBody(
        maxWidth: 900,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader(
                  'Register of beneficial owners',
                  subtitle: 'Section 60B, in force since 1 April 2024. The '
                      'company must keep this and notify the Registrar within '
                      'fourteen days of obtaining the information.',
                ),
                AsyncView(
                  value: owners,
                  onRetry: () =>
                      ref.invalidate(corpBeneficialOwnersProvider(entityId)),
                  loading: const LinearProgressIndicator(),
                  builder: (list) {
                    final current = list.where((o) => o.isCurrent).toList();
                    if (current.isEmpty) {
                      return Text(
                        'Nobody entered. A company with no beneficial owner '
                        'identified must record the steps it took to find '
                        'one — an empty register is itself a statement.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: context.scheme.onSurfaceVariant),
                      );
                    }
                    return Column(children: [
                      for (var i = 0; i < current.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _OwnerRow(owner: current[i]),
                      ],
                    ]);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OwnerRow extends StatelessWidget {
  const _OwnerRow({required this.owner});

  final CorpBeneficialOwner owner;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(owner.name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(owner.identifier ?? '—', style: muted),
                for (final g in owner.grounds)
                  Text('· $g', style: muted),
                if (owner.notifiedOn == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Not yet notified to the Registrar',
                        style: muted?.copyWith(color: context.colors.warning)),
                  ),
              ],
            ),
          ),
          if (owner.percent != null)
            SizedBox(
              width: 90,
              child: Text('${Fmt.plain(owner.percent)}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}

class _Charges extends ConsumerWidget {
  const _Charges({required this.entityId});

  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final charges = ref.watch(corpChargesProvider(entityId));

    return SingleChildScrollView(
      child: PageBody(
        maxWidth: 900,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader(
                  'Register of charges',
                  subtitle: 'Section 357. A charge must be registered within '
                      'thirty days of creation (s.352) or it is void against '
                      'the liquidator.',
                ),
                AsyncView(
                  value: charges,
                  onRetry: () => ref.invalidate(corpChargesProvider(entityId)),
                  loading: const LinearProgressIndicator(),
                  builder: (list) => list.isEmpty
                      ? const Text('No charges registered.')
                      : Column(children: [
                          for (var i = 0; i < list.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _ChargeRow(charge: list[i]),
                          ],
                        ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChargeRow extends StatelessWidget {
  const _ChargeRow({required this.charge});

  final CorpCharge charge;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(charge.chargeeName,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          decoration: charge.isSatisfied
                              ? TextDecoration.lineThrough
                              : null,
                        )),
                  ),
                  if (charge.isSatisfied) ...[
                    const SizedBox(width: Space.sm),
                    const StatusChip('satisfied', compact: true),
                  ],
                ]),
                const SizedBox(height: 2),
                Text(
                  '${charge.chargeType ?? 'Charge'} created '
                  '${Fmt.date(charge.createdOn)}'
                  '${charge.registeredOn == null ? '' : ' · registered ${Fmt.date(charge.registeredOn)}'}',
                  style: muted,
                ),
                if (charge.propertyCharged != null)
                  Text(charge.propertyCharged!, style: muted),
                if (charge.registrationLate)
                  _Flag(
                    'Not registered within thirty days of creation — the '
                    'charge is void against the liquidator (s.352)',
                    colour: context.colors.danger,
                  ),
              ],
            ),
          ),
          if (charge.amountSecured != null)
            SizedBox(width: 130, child: Money(charge.amountSecured)),
        ],
      ),
    );
  }
}

class _Documents extends ConsumerWidget {
  const _Documents({required this.entityId});

  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docs = ref.watch(corpDocumentsProvider(entityId));
    final canWrite = ref.watch(canWriteProvider);

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
                SectionHeader(
                  'Documents',
                  subtitle: 'Generated from the registers, so a resolution '
                      'cannot disagree with the register it relies on',
                  action: canWrite
                      ? FilledButton.icon(
                          onPressed: () => _generate(context, ref),
                          icon: const Icon(Icons.note_add_outlined, size: 18),
                          label: const Text('Generate'),
                        )
                      : null,
                ),
                AsyncView(
                  value: docs,
                  onRetry: () =>
                      ref.invalidate(corpDocumentsProvider(entityId)),
                  loading: const LinearProgressIndicator(),
                  builder: (list) => list.isEmpty
                      ? const Text('Nothing generated yet.')
                      : Column(children: [
                          for (var i = 0; i < list.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _DocumentRow(document: list[i]),
                          ],
                        ]),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Space.lg),
        // The signed hard copy, the stamped instrument, the certificate
        // that came back from the Registrar — the paper that goes with
        // the generated text.
        AttachmentsCard(
          table: 'corp_entities',
          recordId: entityId,
          title: 'Filed papers',
          subtitle: 'Signed copies, stamped instruments and anything '
              'returned by the Registrar',
        ),
        const SizedBox(height: Space.xxl),
          ],
        ),
      ),
    );
  }

  Future<void> _generate(BuildContext context, WidgetRef ref) async {
    final templates = await ref.read(corpTemplatesProvider.future);
    if (!context.mounted || templates.isEmpty) return;

    final code = await showDialog<String>(
      context: context,
      builder: (_) => _TemplatePicker(templates: templates),
    );
    if (code == null || !context.mounted) return;

    // What the template asks for, against what the register can answer.
    // Shown before anything is generated, because a placeholder noticed
    // after signature is a document reissued.
    final repo = ref.read(repoProvider)!;
    final placeholders = await repo.corpPlaceholders(entityId, code);
    if (!context.mounted) return;

    final extra = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _FillGaps(placeholders: placeholders),
    );
    if (extra == null || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () =>
          repo.corpGenerateDocument(entityId, code, extra: extra),
      successMessage: 'Document generated',
    );
    ref.invalidate(corpDocumentsProvider(entityId));
  }
}

class _TemplatePicker extends StatelessWidget {
  const _TemplatePicker({required this.templates});

  final List<CorpTemplate> templates;

  @override
  Widget build(BuildContext context) {
    final byCategory = <String, List<CorpTemplate>>{};
    for (final t in templates) {
      byCategory.putIfAbsent(t.category ?? 'Other', () => []).add(t);
    }

    return AlertDialog(
      title: const Text('Which document?'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final e in byCategory.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(
                      top: Space.md, bottom: Space.xs),
                  child: Text(e.key,
                      style: Theme.of(context).textTheme.labelMedium),
                ),
                for (final t in e.value)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(t.name),
                    subtitle: t.isOwn ? const Text('Your firm’s version') : null,
                    onTap: () => Navigator.pop(context, t.code),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// The placeholders the register cannot answer — a new director's name,
/// a new address — collected before the document is built rather than
/// left as visible {{braces}} in something about to be signed.
class _FillGaps extends StatefulWidget {
  const _FillGaps({required this.placeholders});

  final List<CorpPlaceholder> placeholders;

  @override
  State<_FillGaps> createState() => _FillGapsState();
}

class _FillGapsState extends State<_FillGaps> {
  final _c = <String, TextEditingController>{};

  List<CorpPlaceholder> get _gaps =>
      widget.placeholders.where((p) => !p.isFilled).toList();

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filled = widget.placeholders.where((p) => p.isFilled).toList();

    return AlertDialog(
      title: const Text('Fill in the rest'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (filled.isNotEmpty) ...[
                Text(
                  '${filled.length} of ${widget.placeholders.length} fields '
                  'come straight from the register: '
                  '${filled.map((f) => f.name).join(', ')}.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Space.md),
              ],
              if (_gaps.isEmpty)
                const Text('Nothing left to supply.')
              else
                for (final g in _gaps)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.md),
                    child: TextField(
                      controller:
                          _c.putIfAbsent(g.name, () => TextEditingController()),
                      decoration: InputDecoration(labelText: Fmt.label(g.name)),
                    ),
                  ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            for (final e in _c.entries)
              if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
          }),
          child: const Text('Generate'),
        ),
      ],
    );
  }
}

/// The document, and who has signed it.
///
/// The signatures are recomputed against the text as it stands now, so a
/// document edited after signature says so on its face rather than
/// carrying a tick that stopped meaning anything.
class _DocumentDialog extends ConsumerWidget {
  const _DocumentDialog({required this.document});

  final CorpDocument document;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signatures = ref.watch(corpSignaturesProvider(document.id));
    final canWrite = ref.watch(canWriteProvider);

    return AlertDialog(
      title: Text(document.title),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(document.body),
              const Divider(height: Space.xxl),
              _SignatureBlock(
                documentId: document.id,
                entityId: document.entityId,
                signatures: signatures,
                canWrite: canWrite,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _SignatureBlock extends ConsumerWidget {
  const _SignatureBlock({
    required this.documentId,
    required this.entityId,
    required this.signatures,
    required this.canWrite,
  });

  final String documentId;
  final String entityId;
  final AsyncValue<List<CorpSignature>> signatures;
  final bool canWrite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Signatures',
          subtitle: 'An electronic signature under the Electronic Commerce '
              'Act 2006 — a recorded act of signing. Not a digital '
              'signature under the Digital Signature Act 1997, which needs '
              'a certificate from a licensed authority.',
          action: canWrite
              ? TextButton.icon(
                  onPressed: () => _request(context, ref),
                  icon: const Icon(Icons.draw_outlined, size: 18),
                  label: const Text('Circulate'),
                )
              : null,
        ),
        AsyncView(
          value: signatures,
          onRetry: () => ref.invalidate(corpSignaturesProvider(documentId)),
          loading: const LinearProgressIndicator(),
          builder: (list) => list.isEmpty
              ? Text('Not circulated for signature.', style: muted)
              : Column(children: [
                  for (final s in list) _SignatureRow(
                    signature: s,
                    documentId: documentId,
                    canWrite: canWrite,
                  ),
                ]),
        ),
      ],
    );
  }

  Future<void> _request(BuildContext context, WidgetRef ref) async {
    final officers = await ref.read(corpOfficersProvider(entityId).future);
    if (!context.mounted) return;
    final current = officers.where((o) => o.isCurrent).toList();
    if (current.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Nobody on the register to sign'),
      ));
      return;
    }

    final chosen = await showDialog<List<CorpOfficer>>(
      context: context,
      builder: (_) => _SignatoryPicker(officers: current),
    );
    if (chosen == null || chosen.isEmpty || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.corpRequestSignatures(
            documentId,
            [for (final o in chosen) o.personId],
            capacities: [for (final o in chosen) Fmt.label(o.role)],
          ),
      successMessage: 'Circulated for signature',
    );
    ref.invalidate(corpSignaturesProvider(documentId));
  }
}

class _SignatureRow extends ConsumerWidget {
  const _SignatureRow({
    required this.signature,
    required this.documentId,
    required this.canWrite,
  });

  final CorpSignature signature;
  final String documentId;
  final bool canWrite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(signature.personName,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: Space.sm),
                  StatusChip(signature.status, compact: true),
                ]),
                if (signature.capacity != null)
                  Text(signature.capacity!, style: muted),
                if (signature.isSigned)
                  Text(
                    'Signed "${signature.signedName}" on '
                    '${Fmt.dateTime(signature.signedAt)}',
                    style: muted,
                  ),
                // The whole point of hashing the body: a signature that
                // no longer vouches for what is on screen says so.
                if (signature.isStale)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'The document has been edited since this was signed — '
                      'the signature no longer covers this text',
                      style: muted?.copyWith(color: context.colors.danger),
                    ),
                  ),
              ],
            ),
          ),
          if (canWrite && signature.isPending)
            TextButton(
              onPressed: () => _sign(context, ref),
              child: const Text('Sign'),
            ),
        ],
      ),
    );
  }

  Future<void> _sign(BuildContext context, WidgetRef ref) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _SignDialog(who: signature.personName),
    );
    if (name == null || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.corpSignDocument(signature.id, name),
      successMessage: 'Signed',
    );
    ref.invalidate(corpSignaturesProvider(documentId));
  }
}

class _SignatoryPicker extends StatefulWidget {
  const _SignatoryPicker({required this.officers});

  final List<CorpOfficer> officers;

  @override
  State<_SignatoryPicker> createState() => _SignatoryPickerState();
}

class _SignatoryPickerState extends State<_SignatoryPicker> {
  final _chosen = <String>{};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Who signs?'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final o in widget.officers)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _chosen.contains(o.id),
                  title: Text(o.name),
                  subtitle: Text(Fmt.label(o.role)),
                  onChanged: (on) => setState(() =>
                      on == true ? _chosen.add(o.id) : _chosen.remove(o.id)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _chosen.isEmpty
              ? null
              : () => Navigator.pop(context,
                  widget.officers.where((o) => _chosen.contains(o.id)).toList()),
          child: const Text('Circulate'),
        ),
      ],
    );
  }
}

class _SignDialog extends StatefulWidget {
  const _SignDialog({required this.who});

  final String who;

  @override
  State<_SignDialog> createState() => _SignDialogState();
}

class _SignDialogState extends State<_SignDialog> {
  late final _c = TextEditingController(text: widget.who);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sign'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Typing your name below records that you signed this document '
              'as it stands. The text is fingerprinted at that moment, so a '
              'later edit is detectable.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _c,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Full name'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _c.text.trim()),
          child: const Text('Sign'),
        ),
      ],
    );
  }
}

class _DocumentRow extends StatelessWidget {
  const _DocumentRow({required this.document});

  final CorpDocument document;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(document.title,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(Fmt.dateTime(document.generatedAt),
          style: const TextStyle(fontSize: 12)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          icon: const Icon(Icons.download_outlined, size: 18),
          tooltip: 'Download',
          onPressed: () => _download(context),
        ),
        IconButton(
          icon: const Icon(Icons.visibility_outlined, size: 18),
          tooltip: 'Read and sign',
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => _DocumentDialog(document: document),
          ),
        ),
      ]),
    );
  }

  Future<void> _download(BuildContext context) async {
    final name =
        '${document.title.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').toLowerCase()}.md';
    final messenger = ScaffoldMessenger.of(context);
    final saved = await saveTextFile(name, 'text/markdown', document.body);
    if (!saved) await Clipboard.setData(ClipboardData(text: document.body));
    messenger.showSnackBar(SnackBar(
      content: Text(saved ? 'Downloaded' : 'Copied to the clipboard'),
    ));
  }
}
