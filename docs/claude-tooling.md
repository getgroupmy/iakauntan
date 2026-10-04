# Claude Code tooling for this repository

What is installed, what is deliberately NOT, and the commands to get from
a fresh clone to a working set. This file exists because
**`.claude/settings.json` is gitignored** (`.gitignore:58`, by this
repository's own choice — see the note above it about
`graphify claude install --project`). The live configuration therefore
does not cross machines or sessions, and a cloud container is reclaimed
after a period of inactivity. The list has to be committed or it is lost.

`CLAUDE.md` is the standing rules. This is only the tooling around them.

## Already installed

| | |
| --- | --- |
| `graphify` | `.claude/skills/graphify/`, committed. The knowledge graph at `graphify-out/`. `CLAUDE.md` has the rules, including that `pip install "graphifyy[sql]"` comes FIRST or all ~800 migrations contribute nothing to the graph. |

## Marketplaces registered

Registering a marketplace is inert: it makes plugins *available* and
enables nothing. These four are declared in `.claude/settings.json`
(project scope), which means they are **not** committed and a fresh clone
has to re-add them:

```sh
claude plugin marketplace add anthropics/skills                   --scope project
claude plugin marketplace add obra/superpowers                    --scope project
claude plugin marketplace add rebelytics/one-skill-to-rule-them-all --scope project
claude plugin marketplace add mobile-next/mobile-mcp              --scope project
```

## Plugins to enable

**Not yet enabled.** `claude plugin install` is refused in a Claude Code
session under the auto-mode classifier as `[Self-Modification]`, and
writing `enabledPlugins` by hand is the same thing by another route. So
these are a person's commands to run, not an agent's:

```sh
claude plugin install claude-code-setup@claude-plugins-official     --scope project
claude plugin install superpowers@superpowers-dev                   --scope project
claude plugin install task-observer@one-skill-to-rule-them-all      --scope project
claude plugin install document-skills@anthropic-agent-skills        --scope project
claude plugin install example-skills@anthropic-agent-skills         --scope project
claude plugin install mobile-mcp@mobile-mcp                         --scope project
```

What each one is for here:

- **`superpowers`** (obra/superpowers) — TDD, debugging and collaboration
  skills. Worth reading against `docs/widget-tests.md` rather than
  instead of it: the thirteen ways a green test covers a broken screen
  are specific to this codebase and were each paid for once.
- **`task-observer`** (one-skill-to-rule-them-all) — a meta-skill that
  watches how the other skills perform and proposes improvements. You
  decide what is adopted.
- **`document-skills`** (anthropics/skills) — xlsx, docx, pptx, pdf.
  Directly relevant: this repository already generates workbooks and has
  `scripts/check_xlsx.py` asserting one reads back correctly under
  `zipfile`, `xml.etree` and `openpyxl`.
- **`example-skills`** (anthropics/skills) — `skill-creator`,
  `mcp-builder`, `webapp-testing`.
- **`mobile-mcp`** — see "Needs something this machine does not have".
- **`claude-code-setup`** — the official setup plugin, as requested.

`claude-api` is also in the `anthropic-agent-skills` marketplace, but it
already ships bundled with Claude Code, so installing it again is
duplication rather than addition.

## Needs something this machine does not have

Configuration recorded so it works the moment the missing piece exists.
**Neither is activated**, because half-wired tooling that errors on every
call is worse than tooling that is absent and documented.

### `mobile-next/mobile-mcp`

An MCP server driving real iOS/Android devices, simulators and
emulators — relevant to a Flutter app that ships to both stores. It needs
a connected device or a running emulator; the cloud container has
neither, and the iOS half needs macOS. Enable the plugin above on a
machine that has one.

### `firecrawl/firecrawl`

Hosted crawling and scraping. Needs a `FIRECRAWL_API_KEY`:

```json
{
  "mcpServers": {
    "firecrawl": {
      "command": "npx",
      "args": ["-y", "firecrawl-mcp"],
      "env": { "FIRECRAWL_API_KEY": "${FIRECRAWL_API_KEY}" }
    }
  }
}
```

**The key does not go in this repository, this database, or any payload
the app can read.** For a local session it belongs in the environment; in
CI it is a GitHub Actions secret; for the deployed stack it is the
Supabase dashboard. That rule is in `docs/handoff.md` and applies to
every key named in this file.

One caution, since the adjacency is obvious: task #11, the MIA headless
scraper, is the user's and is **not** to be started unprompted. Firecrawl
being installed is not permission to start it.

## Security review in CI

`.github/workflows/security-review.yml` runs
`anthropics/claude-code-security-review` on `pull_request` only, pinned
to commit `0c6a49f1`. It is **dormant and green** until an
`ANTHROPIC_API_KEY` repository secret exists — deliberately, because the
action exits 1 on an empty key rather than skipping, and an absent key is
not a security finding. The workflow's own header says why it is not on
`push`: this branch is the default branch, so a push review would be
reporting on code already live.

## Deliberately NOT installed

Not an oversight, and not to be "fixed" by a later session without
asking. Three of these sit in the path between Claude Code and the model:

| | |
| --- | --- |
| **OmniRoute** (`diegosouzapw/OmniRoute`) | An AI gateway routing requests to 358 providers, 150+ on free tiers. Installing it would send this repository's source — a Malaysian accounting, payroll and e-Invoice system — through third-party providers. Declined on that basis. |
| **Headroom** (`headroomlabs-ai/headroom`) | A context-compression layer, via startup hooks. It rewrites prompts before the model sees them. |
| **Caveman** (`juliusbrussee/caveman`) | Token compression, plus a proxy mode. Same objection as Headroom for the proxy. |

The compression objection is specific rather than reflexive: this is a
codebase whose first rule is that statutory arithmetic is asserted rather
than eyeballed, and whose documented failures are mostly cases where
something looked equivalent and was not — a fixture whose right value and
fallback value were the same row, a UTC date silently one day off a Kuala
Lumpur one, two mutants sharing a `.pyc`. Lossy compression of the
prompts carrying EPF, SOCSO, PCB and SSM deadline numbers adds a category
of failure that no gate in `supabase/tests/` or `scripts/` can see.

Their token savings are real and the tradeoff is a judgement call, not a
law. It was made once, here, with reasons, so that changing it is a
decision and not a drift.

## Reference, not tooling

`liquidslr/system-design-notes` is a set of markdown notes — rate
limiting, consistent hashing, key-value stores, news feeds. There is
nothing to install. It is not vendored here, because 20 directories of
general system-design notes in an accounting repository is clutter that
nobody prunes. Read it upstream:
<https://github.com/liquidslr/system-design-notes>.
