/**
 * Locating Godot projects and keeping file paths inside them.
 */

import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'fs';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'path';

export class ProjectError extends Error {
  constructor(message: string, public hints: string[] = []) {
    super(message);
  }
}

/** Walk up from `start` looking for a folder that contains project.godot. */
export function findProjectRoot(start: string): string | null {
  let current = resolve(start);
  for (;;) {
    if (existsSync(join(current, 'project.godot'))) return current;
    const parent = dirname(current);
    if (parent === current) return null;
    current = parent;
  }
}

/**
 * Work out which project a tool call is about. In order:
 * the projectPath argument, the GODOT_PROJECT env var, then the folder
 * Claude Code was started in (or any parent of it).
 */
export function resolveProject(projectPath?: string): string {
  if (projectPath) {
    let candidate = resolve(projectPath.trim().replace(/^"|"$/g, ''));
    if (basename(candidate) === 'project.godot') candidate = dirname(candidate);
    if (existsSync(join(candidate, 'project.godot'))) return candidate;
    throw new ProjectError(`Not a Godot project (no project.godot found): ${candidate}`, [
      'Point projectPath at the folder that contains project.godot',
      'Use list_projects to find Godot projects in a folder',
    ]);
  }

  if (process.env.GODOT_PROJECT) {
    const root = findProjectRoot(process.env.GODOT_PROJECT);
    if (root) return root;
  }

  const fromCwd = findProjectRoot(process.cwd());
  if (fromCwd) return fromCwd;

  throw new ProjectError('No Godot project specified, and the current folder is not inside one.', [
    'Pass projectPath (the folder containing project.godot)',
    'Or start Claude Code from inside your Godot project folder',
    'Or set the GODOT_PROJECT environment variable when adding the MCP server',
  ]);
}

export interface ProjectFile {
  /** Absolute path on disk */
  abs: string;
  /** The same file as a res:// path */
  res: string;
}

function realpathOrSelf(path: string): string {
  try {
    return realpathSync.native(path);
  } catch {
    return path;
  }
}

/**
 * Resolve a file path given by the AI against the project and refuse anything
 * that ends up outside it. Accepts "res://a/b.tscn", "a/b.tscn", or an absolute
 * path inside the project.
 */
export function projectFile(root: string, input: string, what = 'path'): ProjectFile {
  if (typeof input !== 'string' || !input.trim()) {
    throw new ProjectError(`${what} is required`);
  }

  let path = input.trim().replace(/\\/g, '/');
  if (path.startsWith('res://')) path = path.slice('res://'.length);

  if (path.startsWith('user://') || /^[a-z][a-z0-9+.-]*:\/\//i.test(path)) {
    throw new ProjectError(`${what} must be inside the project (res://...), got: ${input}`);
  }

  const abs = isAbsolute(path) || /^[a-zA-Z]:\//.test(path) ? resolve(path) : resolve(root, path);
  const rel = relative(root, abs);
  if (rel.startsWith('..') || isAbsolute(rel)) {
    throw new ProjectError(`${what} is outside the project folder: ${input}`, [
      `Use a path inside ${root}, e.g. res://scenes/main.tscn`,
    ]);
  }

  // Follow symlinks/junctions for anything that already exists, so a link
  // inside the project can't be used to reach files outside it
  let existing = abs;
  while (!existsSync(existing) && dirname(existing) !== existing) existing = dirname(existing);
  const realRel = relative(realpathOrSelf(root), realpathOrSelf(existing));
  if (realRel.startsWith('..') || isAbsolute(realRel)) {
    throw new ProjectError(`${what} resolves (through a link) to outside the project: ${input}`);
  }

  return { abs, res: 'res://' + rel.split(sep).join('/') };
}

const SKIP_DIRS = new Set(['.godot', '.git', '.import', 'node_modules', '.vs', '.vscode', '.idea', 'bin', 'obj']);

/** List project files with the given extensions, as res:// paths. */
export function listProjectFiles(root: string, extensions: string[], limit = 5000): string[] {
  const results: string[] = [];
  const walk = (dir: string, resDir: string) => {
    if (results.length >= limit) return;
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    // A folder with a .gdignore file is ignored by Godot itself
    if (entries.some((e) => e.name === '.gdignore')) return;
    for (const entry of entries) {
      if (entry.isDirectory()) {
        if (entry.name.startsWith('.') || SKIP_DIRS.has(entry.name)) continue;
        walk(join(dir, entry.name), `${resDir}${entry.name}/`);
      } else if (extensions.some((ext) => entry.name.toLowerCase().endsWith(ext))) {
        results.push(`${resDir}${entry.name}`);
        if (results.length >= limit) return;
      }
    }
  };
  walk(root, 'res://');
  return results.sort();
}

export interface FoundProject {
  path: string;
  name: string;
}

/** Find Godot projects under a folder, skipping heavy folders and capping depth. */
export function findProjects(directory: string, maxDepth: number): FoundProject[] {
  const projects: FoundProject[] = [];
  const walk = (dir: string, depth: number) => {
    if (projects.length >= 200) return;
    const projectFile = join(dir, 'project.godot');
    if (existsSync(projectFile)) {
      projects.push({ path: dir, name: readProjectName(projectFile) ?? basename(dir) });
      return; // nested projects inside a project are rare and usually test fixtures
    }
    if (depth >= maxDepth) return;
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name.startsWith('.') || SKIP_DIRS.has(entry.name)) continue;
      if (/^(windows|program files|programdata|appdata|\$recycle\.bin)/i.test(entry.name)) continue;
      walk(join(dir, entry.name), depth + 1);
    }
  };
  if (!statSync(directory, { throwIfNoEntry: false })?.isDirectory()) {
    throw new ProjectError(`Folder does not exist: ${directory}`);
  }
  walk(resolve(directory), 0);
  return projects;
}

function readProjectName(projectFile: string): string | null {
  try {
    const match = readFileSync(projectFile, 'utf8').match(/^config\/name="((?:[^"\\]|\\.)*)"/m);
    return match ? match[1].replace(/\\"/g, '"') : null;
  } catch {
    return null;
  }
}
