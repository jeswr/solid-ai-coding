# solid-ai-coding

An opinionated guide that makes AI coding agents — **Claude Code**, **OpenAI Codex**,
**IBM Bob**, and anything else that reads [`AGENTS.md`](https://agents.md/) — effective at
building [Solid](https://solidproject.org/) applications.

The guide itself is [**`AGENTS.md`**](./AGENTS.md). It has two parts:

1. **Solid-specific rules** — the recommended library stack, verified usage patterns for each
   library, how to pull accurate API docs via the [context7](https://context7.com/) MCP server,
   and the superseded stacks agents must avoid.
2. **General engineering rules** — application stack, TypeScript, testing, CI, accessibility,
   and process standards for shipping a high-quality app quickly.

## Use it in your project

Copy two files into your repository root:

```sh
curl -fsSLO https://raw.githubusercontent.com/jeswr/solid-ai-coding/main/AGENTS.md
curl -fsSLO https://raw.githubusercontent.com/jeswr/solid-ai-coding/main/CLAUDE.md
```

`AGENTS.md` is the guide; `CLAUDE.md` is a one-line import (`@AGENTS.md`) for Claude Code, which
does not read `AGENTS.md` natively.

Then wire up the context7 MCP server so your agent can fetch current library documentation
instead of guessing APIs (a free API key from
[context7.com/dashboard](https://context7.com/dashboard) raises rate limits but is optional):

### Claude Code

`CLAUDE.md` is picked up automatically. Add context7:

```sh
claude mcp add --scope user --transport http context7 https://mcp.context7.com/mcp
```

### OpenAI Codex

`AGENTS.md` is picked up automatically. Add context7 to `~/.codex/config.toml`:

```toml
[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"
```

### IBM Bob

`AGENTS.md` at the repo root is auto-loaded into every conversation
([docs](https://bob.ibm.com/docs/ide/getting-started/tutorials/start-a-project)). To make the
rules non-negotiable across all modes, also copy it to `.bob/rules/solid.md`
([rules docs](https://bob.ibm.com/docs/ide/configuration/rules)). Add context7 to `.bob/mcp.json`:

```json
{
  "mcpServers": {
    "context7": {
      "type": "streamable-http",
      "url": "https://mcp.context7.com/mcp"
    }
  }
}
```

(`"type": "streamable-http"` is required — without it Bob treats `url` as a legacy SSE server
and the context7 connection fails. Verified against a live Bob install, June 2026.)

### Other tools

Cursor, Zed, Windsurf, Gemini CLI, GitHub Copilot coding agent, Devin, and a growing list of
[other tools](https://agents.md/) read `AGENTS.md` natively — copying the file is enough.

## Solid skills

This repo bundles seven [Agent Skills](https://agentskills.io/) under [`skills/`](./skills/)
that go deeper than the guide — install them into your agent with:

```sh
npx skills add jeswr/solid-ai-coding -a claude-code -a codex
```

| Skill | Covers |
|---|---|
| [`solid-fetch-rdf`](./skills/solid-fetch-rdf/SKILL.md) | `@jeswr/fetch-rdf` API reference (not in context7) |
| [`solid-object`](./skills/solid-object/SKILL.md) | `@solid/object` API reference + `ProfileAgent` rendering reference class (not in context7) |
| [`solid-reactive-authentication`](./skills/solid-reactive-authentication/SKILL.md) | `@solid/reactive-authentication` API reference + login/IdP-selection UX spec (not in context7) |
| [`solid-server-matrix`](./skills/solid-server-matrix/SKILL.md) | Diagnosing CSS / ESS / NSS differences when an app works on one server and breaks on another |
| [`solid-type-index`](./skills/solid-type-index/SKILL.md) | Reading, writing, and bootstrapping Type Index registries (with a compile-verified wrapper implementation) |
| [`solid-scale-and-sharding`](./skills/solid-scale-and-sharding/SKILL.md) | Collection data without hitting the walls — sharding, index resources, client-side querying |
| [`solid-notifications`](./skills/solid-notifications/SKILL.md) | Live-sync via the Solid Notifications Protocol and the legacy NSS channel |
| [`accessible-html-links`](./skills/accessible-html-links/SKILL.md) | Native `<a href>` + WCAG link-purpose rules (derived from Solid-website review feedback) |

The guide's Part 2 also names a **default set of third-party engineering skills** (vitest,
Playwright, Node, TypeScript, semantic HTML, web design review, code review, and more) with
verified one-line install commands — see AGENTS.md §Recommended skills.


## Contributing

Issues and PRs welcome — especially corrections from people who hit an API drift between this
guide and a released library version. Code examples in the guide are checked against the
**published** packages at the versions stated (`node_modules` type declarations and behaviour),
not against READMEs or git HEAD, both of which drift.

## License

[MIT](./LICENSE)
