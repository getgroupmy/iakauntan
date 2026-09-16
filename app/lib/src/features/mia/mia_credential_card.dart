import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'mia_credential.dart';
import 'mia_service.dart';
import 'mia_verify_dialog.dart';

/// What MIA's register said about one officer or one practice.
///
/// Draws nothing at all when there is no credential and the reader
/// cannot add one — an empty card headed "MIA" on every director of
/// every company would be a permanent invitation to record something
/// that mostly does not apply. `roleNeedsMia` upstream decides who is
/// asked; this only decides what to show once asked.
class MiaCredentialCard extends ConsumerWidget {
  const MiaCredentialCard({
    super.key,
    required this.subjectType,
    required this.subjectId,
    required this.subjectName,
    this.canWrite = false,
    this.kinds = const [MiaKind.member, MiaKind.firm],
  });

  final String subjectType;
  final String subjectId;

  /// Shown in the dialog so somebody pasting a row can see whose record
  /// they are about to overwrite.
  final String subjectName;

  final bool canWrite;

  /// Which credentials this subject can hold. An engagement partner
  /// holds both — they are a member, and the audit firm they sign for
  /// is a firm — while a practice holds only the firm one.
  final List<MiaKind> kinds;

  ({String subjectType, String subjectId}) get _arg =>
      (subjectType: subjectType, subjectId: subjectId);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(miaCredentialsProvider(_arg));
    final rows = async.valueOrNull ?? const <MiaCredential>[];

    if (rows.isEmpty && !canWrite) return const SizedBox.shrink();

    return Card(
      key: const ValueKey('mia-card'),
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Malaysian Institute of Accountants',
              subtitle: 'Members and firms register',
              action: canWrite
                  ? TextButton.icon(
                      key: const ValueKey('mia-verify'),
                      onPressed: () => _verify(context, ref, null),
                      icon: const Icon(Icons.fact_check_outlined, size: 18),
                      label: Text(rows.isEmpty ? 'Check' : 'Check again'),
                    )
                  : null,
            ),
            if (async.hasError)
              Text(
                'Could not read what was recorded.',
                style: TextStyle(color: context.colors.danger),
              )
            else if (async.isLoading)
              // Not "nothing recorded". An answer that has not arrived
              // is not an answer of none, and a card that said so for
              // as long as the query took would be saying something
              // false on every open.
              const LinearProgressIndicator(minHeight: 2)
            else if (rows.isEmpty)
              Text(
                'Nothing recorded. Look $subjectName up on MIA’s register '
                'and paste the row.',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const Divider(height: Space.xl),
                _CredentialBlock(
                  credential: rows[i],
                  canWrite: canWrite,
                  onReverify: () => _verify(context, ref, rows[i].kind),
                  onRemove: () => _remove(context, ref, rows[i]),
                ),
              ],
            const SizedBox(height: Space.md),
            Text(
              miaCredentialCaveat,
              key: const ValueKey('mia-caveat'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _verify(BuildContext context, WidgetRef ref, MiaKind? kind) async {
    final saved = await showMiaVerifyDialog(
      context,
      subjectType: subjectType,
      subjectId: subjectId,
      subjectName: subjectName,
      kinds: kinds,
      initialKind: kind,
    );
    if (saved) ref.invalidate(miaCredentialsProvider(_arg));
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    MiaCredential row,
  ) async {
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(miaServiceProvider).remove(row.id),
      successMessage: 'Removed',
    );
    if (ok) ref.invalidate(miaCredentialsProvider(_arg));
  }
}

class _CredentialBlock extends StatelessWidget {
  const _CredentialBlock({
    required this.credential,
    required this.canWrite,
    required this.onReverify,
    required this.onRemove,
  });

  final MiaCredential credential;
  final bool canWrite;
  final VoidCallback onReverify;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = credential;
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: context.scheme.onSurfaceVariant,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            StatusChip(
              c.kind == MiaKind.firm ? 'Firm' : 'Member',
              compact: true,
            ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: SelectableText(
                '${c.number} · ${c.registeredName}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (canWrite)
              IconButton(
                key: ValueKey('mia-remove-${c.kind.name}'),
                tooltip: 'Remove',
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
          ],
        ),
        const SizedBox(height: Space.sm),
        if (c.kind == MiaKind.member) ...[
          if (c.memberType != null)
            FieldRow(label: 'Member type', value: c.memberType!),
          FieldRow(
            label: 'Practising certificate',
            // Three states, not two. A register that did not say is not
            // the same as a register that said no, and a card that read
            // "No" for a row pasted without the column would be
            // asserting something MIA never told it.
            value: switch (c.pcHolder) {
              true => 'Yes',
              false => 'No',
              null => 'Not recorded',
            },
          ),
        ] else ...[
          if (c.firmType != null)
            FieldRow(
              label: 'Type of firm',
              value: c.firmType == 'A' ? 'Audit' : 'Non-audit',
            ),
          if (c.address != null) FieldRow(label: 'Address', value: c.address!),
          if (c.tel != null) FieldRow(label: 'Tel', value: c.tel!),
          if (c.email != null) FieldRow(label: 'Email', value: c.email!),
          if (c.website != null) FieldRow(label: 'Website', value: c.website!),
        ],
        if (c.state != null) FieldRow(label: 'State', value: c.state!),
        const SizedBox(height: Space.sm),
        Text(
          'Checked on ${Fmt.date(c.verifiedAt)}'
          '${c.verifiedByName == null ? '' : ' by ${c.verifiedByName}'}',
          key: ValueKey('mia-checked-${c.kind.name}'),
          style: muted,
        ),
        if (c.isStale)
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.schedule, size: 16, color: context.colors.warning),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    // A practising certificate is renewed every year,
                    // so a check older than that describes last year's
                    // register and not this one.
                    'Checked over a year ago. A practising certificate is '
                    'renewed annually — worth looking again.',
                    key: const ValueKey('mia-stale'),
                    style: muted?.copyWith(color: context.colors.warning),
                  ),
                ),
                if (canWrite)
                  TextButton(
                    key: ValueKey('mia-reverify-${c.kind.name}'),
                    onPressed: onReverify,
                    child: const Text('Re-check'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
