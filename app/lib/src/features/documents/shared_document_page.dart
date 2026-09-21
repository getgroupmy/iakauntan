import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/theme.dart';

/// What a customer sees when they are sent a link to their invoice.
///
/// Every document in this system could be turned into a PDF and then had
/// nowhere to go: whoever made it downloaded the file and took over by
/// hand. This is the other end of that.
///
/// Like [SigningPage] it works with no account and does not use
/// [repoProvider]: there may be no signed-in user, and
/// `open_shared_document` authorises itself against the token rather
/// than against a JWT. What comes back is chosen in that function and
/// deliberately excludes internal notes and line cost, so there is
/// nothing here to hide in the presentation.
class SharedDocumentPage extends ConsumerStatefulWidget {
  const SharedDocumentPage({super.key, required this.token});

  final String token;

  @override
  ConsumerState<SharedDocumentPage> createState() =>
      _SharedDocumentPageState();
}

class _SharedDocumentPageState extends ConsumerState<SharedDocumentPage> {
  late final Future<Map<String, dynamic>> _doc = _open();

  Future<Map<String, dynamic>> _open() async {
    final data = await Supabase.instance.client
        .rpc('open_shared_document', params: {'p_token': widget.token});
    return Map<String, dynamic>.from(data as Map);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scheme.surfaceContainerLowest,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Space.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: FutureBuilder<Map<String, dynamic>>(
              future: _doc,
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

                final d = snap.data ?? const {'state': 'invalid'};
                final state = d['state']?.toString() ?? 'invalid';
                if (state != 'open') return _stateMessage(state);
                return _Document(data: d, token: widget.token);
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Every unhappy state says the same thing in different words: ask the
  /// sender. Naming which of them it is helps the customer say something
  /// useful when they do.
  Widget _stateMessage(String state) => switch (state) {
        'expired' => const _Message(
            icon: Icons.schedule,
            title: 'This link has expired',
            body: 'Ask whoever sent it for a new one.',
          ),
        'revoked' => const _Message(
            icon: Icons.link_off,
            title: 'This link is no longer in use',
            body: 'A newer link may have replaced it. Ask whoever sent it.',
          ),
        'withdrawn' => const _Message(
            icon: Icons.block,
            title: 'This document has been withdrawn',
            body: 'It was cancelled after the link was sent.',
          ),
        _ => const _Message(
            icon: Icons.help_outline,
            title: 'We cannot find this document',
            body: 'Check the link is complete, or ask whoever sent it.',
          ),
      };
}

class _Document extends StatelessWidget {
  const _Document({required this.data, required this.token});

  final Map<String, dynamic> data;
  final String token;

  @override
  Widget build(BuildContext context) {
    final company = Map<String, dynamic>.from(data['company'] as Map? ?? {});
    final contact = Map<String, dynamic>.from(data['contact'] as Map? ?? {});
    final doc = Map<String, dynamic>.from(data['document'] as Map? ?? {});
    final lines = ((data['lines'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final payWith = ((data['pay_with'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final currency = doc['currency']?.toString() ?? 'MYR';
    final outstanding = Fmt.toDouble(doc['balance_amount']);
    final due = Fmt.parseDate(doc['due_date']);
    final overdue = outstanding > 0 &&
        due != null &&
        due.isBefore(DateTime.now().subtract(const Duration(days: 1)));

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(company: company, doc: doc),
            const Divider(height: Space.xl),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('To', style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 2),
                    Text(contact['name']?.toString() ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    if ((contact['address']?.toString() ?? '').isNotEmpty)
                      Text(contact['address'].toString(),
                          style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _Field('Date', Fmt.date(Fmt.parseDate(doc['doc_date']))),
                    if (due != null) _Field('Due', Fmt.date(due)),
                    if ((doc['reference']?.toString() ?? '').isNotEmpty)
                      _Field('Reference', doc['reference'].toString()),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: Space.lg),
            _Lines(lines: lines, currency: currency),
            const SizedBox(height: Space.lg),
            _Totals(doc: doc, currency: currency),
            if (outstanding > 0) ...[
              const SizedBox(height: Space.lg),
              _Outstanding(
                amount: outstanding,
                currency: currency,
                due: due,
                overdue: overdue,
              ),
              // Only where the company has an acquirer set up and
              // something to settle through it. `shared_payment_options`
              // decides that in SQL and answers with an empty list
              // otherwise, so there is no button that leads nowhere.
              _PayWith(token: token, options: payWith),
            ],
            if ((doc['notes']?.toString() ?? '').isNotEmpty) ...[
              const SizedBox(height: Space.lg),
              Text(doc['notes'].toString(),
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            if ((doc['terms_conditions']?.toString() ?? '').isNotEmpty) ...[
              const SizedBox(height: Space.md),
              Text(doc['terms_conditions'].toString(),
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.company, required this.doc});

  final Map<String, dynamic> company;
  final Map<String, dynamic> doc;

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(company['name']?.toString() ?? '',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            for (final bit in [
              if ((company['registration_no']?.toString() ?? '').isNotEmpty)
                'Reg. ${company['registration_no']}',
              if ((company['sst_registration_no']?.toString() ?? '').isNotEmpty)
                'SST ${company['sst_registration_no']}',
              // The same line the PDF carries. This page and that file
              // are one document seen two ways, and a registration on
              // one and not the other is a customer reading a different
              // tax invoice from the one in their inbox.
              if ((company['tourism_tax_reg_no']?.toString() ?? '').isNotEmpty)
                'TTx ${company['tourism_tax_reg_no']}',
              if ((company['address']?.toString() ?? '').isNotEmpty)
                company['address'].toString(),
              if ((company['phone']?.toString() ?? '').isNotEmpty)
                company['phone'].toString(),
              if ((company['email']?.toString() ?? '').isNotEmpty)
                company['email'].toString(),
            ])
              Text(bit, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(Fmt.label(doc['doc_type']?.toString() ?? '').toUpperCase(),
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          Text(doc['doc_no']?.toString() ?? '',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    ]);
  }
}

class _Lines extends StatelessWidget {
  const _Lines({required this.lines, required this.currency});

  final List<Map<String, dynamic>> lines;
  final String currency;

  @override
  Widget build(BuildContext context) {
    // Horizontal scroll rather than a squeeze: a customer opening this
    // on a phone should be able to read the description.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: MediaQuery.sizeOf(context).width < 700 ? 640 : 0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _LineRow(
              description: 'Description',
              qty: 'Qty',
              price: 'Price',
              total: 'Amount',
              header: true,
            ),
            const Divider(height: 8),
            for (final l in lines)
              _LineRow(
                description: l['description']?.toString() ?? '',
                qty: '${Fmt.qty(Fmt.toDouble(l['quantity']))} '
                    '${l['uom_code'] ?? ''}'.trim(),
                price: Fmt.money(Fmt.toDouble(l['unit_price'])),
                total: Fmt.money(Fmt.toDouble(l['line_total'])),
              ),
          ],
        ),
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.description,
    required this.qty,
    required this.price,
    required this.total,
    this.header = false,
  });

  final String description;
  final String qty;
  final String price;
  final String total;
  final bool header;

  @override
  Widget build(BuildContext context) {
    final style = header
        ? Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(fontWeight: FontWeight.w600)
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 5, child: Text(description, style: style)),
        SizedBox(
            width: 90,
            child: Text(qty, textAlign: TextAlign.right, style: style)),
        SizedBox(
            width: 110,
            child: Text(price, textAlign: TextAlign.right, style: style)),
        SizedBox(
            width: 120,
            child: Text(total, textAlign: TextAlign.right, style: style)),
      ]),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.doc, required this.currency});

  final Map<String, dynamic> doc;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final discount = Fmt.toDouble(doc['discount_amount']);
    final tax = Fmt.toDouble(doc['tax_amount']);
    final shipping = Fmt.toDouble(doc['shipping_amount']);
    final serviceCharge = Fmt.toDouble(doc['service_charge_amount']);
    final rounding = Fmt.toDouble(doc['rounding_amount']);
    final paid = Fmt.toDouble(doc['paid_amount']);

    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: 320,
        child: Column(children: [
          _Total('Subtotal', Fmt.toDouble(doc['subtotal']), currency),
          if (discount != 0) _Total('Discount', -discount, currency),
          if (shipping != 0) _Total('Delivery', shipping, currency),
          // Above the tax, where a Malaysian bill puts it: the service
          // tax underneath is charged on the amount that includes it,
          // so a customer reading down the column can follow it.
          if (serviceCharge != 0)
            _Total('Service charge', serviceCharge, currency),
          if (tax != 0) _Total('Tax', tax, currency),
          if (rounding != 0) _Total('Rounding', rounding, currency),
          const Divider(),
          _Total('Total', Fmt.toDouble(doc['total_amount']), currency,
              bold: true),
          if (paid != 0) _Total('Paid', -paid, currency),
        ]),
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total(this.label, this.amount, this.currency, {this.bold = false});

  final String label;
  final double amount;
  final String currency;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(label, style: style)),
        Text('$currency ${Fmt.money(amount)}', style: style),
      ]),
    );
  }
}

