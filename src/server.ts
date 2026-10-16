/**
 * The MCP tools. Each tool works out which project it is about (argument,
 * GODOT_PROJECT, or the folder Claude Code runs in), keeps every file path
 * inside that project, and gives the AI short, readable results.
 */

import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, copyFileSync, writeFileSync } from 'fs';
import { basename, dirname, join } from 'path';
import { tmpdir } from 'os';
import { spawn } from 'child_process';
import { fileURLToPath } from 'url';
import { z } from 'zod';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';

import { findGodot, GodotInstall, GodotSearch, isGodot44OrLater, parseGodotVersion, runGodot } from './godot.js';
import { findProjects, listProjectFiles, ProjectError, projectFile, resolveProject } from './project.js';
import { readProjectSummary } from './settings.js';
import { formatSceneTree, parseTscn } from './scene.js';
import { GameRun, isProblemLine, startGame } from './runner.js';

export const VERSION = '0.2.0';

const __dirname = dirname(fileURLToPath(import.meta.url));
const OPERATIONS_SCRIPT = join(__dirname, 'scripts', 'godot_operations.gd');

const INSTRUCTIONS = `Tools for working on Godot 4 projects.

Most tools take an optional projectPath. Leave it out when Claude Code was started inside the Godot project (or GODOT_PROJECT is set); the server finds project.godot by itself. File paths can be res://..., relative to the project, or absolute inside the project.

Suggested workflow:
1. get_project_info to learn the project (main scene, autoloads, input actions, scenes, scripts).
2. get_scene_tree to read a .tscn before changing it.
3. Edit .gd/.tscn files with your normal file tools, then run check_scripts to catch GDScript errors without launching the game.
4. run_project to play it; it waits a few seconds and returns the first output and errors. Use get_debug_output for more, stop_project when done.
5. capture_screenshot to see what a scene actually looks like.`;

type ToolResult = CallToolResult;

function text(message: string): ToolResult {
  return { content: [{ type: 'text', text: message }] };
}

function failure(message: string, hints: string[] = []): ToolResult {
  const body = hints.length ? `${message}\n\nTry:\n- ${hints.join('\n- ')}` : message;
  return { content: [{ type: 'text', text: body }], isError: true };
}

const projectPathArg = z
  .string()
  .optional()
  .describe('Folder containing project.godot. Optional: defaults to the project Claude Code is running in.');

/** Node paths inside a scene, e.g. "root/Player/Sprite2D" */
function checkNodePath(path: string, what: string) {
  if (!path || path.includes('..') || /[\\:]/.test(path)) {
    throw new ProjectError(`Invalid ${what}: "${path}"`, ['Use a node path like "root" or "root/Player/Sprite2D"']);
  }
}

function checkClassName(name: string, what: string) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
    throw new ProjectError(`Invalid ${what}: "${name}"`, [
      `${what} must be a class name such as Node2D, Sprite2D or a class_name from your project (not a file path)`,
    ]);
  }
}

/** Pull the useful lines out of the helper script's chatty output. */
function summarizeOperation(stdout: string, stderr: string): { failed: boolean; details: string } {
  const errLines = stderr.split(/\r?\n/).filter((l) => l.trim() && !/^\s+(GDScript backtrace|\[\d+\])/.test(l));
  const failed = errLines.some((l) => /Failed to|\[ERROR\]/.test(l));
  const outLines = stdout.split(/\r?\n/).filter((l) => /success|saved|created|added|exported|UID|Resaved|Updated/i.test(l) && !/^\[DEBUG\]/.test(l));
  const details = [...(failed ? errLines.slice(-40) : errLines.filter(isProblemLine).slice(-15)), ...outLines.slice(-10)].join('\n');
  return { failed, details };
}

export class GodotTools {
  private search: GodotSearch | null = null;
  private game: GameRun | null = null;

  constructor(private readonly readOnly: boolean) {}

  async godot(): Promise<GodotInstall> {
    if (!this.search?.best) this.search = await findGodot();
    if (this.search.best) return this.search.best;
    throw new ProjectError(this.search.envProblem ?? 'Could not find Godot 4 on this computer.', [
      'Install Godot 4 from https://godotengine.org/download',
      'Or set GODOT_PATH to the Godot executable (or the folder it is in) when adding this MCP server',
      'Run "npx godot-mcp doctor" (or "node build/index.js doctor") in a terminal to see where it looked',
    ]);
  }

