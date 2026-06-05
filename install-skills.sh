#!/bin/bash
# Install all recommended skills for Solid development with Bob

set -e

echo "🔧 Installing Solid-specific skills..."
npx skills add jeswr/solid-ai-coding -a bob

echo "🧪 Installing testing and quality skills..."
npx skills add antfu/skills --skill vitest -a bob
npx skills add currents-dev/playwright-best-practices-skill -a bob
npx skills add anthropics/skills --skill webapp-testing -a bob

echo "📦 Installing Node.js and TypeScript skills..."
npx skills add mcollina/skills --skill node -a bob
npx skills add wshobson/agents --skill typescript-advanced-types --skill responsive-design -a bob

echo "🌐 Installing web development skills..."
npx skills add schalkneethling/webdev-agent-skills --skill semantic-html -a bob
npx skills add vercel-labs/agent-skills --skill web-design-guidelines -a bob

echo "✨ Installing code quality skills..."
npx skills add addyosmani/agent-skills --skill code-review-and-quality -a bob

echo "🔍 Installing skill discovery..."
npx skills add vercel-labs/skills --skill find-skills -a bob

echo "✅ All skills installed successfully!"
echo "📝 Reload Bob to activate: Cmd+Shift+P → 'Developer: Reload Window'"
