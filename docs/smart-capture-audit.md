# Smart Capture — Step 0 audit

Against *iAkauntan Smart Capture — Tofu-class document AI (handoff
brief)*, 24 Sep 2026. The brief's first instruction is to fill this in
from the repo and the live database **before writing any code**, so
nothing in the module has been built.

Read against the schema at migration `0708` and the branch at
`ed16168d`.

---

## The one-line answer

**Most of the pipeline already exists, under another name.** The brief
describes Smart Capture as a new module and says iAkauntan "already has
some OCR (the SSM work mentions OCR-extracted company names)". That
understates it by a wide margin: **AI SmartScan** is a built module with
nine reader providers, a key pool, per-provider fallback, per-page
billing, an inbox, a platform console, raw request/response logging, an
on-device reader for when the network is gone, and — as of this week —
a check of what the reader said against what the lines come to.

So the decision in front of this project is not "build Smart Capture".
It is **"does Smart Capture extend AI SmartScan, or replace it?"** The
brief's data model (`capture_batches`, `capture_documents`,
`capture_pages`, `capture_fields`, `capture_lines`) would stand beside
`ocr_scans`, `ocr_exchanges`, `scan_targets`, `scan_target_fields` and
`scan_document_kinds` and do the same job. Two scanning systems in one
product is the outcome nobody wants and the one this lands on by
default.

**Recommendation: extend.** The genuinely new things in the brief —
bounding boxes, per-field confidence, auto-split, a job queue, a
learning engine, click-to-verify — are additive to what is there. The
rest is already running in production.

---

## The matrix