  stopGame() {
    this.game?.stop();
  }

  /**
   * New .gd files (and their class_name) and new assets are only picked up
   * after Godot scans the project. The editor does this automatically, but the
   * headless helper does not, so re-import when something changed since last time.
   */
  private async ensureImported(root: string): Promise<string | null> {
    const marker = join(root, '.godot', 'mcp_last_import');
    let markerTime = 0;
    try {
      markerTime = statSync(marker).mtimeMs;
    } catch {
      // never imported by us
    }

    if (markerTime) {
      const watched = ['.gd', '.cs', '.png', '.jpg', '.jpeg', '.webp', '.svg', '.wav', '.ogg', '.mp3', '.glb', '.gltf', '.ttf', '.otf'];
      const stale = listProjectFiles(root, watched).some((res) => {
        try {
          return statSync(join(root, res.slice('res://'.length))).mtimeMs > markerTime;
        } catch {
          return false;
        }
      });
      if (!stale) return null;
    }

    const godot = await this.godot();
    const v = parseGodotVersion(godot.version);
    const supportsImport = v && (v.major > 4 || (v.major === 4 && v.minor >= 3));
    const args = supportsImport ? ['--headless', '--path', root, '--import'] : ['--headless', '--path', root, '--editor', '--quit'];
    const result = await runGodot(godot.path, args, { timeoutMs: 300_000 });
    try {
      mkdirSync(join(root, '.godot'), { recursive: true });
      writeFileSync(marker, new Date().toISOString());
    } catch {
      // read-only project folder; we'll just import again next time
    }
    return result.timedOut ? 'Import timed out after 5 minutes; results may be incomplete.' : null;
  }

  private async operation(root: string, operation: string, params: Record<string, unknown>, timeoutMs = 120_000) {
    const godot = await this.godot();
    await this.ensureImported(root);
    const result = await runGodot(
      godot.path,
      ['--headless', '--path', root, '--script', OPERATIONS_SCRIPT, operation, JSON.stringify(params)],
      { timeoutMs }
    );
    if (result.timedOut) {
      throw new ProjectError(`Godot did not finish "${operation}" within ${timeoutMs / 1000}s and was stopped.`, [
        'Check whether an autoload script in the project waits or loops forever',
      ]);
    }
    return result;
  }

  private async writeOperation(root: string, operation: string, params: Record<string, unknown>, success: string): Promise<ToolResult> {
    const { stdout, stderr, exitCode } = await this.operation(root, operation, params);
    const { failed, details } = summarizeOperation(stdout, stderr);
    if (failed || exitCode !== 0) {
      return failure(`${operation} failed.${details ? `\n\n${details}` : ''}`, [
        'Read the scene with get_scene_tree to check node paths and types',
      ]);
    }
    return text(details ? `${success}\n\n${details}` : success);
  }