/// The number the customer came here for.
class _Outstanding extends StatelessWidget {
  const _Outstanding({
    required this.amount,
    required this.currency,
    required this.due,
    required this.overdue,
  });

  final double amount;
  final String currency;
  final DateTime? due;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    final colour = overdue ? context.colors.danger : context.colors.warning;

    return Container(
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colour.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(overdue ? 'Overdue' : 'Amount due',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: colour)),
              if (due != null)
                Text(
                  overdue
                      ? 'Was due on ${Fmt.date(due)}'
                      : 'Due on ${Fmt.date(due)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
        Text('$currency ${Fmt.money(amount)}',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700, color: colour)),
      ]),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label ', style: Theme.of(context).textTheme.bodySmall),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ]),
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
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Space.xxl),
        child: Column(children: [
          Icon(icon, size: 40, color: context.scheme.onSurfaceVariant),
          const SizedBox(height: Space.md),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Space.xs),
          Text(body,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}

/// The Pay button, and what happens when it is pressed.
///
/// The payer has no account and never will, so everything here runs as
/// `anon`: `pay-invoice` takes the share token, and the token is checked
/// in SQL rather than in the browser. Nothing on this page knows the
/// amount it is paying — `begin_shared_payment` reads that off the
/// document — and nothing here knows the company's acquirer key.
class _PayWith extends StatefulWidget {
  const _PayWith({required this.token, required this.options});

  final String token;
  final List<Map<String, dynamic>> options;

  @override
  State<_PayWith> createState() => _PayWithState();
}

class _PayWithState extends State<_PayWith> {
  String? _busy;
  String? _error;

  Future<void> _pay(String gateway) async {
    setState(() {
      _busy = gateway;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'pay-invoice',
        body: {'token': widget.token, 'gateway': gateway},
      );
      final data = Map<String, dynamic>.from(res.data as Map? ?? {});
      final url = data['url']?.toString();
      if (url == null || url.isEmpty) {
        throw Exception(data['error']?.toString() ?? 'No checkout was given');
      }
      // The acquirer's own page. Same tab: a payer sent back by the
      // acquirer should land on the invoice they started from, and a
      // popup blocker is not a thing to fight on somebody else's device.
      await launchUrl(Uri.parse(url), webOnlyWindowName: '_self');
    } catch (e) {
      // Whatever went wrong, the payer is told one sentence and the
      // invoice is unchanged. Nothing here has taken any money.
      if (mounted) {
        setState(() => _error = 'The payment could not be started.');
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.options.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final o in widget.options)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.sm),
              child: FilledButton.icon(
                onPressed: _busy == null
                    ? () => _pay(o['code']?.toString() ?? '')
                    : null,
                icon: _busy == o['code']
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.lock_outline, size: 18),
                label: Text('Pay with ${o['name'] ?? o['code']}'),
              ),
            ),
          if (_error != null)
            Text(
              _error!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.scheme.error),
            ),
        ],
      ),
    );
  }
}