| Area | What to check | Found? | Reuse or replace |
| --- | --- | --- | --- |
| **Existing OCR** | Edge functions or Flutter services that read documents; which model or provider | **Yes, extensively.** `supabase/functions/ocr/` (index, pool, retry, exchange, targets, gemini_schema, prompt). Tables `ocr_scans`, `ocr_exchanges` (`0704`, one row per HTTP call, raw), `ocr_providers` (9: claude, openai, gemini, grok, Google Document AI, MLKit on-device, MinerU, PaddleOCR, OCRmyPDF), `ocr_provider_keys` (pooled, budgeted, `0675`). Flutter: `scan_runner.dart`, `scan_flow.dart`, `attachments_card.dart`, `scan_progress.dart`, the console's scan log | **REUSE.** This is the pipeline. Add stages to it |
| **AI provider layer** | How LLM calls reach OmniRoute; env names; vision support | **Layer yes, OmniRoute no.** `ai_providers` (16 rows: anthropic, openrouter, openai, deepseek, qwen, cerebras, nvidia_nim, google, mistral, groq, xai, together, fireworks, perplexity, deepinfra, puter), each with `wire` (`anthropic` or `openai`) and `base_url`; `ai_models` with `kind in (chat, vision)`; `ai_provider_credentials` per org; `ask` edge function routes through it. **The string "OmniRoute" appears nowhere in this repository or database** | **REUSE the layer. OmniRoute is a decision, not a find** — see gaps |
| **Storage** | Buckets; per-org path convention; RLS on storage.objects | **Yes.** Buckets `attachments`, `mail`, `chat`, `logos`, `feedback`. Path `<org_id>/<table>/<record_id>/<file>`, enforced by a trigger that refuses a row whose path disagrees with its columns. Policies `attachments_read/write/delete/move` read the org out of the path prefix. Signed URLs, 10-minute default. `0708` added `attachments_of` and an evidence rule with the 7-year retention argument already written down | **REUSE unchanged.** A `capture` bucket is unnecessary |
| **Bills / expenses / receipts** | RPCs that create them; required fields | **Posting yes, creation no.** `post_purchase_document`, `post_sales_document`, `post_expense`, `post_expense_claim`, `post_receipt`, `post_goods_received`, `post_manual_journal`, `post_withholding`, `create_gl_entry`. But documents are **created by a direct PostgREST insert** (`Repo.saveDocument` → `.from(table).insert()`), not through an RPC | **REUSE the posting RPCs.** Flag: creation does not follow the brief's "writes through SECURITY DEFINER RPCs" house rule today |
| **Chart of accounts and tax codes** | accounts, tax codes (SST), default accounts per contact | **Yes.** `accounts` (typed, subtyped), `tax_codes` (rate, `tax_type_code`, `applies_to`), per-contact `receivable_account_id` / `payable_account_id`, per-item `purchase_account_id` / `inventory_account_id` / `sales_account_id`, `app.calc_document_line` charging tax per line | **REUSE.** Tax is per line all the way to MyInvois — see `0706` |
| **Contacts** | Supplier table, BRN/TIN fields, the SSM search hook | **Yes.** `contacts` with `tin`, `registration_no` (12-digit), `old_registration_no` (`571389-H` form), `sst_registration_no`, `is_tin_verified`, `entity_type`. `set_contact_ssm_entity` writes them; `ssm-search` and `ssm-api` edge functions with `ssm_search_cache`; `createSupplierFromScan` already exists in Flutter | **REUSE.** P1 "SSM auto-fill" is mostly wiring, not building |
| **Bank reconciliation** | Statement line and reconciliation tables and match logic | **Yes, complete.** `bank_accounts`, `bank_transactions`, `bank_reconciliations`, `bank_rules`, `bank_feeds`, `bank_feed_runs`, `bank_transfers`; `match_bank_transaction`, `app.bank_rule_matches`, `complete_bank_reconciliation`, `reopen_bank_reconciliation`, `report_bank_reconciliations`. Statement scanning exists as a scan target, and **`bank_statement` is the only destination with `scan_target_fields` populated** | **REUSE.** P1 "bank rec auto-match" has its tables and its matcher |
| **MyInvois** | e-Invoice tables, UUID validation, self-billed | **Yes.** `einvoice_documents`, `einvoice_lines`, `einvoice_submissions`, `einvoice_logs`, `einvoice_credentials`, `einvoice_consolidations`, `einvoice_consolidation_items`; `myinvois` edge function (manifest, receive, retry, all tested); `purchase_documents.requires_self_billed` with `app.suggest_self_billed`; XAdES signing built | **REUSE.** Reading a QR off a page is the new part |
| **Expense claims** | Payroll or HR claims tables | **Yes.** `expense_claims`, `expense_claim_lines`, `claim_types`, `claim_approvals`, `claim_approval_settings`, `post_expense_claim`, plus `claim_attachments.sql` and `claim_approval_chain.sql` under test | **REUSE** |
| **Inventory** | PO and GRN tables for three-way matching | **Yes.** One table, `purchase_documents`, with `doc_type in (purchase_request, purchase_order, goods_received, bill, purchase_credit_note, purchase_debit_note, purchase_return)`, `parent_id` chaining them and per-line progress counters | **REUSE.** Three-way match has its data today |
| **Jobs / queues** | pg_cron, pgmq or a background edge-function pattern | **Partly.** `pg_cron` is installed with six jobs (daily, activity reminders, SLA sweep, audit purge, OCR exchange purge, demo rebuild). **No `pgmq`, no job table, no `FOR UPDATE SKIP LOCKED` worker anywhere.** Scanning today is synchronous: the app calls the `ocr` function and waits behind a modal | **GAP — build.** The brief's queue-driven chain has no foundation |
| **Email-in** | Any inbound email handling | **Yes, built.** `receive-email` edge function: takes `{to, from, message_id, subject, text, html, attachments[]}`, files the message against the org that reserved the address, stores attachment bytes in the `mail` bucket at `<org_id>/<email_id>/`, and writes rows through `record_inbound_attachment` (service-role only, both). Added in `0354` | **REUSE.** P1 "email-in" is mostly routing mail into the capture queue |

---

## Gaps — what is genuinely not there

Ordered by what blocks what.

1. **A job queue.** Nothing claims work. Every stage in the brief's
   flowchart is a state change on a row, and there is no such row and
   no worker. This blocks the entire pipeline design and is the first
   thing to build. `pg_cron` can tick it; the claim pattern
   (`FOR UPDATE SKIP LOCKED`, N concurrent per org) does not exist.

2. **OmniRoute.** Not a gap in the code — a decision. The provider
   layer is ready for it: adding OmniRoute is one row in `ai_providers`
   with `wire = 'openai'` and a `base_url`, plus a credential. **But the
   brief's own risk section says it runs on Kabeer's Mac, and a
   production pipeline cannot depend on that.** Nothing should be
   pointed at it until there is a hosted address. Meanwhile the vision
   readers already wired (Claude, ChatGPT, Grok, Document AI) work.

3. **Bounding boxes and per-field confidence.** `OcrExtraction`
   returns values; it returns no `page`, no `bbox` and no per-field
   confidence. Click-to-verify and auto-zoom cannot be built on what
   comes back today. This is a prompt-and-schema change plus somewhere
   to put it.

4. **Auto-split.** Nothing finds document boundaries in a multi-page
   PDF. One upload is one document throughout.

5. **Page rendering.** Nothing turns a PDF into page images. The
   readers are handed the file. `capture_pages` has no counterpart.

