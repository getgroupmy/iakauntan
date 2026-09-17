import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// The certificate a version 1.1 e-Invoice is signed with.
///
/// `0615`. A 1.0 document is submitted as it stands; a 1.1 one has to
/// carry a XAdES signature made with a certificate from a Malaysian
/// certification authority, and LHDN recomputes the digests and the
/// signature before it will validate anything.
///
/// Two PEM blocks go in and nothing comes back out. The private key is
/// written to `einvoice_credentials`, a table with RLS, no policies and
/// no grants at all — the edge function is its only reader, through the
/// service role. This card can ask whether one is on file and what it
/// says about itself; it can never read it back.
///
/// **Check before Save.** The button that matters is the first one: a
/// key that does not match its certificate produces a structurally
/// perfect document that LHDN rejects at validation, hours later, with
/// a code naming neither half. Checked here it is a sentence on the
/// screen of the person holding both files.

/// How long is left, in the words to show — or null where nothing needs
/// saying.
///
/// Public and pure. Three bands rather than a date, because "expires on
/// 14 March" is a fact and "expires in 9 days" is a thing to do this
/// week. Signing with an expired certificate is not a degraded mode: it
/// is every e-Invoice from that moment on being rejected.
String? certificateWarning(DateTime? expiresAt, {DateTime? now}) {
  if (expiresAt == null) return null;
  final today = now ?? DateTime.now();
  final days = expiresAt.difference(today).inDays;
  if (days < 0) {
    return 'This certificate expired on ${Fmt.date(expiresAt)}. Every '
        'version 1.1 e-Invoice signed with it will be rejected — renew it '
        'with your certification authority and load the new one.';
  }
  if (days <= 30) {
    return 'This certificate expires in $days '
        '${days == 1 ? 'day' : 'days'}, on ${Fmt.date(expiresAt)}. A '
        'renewal takes longer than that with most certification '
        'authorities.';
  }
  return null;
}

/// Whether a warning is the kind that has already gone wrong.
bool certificateHasExpired(DateTime? expiresAt, {DateTime? now}) =>
    expiresAt != null && expiresAt.isBefore(now ?? DateTime.now());

class EinvoiceCertificateCard extends ConsumerStatefulWidget {
  const EinvoiceCertificateCard({
    super.key,
    required this.canEdit,
    required this.environment,
  });

  final bool canEdit;

  /// Which environment the company is submitting to. A certificate is
  /// per environment, the same way the client id and secret are: the
  /// one that signs sandbox documents is usually a test certificate and
  /// putting it on production is how a real invoice goes out unsigned.
  final String environment;

  @override
  ConsumerState<EinvoiceCertificateCard> createState() =>
      _EinvoiceCertificateCardState();
}

