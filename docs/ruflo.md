# Adding Ruflo to this repository

[Ruflo](https://github.com/ruvnet/ruflo) (published as `ruflo` on npm;
the repository still calls itself `claude-flow` inside `package.json`)
is an agent harness that sits *around* Claude Code and Codex: about a
hundred agent definitions, swarm coordination, a vector memory, an MCP
server and a set of hooks that fire on every tool call.

It is a **development-time tool**. Nothing in it ships to a customer,
nothing in it runs on Supabase, and nothing in it belongs in
`app/pubspec.yaml`. Adding it changes how the people and agents working
on this repository work — which is exactly why it is worth writing the
steps down rather than running an installer and finding out afterwards
what it touched.

## The two ways in, and what each one costs

| | Plugin track | CLI track |
|---|---|---|
| Command | `/plugin marketplace add ruvnet/ruflo` | `npx ruflo@latest init wizard` |
| Files written into this repository | none | `.claude/`, `.claude-flow/`, `CLAUDE.md`, helper scripts, settings |
| MCP server | only `ruflo-core`, which ships its own `.mcp.json` | yes |
| Hooks installed | no | yes |
| Reversible by | uninstalling the plugin | `git checkout` — if you were clean before you started |

The plugin track writes nothing into the working tree, which is the
whole reason to prefer it here.

## Recommended: the plugin track

Inside a Claude Code session opened on this repository:

```
/plugin marketplace add ruvnet/ruflo
/plugin install ruflo-core@ruflo
```

Then add only what a job actually needs. The ones that fit the shape of
this repository:

| Plugin | Why it fits here |
|--------|------------------|
| `ruflo-testgen@ruflo` | finds untested paths — this repository already argues that a rule enforced only in Dart is not enforced, and an assertion nobody wrote is the same argument one step earlier |
| `ruflo-security-audit@ruflo` | dependency and CVE scanning beside the RLS assertions in `supabase/tests/` |
| `ruflo-migrations@ruflo` | schema-change review; read the caveat below before believing it about *this* repository's migrations |
| `ruflo-swarm@ruflo` | several agents on one task, if you want that |

### What is installed here, and what is not

`ruflo-security-audit@ruflo` is installed at project scope and enabled.
It is four markdown components — three skills (`security-scan`,
`dependency-check`, `audit`) and one agent (`security-auditor`) — with
**no hooks and no MCP server**, at about 228 tokens added to every
session. That is the whole of its footprint, and it is why this is the
one plugin worth having here.

Two things to know before relying on it:

- **`.claude/settings.json` is gitignored** (see `.gitignore`, beside
  the same note about `graphify claude install --project`). The
  enablement therefore lives on the machine that ran the install, not
  in the repository. On a new clone, or a fresh Claude Code session in
  a throwaway container, run the two lines again:

  ```bash
  claude plugin marketplace add ruvnet/ruflo
  claude plugin install ruflo-security-audit@ruflo --scope project
  ```

  The install merges into the existing `hooks` block rather than
  replacing it — the two `graphify hook-guard` entries survive, which
  was the thing worth checking.

- **`/audit` is a prompt, not a scanner.** It instructs the agent to
  run `npx @claude-flow/cli@latest security scan`, `security cve
  --list` and `security threats --model stride`, and then to file the
  findings in a Ruflo memory namespace that only exists on the CLI
  track. So the first `/audit` fetches and runs an unpinned npm CLI,
  and the memory step is a no-op here. Read the findings; do not treat
  the run itself as free.

### The first audit, and what it was worth

Run on 7 September 2026 against the whole repository, at standard depth.
All four steps, and what each returned:

| Step | Result |
|---|---|
| `security scan --depth standard --output json` | banner and a spinner. No findings, no JSON, exit 0. The first attempt hung past seven minutes; it completes once the npm package is cached. |
| `security cve --list` | "No known vulnerabilities in dependency tree. Source: `npm audit --json`." |
| `security threats --model stride` | 16 findings — 2 CRITICAL, 8 HIGH, 6 MEDIUM |
| `security secrets` | no secrets detected |

**Every one of the 16 findings is a false positive**, and the two clean
results are worth less than they look:

- The two CRITICALs are `.env.example` and `server/sfu/.env.example`,
  flagged as "`.env` file tracked in git". They are the template files,
  every slot empty or `replace_me`, with a header that says so. The
  rule matched the filename, not the contents.
- Seven findings are under `app/build/web/`, which `app/.gitignore`
  ignores and git does not track. They exist only in a working tree
  that has been built, and they are duplicates of the seven below.
- The other seven are `new Function()`, `__proto__` and "non-localhost
  HTTP URL" inside `app/web/pdfjs/pdf.js` and `app/web/tesseract/*` —
  vendored Mozilla pdf.js and tesseract.js, minified. The HTTP URLs are
  `http://www.w3.org/2000/svg` and the Apache licence URL: XML
  namespaces and a licence, not network calls.
