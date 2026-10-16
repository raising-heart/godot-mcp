// End-to-end test: starts the built server, talks MCP to it over stdio, and
// calls every tool against a temporary copy of test/fixture using real Godot.
//
//   npm test                 (needs Godot 4 installed, or GODOT_PATH set)
//   SKIP_SCREENSHOT=1 npm test   on machines without a display

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const repo = join(dirname(fileURLToPath(import.meta.url)), '..');
const project = mkdtempSync(join(tmpdir(), 'godot-mcp-test-'));
cpSync(join(repo, 'test', 'fixture'), project, { recursive: true });
rmSync(join(project, '.godot'), { recursive: true, force: true });

let failures = 0;
const results = [];

function check(name, condition, detail) {
  results.push(`${condition ? 'PASS' : 'FAIL'}  ${name}`);
  if (!condition) {
    failures++;
    console.error(`--- ${name} failed. Output was:\n${detail}\n---`);
  }
}

const textOf = (result) => result.content.filter((c) => c.type === 'text').map((c) => c.text).join('\n');

async function connect(env = {}) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [join(repo, 'build', 'index.js')],
    cwd: project,
    env: { ...process.env, ...env },
    stderr: 'ignore',
  });
  const client = new Client({ name: 'smoke-test', version: '1.0.0' });
  await client.connect(transport);
  return client;
}

const client = await connect();
const call = async (name, args = {}) => {
  const started = Date.now();
  const result = await client.callTool({ name, arguments: args });
  console.log(`  ${name} (${((Date.now() - started) / 1000).toFixed(1)}s)`);
  return result;
};

