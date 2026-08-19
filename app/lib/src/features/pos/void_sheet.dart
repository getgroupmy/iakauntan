import 'package:flutter/material.dart';

/// Why a plate came off a bill after the kitchen had been told.
///
/// The reasons are the ones a kitchen actually reports, not a generic
/// "reason for void" box. A free-text field collects nothing anybody
/// can count, and the point of recording a void is that thirty "never
/// came out" in a week is a conversation while one is an accident.
///
/// "Something else" is kept, because a fixed list that cannot describe
/// what happened teaches people to pick the nearest wrong option — but
/// it is the one choice that then insists on words, which is the
/// database's rule as well as this sheet's.
class VoidReasonSheet extends StatefulWidget {
  const VoidReasonSheet({super.key, required this.description});

  final String description;

  @override
  State<VoidReasonSheet> createState() => _VoidReasonSheetState();
}

class _VoidReasonSheetState extends State<VoidReasonSheet> {
  static const _reasons = <String, String>{
    'not_received': 'Never came out',
    'item_issue': 'Something wrong with it',
    'wrong_item': 'Wrong item made',
    'customer_cancelled': 'Customer changed their mind',
    'other': 'Something else',
  };

  String? _reason;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool get _ready =>
      _reason != null &&
      (_reason != 'other' || _note.text.trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Take off: ${widget.description}',
                      style: Theme.of(context).textTheme.titleLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'The kitchen has already made this, so it needs a reason.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            for (final e in _reasons.entries)
              RadioListTile<String>(
                dense: true,
                value: e.key,
                groupValue: _reason,
                onChanged: (v) => setState(() => _reason = v),
                title: Text(e.value),
              ),
            if (_reason == 'other')
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _note,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'What happened',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _ready
                      ? () => Navigator.of(context).pop(
                          (reason: _reason!, note: _note.text.trim()),
                        )
                      : null,
                  child: const Text('Take it off'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