class _EinvoiceCertificateCardState
    extends ConsumerState<EinvoiceCertificateCard> {
  final _certificate = TextEditingController();
  final _key = TextEditingController();
  bool _busy = false;

  /// What the last Check said, so Save is pressed knowing the answer.
  Map<String, dynamic>? _checked;

  @override
  void dispose() {
    _certificate.dispose();
    _key.dispose();
    super.dispose();
  }

  bool get _hasBoth =>
      _certificate.text.trim().isNotEmpty && _key.text.trim().isNotEmpty;

  Future<void> _check() async {
    setState(() => _busy = true);
    Map<String, dynamic>? result;
    await runWithFeedback(
      context,
      successMessage: 'The key matches the certificate',
      action: () async {
        result = await ref
            .read(repoProvider)!
            .saveEinvoiceCertificate(
              certificatePem: _certificate.text.trim(),
              privateKeyPem: _key.text.trim(),
              environment: widget.environment,
              checkOnly: true,
            );
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _checked = result?['certificate'] as Map<String, dynamic>?;
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'The signing certificate is on file',
      action: () => ref
          .read(repoProvider)!
          .saveEinvoiceCertificate(
            certificatePem: _certificate.text.trim(),
            privateKeyPem: _key.text.trim(),
            environment: widget.environment,
          ),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        // Cleared on purpose. Leaving a private key sitting in a text
        // box on a screen somebody walks away from is the one thing
        // this card should never do.
        _certificate.clear();
        _key.clear();
        _checked = null;
      }
    });
    if (ok) ref.invalidate(einvoiceStatusProvider);
  }

  Future<void> _remove() async {
    final ok = await confirm(
      context,
      title: 'Remove the signing certificate?',
      message:
          'Version 1.1 e-Invoices cannot be submitted without one. What is '
          'already filed stays filed, and the client id and secret are '
          'left alone.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    final done = await runWithFeedback(
      context,
      successMessage: 'Removed',
      action: () => ref
          .read(repoProvider)!
          .clearEinvoiceSigningCertificate(widget.environment),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (done) ref.invalidate(einvoiceStatusProvider);
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(einvoiceStatusProvider);
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant);

    final rows = status.valueOrNull ?? const <Map<String, dynamic>>[];
    final row = rows.cast<Map<String, dynamic>?>().firstWhere(
      (r) => r?['environment'] == widget.environment,
      orElse: () => null,
    );
    final onFile = row?['has_certificate'] == true;
    final expiresAt = DateTime.tryParse('${row?['cert_expires_at'] ?? ''}');
    final warning = certificateWarning(expiresAt);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'The certificate that signs them',
              subtitle:
                  'A version 1.1 e-Invoice carries a digital signature. '
                  'Version 1.0 does not, and needs none of this.',
              action: onFile && widget.canEdit
                  ? TextButton(
                      key: const ValueKey('einvoice-cert-remove'),
                      onPressed: _busy ? null : _remove,
                      child: Text(
                        'Remove',
                        style: TextStyle(color: context.colors.danger),
                      ),
                    )
                  : null,
            ),
            if (onFile) ...[
              _Fact('Issued by', '${row?['cert_issuer_name'] ?? 'Unknown'}'),
              _Fact('Serial', '${row?['cert_serial_number'] ?? 'Unknown'}'),
              _Fact(
                'Valid until',
                expiresAt == null ? 'Unknown' : Fmt.date(expiresAt),
              ),
              if (warning != null) ...[
                const SizedBox(height: Space.sm),
                _Note(
                  warning,
                  key: const ValueKey('einvoice-cert-warning'),
                  color: certificateHasExpired(expiresAt)
                      ? context.colors.danger
                      : context.colors.warning,
                  icon: certificateHasExpired(expiresAt)
                      ? Icons.error_outline
                      : Icons.schedule_outlined,
                ),
              ],
              const Divider(height: Space.xl),
              Text(
                'Loading another replaces this one.',
                key: const ValueKey('einvoice-cert-replaces'),
                style: muted,
              ),
            ] else
              Text(
                'None on file for ${widget.environment}. A version 1.1 '
                'submission will be refused until there is one, naming the '
                'documents it would have signed.',
                key: const ValueKey('einvoice-cert-none'),
                style: muted,
              ),
            const SizedBox(height: Space.md),
            TextField(
              key: const ValueKey('einvoice-cert-pem'),
              controller: _certificate,
              enabled: widget.canEdit && !_busy,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Certificate',
                helperText: 'The block beginning -----BEGIN CERTIFICATE-----',
              ),
              onChanged: (_) => setState(() => _checked = null),
            ),
            const SizedBox(height: Space.md),
            TextField(
              key: const ValueKey('einvoice-cert-key'),
              controller: _key,
              enabled: widget.canEdit && !_busy,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Private key',
                helperText:
                    'The block beginning -----BEGIN PRIVATE KEY-----. It is '
                    'written where nothing in this app can read it back.',
              ),
              onChanged: (_) => setState(() => _checked = null),
            ),
            const SizedBox(height: Space.sm),
            Text(
              'A certification authority usually sends one .p12 file holding '
              'both. Convert it once:\n'
              '    openssl pkcs12 -in signing.p12 -nodes -legacy -out signing.pem\n'
              'and paste the two blocks from that file.',
              key: const ValueKey('einvoice-cert-p12'),
              style: muted,
            ),
            if (_checked != null) ...[
              const SizedBox(height: Space.md),
              _Note(
                'Read: issued by ${_checked!['issuer']}, serial '
                '${_checked!['serial_number']}, valid until '
                '${'${_checked!['expires_at']}'.split('T').first}. The key '
                'matches it.',
                key: const ValueKey('einvoice-cert-checked'),
                color: context.colors.success,
                icon: Icons.check_circle_outline,
              ),
            ],
            const SizedBox(height: Space.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('einvoice-cert-check'),
                  onPressed: widget.canEdit && !_busy && _hasBoth
                      ? _check
                      : null,
                  child: const Text('Check the pair'),
                ),
                const SizedBox(width: Space.sm),
                FilledButton(
                  key: const ValueKey('einvoice-cert-save'),
                  onPressed: widget.canEdit && !_busy && _hasBoth
                      ? _save
                      : null,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: context.scheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(top: Space.xs),
      child: Wrap(
        spacing: Space.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(label, style: muted),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// A line with an icon in front of it, in the colour of what it means.
class _Note extends StatelessWidget {
  const _Note(this.text, {super.key, required this.color, required this.icon});

  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: Space.sm),
      Expanded(
        child: Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: color),
        ),
      ),
    ],
  );
}
