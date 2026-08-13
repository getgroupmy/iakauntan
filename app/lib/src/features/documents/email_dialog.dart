import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
// Not unused: emailDocument and friends live in an `extension on Repo`,
// and an extension is only in scope where its library is imported.
import '../../data/repository.dart';

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
      if (now) {
        final row = await repo.emailDocumentNow(widget.documentId,
            to: to, attachmentPath: path, attachmentName: name);
        final status = row['status'] as String?;
        // The row is the truth, not the fact that the call returned.
        // A drain that failed leaves it queued, and saying "sent" then
        // would be a lie the customer discovers before you do.
        message = switch (status) {
          'sent' => 'Sent to ${row['to_email']}',
          'failed' => 'Could not send: ${row['last_error'] ?? 'the provider refused it'}',
          _ => 'Queued — mail is not sending right now, so it will go '
              'out on the next scheduled send',
        };
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

/// One thing that happened, in the past tense.
class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.entry});

  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final kind = entry['kind'] as String? ?? '';
    final status = entry['status'] as String? ?? '';
    final at = DateTime.tryParse(entry['at'] as String? ?? '');

    final (IconData icon, Color colour) = switch (kind) {
      'email' => (
          Icons.mail_outline,
          switch (status) {
            'sent' => context.colors.success,
            'failed' => context.colors.danger,
            'cancelled' => Theme.of(context).disabledColor,
            _ => context.colors.warning,
          }
        ),
      'share link' => (
          Icons.link,
          switch (status) {
            'opened' => context.colors.success,
            'revoked' || 'expired' => Theme.of(context).disabledColor,
            _ => context.colors.info,
          }
        ),
      _ => (Icons.picture_as_pdf_outlined, context.colors.info),
    };

    final recipient = entry['recipient'] as String?;
    final detail = entry['detail'] as String?;
    final note = entry['note'] as String?;

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
                  Text(
                    switch (kind) {
                      'email' => 'Emailed',
                      'share link' => 'Link shared',
                      _ => 'PDF downloaded',
                    },
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: Space.sm),
                  // Not StatusChip: its palette is keyed to document
                  // statuses, and half of these words ('opened',
                  // 'revoked', 'downloaded') would land on its neutral
                  // grey — which is the one thing this list must not do,
                  // since opened and revoked are the two facts somebody
                  // is scanning for.
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: colour.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(status,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: colour)),
                  ),
                  if (detail != null) ...[
                    const SizedBox(width: Space.sm),
                    Text(detail,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ]),
                if (recipient != null)
                  Text(recipient,
                      style: Theme.of(context).textTheme.bodySmall),
                if (note != null)
                  Text(note,
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
