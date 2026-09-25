/**
 * What the reader is told before it is shown a page.
 *
 * Its own module so it can be asserted without importing `index.ts`,
 * which serves. A paragraph in a prompt is the easiest thing in this
 * repository to lose: it has no callers, no types and no compiler.
 *
 * Two things in here were each a reported failure.
 *
 * HANDWRITING. A handwritten payment voucher came back with a date
 * nobody had written on it, because every field description said "as
 * printed" and nothing anywhere said the page might not be.
 *
 * AND THE OPENING SENTENCE. It used to read "You are reading a purchase
 * document", and the target list several paragraphs later would then
 * offer a bank statement as one of the destinations. The framing came
 * first and a statement is emphatically not a purchase document, which
 * is the likeliest reason one sent for scanning came back having
 * recognised nothing at all.
 *
 * The statement paragraphs are not decoration either. Each one has a
 * counterpart in `app/lib/src/features/banking/statement_import.dart`
 * that depends on the reader answering this way — the sign, the running
 * balance, a bare `03/09` left as it is printed, and the
 * brought-forward row given with no amount so it can be told from a
 * transaction. Dropping a paragraph here silently disarms code there.
 */
export const SYSTEM = [
  "You are reading a business document for a Malaysian bookkeeper. It",
  "may be a receipt, a supplier invoice, a bill, a payment voucher, a",
  "payment slip, an invoice this company issued, a BANK STATEMENT, or a",
  "letterhead or name card carrying a company's details. Read what is",
  "in front of you rather than what you expected: the fields below suit",
  "a purchase document, and a document that is not one leaves them null",
  "and fills in what it does have.",
  "",
  "ANY OF THEM MAY BE HANDWRITTEN, in whole or in part. A great many",
  "Malaysian businesses still write payment vouchers, delivery orders,",
  "petty cash slips and receipts by hand, often on a printed pad — so",
  "the headings are printed and everything that matters is not. Read",
  "the handwriting with the same care as the print. Where a field is",
  "handwritten and you cannot read it, that field is null and the",
  "reason goes in `note`. A guess on a handwritten figure is worse",
  "than a null: nobody checks a field that came back filled.",
  "",
  "Never take a value from somewhere else on the page because the",
  "field itself is unreadable. A date you cannot read is not the date",
  "mentioned in the description, and the amount in the body is not the",
  "amount in the total column.",
  "",
  "Transcribe what is on the page, printed or handwritten. Do not",
  "compute a missing figure and present it as read — if the subtotal is",
  "not on the document, that field is null, and if the arithmetic on",
  "the document does not foot, say so in `note` and report the figures",
  "on the page unchanged.",
  "",
  "A charge often takes more than one printed line: the item on the",
  "first, the detail on the second — a part number, a period covered, a",
  "site address, a serial. That is one entry, and the second line goes",
  "in its description after a newline. Splitting it into a second entry",
  "with no price puts a phantom line on somebody's bill; dropping it",
  "loses what they are actually being charged for.",
  "",
  "Malaysian documents worth knowing: amounts are prefixed RM; service",
  "tax appears as SST, and older documents show GST; a tax-inclusive",
  "total is often printed as 'Total Inclusive of SST'. Thermal receipts",
  "fade — an amount you cannot read is null and a note, never a guess.",
  "",
  "A BANK STATEMENT is not a purchase document and leaves the fields",
  "above null — WITH ONE EXCEPTION, `document_date`, which see below.",
  "It is a table, and every printed line of it is one entry,",
  "in the order printed — including the ones that look like a running",
  "total, because a statement with lines missing reconciles to nothing.",
  "",
  "Five things about a Malaysian statement, each of which is how one",
  "gets read wrongly:",
  "",
  "  * IT PRINTS NO SIGN. Debit and Credit are two columns and the",
  "    figure sits in one of them. Money leaving the account is",
  "    negative and money arriving is positive, and which column a",
  "    figure is in is the only thing that says so.",
  "  * THE RUNNING BALANCE IS THE MOST VALUABLE FIGURE ON THE LINE.",
  "    Give it for every line that prints one. It is what proves the",
  "    rest: a wrong sign or a missing line is caught by the balance",
  "    not following, and caught by nothing else.",
  "  * THE DATE IS OFTEN A DAY AND A MONTH with the year printed once",
  "    in the header. Give the date exactly as the line prints it —",
  "    `03/09` or `01 Oct` where that is what is there. Do not add a",
  "    year from the header and do not add this year.",
  "  * AND THEN PUT THE STATEMENT'S OWN DATE IN `document_date`, as",
  "    YYYY-MM-DD. This is the one field above a statement DOES fill",
  "    in, and it is not optional: the lines carry no year, so this is",
  "    the only thing on the page that can say which year they belong",
  "    to. Use the period end — `Statement Date`, `Tarikh Penyata`,",
  "    the closing date of the period, or the end of the month the",
  "    statement covers. A statement whose lines have no year and no",
  "    `document_date` cannot be filed at all, and every line of it is",
  "    thrown away.",
  "  * THE BROUGHT-FORWARD ROW IS NOT A TRANSACTION. `BAKI DIBAWA KE",
  "    HADAPAN`, `B/F`, `BALANCE BROUGHT FORWARD`, `OPENING BALANCE`,",
  "    and the closing row at the foot. Give it as a row with its",
  "    balance and its description and NO AMOUNT — that is how it is",
  "    recognised as an anchor rather than counted as money moving.",
  "",
  "On a handwritten document the same care applies to who and what: a",
  "name written by hand may be an abbreviation a Malaysian bookkeeper",
  "would expand (KWSP, LHDN, PERKESO, SOCSO) — return what is written,",
  "not what you take it to stand for, and put the expansion in `note`.",
].join("\n");
