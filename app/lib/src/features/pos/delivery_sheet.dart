import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/address_field.dart';
import '../../core/format.dart';
import '../../data/places_repository.dart';

/// What the counter takes down when somebody rings up to order.
typedef DeliveryAnswer = ({
  String line1,
  String line2,
  String city,
  String state,
  String postcode,
  String recipient,
  String phone,
  String notes,
  double? fee,
});

/// One line of an address, in the order an envelope has it.
///
/// Pure and exported so the board, the till and the tests all read the
/// same string. Blank parts are dropped rather than left as commas with
/// nothing between them, which is what an address typed by somebody in
/// a hurry always has.
String deliveryLine(Map<String, dynamic> row) {
  final parts = [
    '${row['address_line1'] ?? ''}',
    '${row['address_line2'] ?? ''}',
    [
      '${row['postcode'] ?? ''}',
      '${row['city'] ?? ''}',
    ].where((p) => p.trim().isNotEmpty).join(' '),
    '${row['state_name'] ?? ''}',
  ];
  return parts.where((p) => p.trim().isNotEmpty).join(', ');
}

/// How a run reads on the board.
///
/// Deliberately the words a shop uses rather than the enum: nobody at a
/// pass says "assigned".
String deliveryStatus(String? status) => switch (status) {
  'pending' => 'Waiting for a driver',
  'assigned' => 'With a driver',
  'collected' => 'On the way',
  'delivered' => 'Delivered',
  'failed' => 'Did not arrive',
  _ => '—',
};

/// Takes the address for a bill.
///
/// The fee is not asked for. It comes from the zone the postcode falls
/// in, and a shop that wants to charge something else can say so
/// afterwards on the row — putting the box here would have every
/// cashier typing a number that the zone already knows.
Future<DeliveryAnswer?> showDeliverySheet(
  BuildContext context, {
  Map<String, dynamic> existing = const {},
}) => showModalBottomSheet<DeliveryAnswer>(
  context: context,
  isScrollControlled: true,
  builder: (_) => Padding(
    padding: EdgeInsets.only(
      bottom: MediaQuery.of(context).viewInsets.bottom,
    ),
    child: _DeliverySheet(existing: existing),
  ),
);

class _DeliverySheet extends ConsumerStatefulWidget {
  const _DeliverySheet({required this.existing});

  final Map<String, dynamic> existing;

  @override
  ConsumerState<_DeliverySheet> createState() => _DeliverySheetState();
}

class _DeliverySheetState extends ConsumerState<_DeliverySheet> {
  late final TextEditingController _line1;
  late final TextEditingController _line2;
  late final TextEditingController _city;
  late final TextEditingController _state;
  late final TextEditingController _postcode;
  late final TextEditingController _recipient;
  late final TextEditingController _phone;
  late final TextEditingController _notes;

  @override
  void initState() {
    super.initState();
    String at(String key) => '${widget.existing[key] ?? ''}';
    _line1 = TextEditingController(text: at('address_line1'));
    _line2 = TextEditingController(text: at('address_line2'));
    _city = TextEditingController(text: at('city'));
    _state = TextEditingController(text: at('state_name'));
    _postcode = TextEditingController(text: at('postcode'));
    _recipient = TextEditingController(text: at('recipient'));
    _phone = TextEditingController(text: at('phone'));
    _notes = TextEditingController(text: at('notes'));
  }

  @override
  void dispose() {
    for (final c in [
      _line1,
      _line2,
      _city,
      _state,
      _postcode,
      _recipient,
      _phone,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _ready =>
      _line1.text.trim().isNotEmpty && _phone.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing.isEmpty ? 'Where is it going?' : 'The address',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            AddressField(
              controller: _line1,
              label: 'Address',
              autofocus: true,
              // The Save button turns on once there is an address and
              // a phone number, and it is this box that says so.
              onChanged: (_) => setState(() {}),
              country: ref.watch(orgCountryAlpha2Provider),
              // The state here is the name on the envelope rather than
              // the LHDN code: `deliveryLine` reads `state_name`, and a
              // driver reading "10" off a docket is not being told
              // where Selangor is.
              onChosen: (a) => setState(() {
                if (a.postcode != null) _postcode.text = a.postcode!;
                if (a.city != null) _city.text = a.city!;
                if (a.state != null) _state.text = a.state!;
              }),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _line2,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Building or area',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _postcode,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(5),
                    ],
                    // The one field that decides the fee, so it says so
                    // rather than leaving a cashier to wonder why the
                    // charge came out at twelve ringgit.
                    decoration: const InputDecoration(
                      labelText: 'Postcode',
                      helperText: 'Sets the fee',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _city,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Town'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _state,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'State'),
            ),
            const Divider(height: 24),
            TextField(
              controller: _recipient,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Who is expecting it'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone',
                helperText: 'The driver will need it before the roundabout',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _notes,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Anything the driver needs to know',
                hintText: 'Guardhouse, lift, which gate',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _ready
                  ? () => Navigator.of(context).pop((
                      line1: _line1.text.trim(),
                      line2: _line2.text.trim(),
                      city: _city.text.trim(),
                      state: _state.text.trim(),
                      postcode: _postcode.text.trim(),
                      recipient: _recipient.text.trim(),
                      phone: _phone.text.trim(),
                      notes: _notes.text.trim(),
                      fee: null,
                    ))
                  : null,
              child: const Text('Save the address'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks what to charge for the ride instead of what the zone says.
///
/// Separate from the address sheet on purpose: this is the exception,
/// and the server refuses a figure below the zone's without permission
/// to discount.
Future<double?> showDeliveryFeeDialog(
  BuildContext context, {
  required double current,
}) => showDialog<double>(
  context: context,
  builder: (ctx) {
    final controller = TextEditingController(text: Fmt.plain(current));
    return AlertDialog(
      title: const Text('Charge something else'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          labelText: 'Delivery fee',
          prefixText: 'RM ',
          helperText: 'Less than the zone charges needs a manager',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            ctx,
          ).pop(double.tryParse(controller.text.trim()) ?? current),
          child: const Text('Charge this'),
        ),
      ],
    );
  },
);
