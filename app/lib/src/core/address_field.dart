import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/places_repository.dart';

/// An address box that suggests addresses.
///
/// Typed straight through when nothing comes back — the field is a
/// `TextFormField` underneath and every form works without a single
/// suggestion, which is what a deployment with no Places key gets and
/// what everybody gets when Google is unreachable.
///
/// One of these belongs on every screen that asks for an address:
/// company details, branches, warehouses, contacts, their delivery
/// addresses, property sites, and the delivery sheet on the till. They
/// all write the same four columns, so they all fill them the same way.
class AddressField extends ConsumerStatefulWidget {
  const AddressField({
    super.key,
    required this.controller,
    required this.onChosen,
    this.country,
    this.label = 'Address',
    this.enabled = true,
    this.fieldKey,
    this.onChanged,
    this.autofocus = false,
    this.textCapitalization = TextCapitalization.words,
  });

  final TextEditingController controller;

  /// The rest of the address, for the boxes this one does not own.
  final void Function(PlaceAddress address) onChosen;

  /// Two letters, so suggestions stay in the country somebody chose.
  /// Null asks the world, which is the honest answer when the question
  /// has not been answered — before an organization exists, or while
  /// its country is still loading.
  final String? country;

  final String label;

  /// False while a card is saving. A box that keeps suggesting into a
  /// form that is mid-save is offering to change what is being written.
  final bool enabled;

  /// Goes on the text field rather than on this widget, so a test that
  /// wants to type into the box can find the box.
  final Key? fieldKey;

  /// For a screen that watches this box for something other than its
  /// contents — a Save button that turns on once there is an address
  /// to save. Suggesting does not rebuild the screen around it, so a
  /// screen that needs one has to ask.
  final ValueChanged<String>? onChanged;

  final bool autofocus;
  final TextCapitalization textCapitalization;

  @override
  ConsumerState<AddressField> createState() => AddressFieldState();
}

class AddressFieldState extends ConsumerState<AddressField> {
  List<PlaceSuggestion> _suggestions = const [];
  bool _busy = false;

  /// False once the function has said it has no key.
  ///
  /// Asking again on the next keystroke would be asking a question
  /// already answered, once per letter, for as long as somebody types.
  bool _configured = true;

  /// One token for the keystrokes leading to one chosen address.
  ///
  /// Places bills a session as a unit: the same token across every
  /// keystroke and the final details fetch is one charge, and a fresh
  /// token per keystroke is one charge each. Renewed after a choice,
  /// because that choice closed the session.
  String _session = _newSession();

  /// The query the last request was for.
  ///
  /// Answers arrive out of order — a three-letter query can come back
  /// after the five-letter one that followed it, and the list would go
  /// backwards under somebody still typing. A reply for anything but
  /// the current text is dropped.
  String _inFlightFor = '';

  static String _newSession() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  Future<void> _look(String text) async {
    if (!_configured) return;
    final q = text.trim();
    _inFlightFor = q;
    if (q.length < 3) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      return;
    }

    setState(() => _busy = true);
    try {
      final res = await ref.read(placesProvider).suggest(
        q,
        country: widget.country,
        session: _session,
      );
      if (!mounted || _inFlightFor != q) return;
      setState(() {
        _configured = res.configured;
        _suggestions = res.suggestions;
      });
    } catch (_) {
      // A box that will not take an address because the suggester is
      // down is worse than one with no suggestions.
      if (mounted) setState(() => _suggestions = const []);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose(PlaceSuggestion s) async {
    setState(() {
      _suggestions = const [];
      _busy = true;
    });
    try {
      final address = await ref
          .read(placesProvider)
          .address(s.id, session: _session);
      if (!mounted) return;
      if (address != null) {
        widget.controller.text = address.line1 ?? s.line;
        widget.onChosen(address);
      } else {
        widget.controller.text = s.line;
      }
    } catch (_) {
      if (mounted) widget.controller.text = s.line;
    } finally {
      // Whatever happened, that session is over.
      _session = _newSession();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextFormField(
        key: widget.fieldKey,
        controller: widget.controller,
        enabled: widget.enabled,
        autofocus: widget.autofocus,
        textCapitalization: widget.textCapitalization,
        onChanged: (v) {
          widget.onChanged?.call(v);
          _look(v);
        },
        decoration: InputDecoration(
          labelText: widget.label,
          suffixIcon: _busy
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : null,
        ),
      ),
      if (_suggestions.isNotEmpty)
        Card(
          margin: const EdgeInsets.only(top: 4),
          child: Column(
            children: [
              for (final s in _suggestions)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.place_outlined, size: 18),
                  title: Text(s.line),
                  subtitle: s.detail.isEmpty ? null : Text(s.detail),
                  onTap: () => _choose(s),
                ),
            ],
          ),
        ),
    ],
  );
}

String _normalise(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');

/// What a state is called somewhere other than `ref_states`.
///
/// Google answers with the name in common English use; `ref_states`
/// carries the name LHDN publishes, and for five of the sixteen those
/// are different words. Without this, a company in Kuala Lumpur — the
/// single most likely answer — picks an address and the state box stays
/// empty, which looks like the suggestion failed.
const Map<String, String> _stateAliases = {
  'penang': 'pulaupinang',
  'malacca': 'melaka',
  'negrisembilan': 'negerisembilan',
  'kualalumpur': 'wilayahpersekutuankualalumpur',
  'labuan': 'wilayahpersekutuanlabuan',
  'putrajaya': 'wilayahpersekutuanputrajaya',
};

/// The `ref_states` code for a state as Google spells it.
///
/// Returns null for a name no row matches — a state in another country,
/// or one nobody has heard of. Null leaves the box as it was rather
/// than clearing it, because `state_code` is a foreign key into
/// `ref_states` on contacts and warehouses: a name written into it is
/// not a slightly wrong value, it is a row that will not save.
String? stateCodeFor(Iterable<Map<String, dynamic>> states, String? name) {
  if (name == null) return null;
  var wanted = _normalise(name);
  if (wanted.isEmpty) return null;

  // "Federal Territory of Kuala Lumpur" is the same place as the
  // "Wilayah Persekutuan Kuala Lumpur" on the LHDN list, and Google
  // says either depending on the language of the request.
  wanted = wanted.replaceFirst(RegExp(r'^federalterritoryof'), '');
  wanted = _stateAliases[wanted] ?? wanted;

  for (final s in states) {
    if (_normalise('${s['name']}') == wanted) return s['code'] as String?;
  }
  return null;
}

/// Fill the boxes beside an address box from a chosen suggestion.
///
/// Only the parts Google actually returned are written. A suggestion
/// with no postcode leaves the postcode somebody typed alone rather
/// than blanking it, and a state no `ref_states` row matches leaves the
/// state box as it was — see [stateCodeFor] for why an unmatched name
/// must not be written through.
void fillAddressBoxes(
  PlaceAddress address,
  Iterable<Map<String, dynamic>> states, {
  TextEditingController? postcode,
  TextEditingController? city,
  TextEditingController? stateCode,
}) {
  if (address.postcode != null) postcode?.text = address.postcode!;
  if (address.city != null) city?.text = address.city!;
  final code = stateCodeFor(states, address.state);
  if (code != null) stateCode?.text = code;
}
