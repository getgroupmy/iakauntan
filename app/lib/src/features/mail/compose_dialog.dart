import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/denials.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../data/reserved_names_repository.dart';
import 'attachments.dart';
import 'compose.dart';

/// Writing something, or answering something that arrived.
///
/// One dialog for both, because they are the same four boxes with
/// different things already in them. A reply arrives here with its
/// address, its subject, its mailbox and the original quoted
/// underneath; a new message arrives with the mailbox and nothing else.
///
/// Nothing here sends. `send_from_mailbox` queues a row and
/// `send-email` drains it, so the button means "queued" and the screen
/// says so.
Future<void> showCompose(
  BuildContext context,
  WidgetRef ref, {
  String? mailboxId,
  String? to,
  String? subject,
  String? body,
  String? inReplyTo,
}) async {
  final sent = await showDialog<bool>(
    context: context,
    builder: (ctx) => _ComposeDialog(
      mailboxId: mailboxId,
      to: to,
      subject: subject,
      body: body,
      inReplyTo: inReplyTo,
    ),
  );
  if (sent != true || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    // "Queued" rather than "Sent", which is the truth and is also the
    // thing somebody needs to know if it never arrives.
    const SnackBar(content: Text('Queued. It goes out within a few minutes.')),
  );
}

class _ComposeDialog extends ConsumerStatefulWidget {
  const _ComposeDialog({
    this.mailboxId,
    this.to,
    this.subject,
    this.body,
    this.inReplyTo,
  });

  final String? mailboxId;
  final String? to;
  final String? subject;
  final String? body;
  final String? inReplyTo;

  @override
  ConsumerState<_ComposeDialog> createState() => _ComposeDialogState();
}

class _ComposeDialogState extends ConsumerState<_ComposeDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _to =
      TextEditingController(text: widget.to ?? '');
  late final TextEditingController _subject =
      TextEditingController(text: widget.subject ?? '');
  late final TextEditingController _body =
      TextEditingController(text: widget.body ?? '');

  String? _mailboxId;
  bool _sending = false;
  String? _error;

  /// One file, held in memory until the message is sent.
  ///
  /// Uploaded at send rather than at choose, so a message somebody
  /// abandons leaves nothing in the bucket. One rather than many
  /// because `email_outbox` carries one pair of columns and has since
  /// `0109`; a second would be a schema change, not a button.
  PlatformFile? _file;

  @override
  void initState() {
    super.initState();
    _mailboxId = widget.mailboxId;
  }

  @override
  void dispose() {
    _to.dispose();
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final boxes = ref.watch(myMailboxesProvider).valueOrNull ?? const [];
    final domain = ref.watch(mailDomainProvider).valueOrNull ?? 'iakauntan.com';

    // One address is not a choice. A picker holding a single option is
    // a control that can only be operated one way.
    if (_mailboxId == null && boxes.length == 1) {
      _mailboxId = '${boxes.first['id']}';
    }

    return AlertDialog(
      title: Text(widget.inReplyTo == null ? 'New message' : 'Reply'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (boxes.isEmpty)
                  const Text(
                    'You have no address to send from yet. Ask for one in '
                    'Settings, under Names and addresses.',
                  )
                else if (boxes.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.md),
                    child: SearchablePicker<String>(
                      label: 'From',
                      value: _mailboxId,
                      options: [
                        for (final b in boxes)
                          PickerOption(
                            value: '${b['id']}',
                            label: mailboxAddress(b, domain),
                            sublabel: mailboxKind(b),
                            keywords: ['${b['local_part']}'],
                          ),
                      ],
                      onChanged: (v) => setState(() => _mailboxId = v),
                      validator: (v) =>
                          v == null ? 'Which address is this from?' : null,
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.md),
                    child: Text(
                      'From ${mailboxAddress(boxes.first, domain)}',
                      style: TextStyle(color: context.scheme.onSurfaceVariant),
                    ),
                  ),
                TextFormField(
                  controller: _to,
                  enabled: boxes.isNotEmpty,
                  autofocus: widget.to == null,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'To'),
                  validator: (v) => checkRecipient(v ?? ''),
                ),
                const SizedBox(height: Space.md),
                TextFormField(
                  controller: _subject,
                  enabled: boxes.isNotEmpty,
                  decoration: const InputDecoration(labelText: 'Subject'),
                ),
                const SizedBox(height: Space.md),
                TextFormField(
                  controller: _body,
                  enabled: boxes.isNotEmpty,
                  autofocus: widget.to != null,
                  minLines: 8,
                  maxLines: 16,
                  decoration: const InputDecoration(
                    labelText: 'Message',
                    alignLabelWithHint: true,
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'A message needs something in it.'
                      : null,
                ),
                if (boxes.isNotEmpty) _attachment(context),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.md),
                    child: Text(
                      _error!,
                      style: TextStyle(color: context.scheme.error),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _sending || boxes.isEmpty ? null : _send,
          child: Text(_sending ? 'Sending…' : 'Send'),
        ),
      ],
    );
  }

  /// Choose a file, or say which one is already chosen.
  Widget _attachment(BuildContext context) {
    final file = _file;
    return Padding(
      padding: const EdgeInsets.only(top: Space.md),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _sending ? null : _pickFile,
            icon: const Icon(Icons.attach_file, size: 18),
            label: Text(file == null ? 'Attach a file' : 'Change'),
          ),
          if (file != null) ...[
            const SizedBox(width: Space.sm),
            Expanded(
              child: Text(
                [file.name, sizeLabel(file.size)]
                    .whereType<String>()
                    .join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: context.scheme.onSurfaceVariant,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.close, size: 18),
              onPressed: _sending ? null : () => setState(() => _file = null),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _pickFile() async {
    // withData because the web has no path to read from afterwards, and
    // the upload wants bytes on every platform anyway.
    final result = await FilePicker.platform.pickFiles(withData: true);
    final file = result?.files.singleOrNull;
    if (file == null || file.bytes == null || !mounted) return;
    setState(() => _file = file);
  }

  Future<void> _send() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final mailboxId = _mailboxId;
    if (mailboxId == null) {
      setState(() => _error = 'Choose which address this is from.');
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final client = ref.read(supabaseProvider);
      String? path;
      final file = _file;
      if (file != null && file.bytes != null) {
        final orgId = ref.read(currentOrgIdProvider);
        if (orgId == null) throw StateError('No company is open.');
        // Uploaded now rather than when it was chosen, so a message
        // somebody changed their mind about leaves nothing behind.
        path = await uploadMailboxAttachment(
          client,
          orgId: orgId,
          mailboxId: mailboxId,
          filename: file.name,
          bytes: file.bytes!,
        );
      }

      await sendFromMailbox(
        client,
        mailboxId: mailboxId,
        to: _to.text,
        subject: _subject.text,
        body: _body.text,
        inReplyTo: widget.inReplyTo,
        attachmentPath: path,
        attachmentName: path == null ? null : file!.name,
      );
      ref.invalidate(mailboxThreadProvider(mailboxId));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      // The refusals from `send_from_mailbox` are written to be read by
      // the person who caused them, so they are shown rather than
      // replaced with something vaguer.
      if (mounted) {
        setState(() {
          _sending = false;
          _error = deniedDetail(e);
        });
      }
    }
  }
}