- **`cve --list` runs `npm audit`, and this repository has no
  `package.json`.** It reported a clean dependency tree by auditing
  nothing. The actual dependency trees here are Dart (`app/pubspec.yaml`)
  and Deno (the edge functions' imports), and it read neither.
- Both scans stop at **500 files**, and the repository tracks 1,849 —
  651 Dart, 833 SQL, 39 edge-function TypeScript. "No secrets
  detected" covers whichever 500 the walk reached first, which in this
  case was heavily `app/build` and `app/web`. It is not an all-clear.

So the gap this was installed to close — nothing in CI watches the Dart
or Deno dependency trees — **is still open**, and this plugin does not
close it. What would: `dart pub outdated` and a Deno import audit in
CI, neither of which needs Ruflo.

The plugin costs ~228 tokens a session and stays installed; the
`security-auditor` agent and the two skills may still be useful as
review prompts. But `/audit` on this repository is 16 false positives
and two hollow all-clears, and it should not be run before a release in
the belief that a green result means anything.

`ruflo-core`'s tools arrive namespaced —
`mcp__plugin_ruflo-core_ruflo__memory_store` and so on — not as the bare
`memory_store` / `swarm_init` names the CLI track's scaffolding writes
into `CLAUDE.md`. If you follow a Ruflo tutorial that calls the bare
names, it is describing the CLI track.

Plugin installs are per-machine, in the user's own Claude Code
configuration. Nothing about them is committed here, so every person
who wants Ruflo runs the two lines above themselves.

## The CLI track, if you want the whole harness

```bash
# every platform
npx ruflo@latest init wizard

# macOS / Linux / WSL / Git-Bash only
curl -fsSL https://cdn.jsdelivr.net/gh/ruvnet/ruflo@main/scripts/install.sh | bash

# and, to register the MCP server
claude mcp add claude-flow -- npx ruflo@latest mcp start
```

`init` needs Node — this repository's CI already runs Node 22, so the
version is not the problem. What it writes is:

- **`CLAUDE.md`** — the file at the root of this repository that tells
  every agent the database is the application, that migrations are
  append-only, and that CI must be watched to green. `init` rewrites
  it. **Copy it somewhere first, run `init`, then merge by hand**, and
  keep this project's rules at the top. Losing them is not a formatting
  problem; it is the next agent editing an applied migration.
- **`.claude/settings.json`** — which already carries the two
  `graphify` hook-guards. Ruflo installs hooks of its own. Merge the
  `hooks` object rather than letting one side win, or the knowledge
  graph stops being consulted.
- **`.claude-flow/`**, helper scripts, and an `agentdb.rvf` memory
  file. Decide deliberately whether those are committed or added to
  `.gitignore`; a vector memory of a working session is not source.

## Three things to know before either track

**This branch deploys on green.** A push to
`claude/iakauntan-accounting-crm-8snun0` that goes green applies
migrations to the hosted Supabase project and deploys the edge
functions, the workspace proxy and the web bundle. Anything Ruflo
generates is a change like any other: it goes through
`supabase/tests/run_locally.sh`,
`supabase/functions/_local_check/check_locally.sh`,
`flutter analyze --fatal-infos --fatal-warnings` and `flutter test`
before it is pushed. An agent that writes a migration and pushes it
unattended is writing to production.

**Migrations are append-only.** `ruflo-migrations` describes itself as
managing schema changes safely, and the safe change it will reach for
in most repositories is editing the migration that is wrong. Here, a
migration that has been applied to the hosted project is never edited —
the correction is a new numbered file. Read `docs/migrations.md` before
letting any tool near `supabase/migrations/`.

**There is already a knowledge graph.** `graphify-out/` holds it, and
`.claude/settings.json` enforces consulting it before grepping. Ruflo's
`ruflo-knowledge-graph` and `ruflo-rag-memory` build their own. Running
both is not harmful, but it is two maps of the same territory that will
disagree the moment one is refreshed and the other is not. If you want
Ruflo's, say in `CLAUDE.md` which one is authoritative.

## Backing it out

Plugin track: `/plugin uninstall ruflo-core@ruflo`, and
`/plugin marketplace remove ruflo` when the last one is gone.

CLI track: `git status` names everything it wrote, because you started
clean. `git checkout -- CLAUDE.md .claude/settings.json` restores the
two files that matter and the rest are untracked directories to delete.
`claude mcp remove claude-flow` unregisters the server.

## What is not decided here

Nothing in this repository depends on Ruflo, and this document does not
install it. It is a tool for the people working on the code, and
whether the project adopts it — especially the CLI track, which changes
`CLAUDE.md` for everyone — is a decision for the maintainer rather than
for whoever happened to read about it first.
