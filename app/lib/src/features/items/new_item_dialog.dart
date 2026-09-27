import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_text.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../data/models.dart';
import '../settings/tax_code_dialog.dart';

/// Create an item without leaving the line you were typing.
///
/// Somebody entering an invoice reaches for a part number that is not on
/// the list yet. Until now the only way through was to abandon the
/// document, go to Items, add it, come back and start the line again --
/// and a half-typed invoice is exactly the thing people do not want to
/// leave. This is the same act done where they already are, seeded with
/// whatever they had typed.
///
/// WHAT IT ASKS FOR is the shortest list that makes an item usable: a
/// code, a name, whether it is a thing or a service, and a price. Every
/// other column on `items` has a default that is right far more often
/// than not, and a form that asked for all of them here would be the
/// Items screen wearing a dialog. The rest is edited on that screen
/// afterwards by whoever maintains the list.
///
/// It returns the created [Item] so the caller can bind the line to it
/// at once — the point of the exercise is a line that names a real item,
/// not merely an item that now exists somewhere.
class NewItemDialog extends ConsumerStatefulWidget {
  const NewItemDialog({super.key, this.seedCode, this.seedName});

  /// What was typed in the item-number box, if that is where this
  /// started.
  final String? seedCode;

  /// What was typed in the description box, if that is where this
  /// started.
  final String? seedName;

  @override
  ConsumerState<NewItemDialog> createState() => _NewItemDialogState();
}

class _NewItemDialogState extends ConsumerState<NewItemDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _code;
  late final TextEditingController _name;
  late final TextEditingController _price;
  String _type = 'stock';
  String? _taxCodeId;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _code = TextEditingController(text: widget.seedCode ?? '');
    _name = TextEditingController(text: widget.seedName ?? '');
    _price = TextEditingController();
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _price.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {

    return AlertDialog(
      title: const Text('New item'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'This is not on the item list yet. Fill it in here and the '
                'line will use it.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _code,
                // Focus lands on whichever box was NOT seeded, because
                // the seeded one is already what the person typed and
                // the other is the question being asked.
                autofocus: widget.seedCode == null,
                decoration: const InputDecoration(
                  labelText: 'Item number',
                  hintText: 'ITM-140',
                ),
                textCapitalization: TextCapitalization.characters,
                validator: (v) => (v ?? '').trim().isEmpty
                    ? 'Every item needs a number. It is what an invoice '
                          'will refer to.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                autofocus: widget.seedCode != null,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'Network switch, 24 port',
                ),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'And a description.' : null,
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'stock',
                    label: Text('Goods'),
                    icon: Icon(Icons.inventory_2_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: 'service',
                    label: Text('Service'),
                    icon: Icon(Icons.handyman_outlined, size: 16),
                  ),
                ],
                selected: {_type},
                onSelectionChanged: (s) => setState(() => _type = s.first),
              ),
              const SizedBox(height: 4),
              Text(
                // The one consequence worth stating at the moment of the
                // choice: goods are counted, services are not, and it is
                // the answer that decides whether this thing ever has a
                // stock balance.
                _type == 'stock'
                    ? 'Counted in stock, and costed when it is sold.'
                    : 'Not counted. Nothing to run out of.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _price,
                decoration: const InputDecoration(
                  labelText: 'Selling price',
                  prefixText: 'RM ',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                validator: (v) {
                  final text = (v ?? '').trim();
                  if (text.isEmpty) return null;
                  return double.tryParse(text) == null
                      ? 'That is not a price.'
                      : null;
                },
              ),
              const SizedBox(height: 12),
              TaxCodePicker(
                value: _taxCodeId,
                label: 'Sales tax',
                allowEmpty: true,
                onChanged: (v) => setState(() => _taxCodeId = v),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Create and use'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final created = await repo.saveItem(
        Item(
          id: '',
          code: _code.text.trim(),
          name: _name.text.trim(),
          itemType: _type,
          unitPrice: double.tryParse(_price.text.trim()) ?? 0,
          // Goods are counted; a service has nothing to count. The
          // column has its own default, but it is the one the type
          // implies and leaving them to disagree is how an item ends up
          // a service with a stock balance.
          trackInventory: _type == 'stock',
          salesTaxCodeId: _taxCodeId,
        ),
      );
      // The item list is what both boxes on the line search, so it has
      // to be re-read or the thing just created is not findable from the
      // box it was created in.
      ref.invalidate(itemsProvider);
      if (mounted) Navigator.pop(context, created);
    } catch (e) {
      // Shown here rather than thrown away: the likely failure is a code
      // already on the list, and "ITM-100 is taken" is something the
      // person can act on without losing what they typed.
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}


/// The rows an item picker offers.
///
/// Findable by NUMBER as well as description, for the same reason the
/// two boxes on a document line search each other's field: somebody
/// reaching for an item knows one of the two, and which one depends on
/// whether they are holding the part or the paperwork.
List<PickerOption<String>> itemPickerOptions(List<Item> items) => [
  for (final item in items)
    PickerOption<String>(
      value: item.id,
      label: item.name.trim().isEmpty ? item.code : item.name,
      sublabel: item.code.trim().isEmpty ? null : item.code,
      keywords: [item.code],
    ),
];
