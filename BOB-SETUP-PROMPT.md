# Bob Setup Prompt for Solid Development

Copy and paste this into your Bob chat to set up your environment for Solid development:

---

I plan to develop a Solid application. Please help me set up my environment as prescribed in https://github.com/jeswr/solid-ai-coding/

---

That's it! Bob will:
1. Download AGENTS.md and CLAUDE.md to your project root
2. Configure the context7 MCP server in `.bob/mcp.json`
3. Install all 8 Solid-specific skills
4. Install the recommended engineering skills (vitest, Playwright, TypeScript, accessibility, code quality, etc.)
5. Verify the setup is working

**If you scaffold a Next.js app afterwards**: `create-next-app` overwrites `AGENTS.md` — ask
Bob to re-run the setup script (it merges; nothing is lost), or scaffold before setup.

After Bob completes the setup, reload the window (Cmd+Shift+P → "Developer: Reload Window") to activate everything.
