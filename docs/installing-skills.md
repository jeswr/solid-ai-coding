# Installing & advertising the Solid skills

How to get this repo's [Agent Skills](https://agentskills.io/) (the `SKILL.md` bundle under
[`skills/`](../skills/)) in front of your coding agent — three ways, in order of preference — and
how those skills get **advertised** to the agent so it loads the right one at the right time.

Prior art: [LikeC4's AI-tools page](https://likec4.dev/tooling/ai-tools/) documents the same shape
for its `likec4-dsl` skill (`npx skills add https://likec4.dev/`, auto-loaded when editing `.c4`
files). This page adapts that pattern for the Solid skill bundle and adds the suite's
vendor + hash-pin convention for repos that need a reproducible, audited copy.

> Install the [`AGENTS.md`](../README.md#use-it-in-your-project) guide **first** — the skills
> complement it, they don't replace it.

## 1. Discovery protocol (recommended)

These skills are published through the [Agent Skills](https://agentskills.io/) discovery protocol,
so one command installs the whole bundle into any agent that supports it (Claude Code, OpenAI
Codex, IBM Bob, and others):

```sh
npx skills add jeswr/solid-ai-coding
```

Target agents explicitly with `-a` (otherwise the CLI prompts), or pull a single skill with
`--skill`:

```sh
npx skills add jeswr/solid-ai-coding -a claude-code -a codex -a bob
npx skills add jeswr/solid-ai-coding --skill solid-fetch-rdf
```

The CLI writes the skills into the agent's own skills directory (e.g. Claude Code's
`~/.claude/skills/` or a project `.claude/skills/`). This is the same mechanism LikeC4 documents —
the agent auto-loads the skill when the matching context appears. For the full default skill set
(this bundle + the engineering/design skills), see
[`AGENTS.md` § Recommended skills](../AGENTS.md#recommended-skills).

## 2. Vendor into `.agents/skills/` (a project-owned, reviewable copy)

When you want the skills **committed into a project** — so every clone and every CI run has the
exact same copy, and changes show up in review — vendor them under a project skills directory and
symlink the agent at it. The suite convention is a top-level `skills/` (or `.agents/skills/`)
directory of symlinks pointing at the vendored copies, so a single tree serves every agent:

```sh
# clone or submodule this repo somewhere vendored, e.g. .agents/sources/solid-ai-coding
git submodule add https://github.com/jeswr/solid-ai-coding .agents/sources/solid-ai-coding

# symlink each skill into the agent-discovered skills dir
mkdir -p .agents/skills
for s in .agents/sources/solid-ai-coding/skills/*/; do
  ln -s "../sources/solid-ai-coding/skills/$(basename "$s")" ".agents/skills/$(basename "$s")"
done
```

Point your agent's skills path at `.agents/skills/` (Claude Code: a project `.claude/skills/`
symlink, or set the skills directory in settings). The symlink layer means the vendored sources
stay in one place and every consumer (Claude Code, Codex, a CI lint) reads the same tree.

## 3. Hash-pin a vendored copy (`skills-lock.json`)

A vendored copy can drift from upstream silently. The suite pins each vendored skill by a **content
hash over the entire skill directory** — `SKILL.md` *and* every referenced file (`references/`,
`scripts/`, `assets/`, …) — in a `skills-lock.json` at the project root, so a stale or tampered
file *anywhere* in the skill is caught by a gate rather than shipped. (Hashing only `SKILL.md` would
miss drift in the files it points at — those can be modified without the pin noticing.) The shape:

```json
{
  "source": "github:jeswr/solid-ai-coding",
  "skills": {
    "solid-fetch-rdf": { "sha256": "<directory digest of skills/solid-fetch-rdf/ — ALL files>" },
    "solid-object":    { "sha256": "<directory digest of skills/solid-object/ — ALL files>" }
  }
}
```

Generate / verify the hashes with a one-liner and wire the verify into the project's lint gate so a
drifted skill fails the build:

```sh
# deterministic digest over EVERY file in a skill dir (each file's content + the sorted file set,
# so an added, removed, or edited file under references/ scripts/ assets/ all change the digest)
skill_digest() { ( cd "$1" && find . -type f -not -path './.git/*' | LC_ALL=C sort \
  | xargs shasum -a 256 ) | shasum -a 256 | cut -d' ' -f1; }

# compute the pin for one skill (covers SKILL.md + references/ + scripts/ + assets/ + …)
skill_digest .agents/skills/solid-fetch-rdf

# verify every pinned skill matches its directory digest (fail-closed — any drift exits non-zero)
node -e 'for (const n of Object.keys(require("./skills-lock.json").skills)) console.log(n)' \
| while read -r name; do
    want=$(node -e "process.stdout.write(require('./skills-lock.json').skills['"'"'$name'"'"'].sha256)")
    got=$(skill_digest ".agents/skills/$name")
    [ "$want" = "$got" ] && echo "ok    $name" || { echo "DRIFT $name (want=$want got=$got)"; exit 1; }
  done
```

A hash-pinned skill is **not edited in place** — to update one, re-vendor from upstream and
re-generate the lock in the same change, never patch the local copy (a local edit that drifts from
its pin is worse than no skill). Down-suite, `prod-solid-server` carries exactly such a
`skills-lock.json` keyed to this repo as the source of truth.

## How skills are "advertised" to the agent

Each skill is a folder with a `SKILL.md` whose YAML frontmatter is the advertisement:

```yaml
---
name: solid-fetch-rdf
description: >-
  Use when code fetches or parses RDF from a Solid pod — importing @jeswr/fetch-rdf,
  calling fetchRdf/parseRdf, handling RdfFetchError, or keeping the ETag for a conditional write…
---
```

Agents that support skills surface the `name` + `description` of every installed skill in the
system prompt (the progressive-disclosure pattern — roughly 100 tokens per skill), so the model
knows what's available without loading the body. It pulls the full `SKILL.md` only when the
`description`'s trigger conditions match the task at hand. This is why every `description` in this
repo is written as an explicit **"Use when …"** trigger, not a summary — the description *is* the
discovery index the agent reads.

The human-readable counterpart of that index is the bundle table in the
[README](../README.md#the-bundle) and the `Solid skills` section of [`AGENTS.md`](../AGENTS.md) —
keep all three (frontmatter, README table, AGENTS.md list) in sync when adding or renaming a skill.

## MCP, for current library docs

The skills are static references; for live API docs the guide wires the
[context7](https://context7.com/) MCP server (see the README). The two are complementary — skills
for the verified patterns and the packages context7 can't serve, context7 for everything it can.
