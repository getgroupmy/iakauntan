import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/custom_fields_repository.dart';

/// The boxes a company added to this kind of record.
///
/// Dropped into an editor, it renders whatever that company has
/// defined for that entity and hands the values back as the jsonb map
/// the row carries. It renders NOTHING at all when there is nothing
/// defined, which is the common case and should cost those companies
/// no pixels — the same bargain `_UomField` makes on a document line.
///
/// ## It does not validate
///
/// Or rather: it helps, and does not pretend to decide. `required` puts
/// a star on the label and refuses an empty box on save, because that
/// is a kindness. Everything that MATTERS — the type, the choices, and
/// above all that a lookup points at a record of this company's that
/// still exists — is settled by `app.custom_fields_guard()` when the
/// row is written. A form that believed itself the authority would be
/// a second implementation of a rule that already has one.
class CustomFieldsSection extends ConsumerWidget {
  const CustomFieldsSection({
    super.key,
    required this.entity,
    required this.values,
    required this.onChanged,
    this.enabled = true,
    this.heading = 'Your own fields',
  });

  /// Which catalogue of fields to render: 'contact', 'item', and so on.
  final String entity;

  /// What the record carries now. Read as the jsonb column is read, so
  /// a caller can pass `row.customFields` straight in.
  final Map<String, dynamic> values;

  /// Called with the whole map each time one box changes, so a caller
  /// keeps one piece of state rather than one per field.
  final ValueChanged<Map<String, dynamic>> onChanged;

  final bool enabled;
  final String heading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final defs = ref.watch(customFieldsProvider(entity)).valueOrNull;
    if (defs == null) return const SizedBox.shrink();

    // Archived fields are not offered. A value already written under
    // one stays in the map and travels back out untouched, because the
    // caller hands us the whole map and we only replace the keys we
    // render — putting a field away must not quietly wipe what it held.
    final live = defs.where((d) => d.isActive).toList();
    if (live.isEmpty) return const SizedBox.shrink();

    void set(String key, dynamic value) {
      final next = Map<String, dynamic>.from(values);
      if (value == null) {
        next.remove(key);
      } else {
        next[key] = value;
      }
      // A REQUIRED FIELD ALWAYS TRAVELS, null where the box is empty.
      //
      // 0543 lets a row carrying no custom fields through, because
      // forty-one functions in the schema raise one of these records
      // and none of them can answer for a person. That is the right
      // rule, and it means a save that sent `{}` would not be asked.
      // Sending `{"cost_centre": null}` instead puts the question in
      // front of the database, which is where it is answered — the
      // form's own star and validator are a kindness on top, not the
      // authority.
      for (final d in live) {
        if (d.isRequired && !next.containsKey(d.key)) next[d.key] = null;
      }
      onChanged(next);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: Space.lg),
        SectionHeader(heading),
        for (final d in live) ...[
          _FieldInput(
            def: d,
            value: values[d.key],
            enabled: enabled,
            onChanged: (v) => set(d.key, v),
          ),
          const SizedBox(height: Space.md),
        ],
      ],
    );
  }
}