6. **`pgvector`.** Not installed. Extensions present: `btree_gist`,
   `citext`, `pg_cron`, `pg_trgm`, `pgcrypto`, `plpgsql`. The brief
   wants it in the `extensions` schema for `coding_memory.embedding`.
   Worth noting `pg_trgm` is already there and a trigram fingerprint
   may carry the learning engine's first version without embeddings.

7. **The learning engine.** No `capture_rules`, no `coding_memory`, no
   "code from the last 20 posted bills". `_applyScan` deliberately sets
   no tax code and no account on a scanned line today.

8. **Duplicate detection.** No file hash is stored anywhere. Storage
   keys are `<epoch-ms>-<name>`, so the same file uploaded twice is two
   objects and two rows.

9. **`scan_target_fields` is empty except for bank statements.** This
   is the cause of the payment-voucher report: `0681` built a
   per-destination column list so the reader could be asked for the
   destination's own fields, and only `bank_statement` was ever
   populated. Every other kind falls through to one generic 14-field
   invoice schema — which is why "A/C Debited", "File Ref" and the
   payee had nowhere to go. **Cheapest high-value fix in this whole
   document, and it needs no new tables.**

10. **WhatsApp, Drive/Dropbox/OneDrive.** Nothing. P2 in the brief.

---

## Corrections to the brief

Stated plainly because the brief asks for an audit, and an audit that
only confirms is not one.

- **"iAkauntan already has some OCR"** — understates it. See above.
- **"OmniRoute gateway ... route every LLM call through it"** — there
  is no OmniRoute in this codebase. The instruction cannot be followed
  as written until it exists at a reachable address.
- **"data kept in-region (Supabase ap-northeast-2)"** — not verifiable
  from the repository. Needs checking in the Supabase dashboard.
- **"no live_change triggers on tables written by read paths"** — this
  repository already enforces the opposite default:
  `live_change_feed.sql` requires *every* table with an `org_id` to
  carry the `live_change_insert` trigger **or be named in
  `pg_temp.feed_exempt()` with a reason**. The capture tables will have
  to be named there, not simply left out.
- **"never auto-post in P0/P1: a human approves"** — consistent with
  what is here, and worth keeping: `0705` added a banner precisely
  because a reader that mistakes 1,086.12 for 1,086.72 produces a
  document that balances, posts and reconciles to nothing.

---

## What was already done this week that the brief asks for

Not planned against it — it arrived from the same reports.

- `0704` — every reader request and reply logged raw, per call, opened
  from the console. The brief's "record the model and token cost per
  document" has its table.
- `0705` — `document_scan_totals`: the paper's own subtotal, tax and
  total, with a banner when the lines disagree. The brief's "line sum
  equals subtotal within RM0.01, otherwise flagged", for documents
  already in the ledger.
- `0706` — the supplier's stated total decides whether the document
  rounds. The brief's "rounding adjustment" recognition, enforced.
- `0707` — `entry_source`, so every record a reader filled in is
  tagged "AI Scan" wherever it is listed.
- `0708` — the paper behind a posting cannot be deleted; LHDN's 7-year
  retention is the argument in the migration header. The brief's
  "attachments carried through" and "keep files for 7 years".
- `ed16168d` — the reader is told any document may be handwritten.
  The brief's "handwriting" parity row, in its first form.

---

## Open questions — back to Kabeer

The brief's own three, plus four this audit raises.

1. **Extend AI SmartScan, or replace it?** The single biggest decision
   here. Recommendation: extend.
2. **Where will OmniRoute live in production?** Nothing should point at
   a laptop. Until there is an address, which of the wired vision
   providers should extraction use?
3. **Which vision models are on OmniRoute today?** (the brief's own)
4. **Bundle Smart Capture or meter per page?** (the brief's own) — note
   the OCR credit ledger and per-page pricing already exist, so
   metering is the cheaper of the two to build.
5. **Is WhatsApp Business API access available?** (the brief's own)
6. **Shall I do gap 9 now?** Populating `scan_target_fields` for bills,
   receipts, expenses, vouchers and contacts is small, needs no new
   tables, and is the direct fix for the payment-voucher report. It
   does not depend on any of the phase work.
7. **Is the 50-document test set available?** Phase 0's exit test needs
   it and nothing here can produce it: 20 bills including handwritten
   and Chinese, 10 receipts, 10 bank statements from 5 banks,
   5 e-Invoices, 5 mixed bulk PDFs.

No code has been written against this brief. Phase 1 starts when you
say so.