  register(server: McpServer) {
    const wrap = <A>(handler: (args: A) => Promise<ToolResult>) => async (args: A): Promise<ToolResult> => {
      try {
        return await handler(args);
      } catch (error) {
        if (error instanceof ProjectError) return failure(error.message, error.hints);
        const message = error instanceof Error ? error.message : String(error);
        return failure(`Unexpected error: ${message}`);
      }
    };

    const readOnlyTool = { readOnlyHint: true, destructiveHint: false, openWorldHint: false };
    const writeTool = { readOnlyHint: false, destructiveHint: false, openWorldHint: false };

    // ---------- Setup & discovery ----------

    server.registerTool(
      'get_godot_version',
      {
        title: 'Godot install info',
        description: 'Show which Godot executable this server uses (path, version, how it was found) and any other Godot installs it found.',
        annotations: readOnlyTool,
      },
      wrap(async () => {
        const godot = await this.godot();
        const others = (this.search?.all ?? []).filter((g) => g.path !== godot.path);
        const lines = [`Using Godot ${godot.version}`, `Path: ${godot.path}`, `Found via: ${godot.source}`];
        if (others.length) {
          lines.push('', 'Other installs found:', ...others.map((g) => `- ${g.version} at ${g.path}`));
          lines.push('(Set GODOT_PATH to pick a different one.)');
        }
        return text(lines.join('\n'));
      })
    );

    server.registerTool(
      'list_projects',
      {
        title: 'Find Godot projects',
        description: 'Find Godot projects (folders with project.godot) under a folder.',
        inputSchema: {
          directory: z.string().optional().describe('Folder to search. Defaults to the folder Claude Code is running in.'),
          maxDepth: z.number().int().min(0).max(8).optional().describe('How many folder levels to search (default 3).'),
        },
        annotations: readOnlyTool,
      },
      wrap(async ({ directory, maxDepth }) => {
        const dir = directory || process.cwd();
        const projects = findProjects(dir, maxDepth ?? 3);
        if (!projects.length) return text(`No Godot projects found under ${dir} (searched ${maxDepth ?? 3} levels deep).`);
        return text(`Found ${projects.length} project(s):\n${projects.map((p) => `- ${p.name}: ${p.path}`).join('\n')}`);
      })
    );

    server.registerTool(
      'get_project_info',
      {
        title: 'Project overview',
        description:
          'Overview of a Godot project: name, main scene, Godot version features, renderer, viewport size, autoloads, input actions, enabled plugins, and the lists of scenes and scripts. A good first call.',
        inputSchema: { projectPath: projectPathArg },
        annotations: readOnlyTool,
      },
      wrap(async ({ projectPath }) => {
        const root = resolveProject(projectPath);
        const info = readProjectSummary(root, basename(root));
        const scenes = listProjectFiles(root, ['.tscn', '.scn']);
        const scripts = listProjectFiles(root, ['.gd', '.cs']);
        const resources = listProjectFiles(root, ['.tres', '.res']);
        const assets = listProjectFiles(root, ['.png', '.jpg', '.jpeg', '.webp', '.svg', '.wav', '.ogg', '.mp3', '.glb', '.gltf', '.fbx', '.obj', '.ttf', '.otf']);

        const list = (items: string[], max = 60) =>
          items.length ? items.slice(0, max).map((i) => `  - ${i}`).join('\n') + (items.length > max ? `\n  … and ${items.length - max} more` : '') : '  (none)';

        const lines = [
          `Project: ${info.name}`,
          `Path: ${root}`,
          info.description ? `Description: ${info.description}` : '',
          `Main scene: ${info.mainScene ?? '(not set)'}`,
          `Features: ${info.godotFeatures.join(', ') || '(none listed)'}`,
          info.renderer ? `Renderer: ${info.renderer}` : '',
          info.viewport ? `Viewport: ${info.viewport.width}x${info.viewport.height}` : '',
          info.dotnet ? 'Uses C#/.NET: yes' : '',
          '',
          `Autoloads (${info.autoloads.length}):`,
          info.autoloads.length ? info.autoloads.map((a) => `  - ${a.name} -> ${a.path}${a.singleton ? '' : ' (not a global)'}`).join('\n') : '  (none)',
          `Input actions (${info.inputActions.length}): ${info.inputActions.join(', ') || '(none; only built-in ui_* actions)'}`,
          info.plugins.length ? `Enabled plugins: ${info.plugins.join(', ')}` : '',
          '',
          `Scenes (${scenes.length}):`,
          list(scenes),
          `Scripts (${scripts.length}):`,
          list(scripts),
          `Resources: ${resources.length}, asset files: ${assets.length}`,
        ];
        return text(lines.filter((l, i, all) => l !== '' || all[i - 1] !== '').join('\n'));
      })
    );

    server.registerTool(
      'get_scene_tree',
      {
        title: 'Read a scene',
        description:
          'Show the node tree of a .tscn scene as the Scene dock would: node names, types, attached scripts, instanced scenes, groups and signal connections. Reads the file only; does not run Godot.',
        inputSchema: {
          projectPath: projectPathArg,
          scenePath: z.string().describe('The scene, e.g. "res://main.tscn" or "scenes/player.tscn".'),
          includeProperties: z.boolean().optional().describe('Also list property values set on each node (default false).'),
        },
        annotations: readOnlyTool,
      },
      wrap(async ({ projectPath, scenePath, includeProperties }) => {
        const root = resolveProject(projectPath);
        const file = projectFile(root, scenePath, 'scenePath');
        if (!existsSync(file.abs)) {
          throw new ProjectError(`Scene not found: ${file.res}`, ['Use get_project_info to list the scenes in the project']);
        }
        if (!file.abs.toLowerCase().endsWith('.tscn')) {
          throw new ProjectError(`Only text scenes (.tscn) can be read: ${file.res}`, ['Binary .scn scenes can be converted by re-saving them as .tscn in the editor']);
        }
        const scene = parseTscn(readFileSync(file.abs, 'utf8'));
        const parts = [`${file.res} (${scene.nodeCount} nodes)`, '', formatSceneTree(scene, Boolean(includeProperties))];
        if (scene.connections.length) {
          const nodeLabel = (path: string) => (path === '.' ? scene.root?.name ?? '.' : path);
          parts.push('', 'Signal connections:', ...scene.connections.map((c) => `- ${nodeLabel(c.from)}.${c.signal} -> ${nodeLabel(c.to)}.${c.method}()`));
        }
        const external = scene.extResources.filter((r) => r.type !== 'Script' && r.type !== 'PackedScene');
        if (external.length) {
          parts.push('', 'Other resources used:', ...external.map((r) => `- ${r.type}: ${r.path}`));
        }
        return text(parts.join('\n'));
      })
    );

    server.registerTool(
      'check_scripts',
      {
        title: 'Check GDScript for errors',
        description:
          'Compile GDScript files with the real Godot engine and report parse/compile errors with file and line, without launching the game. Run this after editing .gd files. Checks every script in the project unless paths are given.',
        inputSchema: {
          projectPath: projectPathArg,
          paths: z.array(z.string()).optional().describe('Specific .gd files to check (default: all scripts in the project).'),
        },
        annotations: readOnlyTool,
      },
      wrap(async ({ projectPath, paths }) => {
        const root = resolveProject(projectPath);
        const resPaths = (paths ?? []).map((p) => projectFile(root, p, 'path').res);
        const { stdout, stderr } = await this.operation(root, 'check_scripts', { paths: resPaths }, 180_000);

        const resultLine = stdout.split(/\r?\n/).find((l) => l.startsWith('MCP_RESULT:'));
        if (!resultLine) {
          return failure('Godot did not report results for check_scripts.', [`Godot output:\n${(stderr || stdout).slice(-2000)}`]);
        }
        const results: Array<{ path: string; loaded: boolean }> = JSON.parse(resultLine.slice('MCP_RESULT:'.length)).scripts;

        // Engine errors look like:
        //   SCRIPT ERROR: Parse Error: Identifier "x" not declared in the current scope.
        //      at: GDScript::reload (res://player.gd:12)
        const errors = new Map<string, Array<{ line: number; message: string }>>();
        const lines = stderr.split(/\r?\n/);
        for (let i = 0; i < lines.length; i++) {
          const head = lines[i].match(/^(?:SCRIPT ERROR|ERROR):\s*(.*)$/);
          if (!head || /^Failed to load script/.test(head[1])) continue;
          const at = lines[i + 1]?.match(/\((res:\/\/[^)]+?):(\d+)\)/);
          if (!at) continue;
          const list = errors.get(at[1]) ?? [];
          if (!list.some((e) => e.line === Number(at[2]) && e.message === head[1])) {
            list.push({ line: Number(at[2]), message: head[1] });
          }
          errors.set(at[1], list);
        }
        for (const r of results) {
          if (!r.loaded && !errors.has(r.path)) errors.set(r.path, [{ line: 0, message: 'Could not be loaded (file missing or not a script)' }]);
        }

        const failed = results.filter((r) => errors.has(r.path));
        if (!failed.length) return text(`All ${results.length} script(s) compiled without errors.`);

        const report = failed.map((r) => {
          const list = errors.get(r.path)!.sort((a, b) => a.line - b.line);
          return `${r.path}\n${list.map((e) => `  line ${e.line}: ${e.message}`).join('\n')}`;
        });
        return {
          content: [{ type: 'text', text: `${failed.length} of ${results.length} script(s) have errors:\n\n${report.join('\n\n')}` }],
          isError: true,
        };
      })
    );