class _FieldInput extends ConsumerStatefulWidget {
  const _FieldInput({
    required this.def,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final CustomFieldDef def;
  final dynamic value;
  final bool enabled;
  final ValueChanged<dynamic> onChanged;

  @override
  ConsumerState<_FieldInput> createState() => _FieldInputState();
}

class _FieldInputState extends ConsumerState<_FieldInput> {
  TextEditingController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.def.kind == 'text' || widget.def.kind == 'number') {
      _controller = TextEditingController(text: _asText(widget.value));
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  static String _asText(dynamic v) => v == null ? '' : '$v';

  String get _label =>
      widget.def.isRequired ? '${widget.def.label} *' : widget.def.label;

  @override
  Widget build(BuildContext context) {
    final d = widget.def;
    switch (d.kind) {
      case 'number':
        return TextFormField(
          controller: _controller,
          enabled: widget.enabled,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*')),
          ],
          decoration: InputDecoration(
            labelText: _label,
            helperText: d.helpText,
          ),
          // A number goes into jsonb as a number. Sending the digits as
          // text would be refused by the guard, and rightly: "72" and
          // 72 are different answers to "how much".
          onChanged: (v) {
            final t = v.trim();
            widget.onChanged(t.isEmpty ? null : num.tryParse(t) ?? t);
          },
          validator: (v) => _requiredCheck(v?.trim() ?? ''),
        );

      case 'boolean':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_label),
          subtitle: d.helpText == null ? null : Text(d.helpText!),
          value: widget.value == true,
          onChanged: widget.enabled
              ? (v) => widget.onChanged(v)
              : null,
        );

      case 'date':
        final current = DateTime.tryParse(_asText(widget.value));
        return InputDecorator(
          decoration: InputDecoration(
            labelText: _label,
            helperText: d.helpText,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  current == null
                      ? 'Not set'
                      : current.toIso8601String().substring(0, 10),
                ),
              ),
              if (widget.value != null && widget.enabled)
                IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => widget.onChanged(null),
                ),
              IconButton(
                tooltip: 'Pick a date',
                icon: const Icon(Icons.calendar_today, size: 18),
                onPressed: !widget.enabled
                    ? null
                    : () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: current ?? DateTime.now(),
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          // The guard reads it with ::date, so the one
                          // unambiguous form is the one to send.
                          widget.onChanged(
                            picked.toIso8601String().substring(0, 10),
                          );
                        }
                      },
              ),
            ],
          ),
        );

      case 'select':
        return SearchablePicker<String>(
          label: _label,
          value: d.options.contains(_asText(widget.value))
              ? _asText(widget.value)
              : null,
          allowEmpty: !d.isRequired,
          emptyLabel: 'Not set',
          helperText: d.helpText,
          enabled: widget.enabled,
          onChanged: widget.onChanged,
          options: [
            for (final o in d.options) PickerOption(value: o, label: o),
          ],
        );

      case 'lookup':
        return _LookupInput(
          def: d,
          label: _label,
          value: _asText(widget.value),
          enabled: widget.enabled,
          onChanged: widget.onChanged,
        );

      default:
        return TextFormField(
          controller: _controller,
          enabled: widget.enabled,
          maxLength: d.maxLength,
          decoration: InputDecoration(
            labelText: _label,
            helperText: d.helpText,
            counterText: d.maxLength == null ? '' : null,
          ),
          onChanged: (v) =>
              widget.onChanged(v.trim().isEmpty ? null : v),
          validator: (v) => _requiredCheck(v?.trim() ?? ''),
        );
    }
  }

  String? _requiredCheck(String v) =>
      widget.def.isRequired && v.isEmpty ? 'Required' : null;
}

/// A field that points at another record.
///
/// The list comes from `custom_field_lookup_options`, which narrows by
/// company and by "not deleted" exactly as the guard does — so what is
/// offered here is what will be accepted there.
class _LookupInput extends ConsumerStatefulWidget {
  const _LookupInput({
    required this.def,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final CustomFieldDef def;
  final String label;
  final String value;
  final bool enabled;
  final ValueChanged<dynamic> onChanged;

  @override
  ConsumerState<_LookupInput> createState() => _LookupInputState();
}

class _LookupInputState extends ConsumerState<_LookupInput> {
  @override
  Widget build(BuildContext context) {
    final target = widget.def.targetEntity;
    if (target == null) return const SizedBox.shrink();

    final options = ref
        .watch(customFieldLookupProvider((target: target, search: '')))
        .valueOrNull ??
        const <LookupOption>[];

    // A record chosen before it was deleted, or one past the end of the
    // list: it is still what the row holds, and saying so is better
    // than showing an empty box over a value that is really there.
    final known = options.any((o) => o.id == widget.value);

    return SearchablePicker<String>(
      label: widget.label,
      value: known ? widget.value : null,
      allowEmpty: !widget.def.isRequired,
      emptyLabel: 'Not set',
      enabled: widget.enabled,
      helperText: widget.value.isNotEmpty && !known
          ? 'The record this points at is not on the list — it may have '
                'been deleted. Choosing another replaces it.'
          : widget.def.helpText,
      onChanged: widget.onChanged,
      options: [
        for (final o in options) PickerOption(value: o.id, label: o.label),
      ],
    );
  }
}
