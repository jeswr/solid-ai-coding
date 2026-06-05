#!/bin/bash
# Install all recommended skills for Solid development with Bob

set -e

echo "⚠️  DEPRECATED: This script is deprecated in favor of setup-bob.js"
echo "   The new Node.js script is faster, cross-platform, and fully parallelized."
echo ""
echo "   Please use instead:"
echo "   curl -fsSL https://raw.githubusercontent.com/jeswr/solid-ai-coding/main/setup-bob.js | node"
echo ""
echo "   Continuing with legacy script in 5 seconds..."
echo "   Press Ctrl+C to cancel and use the new script."
echo ""
sleep 5

echo "🔧 Installing Solid-specific skills..."
npx skills add jeswr/solid-ai-coding -a bob

echo "🧪 Installing testing and quality skills..."
npx skills add obra/superpowers --skill test-driven-development -a bob
npx skills add antfu/skills --skill vitest -a bob
npx skills add currents-dev/playwright-best-practices-skill -a bob
npx skills add anthropics/skills --skill webapp-testing -a bob

echo "📦 Installing Node.js and TypeScript skills..."
npx skills add mcollina/skills --skill node -a bob
npx skills add wshobson/agents --skill typescript-advanced-types --skill responsive-design -a bob

echo "🌐 Installing web development skills..."
npx skills add schalkneethling/webdev-agent-skills --skill semantic-html -a bob
npx skills add vercel-labs/agent-skills --skill web-design-guidelines -a bob
npx skills add emilkowalski/skill --skill emil-design-eng -a bob
npx skills add wondelai/skills --skill web-typography -a bob
npx skills add dembrandt/dembrandt-skills --skill color-mode-and-theme -a bob

echo "✨ Installing code quality skills..."
npx skills add addyosmani/agent-skills --skill code-review-and-quality -a bob

echo "🔍 Installing skill discovery..."
npx skills add vercel-labs/skills --skill find-skills -a bob

echo "✅ All skills installed successfully!"
echo "📝 Reload Bob to activate: Cmd+Shift+P → 'Developer: Reload Window'"
