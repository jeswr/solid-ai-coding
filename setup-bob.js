#!/usr/bin/env node
/**
 * Cross-platform setup script for Solid development with IBM Bob
 * Works on Windows, macOS, and Linux
 * Fully parallelized for maximum speed
 */

const { spawn } = require('child_process');
const { mkdir, writeFile } = require('fs/promises');
const { join } = require('path');
const https = require('https');

const REPO_BASE = 'https://raw.githubusercontent.com/jeswr/solid-ai-coding/main';

function log(emoji, message) {
  console.log(`${emoji} ${message}`);
}

function download(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      if (res.statusCode === 302 || res.statusCode === 301) {
        return download(res.headers.location).then(resolve).catch(reject);
      }
      if (res.statusCode !== 200) {
        return reject(new Error(`HTTP ${res.statusCode}: ${url}`));
      }
      let data = '';
      res.on('data', (chunk) => data += chunk);
      res.on('end', () => resolve(data));
    }).on('error', reject);
  });
}

function runCommand(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const proc = spawn(command, args, {
      stdio: 'pipe',
      shell: true,
      ...options,
    });
    
    let stdout = '';
    let stderr = '';
    
    proc.stdout?.on('data', (data) => stdout += data);
    proc.stderr?.on('data', (data) => stderr += data);
    
    proc.on('close', (code) => {
      if (code === 0) {
        resolve({ stdout, stderr });
      } else {
        reject(new Error(`Command failed with code ${code}: ${command} ${args.join(' ')}`));
      }
    });
    
    proc.on('error', reject);
  });
}

async function downloadAndSaveFile(url, path, name) {
  try {
    const content = await download(url);
    await writeFile(path, content);
    log('  ✓', name);
  } catch (error) {
    log('  ✗', `${name} (${error.message})`);
    throw error;
  }
}

async function installSkill(repo, skill, name) {
  const args = ['skills', 'add', repo];
  if (skill) {
    args.push('--skill', skill);
  }
  args.push('-a', 'bob');
  
  try {
    await runCommand('npx', args);
    log('  ✓', name);
  } catch (error) {
    log('  ✗', `${name} (${error.message})`);
    throw error;
  }
}

async function reloadVSCode() {
  // Note: Automatic reload is not reliable across all environments
  // Bob is a VS Code extension, so the user needs to reload the window
  // to pick up the newly installed skills
  
  log('⚠️', 'VS Code reload required to activate skills');
  log('', 'Please reload VS Code:');
  log('', '  1. Press Cmd+Shift+P (Mac) or Ctrl+Shift+P (Windows/Linux)');
  log('', '  2. Type "Developer: Reload Window"');
  log('', '  3. Press Enter');
  
  return false;
}

async function main() {
  console.log('');
  log('🚀', 'Setting up Solid development environment for IBM Bob...');
  log('', 'All tasks running in parallel for maximum speed...');
  console.log('');

  // Ensure .bob directory exists before starting parallel operations
  await mkdir('.bob', { recursive: true });

  // Define all tasks to run in parallel
  const tasks = [
    // Download guide files
    downloadAndSaveFile(`${REPO_BASE}/AGENTS.md`, 'AGENTS.md', 'AGENTS.md'),
    downloadAndSaveFile(`${REPO_BASE}/CLAUDE.md`, 'CLAUDE.md', 'CLAUDE.md'),
    downloadAndSaveFile(`${REPO_BASE}/config/mcp.json`, join('.bob', 'mcp.json'), 'MCP config'),
    
    // Install Solid skills
    installSkill('jeswr/solid-ai-coding', null, 'Solid AI Coding (skill bundle)'),
    
    // Install engineering + design skills (AGENTS.md §Recommended skills is canonical)
    installSkill('obra/superpowers', 'test-driven-development', 'Test-driven development'),
    installSkill('antfu/skills', 'vitest', 'vitest'),
    installSkill('currents-dev/playwright-best-practices-skill', null, 'Playwright best practices'),
    installSkill('anthropics/skills', 'webapp-testing', 'webapp-testing'),
    installSkill('mcollina/skills', 'node', 'Node.js'),
    installSkill('wshobson/agents', 'typescript-advanced-types', 'TypeScript advanced types'),
    installSkill('wshobson/agents', 'responsive-design', 'Responsive design'),
    installSkill('schalkneethling/webdev-agent-skills', 'semantic-html', 'Semantic HTML'),
    installSkill('vercel-labs/agent-skills', 'web-design-guidelines', 'Web design guidelines'),
    installSkill('emilkowalski/skill', 'emil-design-eng', 'UI polish (emil-design-eng)'),
    installSkill('wondelai/skills', 'web-typography', 'Web typography'),
    installSkill('dembrandt/dembrandt-skills', 'color-mode-and-theme', 'Colour mode and theme'),
    installSkill('addyosmani/agent-skills', 'code-review-and-quality', 'Code review and quality'),
    installSkill('vercel-labs/skills', 'find-skills', 'find-skills'),
  ];

  try {
    // Run all tasks in parallel and wait for completion
    await Promise.all(tasks);

    console.log('');
    log('✅', 'All tasks completed successfully!');
    console.log('');

    log('📋', 'What was installed:');
    log('', '   • AGENTS.md and CLAUDE.md guide files');
    log('', '   • MCP server configuration (.bob/mcp.json)');
    log('', '   • the full Solid skill bundle (jeswr/solid-ai-coding)');
    log('', '   • 14 engineering + design skills (TDD, testing, TypeScript, accessibility, UI quality)');
    console.log('');

    log('🎉', 'Setup complete! Your Solid development environment is ready.');
    console.log('');

    // Provide reload instructions
    await reloadVSCode();
    console.log('');

    log('🚀', 'After reloading, you can start building your Solid application!');
    console.log('');

  } catch (error) {
    console.error('');
    log('❌', `Setup failed: ${error.message}`);
    console.error('');
    log('', 'Some tasks may have completed successfully. Check the output above.');
    log('', 'You can re-run the script to retry failed tasks.');
    console.error('');
    log('', 'If the problem persists, please report it at:');
    log('', 'https://github.com/jeswr/solid-ai-coding/issues');
    console.error('');
    process.exit(1);
  }
}

main();

// Made with Bob
