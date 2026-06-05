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
    "context7": { "httpURL": "https://mcp.context7.com/mcp" }
  }
}
```

(Bob uses `httpURL` for streamable-HTTP servers; its `url` key is legacy SSE and will not work
with context7.)

### Other tools

Cursor, Zed, Windsurf, Gemini CLI, GitHub Copilot coding agent, Devin, and a growing list of
[other tools](https://agents.md/) read `AGENTS.md` natively — copying the file is enough.

## Solid skills

Reusable Solid skill files live at
[`solid-contrib/llm-skills`](https://github.com/solid-contrib/llm-skills). Once that repo's
restructure to the [Agent Skills](https://agentskills.io/) format (`SKILL.md`) lands, install
them into your agent with:

```sh
npx skills add solid-contrib/llm-skills -a claude-code -a codex
```

## Contributing

Issues and PRs welcome — especially corrections from people who hit an API drift between this
guide and a released library version. Code examples in the guide are checked against the
**published** packages at the versions stated (`node_modules` type declarations and behaviour),
not against READMEs or git HEAD, both of which drift.

## License

[MIT](./LICENSE)
