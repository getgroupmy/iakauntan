import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
// Not unused: emailDocument and friends live in an `extension on Repo`,
// and an extension is only in scope where its library is imported.
import '../../data/repository.dart';
import 'activity_entry.dart';

/// Emailing a document, and the record of everything that ever left the
/// building for it.
///
/// Replaces a yes/no confirmation that could only queue, to the address
/// on the customer record, and told you nothing afterwards. Three things
/// were missing and all three are the same question — *did the customer
/// get this?* — asked at different times:
///
///   * **Send now**, because "it goes out within half an hour" is not an
///     answer when somebody is on the phone.
///   * **A different address**, because the person who pays is often not
///     the person on the customer record.
///   * **The history**, because a week later the only useful answer is
///     what was actually sent, to whom, and whether it arrived.
///
/// The history is the interesting one: it merges messages, share links
/// and PDF downloads, so an opened link sitting under a sent message is
/// the strongest evidence available that a human read the invoice.
/// What a send-now actually did, read off the outbox row rather than
/// inferred from the call returning.
///
/// Shared by the document and receipt dialogs because this is the part
/// worth getting right once: the call succeeding does not mean the
/// message went. A drain that failed leaves the row queued, and saying
/// "Sent" over that is a lie the customer discovers before you do.
///
/// `finished` is whether the dialog has done its job and should close.
/// Everything except an outright refusal has — a queued row is still
/// going out on the schedule. A refusal keeps it open, because the
/// address that caused it is on screen and usually needs editing.
({String message, bool finished, String? error}) sendNowOutcome(
    Map<String, dynamic> row) {
  final status = row['status'] as String?;
  return switch (status) {
    'sent' => (
        message: 'Sent to ${row['to_email']}',
        finished: true,
        error: null,
      ),
    'failed' => (
        message: 'Could not send: '
            '${row['last_error'] ?? 'the provider refused it'}',
        finished: false,
        error: row['last_error'] as String? ??
            'The provider refused it. Check the address and try again.',
      ),
    _ => (
        message: 'Queued — mail is not sending right now, so it will go '
            'out on the next scheduled send',
        finished: true,
        error: null,
      ),
  };
}

/// [buildPdf] renders the same PDF the download button produces. It is
/// passed in rather than built here because the renderer needs the
/// organization, its logo and its letterhead mode, all of which the
/// editor already has — and because a dialog that knew how to lay out an
/// invoice would be a dialog nobody could change safely.
Future<bool?> showEmailDialog(
  BuildContext context, {
  required String documentId,
  required String docNo,
  String? defaultTo,
  Future<Uint8List> Function()? buildPdf,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _EmailDialog(
      documentId: documentId,
      docNo: docNo,
      defaultTo: defaultTo,
      buildPdf: buildPdf,
    ),
  );
}

class _EmailDialog extends ConsumerStatefulWidget {
  const _EmailDialog({
    required this.documentId,
    required this.docNo,
    this.defaultTo,
    this.buildPdf,
  });

  final String documentId;
  final String docNo;
  final String? defaultTo;
  final Future<Uint8List> Function()? buildPdf;

  @override
  ConsumerState<_EmailDialog> createState() => _EmailDialogState();
}

class _EmailDialogState extends ConsumerState<_EmailDialog> {
  late final TextEditingController _to =
      TextEditingController(text: widget.defaultTo ?? '');
  bool _busy = false;
  String? _error;
  bool _sentSomething = false;

  /// Off by default. A link is the better thing to send and the one
  /// that reports back; attaching is the accommodation, not the norm.
  bool _attachPdf = false;

  @override
  void dispose() {
    _to.dispose();
    super.dispose();
  }

  /// Deliberately permissive, and deliberately not the only check. The
  /// database applies the same rule and is the one that counts; this
  /// exists so a typo is caught before a round trip rather than coming
  /// back as a red banner.
  bool get _addressLooksSane {
    final v = _to.text.trim();
    if (v.isEmpty) return true; // falls back to the customer record
    return RegExp(r'^[^@\s,]+@[^@\s,]+\.[^@\s,]{2,}$').hasMatch(v);
  }

