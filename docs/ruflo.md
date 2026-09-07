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