    server.registerTool(
      'get_uid',
      {
        title: 'Get resource UID',
        description: 'Get the uid:// of a file in the project (Godot 4.4+).',
        inputSchema: {
          projectPath: projectPathArg,
          filePath: z.string().describe('The file, e.g. "res://player.gd".'),
        },
        annotations: readOnlyTool,
      },
      wrap(async ({ projectPath, filePath }) => {
        const root = resolveProject(projectPath);
        const file = projectFile(root, filePath, 'filePath');
        if (!existsSync(file.abs)) throw new ProjectError(`File not found: ${file.res}`);

        // Godot stores UIDs in plain text; read them directly when we can
        const sources = [
          { path: `${file.abs}.uid`, pattern: /^(uid:\/\/\w+)/m },
          { path: `${file.abs}.import`, pattern: /^uid="(uid:\/\/\w+)"/m },
          { path: file.abs, pattern: /^\[gd_(?:scene|resource)[^\]]*uid="(uid:\/\/\w+)"/m },
        ];
        for (const { path, pattern } of sources) {
          if (!existsSync(path) || (path === file.abs && !/\.(tscn|tres)$/i.test(path))) continue;
          const match = readFileSync(path, 'utf8').match(pattern);
          if (match) return text(`UID for ${file.res}: ${match[1]}`);
        }

        const godot = await this.godot();
        if (!isGodot44OrLater(godot.version)) {
          throw new ProjectError(`UIDs need Godot 4.4 or later (you have ${godot.version}).`);
        }
        const { stdout } = await this.operation(root, 'get_uid', { file_path: file.res });
        const uid = stdout.match(/uid:\/\/\w+/)?.[0];
        return uid ? text(`UID for ${file.res}: ${uid}`) : failure(`No UID found for ${file.res}. It may not have been imported yet.`);
      })
    );

