import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One row a picker can offer.
class PickerOption<T> {
  const PickerOption({
    required this.value,
    required this.label,
    this.sublabel,
    this.keywords = const [],
  });

  final T value;

  /// What goes in the box once this is chosen.
  final String label;

  /// The second line in the list — a code, a balance, a town.
  final String? sublabel;

  /// Anything else this row should be findable by. A contact is found by
  /// its code as well as its name; an account by its number.
  final List<String> keywords;
}

/// Which options match what has been typed.
///
/// Pure, and separate from the widget, so the rule can be asserted:
/// `app/test/searchable_picker_test.dart`.
///
/// The rules, each of which is a thing somebody actually does:
///
///   * EVERY WORD has to match SOMETHING, in any order. "sdn ramli"
///     finds "Ramli Enterprise Sdn Bhd" — people type the words they
///     remember, not the string as filed.
///   * The LABEL and the KEYWORDS are searched together, so a contact
///     is found by its code and an account by its number without the
///     caller having to decide which the person will type.
///   * A row whose label STARTS with what was typed comes first. Typing
///     "1000" should not put "Retained earnings (contra 1000)" above
///     account 1000.
///   * An empty box shows EVERYTHING. A picker that shows nothing until
///     you type is a dropdown you cannot browse, which is worse than
///     the dropdown it replaced.
List<PickerOption<T>> matchingOptions<T>(
  List<PickerOption<T>> options,
  String query,
) {
  final words = query.toLowerCase().trim().split(RegExp(r'\s+'))
    ..removeWhere((w) => w.isEmpty);
  if (words.isEmpty) return options;

  final starts = <PickerOption<T>>[];
  final rest = <PickerOption<T>>[];
  for (final option in options) {
    final haystack = [
      option.label,
      option.sublabel ?? '',
      ...option.keywords,
    ].join(' ').toLowerCase();
    if (!words.every(haystack.contains)) continue;
    if (option.label.toLowerCase().startsWith(words.first)) {
      starts.add(option);
    } else {
      rest.add(option);
    }
  }
  return [...starts, ...rest];
}

/// A box you type into instead of a list you scroll.
///
/// The control this replaces is `DropdownButtonFormField`, and it
/// replaces it only where the list GROWS. A dropdown of four statuses is
/// the right control for four statuses: it shows all of them at once,
/// needs no keystroke, and cannot be typed into wrongly. A dropdown of
/// four hundred contacts is a scrollbar.
///
/// [onCreate] is the second half. Where the list is one somebody
/// maintains on another screen, the picker ends with an offer to add to
/// it — seeded with whatever was typed — so the answer to "it is not on
/// the list" is not "go somewhere else and start again". Leave it null
/// where the list is not the user's to extend (a currency, a state, a
/// tax type), and no offer appears.
class SearchablePicker<T> extends StatefulWidget {
  const SearchablePicker({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.label,
    this.hint,
    this.helperText,
    this.helperStyle,
    this.enabled = true,
    this.dense = false,
    this.allowEmpty = false,
    this.emptyLabel = 'None',
    this.onCreate,
    this.createLabel = 'Add',
    this.validator,
  });

  final List<PickerOption<T>> options;
  final T? value;
  final ValueChanged<T?> onChanged;
  final String label;
  final String? hint;

  /// The line under the box. Carried through because a picker is often
  /// where a warning belongs — "no TIN on file" is about the customer
  /// that was chosen, and belongs under the box that chose them.
  final String? helperText;
  final TextStyle? helperStyle;

  final bool enabled;

  /// A cell in a row of a table rather than a field on a form.
  ///
  /// A line on an invoice gives the tax code about a fifth of the row
  /// and no vertical room for a floating label, so in dense form the
  /// label becomes the hint, the text is the small size the rest of the
  /// row uses, and the overlay opens tight under the box. The
  /// behaviour is identical; only the height changes.
  final bool dense;

  /// Whether "none" is an answer. A project is optional; a customer on
  /// an invoice is not.
  final bool allowEmpty;
  final String emptyLabel;

  /// Called with whatever was typed. Return the new value to select it,
  /// or null if the person backed out.
  final Future<T?> Function(String typed)? onCreate;
  final String createLabel;

  final String? Function(T?)? validator;

  @override
  State<SearchablePicker<T>> createState() => _SearchablePickerState<T>();
}

