#!/bin/bash
set -e

echo "🚀 Setting up Solid development environment for IBM Bob..."
echo ""

# Step 1: Download guide files
echo "📚 Downloading guide files..."
curl -fsSLO https://raw.githubusercontent.com/jeswr/solid-ai-coding/main/AGENTS.md &
curl -fsSLO https://raw.githubusercontent.com/jeswr/solid-ai-coding/main/CLAUDE.md &
wait
echo "✅ Guide files downloaded"
echo ""

# Step 2: Configure MCP server
echo "🔧 Configuring MCP server..."
mkdir -p .bob
curl -fsSL https://raw.githubusercontent.com/jeswr/solid-ai-coding/main/config/mcp.json -o .bob/mcp.json
echo "✅ MCP server configured"
echo ""

# Step 3: Install all skills in parallel
echo "📦 Installing skills (this may take a minute)..."
echo ""

# Function to install a skill
install_skill() {
    local repo=$1
    local skill=$2
    local name=$3
    
    if [ -n "$skill" ]; then
        npx skills add "$repo" --skill "$skill" -a bob > /dev/null 2>&1
    else
        npx skills add "$repo" -a bob > /dev/null 2>&1
    fi
    
    echo "  ✓ $name"
}

# Install Solid-specific skills
echo "Installing Solid skills..."
install_skill "jeswr/solid-ai-coding" "" "Solid AI Coding (8 skills)" &

# Install engineering skills in parallel
echo "Installing engineering skills..."
install_skill "antfu/skills" "vitest" "vitest" &
install_skill "currents-dev/playwright-best-practices-skill" "" "Playwright best practices" &
install_skill "anthropics/skills" "webapp-testing" "webapp-testing" &
install_skill "mcollina/skills" "node" "Node.js" &
install_skill "wshobson/agents" "typescript-advanced-types" "TypeScript advanced types" &
install_skill "wshobson/agents" "responsive-design" "Responsive design" &
install_skill "schalkneethling/webdev-agent-skills" "semantic-html" "Semantic HTML" &
install_skill "vercel-labs/agent-skills" "web-design-guidelines" "Web design guidelines" &
install_skill "addyosmani/agent-skills" "code-review-and-quality" "Code review and quality" &
install_skill "vercel-labs/skills" "find-skills" "find-skills" &

# Wait for all background jobs to complete
wait

echo ""
echo "✅ All skills installed successfully!"
echo ""

# Step 4: Reload VS Code window
echo "🔄 Reloading VS Code window..."
if command -v code &> /dev/null; then
    # Get the current workspace folder
    WORKSPACE_DIR=$(pwd)
    
    # Close and reopen the workspace to reload Bob
    osascript -e 'tell application "Visual Studio Code" to activate' 2>/dev/null || true
    osascript -e 'tell application "System Events" to keystroke "w" using {command down, shift down}' 2>/dev/null || true
    sleep 1
    code "$WORKSPACE_DIR" 2>/dev/null || true
    
    echo "✅ VS Code window reloaded"
else
    echo "⚠️  Could not automatically reload VS Code"
    echo "   Please manually reload: Cmd+Shift+P → 'Developer: Reload Window'"
fi

echo ""
echo "🎉 Setup complete! Your Solid development environment is ready."
echo ""
echo "📋 What was installed:"
echo "   • AGENTS.md and CLAUDE.md guide files"
echo "   • MCP server configuration (.bob/mcp.json)"
echo "   • 8 Solid-specific skills"
echo "   • 10 engineering skills (testing, TypeScript, accessibility, code quality)"
echo ""
echo "🚀 You can now start building your Solid application!"

# Made with Bob