    // ---------- Running ----------

    server.registerTool(
      'launch_editor',
      {
        title: 'Open the Godot editor',
        description: 'Open the Godot editor for the project (in its own window, for the user).',
        inputSchema: {
          projectPath: projectPathArg,
          scenePath: z.string().optional().describe('Optional scene to open in the editor.'),
        },
        annotations: { ...readOnlyTool, idempotentHint: false },
      },
      wrap(async ({ projectPath, scenePath }) => {
        const root = resolveProject(projectPath);
        const godot = await this.godot();
        const args = ['-e', '--path', root];
        if (scenePath) args.push(projectFile(root, scenePath, 'scenePath').res);
        // Detached so the editor stays open after Claude Code exits
        const child = spawn(godot.path, args, { detached: true, stdio: 'ignore' });
        child.on('error', () => undefined);
        child.unref();
        return text(`Opened the Godot ${godot.version} editor for ${root}.`);
      })
    );

    server.registerTool(
      'run_project',
      {
        title: 'Run the game',
        description:
          'Run the project (or one scene) in a window, wait a few seconds, and return the output and any errors. The game keeps running: use get_debug_output to read more output and stop_project to close it. Can also run a SceneTree script from the project (e.g. a headless test script).',
        inputSchema: {
          projectPath: projectPathArg,
          scene: z.string().optional().describe('Scene to run instead of the main scene, e.g. "res://levels/level_1.tscn".'),
          script: z.string().optional().describe('Run this project script (extends SceneTree or MainLoop) instead of a scene, e.g. "res://tests/run_tests.gd".'),
          headless: z.boolean().optional().describe('Run without a window (default false). Useful for tests and logic-only checks.'),
          waitSeconds: z.number().min(0).max(120).optional().describe('Seconds to wait before returning the first output (default 3).'),
          userArgs: z.array(z.string()).optional().describe('Extra arguments for the game, readable with OS.get_cmdline_user_args().'),
        },
        annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
      },
      wrap(async ({ projectPath, scene, script, headless, waitSeconds, userArgs }) => {
        const root = resolveProject(projectPath);
        if (scene && script) throw new ProjectError('Pass either scene or script, not both.');
        const godot = await this.godot();
        const importNote = await this.ensureImported(root);

        if (this.game && !this.game.exited) this.game.stop();

        const args: string[] = [];
        if (headless) args.push('--headless');
        args.push('--path', root);
        let what = 'main scene';
        if (scene) {
          const file = projectFile(root, scene, 'scene');
          if (!existsSync(file.abs)) throw new ProjectError(`Scene not found: ${file.res}`);
          args.push(file.res);
          what = file.res;
        } else if (script) {
          const file = projectFile(root, script, 'script');
          if (!existsSync(file.abs)) throw new ProjectError(`Script not found: ${file.res}`);
          args.push('--script', file.res);
          what = `script ${file.res}`;
        }
        if (userArgs?.length) args.push('--', ...userArgs);

        this.game = startGame(godot.path, args, root, `${what}${headless ? ', headless' : ''}`);
        const waitMs = (waitSeconds ?? 3) * 1000;
        await this.game.waitForExit(waitMs);
        if (waitMs > 0 && !headless && !script) await this.game.waitForRendererStart(8000);
        const output = this.game.read({ onlyNew: true, errorsOnly: false, tail: 200 });
        return text(importNote ? `${importNote}\n\n${output}` : output);
      })
    );