class _SearchablePickerState<T> extends State<SearchablePicker<T>> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _layerLink = LayerLink();

  /// The field and its overlay are ONE tap region, so a tap on a row
  /// counts as a tap inside rather than a tap outside. See [initState]
  /// for why that matters.
  final _tapGroup = Object();

  OverlayEntry? _overlay;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _controller.text = _labelFor(widget.value);
    _focus.addListener(() {
      if (!_focus.hasFocus) return;
      // The whole text is selected on focus so the first keystroke
      // REPLACES the current choice rather than appending to it.
      // Without this, tapping a box that says "Ramli Enterprise" and
      // typing "b" searches for "Ramli Enterpriseb".
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
      _open();
    });
  }

  /// CLOSING ON BLUR IS THE BUG THIS AVOIDS, and it was reported from
  /// the Record expense screen as "the list opens and tapping a row
  /// does nothing".
  ///
  /// On the web a text field is a real DOM input, and the browser blurs
  /// it on MOUSEDOWN — before the pointer is released, and so before
  /// any row's `onTap` can fire. A blur listener that closed the
  /// overlay therefore removed the row out from under the finger, every
  /// time, in the browser only. No widget test showed it: in the test
  /// harness the whole gesture lands in one frame and nothing blurs in
  /// the middle of it.
  ///
  /// So the overlay is not closed on blur at all. It is closed when a
  /// row is chosen, when Escape is pressed, and when a tap lands
  /// genuinely OUTSIDE both the field and the overlay — which is what
  /// [TapRegion] with a shared group id means by "outside".
  void _dismiss() {
    if (_overlay == null) return;
    _close();
    // Whatever was typed and not chosen is discarded. A picker is a
    // CHOICE: half a name left in the box would read as a selection
    // that was never made.
    setState(() => _controller.text = _labelFor(widget.value));
    _focus.unfocus();
  }

  @override
  void didUpdateWidget(covariant SearchablePicker<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_focus.hasFocus) return;
    // The value changing is the obvious case. The OPTIONS changing is
    // the one that was wrong: a screen that knows the chosen id before
    // the list it belongs to has loaded — a reconciliation opened on a
    // bank account, a document opened on its customer — had no row to
    // find, so the box showed nothing, and went on showing nothing
    // after the list arrived because only `value` was watched.
    if (oldWidget.value != widget.value ||
        oldWidget.options.length != widget.options.length) {
      _controller.text = _labelFor(widget.value);
    }
  }

  @override
  void dispose() {
    _close();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _labelFor(T? value) {
    if (value == null) return '';
    for (final option in widget.options) {
      if (option.value == value) return option.label;
    }
    // A value whose row is not in the list — one that has been
    // deactivated since, or a list still loading. Showing nothing is
    // better than showing somebody else's row.
    return '';
  }

  void _open() {
    if (_overlay != null || !widget.enabled) return;
    _overlay = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context).insert(_overlay!);
  }

  void _close() {
    _overlay?.remove();
    _overlay = null;
  }

  void _refresh() => _overlay?.markNeedsBuild();

  Widget _buildOverlay(BuildContext context) {
    final matches = matchingOptions(widget.options, _query);
    final box = context.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 320;

    return Positioned(
      width: width,
      child: CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        offset: Offset(0, widget.dense ? 42 : 56),
        child: TapRegion(
          groupId: _tapGroup,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  if (widget.allowEmpty && _query.isEmpty)
                    ListTile(
                      dense: true,
                      title: Text(widget.emptyLabel),
                      onTap: () => _choose(null),
                    ),
                  for (final option in matches)
                    ListTile(
                      dense: true,
                      title: Text(option.label),
                      subtitle: option.sublabel == null
                          ? null
                          : Text(option.sublabel!),
                      onTap: () => _choose(option.value),
                    ),
                  if (matches.isEmpty && widget.onCreate == null)
                    const ListTile(
                      dense: true,
                      enabled: false,
                      title: Text('Nothing matches that.'),
                    ),
                  // Last, and only when there is something to add. It is a
                  // way out, not a suggestion.
                  if (widget.onCreate != null && _query.trim().isNotEmpty)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.add, size: 18),
                      title: Text('${widget.createLabel} "${_query.trim()}"'),
                      onTap: _create,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _choose(T? value) {
    _close();
    _focus.unfocus();
    setState(() {
      _query = '';
      _controller.text = _labelFor(value);
    });
    widget.onChanged(value);
  }

  Future<void> _create() async {
    final typed = _query.trim();
    _close();
    final created = await widget.onCreate!(typed);
    if (!mounted) return;
    if (created == null) {
      // Backed out. The box goes back to what was chosen before rather
      // than keeping half a name nobody selected.
      setState(() => _controller.text = _labelFor(widget.value));
      return;
    }
    _choose(created);
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: TapRegion(
        groupId: _tapGroup,
        onTapOutside: (_) => _dismiss(),
        child: FormField<T>(
          initialValue: widget.value,
          validator: (_) => widget.validator?.call(widget.value),
          builder: (state) => Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                DismissIntent: CallbackAction<DismissIntent>(
                  onInvoke: (_) {
                    _dismiss();
                    return null;
                  },
                ),
              },
              child: TextFormField(
                controller: _controller,
                focusNode: _focus,
                enabled: widget.enabled,
                style: widget.dense
                    ? Theme.of(context).textTheme.bodySmall
                    : null,
                decoration: InputDecoration(
                  isDense: widget.dense,
                  labelText: widget.dense ? null : widget.label,
                  hintText: widget.dense
                      ? (widget.hint ?? widget.label)
                      : widget.hint,
                  helperText: widget.helperText,
                  helperStyle: widget.helperStyle,
                  errorText: state.errorText,
                  suffixIcon: Icon(
                    Icons.arrow_drop_down,
                    size: widget.dense ? 18 : null,
                  ),
                  suffixIconConstraints: widget.dense
                      ? const BoxConstraints(minWidth: 20, minHeight: 20)
                      : null,
                ),
                onChanged: (v) {
                  _query = v;
                  _open();
                  _refresh();
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