try {
  const { tools } = await client.listTools();
  const names = tools.map((t) => t.name);
  check('lists all 17 tools', names.length === 17, names.join(', '));
  check('server sends instructions', Boolean(client.getInstructions()?.includes('check_scripts')), client.getInstructions());

  let r = await call('get_godot_version');
  check('get_godot_version', !r.isError && /Using Godot 4\./.test(textOf(r)), textOf(r));

  r = await call('get_project_info');
  let t = textOf(r);
  check('get_project_info finds project from cwd', /Project: MCP Fixture/.test(t), t);
  check('get_project_info lists autoloads and input', /GameState -> res:\/\/scripts\/game_state\.gd/.test(t) && /jump/.test(t), t);
  check('get_project_info lists scripts', /res:\/\/scripts\/player\.gd/.test(t), t);

  r = await call('list_projects', { directory: project, maxDepth: 1 });
  check('list_projects', /MCP Fixture/.test(textOf(r)), textOf(r));

  r = await call('get_scene_tree', { scenePath: 'res://main.tscn', includeProperties: true });
  t = textOf(r);
  check('get_scene_tree shows nested nodes', /Main \(Node2D\)/.test(t) && /└─ Marker \(ColorRect\)/.test(t), t);
  check('get_scene_tree resolves scripts', /Player \(Node2D\) script=res:\/\/scripts\/player\.gd/.test(t), t);
  check('get_scene_tree shows properties and connections', /position = Vector2\(100, 180\)/.test(t) && /Player\.ready -> Main\._on_player_ready/.test(t), t);

  r = await call('get_scene_tree', { scenePath: '../outside.tscn' });
  check('rejects paths outside the project', r.isError && /outside the project/.test(textOf(r)), textOf(r));
  r = await call('get_scene_tree', { scenePath: 'C:/Windows/win.ini' });
  check('rejects absolute paths outside the project', r.isError && /outside the project/.test(textOf(r)), textOf(r));

  r = await call('check_scripts', { paths: ['res://scripts/player.gd', 'res://scripts/game_state.gd'] });
  check('check_scripts: autoload references compile', !r.isError && /All 2 script/.test(textOf(r)), textOf(r));

  r = await call('check_scripts');
  t = textOf(r);
  check('check_scripts finds the broken script with line numbers', r.isError && /res:\/\/broken\/broken\.gd/.test(t) && /line 4: Parse Error/.test(t) && /line 5:.*undefined_thing/.test(t), t);
  check('check_scripts does not flag good scripts', !/player\.gd/.test(t), t);

  // A brand-new script with a new class_name should be picked up (re-import)
  writeFileSync(join(project, 'scripts', 'enemy.gd'), 'class_name Enemy\nextends Node2D\n\nvar hp := 3\n');
  writeFileSync(join(project, 'scripts', 'spawner.gd'), 'extends Node\n\nfunc spawn() -> Enemy:\n\treturn Enemy.new()\n');
  r = await call('check_scripts', { paths: ['res://scripts/spawner.gd'] });
  check('check_scripts sees new class_name scripts', !r.isError, textOf(r));

  r = await call('get_uid', { filePath: 'res://scripts/player.gd' });
  check('get_uid', !r.isError && /uid:\/\//.test(textOf(r)), textOf(r));

  r = await call('create_scene', { scenePath: 'res://scenes/enemy.tscn', rootNodeType: 'CharacterBody2D' });
  check('create_scene', !r.isError && existsSync(join(project, 'scenes', 'enemy.tscn')), textOf(r));

  r = await call('create_scene', { scenePath: 'res://scenes/enemy.tscn' });
  check('create_scene refuses to overwrite', r.isError, textOf(r));

  r = await call('create_scene', { scenePath: 'res://scenes/x.tscn', rootNodeType: 'res://scripts/player.gd' });
  check('create_scene rejects script paths as node types', r.isError, textOf(r));

  r = await call('add_node', {
    scenePath: 'res://scenes/enemy.tscn',
    nodeType: 'Sprite2D',
    nodeName: 'Body',
    properties: { position: { x: 4, y: 8 } },
  });
  check('add_node', !r.isError, textOf(r));
  r = await call('add_node', { scenePath: 'res://scenes/enemy.tscn', nodeType: 'Player', nodeName: 'Brain', parentNodePath: 'root/Body' });
  check('add_node with a project class_name under a child', !r.isError, textOf(r));

  r = await call('get_scene_tree', { scenePath: 'res://scenes/enemy.tscn' });
  t = textOf(r);
  check('added nodes are in the scene', /Body \(Sprite2D\)/.test(t) && /Brain/.test(t), t);

  r = await call('save_scene', { scenePath: 'res://scenes/enemy.tscn', newPath: 'res://scenes/enemy_copy.tscn' });
  check('save_scene to new path', !r.isError && existsSync(join(project, 'scenes', 'enemy_copy.tscn')), textOf(r));

  r = await call('run_project', { waitSeconds: 4 });
  t = textOf(r);
  check('run_project returns first output', /Player ready, score=0/.test(t), t);

  r = await call('get_debug_output', { onlyNew: true });
  check('get_debug_output only returns new lines', /no new output/.test(textOf(r)), textOf(r));

  r = await call('stop_project');
  check('stop_project', !r.isError && /Stopped the game|already exited/.test(textOf(r)), textOf(r));

  writeFileSync(join(project, 'tests_run.gd'), 'extends SceneTree\n\nfunc _process(_d):\n\tprint("TESTS: 3 passed")\n\tquit(0)\n\treturn true\n');
  r = await call('run_project', { script: 'res://tests_run.gd', headless: true, waitSeconds: 20 });
  t = textOf(r);
  check('run_project can run a headless test script', /TESTS: 3 passed/.test(t) && /exited with code 0/.test(t), t);

  if (!process.env.SKIP_SCREENSHOT) {
    r = await call('capture_screenshot', { seconds: 0.5 });
    const image = r.content.find((c) => c.type === 'image');
    check('capture_screenshot returns a PNG', !r.isError && image && image.mimeType === 'image/png' && image.data.length > 1000, textOf(r));
    if (image) writeFileSync(join(repo, 'test', 'last-screenshot.png'), Buffer.from(image.data, 'base64'));
  }

  await client.close();

  // Read-only mode hides the editing tools
  const readOnly = await connect({ GODOT_MCP_READ_ONLY: '1' });
  const readOnlyNames = (await readOnly.listTools()).tools.map((x) => x.name);
  check('read-only mode hides editing tools', !readOnlyNames.includes('add_node') && readOnlyNames.includes('check_scripts'), readOnlyNames.join(', '));
  await readOnly.close();
} catch (error) {
  failures++;
  console.error(error);
} finally {
  await client.close().catch(() => undefined);
  rmSync(project, { recursive: true, force: true });
}

console.log('\n' + results.join('\n'));
console.log(`\n${results.length - failures} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