    server.registerTool(
      'get_debug_output',
      {
        title: 'Read game output',
        description: 'Read output and errors from the game started with run_project. By default returns only lines you have not seen yet.',
        inputSchema: {
          onlyNew: z.boolean().optional().describe('Only lines not returned before (default true). Set false for the full log.'),
          errorsOnly: z.boolean().optional().describe('Only errors and warnings (default false).'),
          tail: z.number().int().min(1).max(5000).optional().describe('Return at most this many of the latest lines (default 200).'),
          waitSeconds: z.number().min(0).max(120).optional().describe('Wait this long first (or until the game exits), e.g. to let something happen.'),
        },
        annotations: readOnlyTool,
      },
      wrap(async ({ onlyNew, errorsOnly, tail, waitSeconds }) => {
        if (!this.game) return failure('No game has been started yet.', ['Use run_project first']);
        if (waitSeconds) await this.game.waitForExit(waitSeconds * 1000);
        return text(this.game.read({ onlyNew: onlyNew ?? true, errorsOnly: errorsOnly ?? false, tail: tail ?? 200 }));
      })
    );

    server.registerTool(
      'stop_project',
      {
        title: 'Stop the game',
        description: 'Stop the game started with run_project and return its last output.',
        annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
      },
      wrap(async () => {
        if (!this.game) return failure('No game has been started.', ['Use run_project first']);
        const wasRunning = !this.game.exited;
        this.game.stop();
        await this.game.waitForExit(3000);
        const output = this.game.read({ onlyNew: true, errorsOnly: false, tail: 100 });
        return text(`${wasRunning ? 'Stopped the game.' : 'The game had already exited.'}\n\n${output}`);
      })
    );

    server.registerTool(
      'capture_screenshot',
      {
        title: 'Screenshot a scene',
        description:
          'Run the game (or one scene) for a moment and return a screenshot of what it renders, so you can see the result of your changes. Uses Godot\'s Movie Maker mode, so a game window appears briefly. The image is also saved to a temp folder.',
        inputSchema: {
          projectPath: projectPathArg,
          scene: z.string().optional().describe('Scene to capture (default: the main scene).'),
          seconds: z.number().min(0.1).max(20).optional().describe('Game time to run before capturing (default 1).'),
          resolution: z.string().regex(/^\d{2,5}x\d{2,5}$/).optional().describe('Window size like "1280x720" (default: the project setting).'),
        },
        annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
      },
      wrap(async ({ projectPath, scene, seconds, resolution }) => {
        const root = resolveProject(projectPath);
        const godot = await this.godot();
        await this.ensureImported(root);

        const fps = 20;
        const frames = Math.max(1, Math.round((seconds ?? 1) * fps));
        const work = mkdtempSync(join(tmpdir(), 'godot-mcp-shot-'));
        try {
          const args = ['--path', root, '--write-movie', join(work, 'frame.png'), '--fixed-fps', String(fps), '--quit-after', String(frames)];
          if (resolution) args.push('--resolution', resolution);
          let what = 'main scene';
          if (scene) {
            const file = projectFile(root, scene, 'scene');
            if (!existsSync(file.abs)) throw new ProjectError(`Scene not found: ${file.res}`);
            args.push(file.res);
            what = file.res;
          }
          const result = await runGodot(godot.path, args, { timeoutMs: 90_000 });
          const pngs = readdirSync(work).filter((f) => f.endsWith('.png')).sort();
          if (!pngs.length) {
            const problems = (result.stderr + '\n' + result.stdout).split(/\r?\n/).filter(isProblemLine).slice(-20);
            return failure(`No frame was captured from ${what}.${problems.length ? `\n\n${problems.join('\n')}` : ''}`, [
              'Run the scene with run_project to see its errors',
            ]);
          }

          const keepDir = join(tmpdir(), 'godot-mcp', 'screenshots');
          mkdirSync(keepDir, { recursive: true });
          const stamp = new Date().toISOString().replace(/[:.]/g, '-');
          const saved = join(keepDir, `${basename(root)}-${stamp}.png`);
          copyFileSync(join(work, pngs[pngs.length - 1]), saved);

          const problems = result.stderr.split(/\r?\n/).filter(isProblemLine).slice(-10);
          const note = [`Screenshot of ${what} after ${frames / fps}s of game time. Saved to ${saved}`];
          if (problems.length) note.push('', 'Errors/warnings while running:', ...problems);
          return {
            content: [
              { type: 'image', data: readFileSync(saved).toString('base64'), mimeType: 'image/png' },
              { type: 'text', text: note.join('\n') },
            ],
          };
        } finally {
          rmSync(work, { recursive: true, force: true });
        }
      })
    );

