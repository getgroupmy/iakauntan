import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';
import 'tax_details.dart';

/// The page a customer fills in their own TIN on.
///
/// 0626. The third of the token-shaped pages, after [SharedDocumentPage]
/// and [CustomerPortalPage], and like both it works with no account and
/// does not use `repoProvider`: there may be no signed-in user, and
/// `open_tax_detail_request` authorises itself against the token rather
/// than against a JWT.
///
/// It shows what the company already holds, so that somebody corrects
/// rather than retypes — a blank form produces a conflict for every
/// field typed differently, and a conflict is the case that needs a
/// human, which is the case this page exists to avoid.
///
/// There is nothing about money on it. That is `open_customer_portal`,
/// a different token and a different page, and the separation is
/// asserted in `supabase/tests/tax_details.sql` rather than left to
/// this comment.
class TaxDetailsPage extends StatefulWidget {
  const TaxDetailsPage({super.key, required this.token});

  final String token;

  @override
  State<TaxDetailsPage> createState() => _TaxDetailsPageState();
}

class _TaxDetailsPageState extends State<TaxDetailsPage> {
  late final Future<TaxDetailsInvite> _invite = _open();

  Future<TaxDetailsInvite> _open() async {
    final data = await Supabase.instance.client
        .rpc('open_tax_detail_request', params: {'p_token': widget.token});
    final map = Map<String, dynamic>.from(data as Map);
    _states = [
      for (final s in (map['states'] as List? ?? const []))
        Map<String, dynamic>.from(s as Map),
    ];
    return TaxDetailsInvite.fromMap(map);
  }

