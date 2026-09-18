import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two things about the navigation, both reported from a phone.
///
/// ## 1. Settings was hidden from anybody with no company
///
/// `_visible` in `app_shell.dart` refused every non-console destination
/// when `hasOrg` was false, Settings included -- and Settings is where
/// the "Your account" card lives: change password, change email, change
/// mobile, JOIN ANOTHER COMPANY, close this login, sign out. Somebody
/// with no company is exactly the person who needs "join another
/// company", and the door to it was hidden from them on every surface.
///
/// `settings_no_org_test.dart` already asserted that the CARD is
/// reachable without an organization. Nothing asserted that the RAIL
/// offered any way to reach it, which is the gap between a screen
/// existing and a screen being reachable.
///
/// It also fixed a transient nobody would have filed: `hasOrg` reads
/// `organizationsProvider.valueOrNull ?? const []`, so it is false for
/// the frame before the answer lands and Settings blinked out of the
/// rail on every cold start.
///
/// ## 2. A wrapped label in the bottom bar sat left while its icon sat
/// centred
///
/// Material builds a destination's label as `Text(label, style:
/// textStyle)` with no `textAlign` -- see
/// `flutter/src/material/navigation_bar.dart` -- so a label too long
/// for its slot wraps and falls back to `TextAlign.start`. On a
/// six-slot phone bar two of them wrap: "All Contacts" and "Ask about
/// your books".
///
/// Asserted here against FLUTTER'S OWN BEHAVIOUR rather than against
/// the shell, because that is what the fix depends on: `Text` with no
/// alignment of its own reads `DefaultTextStyle.of(context).textAlign`.
/// If a Flutter upgrade ever gives that `Text` an explicit `textAlign`,
/// the merge stops working and this fails -- which is the only warning
/// there would be, since the symptom is two labels looking slightly
/// off on a phone.
void main() {
  testWidgets('a wrapped label reads the ambient textAlign', (tester) async {
    // The mechanism, isolated. A `Text` narrow enough to wrap, with no
    // `textAlign` of its own, inside a `DefaultTextStyle` that sets
    // one.
    await tester.pumpWidget(
      const MaterialApp(
        home: DefaultTextStyle(
          style: TextStyle(fontSize: 12, color: Color(0xFF000000)),
          textAlign: TextAlign.center,
          child: Center(
            child: SizedBox(
              width: 60,
              child: Text('Ask about your books'),
            ),
          ),
        ),
      ),
    );

    final rich = tester.widget<RichText>(find.byType(RichText));
    expect(rich.textAlign, TextAlign.center);
  });

  testWidgets('and left when nothing sets one, which was the defect', (
    tester,
  ) async {
    // The control. Without this, the assertion above would pass against
    // a Flutter that centred by default and would prove nothing about
    // the merge.
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 60,
            child: Text('Ask about your books'),
          ),
        ),
      ),
    );

    final rich = tester.widget<RichText>(find.byType(RichText));
    expect(rich.textAlign, TextAlign.start);
  });

  testWidgets('a NavigationBar label inherits it', (tester) async {
    // The whole arrangement, at the widget the shell actually uses.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: DefaultTextStyle.merge(
            textAlign: TextAlign.center,
            child: NavigationBar(
              selectedIndex: 0,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.people_outline),
                  label: 'All Contacts',
                ),
                NavigationDestination(
                  icon: Icon(Icons.auto_awesome_outlined),
                  label: 'Ask about your books',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final labels = tester.widgetList<RichText>(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byType(RichText),
      ),
    );
    expect(labels, isNotEmpty);
    // NOT centred, and this is the FINDING rather than the fix. The
    // merge is inert here: `NavigationBar` builds a `Material`,
    // `Material` inserts its own `AnimatedDefaultTextStyle` whose
    // `textAlign` is null, and THAT is the `DefaultTextStyle` the label
    // resolves against -- so an ambient alignment set outside the bar
    // never reaches it.
    //
    // Recorded as an assertion because it cost an afternoon and the
    // next person will reach for the same one-liner. The label is made
    // to FIT instead: see `_Dest.short`.
    expect(
      labels.every((l) => l.textAlign == TextAlign.center),
      isFalse,
      reason: 'if this now passes, Material has changed and _Dest.short '
          'may be replaceable with an ambient textAlign',
    );
  });

  testWidgets('and is not centred without one either', (tester) async {
    // The other half: Material does not centre it of its own accord,
    // so a wrapped label really does sit left in a slot whose icon is
    // centred. That is what was reported from the phone.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: NavigationBar(
            selectedIndex: 0,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.people_outline),
                label: 'All Contacts',
              ),
              NavigationDestination(
                icon: Icon(Icons.auto_awesome_outlined),
                label: 'Ask about your books',
              ),
            ],
          ),
        ),
      ),
    );

    final labels = tester.widgetList<RichText>(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byType(RichText),
      ),
    );
    expect(labels, isNotEmpty);
    expect(
      labels.every((l) => l.textAlign == TextAlign.center),
      isFalse,
      reason: 'Material now centres it itself; the merge is redundant',
    );
  });
}
