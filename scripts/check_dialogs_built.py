#!/usr/bin/env python3
"""Refuse a dialog or sheet that no test ever opens.

    python3 scripts/check_dialogs_built.py

`check_screens_built.py` asks that every screen be constructed by a
test, and putting those 115 screens on a 412px surface for the first
time found SEVEN real defects -- five of them an unflexed `Row` that
took its natural width and ran off the edge, one a viewport nested
inside another, one a `Uri.base.origin` that throws on every phone.

None of that gate's reach extends here. A dialog body is not a
`*Screen`, so it was never asked about, and there are 272 of them --
more than there are screens.

## Why this is keyed on the OPENER and not the class

242 of those 272 classes are PRIVATE. A gate demanding that
`_MappingDialog` be constructed by a test would be demanding something
impossible for 89% of the surface, and a rule that cannot be satisfied
is a rule that gets an exemption rather than a test.

The way in is the way the app itself goes in: a public opener function
-- `showFsMapping(context)`, `showPersonEditor(context, person: ...)`
-- which is callable from a test and which builds the private class
behind it. 122 of those exist. So the unit here is the opener, and
"built" means some test calls it.

## What counts as an opener

A top-level, public function returning `Future<...>` or `void` whose
OWN body calls `showDialog` or `showModalBottomSheet`. Its own body,
found by matching braces from its parameter list -- an earlier version
read a fixed window of characters after the signature and would have
credited a short function with its neighbour's dialog.

Both body forms are handled: a `{ ... }` block and an expression body
(`=> showDialog(...)`), because `showFsMapping` is the second kind and
several others are too.

## What "built by a test" means, and how crude that is

The opener's name appearing anywhere under `app/test`. Exactly as
crude as the screens gate, and deliberately so: judging whether a test
asserts anything worthwhile would be judging taste, and the bar here
is the one nothing was enforcing -- that the thing is put on a surface
once.

It is the NAME and not `name(`, which the first version required. An
opener taken as a tear-off -- `opened(tester, overrides, showFsMapping)`
-- is the cleanest way to hand one to a helper, and it never appears
followed by a bracket. That version reported four openers as untested
in the same commit that tested them.

Comments are stripped on both sides. This repository explains itself
in prose and those explanations name openers constantly, so without
that a dialog somebody had written a sentence about would read as a
dialog somebody had tested.

## The exemptions are a backlog

Like the screens list was, and unlike `check_async_skeletons.py`'s
seven, which share a reason and are an argument. These are simply
dialogs nobody has got to. They are listed so the gate can refuse the
next one, and the number should go down. An entry whose opener is
tested now, or has been renamed away, is refused -- a list of what is
missing that nobody revisits is how `docs/gaps-against-autocount.md`
came to be wrong about four of its own entries.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

APP = Path(__file__).resolve().parent.parent / 'app'

#: Openers no test opens yet. A BACKLOG: the number should go down.
#:
#: 105 when this gate went in, which is nearly every one of them --
#: the screens list started at 38 of 117 and this one starts at 105 of
#: 122, because nothing has ever asked the question here at all.
EXEMPT: dict[str, str] = {
    'assignTable': 'lib/src/features/pos/assign_table.dart',
    'createAccountFromPicker': 'lib/src/features/settings/new_account_dialog.dart',
    'createBankAccountFromPicker': 'lib/src/features/banking/new_bank_account_dialog.dart',
    'createContactFromPicker': 'lib/src/features/contacts/new_contact_dialog.dart',
    'createSupplierFromScan': 'lib/src/features/shared/supplier_from_scan.dart',
    'pickMsicCode': 'lib/src/features/settings/msic_picker.dart',
    'pickedTaxCode': 'lib/src/features/settings/tax_code_dialog.dart',
    'resolveSupplier': 'lib/src/features/shared/supplier_from_scan.dart',
    'showActivityDialog': 'lib/src/features/documents/email_dialog.dart',
    'showApplicantEditor': 'lib/src/features/hr/applicant_editor.dart',
    'showApplyDepositSheet': 'lib/src/features/documents/deposit_apply_sheet.dart',
    'showAppraisalCycles': 'lib/src/features/hr/appraisal_cycles_dialog.dart',
    'showAppraisalGoals': 'lib/src/features/hr/appraisal_goals_dialog.dart',
    'showAppraisalReview': 'lib/src/features/hr/appraisal_review.dart',
    'showApprovalRuleEditor': 'lib/src/features/approvals/rule_editor.dart',
    'showAttendanceMonth': 'lib/src/features/hr/attendance_month.dart',
    'showBeneficialOwnerSheet': 'lib/src/features/secretarial/beneficial_owner_sheet.dart',
    'showBillMatterSheet': 'lib/src/features/legal/matter_billing.dart',
    'showBillingRateSheet': 'lib/src/features/timesheets/billing_rate_sheet.dart',
    'showBookBalance': 'lib/src/features/banking/book_balance.dart',
    'showBudgetLineEditor': 'lib/src/features/reports/budget_line_editor.dart',
    'showChargeSheet': 'lib/src/features/secretarial/charge_sheet.dart',
    'showCloseDealDialog': 'lib/src/features/crm/close_deal_dialog.dart',
    'showCompose': 'lib/src/features/mail/compose_dialog.dart',
    'showCreditDialog': 'lib/src/features/documents/credit_dialog.dart',
    'showCreditLedger': 'lib/src/features/settings/credit_ledger_dialog.dart',
    'showDeliveryDay': 'lib/src/features/pos/delivery_day_dialog.dart',
    'showDeliveryFeeDialog': 'lib/src/features/pos/delivery_sheet.dart',
    'showDepartureDialog': 'lib/src/features/hr/departure_dialog.dart',
    'showEditLeaveContact': 'lib/src/features/hr/who_is_away.dart',
    'showEmailDialog': 'lib/src/features/documents/email_dialog.dart',
    'showFilingDetails': 'lib/src/features/financials/filing_details.dart',
    'showFilingStep': 'lib/src/features/secretarial/filing_lifecycle.dart',
    'showForecastLineSheet': 'lib/src/features/forecasting/forecast_screen.dart',
    'showForecastSettings': 'lib/src/features/forecasting/forecast_settings_dialog.dart',
    'showHireDialog': 'lib/src/features/hr/hire_dialog.dart',
    'showInterviews': 'lib/src/features/hr/interviews_dialog.dart',
    'showItemForecastParams': 'lib/src/features/forecasting/item_params_dialog.dart',
    'showItemPacks': 'lib/src/features/items/item_packs_dialog.dart',
    'showItemPrices': 'lib/src/features/items/item_prices_dialog.dart',
    'showLeaveBands': 'lib/src/features/hr/leave_bands_dialog.dart',
    'showLogAttemptSheet': 'lib/src/features/collections/log_attempt_sheet.dart',
    'showMiaVerifyDialog': 'lib/src/features/mia/mia_verify_dialog.dart',
    'showModifierGroups': 'lib/src/features/items/modifier_groups_dialog.dart',
    'showNotificationsSheet': 'lib/src/features/shell/notification_bell.dart',
    'showParticularsSheet': 'lib/src/features/secretarial/particulars_sheet.dart',
    'showPersonEditor': 'lib/src/features/secretarial/person_editor.dart',
    'showPriceLevels': 'lib/src/features/items/item_prices_dialog.dart',
    'showProjectBudgets': 'lib/src/features/timesheets/project_budget.dart',
    'showProjectEditor': 'lib/src/features/timesheets/project_budget.dart',
    'showQueueDay': 'lib/src/features/pos/queue_day_dialog.dart',
    'showReceiptEmailDialog': 'lib/src/features/documents/receipts_screen.dart',
    'showRecurringTemplateDialog': 'lib/src/features/documents/recurring_template_dialog.dart',
    'showReferralHires': 'lib/src/features/hr/referrals_dialog.dart',
    'showRenewDocument': 'lib/src/features/hr/expiring_documents.dart',
    'showRepeatDialog': 'lib/src/features/documents/repeat_dialog.dart',
    'showRequisitionEditor': 'lib/src/features/hr/requisition_editor.dart',
    'showResolutionSheet': 'lib/src/features/secretarial/resolution_sheet.dart',
    'showSettlementDetail': 'lib/src/features/documents/receipts_screen.dart',
    'showShareClassSheet': 'lib/src/features/secretarial/share_class_sheet.dart',
    'showShareDialog': 'lib/src/features/documents/share_dialog.dart',
    'showShareEventSheet': 'lib/src/features/secretarial/share_event_sheet.dart',
    'showStallItems': 'lib/src/features/pos/stall_items_dialog.dart',
    'showSubAccountDialog': 'lib/src/features/settings/sub_account_dialog.dart',
    'showTaxInputs': 'lib/src/features/financials/tax_computation_screen.dart',
    'showTemplateItems': 'lib/src/features/hr/onboarding_template_dialog.dart',
    'showTenderSheet': 'lib/src/features/pos/tender_sheet.dart',
    'showTicketShareDialog': 'lib/src/features/ticketing/ticket_share_dialog.dart',
    'showTimeEntrySheet': 'lib/src/features/timesheets/time_entry_sheet.dart',
    'showTransferDialog': 'lib/src/features/documents/transfer_dialog.dart',
    'showTransfersHistory': 'lib/src/features/banking/transfers_history_dialog.dart',
    'showWithholdingDialog': 'lib/src/features/documents/withholding_dialog.dart',
}

_LINE_COMMENT = re.compile(r'//[^\n]*')
_BLOCK_COMMENT = re.compile(r'/\*.*?\*/', re.S)

#: A top-level function declaration: no indentation, a Future or void
#: return, a public name. Anything indented belongs to a class and is
#: reached through its own widget rather than by being called.
DECL = re.compile(r'^(?:Future<[^>\n]*>|void)\s+([a-z]\w*)\s*\(', re.M)

OPENS = ('showDialog', 'showModalBottomSheet')


def strip_comments(source: str) -> str:
    """Comments open nothing.

    Spaces rather than deletion, so an offset in the result is the
    offset in the original and a line number computed from it is the
    line the reader will open.
    """

    def spaces(match: re.Match[str]) -> str:
        return re.sub(r'[^\n]', ' ', match.group(0))

    return _BLOCK_COMMENT.sub(spaces, _LINE_COMMENT.sub(spaces, source))


def body_of(source: str, open_paren: int) -> str:
    """A function's own body, given the `(` of its parameter list.

    Handles both shapes this codebase uses: a braced block, and an
    expression body introduced by `=>` and ended by the `;` at depth
    zero. Returns '' if neither is found, which reads as "opens
    nothing" and is the safe direction for a gate.
    """
    depth = 0
    i = open_paren
    while i < len(source):
        if source[i] == '(':
            depth += 1
        elif source[i] == ')':
            depth -= 1
            if depth == 0:
                break
        i += 1
    else:
        return ''

    rest = source[i + 1:]
    brace = rest.find('{')
    arrow = rest.find('=>')
    semi = rest.find(';')

    # An expression body: `=>` comes before any brace, or there is no
    # brace before the statement ends.
    if arrow != -1 and (brace == -1 or arrow < brace):
        end = semi if semi != -1 else len(rest)
        # A `=>` body can still contain braces -- a builder closure --
        # so run to the semicolon at depth zero rather than the first.
        depth = 0
        for j, char in enumerate(rest[arrow:], start=arrow):
            if char in '({[':
                depth += 1
            elif char in ')}]':
                depth -= 1
            elif char == ';' and depth == 0:
                end = j
                break
        return rest[arrow:end]

    if brace == -1:
        return ''
    depth = 0
    for j, char in enumerate(rest[brace:], start=brace):
        if char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return rest[brace:j + 1]
    return rest[brace:]


def openers() -> dict[str, str]:
    """Every public opener, mapped to the file it lives in."""
    found: dict[str, str] = {}
    for path in sorted((APP / 'lib' / 'src').rglob('*.dart')):
        source = strip_comments(path.read_text())
        for match in DECL.finditer(source):
            body = body_of(source, match.end() - 1)
            if any(call in body for call in OPENS):
                found[match.group(1)] = str(path.relative_to(APP))
    return found


def opened_by_tests(names: set[str]) -> set[str]:
    tests = '\n'.join(
        strip_comments(p.read_text())
        for p in (APP / 'test').rglob('*.dart'))
    return {n for n in names if re.search(rf'\b{re.escape(n)}\b', tests)}


def main() -> int:
    found = openers()
    opened = opened_by_tests(set(found))
    problems: list[str] = []

    for name in sorted(found):
        if name in opened or name in EXEMPT:
            continue
        problems.append(
            f'  {found[name]}\n'
            f'    {name}() opens a dialog or sheet and no test ever calls '
            f'it, so nothing\n'
            f'    knows it builds. Call it from a test under a MaterialApp '
            f'at phone width,\n'
            f'    or add it to EXEMPT in this script with its file beside '
            f'it.')

    # An exemption for an opener that is tested now, or renamed away,
    # is a line that stopped meaning anything.
    for name in sorted(EXEMPT):
        if name not in found:
            problems.append(
                f'  {EXEMPT[name]}\n'
                f'    {name} is exempted here and is no longer an opener. '
                f'Remove the entry.')
        elif name in opened:
            problems.append(
                f'  {EXEMPT[name]}\n'
                f'    {name} is exempted here and IS opened by a test now. '
                f'Remove the entry.')

    if problems:
        print('Dialogs and sheets that no test opens:\n')
        print('\n\n'.join(problems))
        print(
            f'\n{len(problems)} of them. A dialog nothing opens cannot be '
            f'known to build.')
        return 1

    print(
        f'All {len(found)} dialog and sheet openers are called by a test, '
        f'or named as a backlog ({len(EXEMPT)}).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
