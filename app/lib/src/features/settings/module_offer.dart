import '../../core/format.dart';
import '../../data/models.dart';

/// What the settings screen says when it offers a paid add-on.
///
/// Kept apart from the card that draws it for the same reason
/// `credit_banner_state.dart` is: the words here are about money —
/// what a module costs, when the charge starts, and who may agree to
/// it — and a sentence assembled inside a `build` method among the
/// padding is a sentence nobody can assert.
///
/// Until 0488 the screen said "Contact us to add one of these", with
/// no address behind it. Every add-on carried a monthly price and none
/// of them could be had.

/// The line under "Not on this account".
///
/// Two different facts, and the wrong one is worse than none: somebody
/// who may add a module needs to know the charge starts today, and
/// somebody who may not needs to know who can, rather than being told
/// to press something that will refuse.
String moduleOfferLine({required bool canAdmin}) => canAdmin
    ? 'Add one and it is on straight away. The monthly price starts '
          'from the day you add it, and you can take it off here too.'
    : 'An owner or admin can add these.';

/// The chip: what it is, and what it costs. A module with no price is
/// shown by name alone rather than as "RM 0.00/mo", which reads like a
/// mistake.
String moduleChipLabel(ModuleSurface m) => m.monthlyPrice > 0
    ? '${m.name} · ${Fmt.money(m.monthlyPrice)}/mo'
    : m.name;

String addModuleTitle(ModuleSurface m) => 'Add ${m.name}?';

/// What the confirmation says. Adding a module is a bill, so the price
/// is on the way in rather than on the invoice afterwards — and so is
/// the fact that it can be taken off again, because a charge somebody
/// believes is permanent is a charge they will not risk.
String addModulePrompt(ModuleSurface m) => m.monthlyPrice > 0
    ? 'It is on straight away, and ${Fmt.money(m.monthlyPrice)} a month '
          'is added to this company from today. You can take it off '
          'again here whenever you like.'
    : 'It is on straight away, and you can take it off again here.';
