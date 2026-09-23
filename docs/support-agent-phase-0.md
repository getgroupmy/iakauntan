# Support agent — Phase 0, the repository truth check

`CLAUDE_HANDOVER_IAKAUNTAN_SUPPORT_AGENT.md` (22 September 2026) opens
its implementation plan with a Phase 0 and one instruction:

> Document discrepancies between this handover and current code before
> implementation.

This is that document. **No code has been written for the support
agent.** Everything below is counted or looked up on this branch,
`claude/iakauntan-accounting-crm-8snun0`, at `ce6b2ae0`.

The headline: the handover is a good specification written against a
repository state that does not match this one. Four of its assumptions
are wrong, two of its proposed builds already exist in a different
shape, and its largest precondition is entirely absent.

## 1. The files it says to read are not here

Phase 0 step 1 says to read `AGENTS.md`; step 3 says to locate
`docs/chatgpt-support-agent-handoff.md` and
`docs/chatgpt-support-agent.md`.

| Expected | State |
| --- | --- |
| `AGENTS.md` | **absent.** This repository's standing instructions are `CLAUDE.md`, `.claude/CLAUDE.md` and `README.md` |
| `docs/chatgpt-support-agent-handoff.md` | **absent** |
| `docs/chatgpt-support-agent.md` | **absent** |

Nothing about a ChatGPT surface has ever been written here. The
handover's own §2 hedges — *"Previously identified implementation gaps
that remain to be verified"* — and the answer to every one of them is
"not started", not "started and incomplete".

**This matters more than a missing file.** A spec that expects prior
design documents is a spec whose author believed a design phase had
happened. It has not, and Phase 1 is therefore a real design phase and
not a freeze.

## 2. `support_feedback` should not be created — `feedback_reports` exists

§9.1 proposes a `support_feedback` table. The product already has one,
built and in use, reachable from "Report a problem" in the menu:

```
feedback_reports
  id, org_id, reported_by, kind, title, body, screen, app_version,
  status, severity, platform_note, handled_by, resolved_at,
  created_at, updated_at
```

with six RPCs — `report_feedback`, `my_feedback`, `platform_feedback`,
`set_feedback_status`, `attach_feedback_file`, `feedback_files` — an
attachments table (`feedback_attachments`, `0660`), and **its own
authorisation predicates**: `app.can_see_feedback` and
`app.can_attach_to_feedback`.

`screen` and `app_version` are already there, which are two of the
fields the handover asks a bug report to carry.

**Recommendation: extend, do not duplicate.** A second feedback table
would split the support queue in two and give the platform console a
partial view — and the console reads `platform_feedback` today.

What `feedback_reports` genuinely lacks for §8.2:

- no pending-draft/confirmation-token mechanism;
- **no idempotency key on `report_feedback`** — zero of the feedback
  RPCs take one;
- no channel, conversation, actor-vs-submitter, consent text/version or
  correlation id.

Those are columns and a guarded RPC, not a new subsystem.

## 3. There is no authorisation server, and that is the critical path

§7 requires OAuth/OIDC with an issuer, clients, redirect URIs, scopes
and short-lived tokens. §2 forbids pasted tokens.

**None of it exists.** The only OAuth code in the repository is Google
*service-account* auth (`_shared/google_auth.ts`, for Document AI) and
MyInvois certificate handling. Both are this server authenticating to
somebody else. Neither is this server issuing anything.

Every write path in the product today is a signed-in human holding a
Supabase JWT. There is no token, key, scope or grant table —
`device_tokens` is push notifications.

This is the same finding `docs/mcp-server.md` reached from the other
direction, and it is the one that decides the schedule: **the in-app
surface needs no new authorisation and the ChatGPT surface cannot
begin without it.** They are not one project.

## 4. The knowledge base does not exist in any form

§4, §11 and three of the ten read-only tools (`search_help`,
`get_help_article`, `find_known_issue`) require articles, versions,
citations and an approved issue registry.

There are **no help, article, knowledge or known-issue tables**, and no
content. §11.1's source hierarchy has nothing at the top of it.