    if (this.readOnly) return;

    // ---------- Editing (hidden when GODOT_MCP_READ_ONLY=1) ----------

    server.registerTool(
      'create_scene',
      {
        title: 'Create a scene',
        description: 'Create a new .tscn scene file with a root node of the given type.',
        inputSchema: {
          projectPath: projectPathArg,
          scenePath: z.string().describe('Where to save it, e.g. "res://scenes/enemy.tscn".'),
          rootNodeType: z.string().optional().describe('Root node class (default Node2D), e.g. Node3D, Control, CharacterBody2D.'),
        },
        annotations: writeTool,
      },
      wrap(async ({ projectPath, scenePath, rootNodeType }) => {
        const root = resolveProject(projectPath);
        const file = projectFile(root, scenePath, 'scenePath');
        const type = rootNodeType || 'Node2D';
        checkClassName(type, 'rootNodeType');
        if (existsSync(file.abs)) {
          throw new ProjectError(`${file.res} already exists.`, ['Pick a new path, or edit the existing scene with add_node']);
        }
        return this.writeOperation(root, 'create_scene', { scene_path: file.res, root_node_type: type }, `Created ${file.res} with a ${type} root node.`);
      })
    );

    server.registerTool(
      'add_node',
      {
        title: 'Add a node to a scene',
        description: 'Add a node to an existing scene and save it. Properties are set by name, e.g. {"position": {"x": 10, "y": 20}}; strings starting with res:// are loaded as resources.',
        inputSchema: {
          projectPath: projectPathArg,
          scenePath: z.string().describe('The scene to change, e.g. "res://main.tscn".'),
          nodeType: z.string().describe('Node class, e.g. Sprite2D, CollisionShape2D, Label, or a class_name from the project.'),
          nodeName: z.string().describe('Name of the new node.'),
          parentNodePath: z.string().optional().describe('Parent node: "root" (default) or a path like "root/Player".'),
          properties: z.record(z.string(), z.unknown()).optional().describe('Property values to set on the new node.'),
        },
        annotations: writeTool,
      },
      wrap(async ({ projectPath, scenePath, nodeType, nodeName, parentNodePath, properties }) => {
        const root = resolveProject(projectPath);
        const file = projectFile(root, scenePath, 'scenePath');
        if (!existsSync(file.abs)) throw new ProjectError(`Scene not found: ${file.res}`, ['Create it first with create_scene']);
        checkClassName(nodeType, 'nodeType');
        if (!/^[^/\\:"%@.]+$/.test(nodeName)) throw new ProjectError(`Invalid node name: "${nodeName}"`, ['Node names cannot contain . : / \\ " % or @']);
        const parent = parentNodePath || 'root';
        checkNodePath(parent, 'parentNodePath');
        const params: Record<string, unknown> = { scene_path: file.res, node_type: nodeType, node_name: nodeName, parent_node_path: parent };
        if (properties) params.properties = properties;
        return this.writeOperation(root, 'add_node', params, `Added ${nodeName} (${nodeType}) under ${parent} in ${file.res}.`);
      })
    );

    server.registerTool(
      'load_sprite',
      {
        title: 'Set a sprite texture',
        description: 'Set the texture of a Sprite2D, Sprite3D or TextureRect node in a scene and save it.',
        inputSchema: {
          projectPath: projectPathArg,
          scenePath: z.string().describe('The scene, e.g. "res://player.tscn".'),
          nodePath: z.string().describe('The node, e.g. "root/Sprite2D".'),
          texturePath: z.string().describe('The image, e.g. "res://art/player.png".'),
        },
        annotations: writeTool,
      },
      wrap(async ({ projectPath, scenePath, nodePath, texturePath }) => {
        const root = resolveProject(projectPath);
        const scene = projectFile(root, scenePath, 'scenePath');
        const texture = projectFile(root, texturePath, 'texturePath');
        if (!existsSync(scene.abs)) throw new ProjectError(`Scene not found: ${scene.res}`);
        if (!existsSync(texture.abs)) throw new ProjectError(`Texture not found: ${texture.res}`);
        checkNodePath(nodePath, 'nodePath');
        return this.writeOperation(
          root,
          'load_sprite',
          { scene_path: scene.res, node_path: nodePath, texture_path: texture.res },
          `Set the texture of ${nodePath} in ${scene.res} to ${texture.res}.`
        );
      })
    );

    server.registerTool(
      'save_scene',
      {
        title: 'Re-save a scene',
        description: 'Load and re-save a scene through Godot (normalizes the file), optionally to a new path to make a copy/variant.',
        inputSchema: {
          projectPath: projectPathArg,
          scenePath: z.string().describe('The scene, e.g. "res://main.tscn".'),
          newPath: z.string().optional().describe('Save a copy here instead of overwriting.'),
        },
        annotations: writeTool,
      },
      wrap(async ({ projectPath, scenePath, newPath }) => {
        const root = resolveProject(projectPath);
        const scene = projectFile(root, scenePath, 'scenePath');
        if (!existsSync(scene.abs)) throw new ProjectError(`Scene not found: ${scene.res}`);
        const params: Record<string, unknown> = { scene_path: scene.res };
        let target = scene.res;
        if (newPath) {
          target = projectFile(root, newPath, 'newPath').res;
          params.new_path = target;
        }
        return this.writeOperation(root, 'save_scene', params, `Saved ${target}.`);
      })
    );

    server.registerTool(
      'export_mesh_library',
      {
        title: 'Export a MeshLibrary',
        description: 'Export the meshes in a 3D scene as a MeshLibrary resource for GridMap.',
        inputSchema: {
          projectPath: projectPathArg,
          scenePath: z.string().describe('The 3D scene (.tscn) containing MeshInstance3D nodes.'),
          outputPath: z.string().describe('Where to save the library, e.g. "res://tiles.res".'),
          meshItemNames: z.array(z.string()).optional().describe('Only include these mesh names (default: all).'),
        },
        annotations: writeTool,
      },
      wrap(async ({ projectPath, scenePath, outputPath, meshItemNames }) => {
        const root = resolveProject(projectPath);
        const scene = projectFile(root, scenePath, 'scenePath');
        const output = projectFile(root, outputPath, 'outputPath');
        if (!existsSync(scene.abs)) throw new ProjectError(`Scene not found: ${scene.res}`);
        const params: Record<string, unknown> = { scene_path: scene.res, output_path: output.res };
        if (meshItemNames?.length) params.mesh_item_names = meshItemNames;
        return this.writeOperation(root, 'export_mesh_library', params, `Exported a MeshLibrary to ${output.res}.`);
      })
    );

    server.registerTool(
      'update_project_uids',
      {
        title: 'Refresh UIDs',
        description: 'Re-save every scene/resource so all references use up-to-date UIDs (Godot 4.4+). Useful after upgrading a project from an older Godot.',
        inputSchema: { projectPath: projectPathArg },
        annotations: { ...writeTool, idempotentHint: true },
      },
      wrap(async ({ projectPath }) => {
        const root = resolveProject(projectPath);
        const godot = await this.godot();
        if (!isGodot44OrLater(godot.version)) throw new ProjectError(`UIDs need Godot 4.4 or later (you have ${godot.version}).`);
        return this.writeOperation(root, 'resave_resources', { project_path: root }, 'Re-saved project resources with current UIDs.');
      })
    );
  }
}

export function createServer(readOnly: boolean): { server: McpServer; tools: GodotTools } {
  const server = new McpServer({ name: 'godot', version: VERSION }, { instructions: INSTRUCTIONS });
  const tools = new GodotTools(readOnly);
  tools.register(server);
  return { server, tools };
}