  @override
  Widget build(BuildContext context) {
    final activity = ref.watch(documentActivityProvider(widget.documentId));

    return AlertDialog(
      title: Text('Email ${widget.docNo}'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _to,
                keyboardType: TextInputType.emailAddress,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Send to',
                  hintText: widget.defaultTo ?? 'the address on the customer',
                  helperText: widget.defaultTo == null
                      ? 'This customer has no address saved — type one'
                      : 'Leave as-is to use the customer’s address',
                  errorText: _addressLooksSane
                      ? null
                      : 'That does not look like an email address',
                ),
              ),
              const SizedBox(height: Space.md),
              Text(
                'The message carries a link to this document. A new link '
                'is issued for whoever you send it to, and it replaces '
                'any link issued before.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (widget.buildPdf != null)
                CheckboxListTile(
                  value: _attachPdf,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _attachPdf = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Attach the PDF as well'),
                  // The honest case for leaving it off. A link is always
                  // the current document and records that somebody
                  // opened it; a PDF is a snapshot that will still be
                  // sitting in a mailbox looking authoritative after the
                  // invoice has been credited and reissued.
                  subtitle: Text(
                    _attachPdf
                        ? 'A copy of the document as it stands now travels '
                            'with the message and stays as it is.'
                        : 'Link only. It always shows the current document, '
                            'and tells you when it was opened.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: Space.md),
                Text(_error!,
                    style: TextStyle(color: context.colors.danger)),
              ],
              const Divider(height: Space.xl),
              Text('History', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Space.xs),
              AsyncView(
                value: activity,
                onRetry: () => ref
                    .invalidate(documentActivityProvider(widget.documentId)),
                // Three, because this list sits under the form inside a
                // dialog and the dialog is already as tall as the
                // screen allows. An eighteen-pixel icon at the front,
                // not an avatar.
                skeleton: const CardRowsSkeleton(
                  rows: 3,
                  leadingSize: 18,
                  rowGap: Space.xs,
                ),
                builder: (list) => list.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: Space.md),
                        child: Text(
                            'Nothing has been sent, shared or downloaded.'),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [for (final e in list) _ActivityTile(entry: e)],
                      ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, _sentSomething),
          child: const Text('Close'),
        ),
        OutlinedButton.icon(
          onPressed: _busy || !_addressLooksSane ? null : () => _send(now: false),
          icon: const Icon(Icons.schedule_send_outlined, size: 18),
          label: const Text('Queue it'),
        ),
        FilledButton.icon(
          onPressed: _busy || !_addressLooksSane ? null : () => _send(now: true),
          icon: const Icon(Icons.send_outlined, size: 18),
          label: const Text('Send now'),
        ),
      ],
    );
  }

  Future<void> _send({required bool now}) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final to = _to.text.trim().isEmpty ? null : _to.text.trim();

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      // Rendered and uploaded before the row is queued, because the row
      // has to name the file. A failure here stops the send rather than
      // quietly posting a link-only message somebody believed carried an
      // attachment.
      String? path;
      String? name;
      if (_attachPdf && widget.buildPdf != null) {
        final stem = widget.docNo
            .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
            .toLowerCase();
        name = '$stem.pdf';
        path = await repo.uploadDocumentPdf(
            widget.documentId, name, await widget.buildPdf!());
      }

      String message;
      // Whether the dialog has done its job and should get out of the
      // way. Everything except an outright provider refusal has: a row
      // that is queued rather than sent is still going, and the snackbar
      // says so. A refusal is the one case with something left to do
      // here — usually the address in the field above — so that stays
      // open with the reason on screen.
      var finished = true;

      if (now) {
        final outcome = sendNowOutcome(await repo.emailDocumentNow(
            widget.documentId,
            to: to,
            attachmentPath: path,
            attachmentName: name));
        message = outcome.message;
        finished = outcome.finished;
        _error = outcome.error;
      } else {
        await repo.emailDocument(widget.documentId,
            to: to, attachmentPath: path, attachmentName: name);
        message = 'Queued — it will go out on the next send';
      }

      _sentSomething = true;
      ref.invalidate(documentActivityProvider(widget.documentId));
      ref.invalidate(documentShareLinksProvider(widget.documentId));
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(message)));
      // Popped after the snackbar is handed to the messenger, which
      // outlives this route — otherwise the message goes with the
      // dialog and nobody learns what happened.
      if (finished) Navigator.pop(context, true);
    } catch (e) {
      // Shown in the dialog rather than a snackbar: the address that
      // caused it is on screen and usually needs editing, and a banner
      // that vanishes takes the reason with it.
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// The history on its own, for looking rather than sending.
///
/// The same list appears inside the send dialog, where it answers "have
/// I already sent this?" before you send it again. This one answers the
/// question a week later, when the customer says they never received it
/// and nobody wants to open a compose box to find out.
Future<void> showActivityDialog(
    BuildContext context, String documentId, String docNo) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ActivityDialog(documentId: documentId, docNo: docNo),
  );
}

class _ActivityDialog extends ConsumerWidget {
  const _ActivityDialog({required this.documentId, required this.docNo});

  final String documentId;
  final String docNo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activity = ref.watch(documentActivityProvider(documentId));
    return AlertDialog(
      title: Text('History of $docNo'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: AsyncView(
            value: activity,
            onRetry: () => ref.invalidate(documentActivityProvider(documentId)),
            // The same rows, in a dialog that is nothing but them, so
            // there is room for more of an outline.
            skeleton: const CardRowsSkeleton(
              rows: 5,
              leadingSize: 18,
              rowGap: Space.xs,
            ),
            builder: (list) => list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: Space.md),
                    child: Text('Nothing has happened to this yet.'),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final e in list) _ActivityTile(entry: e)],
                  ),
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// One thing that happened, in the past tense.
class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.entry});

  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final line = ActivityLine.from(entry);
    final at = DateTime.tryParse(entry['at'] as String? ?? '');

    final colour = switch (line.tone) {
      ActivityTone.good => context.colors.success,
      ActivityTone.bad => context.colors.danger,
      ActivityTone.waiting => context.colors.warning,
      ActivityTone.neutral => context.colors.info,
      ActivityTone.muted => Theme.of(context).disabledColor,
    };
    final icon = switch (line.icon) {
      'mail' => Icons.mail_outline,
      'link' => Icons.link,
      'history' => Icons.history,
      'payment' => Icons.payments_outlined,
      'einvoice' => Icons.receipt_long_outlined,
      _ => Icons.picture_as_pdf_outlined,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: colour),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(line.label,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: Space.sm),
                  // Not StatusChip: its palette is keyed to document
                  // statuses, and half of these words ('opened',
                  // 'revoked', 'downloaded') would land on its neutral
                  // grey — which is the one thing this list must not do,
                  // since opened and revoked are the two facts somebody
                  // is scanning for.
                  if (line.badge.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: colour.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(line.badge,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: colour)),
                    ),
                  if (line.detail != null) ...[
                    const SizedBox(width: Space.sm),
                    Flexible(
                      child: Text(line.detail!,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ],
                ]),
                if (line.recipient != null)
                  Text(line.recipient!,
                      style: Theme.of(context).textTheme.bodySmall),
                if (line.note != null)
                  Text(line.note!,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Theme.of(context).hintColor)),
              ],
            ),
          ),
          if (at != null)
            Text(Fmt.dateTime(at),
                style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
