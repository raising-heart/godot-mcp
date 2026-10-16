#!/usr/bin/env node
/**
 * Godot MCP Server
 *
 *   godot-mcp            start the MCP server on stdio (what Claude Code runs)
 *   godot-mcp doctor     check the setup and print the command to add it to Claude Code
 */

import { existsSync } from 'fs';
import { dirname, join, resolve } from 'path';
import { fileURLToPath } from 'url';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';

import { findGodot } from './godot.js';
import { findProjectRoot } from './project.js';
import { readProjectSummary } from './settings.js';
import { createServer, VERSION } from './server.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

function isTruthy(value: string | undefined): boolean {
  return Boolean(value && /^(1|true|yes|on)$/i.test(value.trim()));
}

async function doctor(projectDir?: string) {
  const out = (line = '') => console.log(line);
  out(`Godot MCP ${VERSION} doctor`);
  out();

  const nodeMajor = parseInt(process.versions.node.split('.')[0], 10);
  out(`${nodeMajor >= 18 ? 'OK  ' : 'FAIL'} Node.js ${process.version}${nodeMajor >= 18 ? '' : ' (need 18 or newer)'}`);

  const helper = join(__dirname, 'scripts', 'godot_operations.gd');
  out(`${existsSync(helper) ? 'OK  ' : 'FAIL'} Helper script ${existsSync(helper) ? 'found' : `missing at ${helper} (run "npm run build")`}`);

  const search = await findGodot();
  if (search.envProblem) out(`WARN ${search.envProblem}`);
  if (search.best) {
    out(`OK   Godot ${search.best.version} (found via ${search.best.source})`);
    out(`     ${search.best.path}`);
    for (const other of search.all.slice(1)) out(`     also found: ${other.version} at ${other.path}`);
  } else {
    out('FAIL Godot 4 not found. Install it from https://godotengine.org/download');
    out('     or set GODOT_PATH to the Godot executable (or the folder containing it).');
  }

  const root = findProjectRoot(projectDir ? resolve(projectDir) : process.cwd());
  if (root) {
    const info = readProjectSummary(root, root);
    out(`OK   Godot project "${info.name}" at ${root}`);
  } else {
    out('--   Not inside a Godot project right now (that is fine; the server uses');
    out('     the folder Claude Code is started in, or a projectPath argument).');
  }

  const entry = join(__dirname, 'index.js');
  const env = search.best ? ` -e GODOT_PATH="${search.best.path}"` : '';
  out();
  out('Add it to Claude Code for all your projects:');
  out();
  out(`  claude mcp add godot --scope user${env} -- node "${entry}"`);
  out();
  out('Or only for one project (run inside that project folder; saved to .mcp.json):');
  out();
  out(`  claude mcp add godot --scope project${env} -- node "${entry}"`);
  out();
  out('Optional: add -e GODOT_MCP_READ_ONLY=1 to hide the tools that change scenes.');
  out('Then start Claude Code in your Godot project and run /mcp to check it is connected.');

  process.exitCode = search.best && existsSync(helper) ? 0 : 1;
}

function help() {
  console.log(`Godot MCP ${VERSION}

Usage:
  godot-mcp              Start the MCP server on stdio (Claude Code does this for you)
  godot-mcp doctor [dir] Check Node, Godot and the project, and print the setup command
  godot-mcp --version    Print the version

Environment:
  GODOT_PATH             Godot executable, or the folder it is in (default: auto-detect)
  GODOT_PROJECT          Default project folder (default: the folder Claude Code runs in)
  GODOT_MCP_READ_ONLY=1  Hide the tools that modify scenes/resources`);
}

async function serve() {
  const { server, tools } = createServer(isTruthy(process.env.GODOT_MCP_READ_ONLY));

  const shutdown = async () => {
    tools.stopGame();
    await server.close().catch(() => undefined);
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
  process.stdin.on('close', shutdown);

  await server.connect(new StdioServerTransport());
  // stdout is the MCP channel; logs go to stderr
  console.error(`Godot MCP ${VERSION} running on stdio`);

  // Look for Godot in the background so the first tool call is fast
  tools.godot().then(
    (godot) => console.error(`Using Godot ${godot.version} at ${godot.path}`),
    (error) => console.error(`Godot not found yet: ${error.message}`)
  );
}

const [command, arg] = process.argv.slice(2);
if (command === 'doctor') {
  doctor(arg).catch((error) => {
    console.error(error);
    process.exit(1);
  });
} else if (command === '--version' || command === '-v') {
  console.log(VERSION);
} else if (command === '--help' || command === '-h' || command === 'help') {
  help();
} else {
  serve().catch((error) => {
    console.error('Failed to start the Godot MCP server:', error);
    process.exit(1);
  });
}