  List<Map<String, dynamic>> _states = const [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scheme.surfaceContainerLowest,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Space.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: FutureBuilder<TaxDetailsInvite>(
              future: _invite,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(Space.xxl),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.hasError) {
                  return _Message(
                    icon: Icons.error_outline,
                    title: 'Something went wrong',
                    body: '${snap.error}',
                  );
                }
                final invite = snap.data;
                if (invite == null || !invite.isOpen) {
                  final m = taxDetailsStateMessage(invite?.state ?? 'invalid');
                  return _Message(
                    icon: switch (invite?.state) {
                      'expired' => Icons.schedule,
                      'revoked' => Icons.link_off,
                      'withdrawn' => Icons.block,
                      _ => Icons.help_outline,
                    },
                    title: m.title,
                    body: m.body,
                  );
                }
                return TaxDetailsForm(
                  token: widget.token,
                  invite: invite,
                  states: _states,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The form itself, public so a test can pump it without a Supabase
/// client behind it.
///
/// `bank_rules_card.dart` does the same and for the same reason: the
/// decisions worth asserting — what the form refuses, and what it says
/// afterwards — are made here, and a private State is a decision no
/// test can reach.
class TaxDetailsForm extends StatefulWidget {
  const TaxDetailsForm({
    super.key,
    required this.token,
    required this.invite,
    required this.states,
  });

  final String token;
  final TaxDetailsInvite invite;
  final List<Map<String, dynamic>> states;

  @override
  State<TaxDetailsForm> createState() => TaxDetailsFormState();
}

class TaxDetailsFormState extends State<TaxDetailsForm> {
  final _fields = <String, TextEditingController>{};
  final _who = TextEditingController();
  final _whoEmail = TextEditingController();
  String _idType = 'BRN';
  String? _stateCode;
  bool _sending = false;
  String? _thanks;

  @override
  void initState() {
    super.initState();
    // Pre-filled from what the company holds. The whole point: a
    // customer correcting one field should not have to retype an
    // address that was already right.
    for (final f in taxDetailFields) {
      if (f == 'id_type' || f == 'state_code') continue;
      _fields[f] = TextEditingController(text: widget.invite.held[f] ?? '');
    }
    final held = widget.invite.held;
    if ((held['id_type'] ?? '').isNotEmpty) _idType = held['id_type']!;
    _stateCode = (held['state_code'] ?? '').isEmpty
        ? null
        : held['state_code'];
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    _who.dispose();
    _whoEmail.dispose();
    super.dispose();
  }

  TextEditingController _c(String key) => _fields[key]!;

  /// What the form is refusing to send, or null.
  String? get problem => taxDetailsProblem(
    tin: _c('tin').text,
    idValue: _c('id_value').text,
    held: {
      for (final f in taxDetailFields)
        f: f == 'id_type'
            ? _idType
            : (f == 'state_code' ? (_stateCode ?? '') : _c(f).text),
    },
  );

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      final out = await Supabase.instance.client.rpc(
        'submit_tax_details',
        params: {
          'p_token': widget.token,
          'p_details': {
            for (final f in taxDetailFields)
              f: f == 'id_type'
                  ? _idType
                  : (f == 'state_code' ? _stateCode : _c(f).text.trim()),
            'submitted_by_name': _who.text.trim(),
            'submitted_by_email': _whoEmail.text.trim(),
          },
        },
      );
      if (!mounted) return;
      final map = Map<String, dynamic>.from(out as Map);
      setState(() {
        _thanks = taxDetailsThanks(
          companyName: widget.invite.companyName,
          awaitingReview: map['awaiting_review'] == true,
        );
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (_thanks != null) {
      return _Message(
        icon: Icons.check_circle_outline,
        title: 'Sent',
        body: _thanks!,
      );
    }

    final why = problem;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if ((widget.invite.logoUrl ?? '').isNotEmpty) ...[
                  Image.network(
                    widget.invite.logoUrl!,
                    height: 40,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                  const SizedBox(width: Space.md),
                ],
                Expanded(
                  child: Text(
                    widget.invite.companyName,
                    style: text.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            Text(
              'Your tax details for e-Invoicing',
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: Space.sm),
            Text(
              'Every invoice ${widget.invite.companyName} issues to '
              '${widget.invite.contactName} has to be submitted to LHDN, '
              'and it will not be accepted without your TIN and the '
              'number it was issued against. What they already hold is '
              'filled in below — please correct anything that is wrong.',
              style: text.bodyMedium,
            ),
            if (widget.invite.alreadySubmitted) ...[
              const SizedBox(height: Space.md),
              Text(
                'You have sent this form before. Sending it again '
                'replaces your earlier answer.',
                key: const ValueKey('tax-details-again'),
                style: text.bodySmall,
              ),
            ],
            const SizedBox(height: Space.lg),
            const Divider(),
            const SizedBox(height: Space.lg),

            TextField(
              controller: _c('tin'),
              key: const ValueKey('tax-details-tin'),
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Tax Identification Number (TIN)',
                helperText: 'From LHDN, e.g. C1234567890',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Space.lg),
            DropdownButtonFormField<String>(
              isExpanded: true,
              value: _idType,
              key: const ValueKey('tax-details-id-type'),
              decoration: const InputDecoration(labelText: 'ID type'),
              items: const [
                DropdownMenuItem(value: 'BRN', child: Text('BRN (business)')),
                DropdownMenuItem(
                  value: 'NRIC',
                  child: Text('NRIC (individual)'),
                ),
                DropdownMenuItem(value: 'PASSPORT', child: Text('Passport')),
                DropdownMenuItem(value: 'ARMY', child: Text('Army')),
              ],
              onChanged: (v) => setState(() => _idType = v ?? 'BRN'),
            ),
            const SizedBox(height: Space.lg),
            TextField(
              controller: _c('id_value'),
              key: const ValueKey('tax-details-id-value'),
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Registration or identification number',
                helperText: 'The number the TIN above was issued against',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Space.lg),
            TextField(
              controller: _c('sst_registration_no'),
              key: const ValueKey('tax-details-sst'),
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'SST number',
                helperText: 'Only if you are registered for SST',
              ),
            ),

            const SizedBox(height: Space.xl),
            Text('Where you are', style: text.titleSmall),
            const SizedBox(height: Space.md),
            for (final f in const [
              'address_line1',
              'address_line2',
              'address_line3',
            ]) ...[
              TextField(
                controller: _c(f),
                key: ValueKey('tax-details-$f'),
                decoration: InputDecoration(labelText: taxFieldLabel(f)),
              ),
              const SizedBox(height: Space.md),
            ],
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _c('postcode'),
                    key: const ValueKey('tax-details-postcode'),
                    decoration: const InputDecoration(labelText: 'Postcode'),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: TextField(
                    controller: _c('city'),
                    key: const ValueKey('tax-details-city'),
                    decoration: const InputDecoration(
                      labelText: 'Town or city',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            // Built from the list the server sent, not from a copy here:
            // these are LHDN's codes and a screen with its own copy goes
            // on offering the old ones. See 0627.
            DropdownButtonFormField<String>(
              isExpanded: true,
              value: _stateCode,
              key: const ValueKey('tax-details-state'),
              decoration: const InputDecoration(labelText: 'State'),
              items: [
                for (final s in widget.states)
                  DropdownMenuItem(
                    value: s['code']?.toString(),
                    child: Text(s['name']?.toString() ?? ''),
                  ),
              ],
              onChanged: (v) => setState(() => _stateCode = v),
            ),

            const SizedBox(height: Space.xl),
            Text('How to reach you', style: text.titleSmall),
            const SizedBox(height: Space.md),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _c('email'),
                    key: const ValueKey('tax-details-email'),
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: TextField(
                    controller: _c('phone'),
                    key: const ValueKey('tax-details-phone'),
                    decoration: const InputDecoration(labelText: 'Phone'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.lg),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _who,
                    key: const ValueKey('tax-details-who'),
                    decoration: const InputDecoration(
                      labelText: 'Your name',
                      helperText: 'So they know who filled this in',
                    ),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: TextField(
                    controller: _whoEmail,
                    key: const ValueKey('tax-details-who-email'),
                    decoration: const InputDecoration(
                      labelText: 'Your email',
                    ),
                  ),
                ),
              ],
            ),

            if (why != null) ...[
              const SizedBox(height: Space.lg),
              Text(
                why,
                key: const ValueKey('tax-details-problem'),
                style: text.bodySmall?.copyWith(color: context.scheme.error),
              ),
            ],
            const SizedBox(height: Space.lg),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const ValueKey('tax-details-send'),
                onPressed: why != null || _sending ? null : _send,
                child: Text(_sending ? 'Sending…' : 'Send these details'),
              ),
            ),
            const SizedBox(height: Space.md),
            // Said out loud on the page, not only in the email. Somebody
            // typing their company's tax number into a form they reached
            // from a link is entitled to know what it is for and what it
            // is not.
            Text(
              'Only ${widget.invite.companyName} sees this, and only to '
              'issue you invoices. There is nothing about your account or '
              'any amount owing on this page.',
              key: const ValueKey('tax-details-assurance'),
              style: text.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: context.scheme.outline),
            const SizedBox(height: Space.lg),
            Text(
              title,
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Space.sm),
            Text(body, style: text.bodyMedium, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
