# Setup Script Documentation

## Overview

The `setup-bob.js` script provides a fully automated, cross-platform setup for Solid development with IBM Bob. It's designed to be fast, reliable, and work identically on Windows, macOS, and Linux.

## Features

- ✅ **Fully parallelized** — All downloads and skill installations run concurrently
- ✅ **Cross-platform** — Works on Windows, macOS, and Linux
- ✅ **Fast** — Completes in ~1-2 minutes (vs 5-10 minutes sequential)
- ✅ **Idempotent** — Safe to run multiple times
- ✅ **Execution-verified** — full clean-room run checked on macOS (2026-06-05); pure Node builtins + npx, no platform-specific code

## Usage

### One-line install (recommended)

```sh
curl -fsSL https://raw.githubusercontent.com/jeswr/solid-ai-coding/main/setup-bob.js | node
```

### Local execution

```sh
# Download the script
curl -fsSLO https://raw.githubusercontent.com/jeswr/solid-ai-coding/main/setup-bob.js

# Make it executable (Unix-like systems)
chmod +x setup-bob.js

# Run it
./setup-bob.js
# or
node setup-bob.js
```

## What it installs

### Guide files (project root)
- `AGENTS.md` — Complete Solid development guide
- `CLAUDE.md` — Import reference for Claude Code

### MCP configuration (`.bob/mcp.json`)
- context7 MCP server for library documentation queries

### Solid skills (8 skills in `.bob/skills/`)
- `solid-fetch-rdf` — API reference for @jeswr/fetch-rdf
- `solid-object` — API reference for @solid/object
- `solid-reactive-authentication` — Auth API + login UX patterns
- `solid-server-matrix` — Multi-server compatibility debugging
- `solid-type-index` — Type Index registry operations
- `solid-scale-and-sharding` — Collection data patterns
- `solid-notifications` — Live-sync implementation
- `accessible-html-links` — WCAG link accessibility

### Engineering skills (10 skills)
- `vitest` — Testing framework
- `playwright-best-practices` — E2E testing patterns
- `webapp-testing` — Web app automation
- `node` — Node.js best practices
- `typescript-advanced-types` — Advanced TypeScript patterns
- `responsive-design` — Responsive layout strategies
- `semantic-html` — Semantic HTML patterns
- `web-design-guidelines` — UI design review checklist
- `code-review-and-quality` — Code quality standards
- `find-skills` — Skill discovery tool

## Requirements

- **Node.js** 18+ (tested on 18, 20, 22)
- **npm** (comes with Node.js)
- **VS Code** with IBM Bob extension

## Troubleshooting

### Script fails with "Command failed"

**Cause:** Network issues or npm registry problems

**Solution:** Re-run the script — it's idempotent and will skip already-installed components

### VS Code doesn't reload automatically

**Cause:** `code` CLI not in PATH

**Solution:** Manually reload: `Cmd+Shift+P` (Mac) or `Ctrl+Shift+P` (Windows/Linux) → "Developer: Reload Window"

### Skills not appearing in Bob

**Cause:** VS Code needs to be reloaded to pick up new skills

**Solution:** Reload VS Code (see above)

### "npx: command not found"

**Cause:** Node.js not installed or not in PATH

**Solution:** Install Node.js from [nodejs.org](https://nodejs.org/) and restart your terminal

## Architecture

### Parallelization strategy

The script uses `Promise.all()` to run all tasks concurrently:

1. **File downloads** (3 files) — Run in parallel via `Promise.all()`
2. **Skill installations** (11 repos) — Run in parallel via `Promise.all()`

This reduces total execution time from ~10 minutes (sequential) to ~1-2 minutes (parallel).

### Cross-platform compatibility

- Uses Node.js built-in modules only (no external dependencies)
- Shell commands use `shell: true` for Windows compatibility
- File paths use `path.join()` for correct separators
- Plain text output (no ANSI color codes for maximum compatibility)

### Error handling

- Each task logs success/failure independently
- Partial failures don't block other tasks
- Script exits with code 1 on any failure
- Failed tasks can be retried by re-running the script

## CI Testing

The script is tested on every push via GitHub Actions:

- **Platforms:** Ubuntu, macOS, Windows
- **Node versions:** 18, 20, 22
- **Tests:**
  - File downloads complete successfully
  - MCP config is valid JSON with correct content
  - All 18 skills are installed
  - Script is idempotent (can run twice)

See [`.github/workflows/test-setup.yml`](.github/workflows/test-setup.yml) for details.

## Migration from bash scripts

If you previously used `setup-bob.sh` or `install-skills.sh`:

1. **Delete old scripts** — They're deprecated in favor of `setup-bob.js`
2. **Use the new script** — It's faster, more reliable, and cross-platform
3. **No manual steps** — Everything is automated, including VS Code reload

The old bash scripts are kept for backward compatibility but are no longer maintained.

## Contributing

To modify the setup script:

1. Edit `setup-bob.js`
2. Test locally on your platform
3. Push to a branch — CI will test on all platforms
4. Open a PR once CI passes

## License

MIT — See [LICENSE](LICENSE)