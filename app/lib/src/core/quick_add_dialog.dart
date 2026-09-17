import 'package:flutter/material.dart';

/// Add a row to a short list without leaving what you were doing.
///
/// The long tail of the "offer to add what is missing" work. A customer
/// gets `NewContactDialog`, an item gets `NewItemDialog`, an account
/// gets `NewAccountDialog` — each asks several questions and each earns
/// its own file. But a project, an item category, a shift, a leave
/// type, a price level and a work centre all ask THE SAME TWO
/// QUESTIONS: what is it called, and what is its short code. Writing six
/// dialogs for that is six places for the same mistake.
///
/// So this is one dialog and a save callback. What it deliberately does
/// NOT do is try to cover the ones with real content: a dialog general
/// enough to create a bank account would be a form builder, and a form
/// builder is how a screen stops saying anything about the thing it is
/// for.
class QuickAddDialog extends StatefulWidget {
  const QuickAddDialog({
    super.key,
    required this.title,
    required this.save,
    this.blurb,
    this.nameLabel = 'Name',
    this.nameHint,
    this.codeLabel,
    this.codeHint,
    this.seed,
  });

  /// The dialog's heading — "New project", "New shift".
  final String title;

  /// A line above the fields saying why this appeared. Left null where
  /// the title says enough.
  final String? blurb;

  final String nameLabel;
  final String? nameHint;

  /// The short code, where the row has one. Null means the list does
  /// not use codes, and no second box appears — asking for a code a
  /// table has no column for is how a dialog teaches somebody a rule
  /// that is not there.
  final String? codeLabel;
  final String? codeHint;

  /// What was typed into the picker.
  final String? seed;

  /// Writes the row and returns its id, which the picker selects.
  /// [code] is null exactly when [codeLabel] is.
  final Future<String> Function({required String name, String? code}) save;

  @override
  State<QuickAddDialog> createState() => _QuickAddDialogState();
}

/// A first guess at a short code from a name.
///
/// Pure, and asserted in `app/test/quick_add_test.dart`. The first word,
/// letters and digits only, upper case, at most eight characters. It is
/// a SUGGESTION in an editable box: it does not have to be right, it
/// has to save a keystroke and never produce something a code column
/// would reject.
String suggestCode(String name) {
  final first = name.trim().split(RegExp(r'\s+')).first;
  final letters = first.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  if (letters.isEmpty) return '';
  return letters
      .substring(0, letters.length > 8 ? 8 : letters.length)
      .toUpperCase();
}

class _QuickAddDialogState extends State<QuickAddDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _code;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.seed ?? '');
    _code = TextEditingController(text: suggestCode(widget.seed ?? ''));
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.blurb != null) ...[
                Text(
                  widget.blurb!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: _name,
                autofocus: widget.seed == null,
                decoration: InputDecoration(
                  labelText: widget.nameLabel,
                  hintText: widget.nameHint,
                ),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'It needs a name.' : null,
              ),
              if (widget.codeLabel != null) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _code,
                  autofocus: widget.seed != null,
                  decoration: InputDecoration(
                    labelText: widget.codeLabel,
                    hintText: widget.codeHint,
                  ),
                  textCapitalization: TextCapitalization.characters,
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'And a short code.' : null,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error),
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
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final id = await widget.save(
        name: _name.text.trim(),
        code: widget.codeLabel == null ? null : _code.text.trim().toUpperCase(),
      );
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      // The likely failure is a code already in use, which is something
      // the person can fix without losing what is behind this dialog.
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// Open a [QuickAddDialog] and return the id it wrote, or null if the
/// person backed out — the shape `SearchablePicker.onCreate` wants.
Future<String?> quickAdd(
  BuildContext context, {
  required String title,
  required Future<String> Function({required String name, String? code}) save,
  String? blurb,
  String nameLabel = 'Name',
  String? nameHint,
  String? codeLabel,
  String? codeHint,
  String? seed,
}) => showDialog<String>(
  context: context,
  builder: (_) => QuickAddDialog(
    title: title,
    save: save,
    blurb: blurb,
    nameLabel: nameLabel,
    nameHint: nameHint,
    codeLabel: codeLabel,
    codeHint: codeHint,
    seed: seed,
  ),
);
