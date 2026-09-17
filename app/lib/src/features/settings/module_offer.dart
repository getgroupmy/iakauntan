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
///
/// A promotion (0548) is priced on the chip rather than announced
/// there: "free for 30 days" is what somebody is deciding about, and a
/// chip is not wide enough to also carry the promotion's name and the
/// price it replaced. Those are in [modulePromoNote], under the list,
/// and in the confirmation.
String moduleChipLabel(ModuleSurface m) {
  if (m.promoKind == 'trial' && (m.promoDays ?? 0) > 0) {
    return '${m.name} · free for ${m.promoDays} days';
  }
  if (m.promotion != null && m.isFreeNow) return '${m.name} · free';
  return m.price > 0 ? '${m.name} · ${Fmt.money(m.price)}/mo' : m.name;
}

/// The sentence under a chip whose price is not the price list's.
///
/// Null when there is no promotion, which is the caller's cue to draw
/// nothing rather than an empty line. A discount nobody can see the
/// old price beside is not a discount; it is just a number.
String? modulePromoNote(ModuleSurface m) {
  final name = m.promotion;
  if (name == null) return null;
  final until = m.promoUntil == null ? '' : ', until ${Fmt.date(m.promoUntil)}';
  if (m.promoKind == 'trial' && (m.promoDays ?? 0) > 0) {
    return m.monthlyPrice > 0
        ? '$name: the first ${m.promoDays} days are free, then '
              '${Fmt.money(m.monthlyPrice)} a month.'
        : '$name: free for the first ${m.promoDays} days.';
  }
  if (m.isFreeNow) {
    return m.monthlyPrice > 0
        ? '$name: nothing to pay$until, instead of '
              '${Fmt.money(m.monthlyPrice)} a month.'
        : '$name: nothing to pay$until.';
  }
  return '$name: ${Fmt.money(m.price)} a month$until, instead of '
      '${Fmt.money(m.monthlyPrice)}.';
}

String addModuleTitle(ModuleSurface m) => 'Add ${m.name}?';

/// What the confirmation says. Adding a module is a bill, so the price
/// is on the way in rather than on the invoice afterwards — and so is
/// the fact that it can be taken off again, because a charge somebody
/// believes is permanent is a charge they will not risk.
///
/// A trial says both numbers. "Free for 30 days" on its own is the
/// half of the sentence that sells; the half that stops a complaint on
/// day thirty-one is what happens after it.
String addModulePrompt(ModuleSurface m) {
  const off = 'You can take it off again here whenever you like.';
  if (m.promoKind == 'trial' && (m.promoDays ?? 0) > 0 && m.monthlyPrice > 0) {
    return 'It is on straight away. The first ${m.promoDays} days are free '
        '(${m.promotion}), and ${Fmt.money(m.monthlyPrice)} a month is '
        'added to this company after that. $off';
  }
  if (m.promotion != null && m.isFreeNow) {
    return 'It is on straight away and costs nothing'
        '${m.promoUntil == null ? '' : ' until ${Fmt.date(m.promoUntil)}'} '
        '(${m.promotion}). $off';
  }
  if (m.price > 0) {
    final instead = m.promotion == null
        ? ''
        : ' — ${m.promotion}, instead of ${Fmt.money(m.monthlyPrice)}';
    return 'It is on straight away, and ${Fmt.money(m.price)} a month '
        'is added to this company from today$instead. $off';
  }
  return 'It is on straight away, and you can take it off again here.';
}

/// The confirmation for taking a paid add-on off again.
///
/// 0488's own copy says "you can take it off here too" and there was no
/// way to do it -- the switch on a held module hides its screens and
/// leaves the entitlement, and the bill, exactly where they were. What
/// this has to be clear about is the two things a person is actually
/// afraid of: that the charge stops, and that their records do not go
/// with it.
String removeModuleTitle(ModuleSurface m) => 'Remove ${m.name}?';

///
/// The price named is what they are actually paying, not what the
/// price list says: telling somebody on a free trial that "RM 39.00 a
/// month stops being charged" is telling them they are saving money
/// they were never spending.
String removeModulePrompt(ModuleSurface m) => m.price > 0
    ? 'The screens go, and ${Fmt.money(m.price)} a month stops '
          'being charged from today— this month is billed for the days '
          'it was on. Nothing already recorded is deleted, and you can '
          'add it again here.'
    : 'The screens go. Nothing already recorded is deleted, and you can '
          'add it again here.';
