#!/bin/bash
# One-line setup for IBM Bob with Solid development

set -e

echo "📥 Downloading Solid development guide..."
curl -fsSLO https://raw.githubusercontent.com/jeswr/solid-ai-coding/main/AGENTS.md
curl -fsSLO https://raw.githubusercontent.com/jeswr/solid-ai-coding/main/CLAUDE.md

echo "⚙️  Configuring MCP server..."
mkdir -p .bob
curl -fsSL https://raw.githubusercontent.com/jeswr/solid-ai-coding/main/config/mcp.json -o .bob/mcp.json

echo "📦 Installing all recommended skills..."
curl -fsSL https://raw.githubusercontent.com/jeswr/solid-ai-coding/main/install-skills.sh | bash

echo ""
echo "✅ Setup complete!"
echo "📝 Reload Bob to activate: Cmd+Shift+P → 'Developer: Reload Window'"