The handover is right that Bukku's text must not be copied and that
articles must be authored from actual behaviour. That is a writing
project measured in weeks of somebody who knows the product, and it
gates the tools that answer the commonest questions.

## 5. Chat already exists, and §12 has to reckon with it

§12 proposes canonical conversations. There are **ten `chat_*`
tables** — conversations, messages, participants, presence, typing,
links, access, attachments, calls, call participants — with real-time
subscriptions and an unread-badge path through the shell.

Whether support conversations are chat conversations or a parallel
structure is a design decision nobody has made. Either is defensible;
inventing a second one silently is not.

## 6. What the guards actually are

The handover asks for the real source of truth for roles and
membership. It is 21 SECURITY DEFINER predicates in the `app` schema,
used inside RPCs and RLS policies:

```
can_add_company      can_admin           can_attach_to
can_attach_to_feedback  can_discount_pos can_manage_firm
can_manage_hr        can_post            can_read_attachment
can_read_ledger      can_read_module     can_run_payroll
can_see_feedback     can_void_pos        can_write
can_write_module     is_firm_member      is_group_member
is_org_member        is_platform_admin   ...
```

These answer *what may this USER do*. They do not answer *what may an
AGENT do on that user's behalf*, which is §7.2's scopes and is the gap
in `docs/mcp-server.md` §"The question that decides the design".

## 7. The surface the agent must not be given

§8.3 forbids arbitrary RPC invocation, and the numbers say why:

| | |
| --- | --- |
| Functions `authenticated` may execute | 1,053 |
| Of those, VOLATILE — they write | 482 |
| Of those, accepting an idempotency key | 4 |
| `platform_*` functions grantable to `authenticated` | 53, each guarded internally by `app.is_platform_admin()` |

A frozen tool census is the mechanism, as `docs/mcp-server.md` argues.
Note the 53: they are safe — every one checks — but an agent should not
be *offered* 53 tools it will be refused at.

## 8. Discrepancies, ranked

| # | Discrepancy | Consequence |
| --- | --- | --- |
| 1 | No OAuth/OIDC issuer | The ChatGPT surface cannot start. Split it from the in-app surface |
| 2 | No knowledge base, no content | Three tools have nothing behind them; the writing is the long pole |
| 3 | `support_feedback` proposed where `feedback_reports` exists | Extend it; a second table splits the support queue |
| 4 | Named design documents absent | Phase 1 is a design phase, not a freeze |
| 5 | Chat subsystem unaccounted for | §12 must adopt or deliberately bypass ten existing tables |
| 6 | No idempotency on any feedback RPC | §8.2 requires it; `0307` has the mechanism and four users |

## 9. What Phase 1 has to decide, and nobody can decide for it

1. **In-app first, or both surfaces together?** In-app needs no new
   authorisation. Both together means building an authorisation server
   before a single question is answered.
2. **Support conversations: `chat_*` or separate?**
3. **Who writes the articles, and what is the v1 list?**
4. **Does the agent read accounting data at all in v1**, or only the
   knowledge base plus diagnostics? §5.2 assumes yes; it is the
   difference between a docs bot and a delegated reader.

## 10. Recommended order, which differs from the handover's

The handover's Phase 2 begins with migrations. That is right, but not
the migrations it lists:

1. **Extend `feedback_reports`** with the pending-draft, confirmation
   and idempotency machinery from §8.2, and give `report_feedback` the
   `0307` idempotency overload. This is useful on its own — the
   existing "Report a problem" flow gets a confirmation protocol — and
   it is the whole of the agent's only write.
2. **Knowledge tables and the first ten articles.** Nothing else
   unblocks `search_help`.
3. **The in-app surface**, on the existing session. No new
   authorisation, no OAuth, working agent.
4. **Then** the authorisation server, and then ChatGPT.

This delivers a working support agent to iAkauntan users before the
hardest and least certain piece begins, and it makes that piece a
decision taken with a working system to point at.

## What this document is not

An architecture decision record. §19 Phase 1 asks for one and it needs
the four answers in §9 first.
