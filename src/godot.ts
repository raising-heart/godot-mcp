/**
 * Finding and running the Godot executable.
 */

import { execFile } from 'child_process';
import { existsSync, readdirSync, statSync } from 'fs';
import { delimiter, join, normalize } from 'path';
import { homedir } from 'os';

export interface GodotInstall {
  path: string;
  version: string;
  /** Where we found it, e.g. "GODOT_PATH" or "Downloads folder" */
  source: string;
}

export interface GodotRunResult {
  stdout: string;
  stderr: string;
  exitCode: number | null;
  timedOut: boolean;
}

const ANSI_PATTERN = /\x1b\[[0-9;]*[A-Za-z]/g;

export function stripAnsi(text: string): string {
  return text.replace(ANSI_PATTERN, '');
}

/**
 * Run Godot with an argument array (never through a shell) and collect its output.
 * Never throws for a non-zero exit code; check exitCode / timedOut instead.
 */
export function runGodot(
  godotPath: string,
  args: string[],
  options: { timeoutMs?: number; cwd?: string } = {}
): Promise<GodotRunResult> {
  return new Promise((resolve, reject) => {
    execFile(
      godotPath,
      args,
      {
        timeout: options.timeoutMs ?? 120_000,
        cwd: options.cwd,
        windowsHide: true,
        maxBuffer: 32 * 1024 * 1024,
      },
      (error, stdout, stderr) => {
        const err = error as (NodeJS.ErrnoException & { killed?: boolean; code?: number | string }) | null;
        if (err && typeof err.code === 'string') {
          // Spawn failure (ENOENT, EACCES...), not a Godot exit code
          reject(err);
          return;
        }
        resolve({
          stdout: stripAnsi(stdout ?? ''),
          stderr: stripAnsi(stderr ?? ''),
          exitCode: err ? (typeof err.code === 'number' ? err.code : null) : 0,
          timedOut: Boolean(err?.killed),
        });
      }
    );
  });
}

/** Parse "4.7.2.stable.official.ed1daf0bf" into comparable numbers. */
export function parseGodotVersion(version: string): { major: number; minor: number; patch: number } | null {
  const match = version.match(/^(\d+)\.(\d+)(?:\.(\d+))?/);
  if (!match) return null;
  return {
    major: parseInt(match[1], 10),
    minor: parseInt(match[2], 10),
    patch: match[3] ? parseInt(match[3], 10) : 0,
  };
}

function compareVersions(a: string, b: string): number {
  const va = parseGodotVersion(a);
  const vb = parseGodotVersion(b);
  if (!va || !vb) return 0;
  return va.major - vb.major || va.minor - vb.minor || va.patch - vb.patch;
}

export function isGodot44OrLater(version: string): boolean {
  const v = parseGodotVersion(version);
  return Boolean(v && (v.major > 4 || (v.major === 4 && v.minor >= 4)));
}

/** Returns the version string if `path` is a working Godot 4+ executable. */
async function probeGodot(path: string): Promise<string | null> {
  try {
    const result = await runGodot(path, ['--version'], { timeoutMs: 15_000 });
    const version = result.stdout.trim().split(/\r?\n/).pop()?.trim() ?? '';
    const parsed = parseGodotVersion(version);
    return parsed && parsed.major >= 4 ? version : null;
  } catch {
    return null;
  }
}

const WINDOWS_EXE = /^godot.*\.exe$/i;

function isFile(path: string): boolean {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

function isDir(path: string): boolean {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function safeReaddir(dir: string): string[] {
  try {
    return readdirSync(dir);
  } catch {
    return [];
  }
}

/**
 * Turn a file or folder into Godot executable candidates.
 * Godot downloads are zips, and once extracted on Windows you often get a
 * *folder* called "Godot_v4.x-stable_win64.exe" with the real exe inside,
 * so folders are searched up to two levels deep.
 */
function expandWindowsCandidate(path: string, depth = 2): string[] {
  if (isFile(path)) {
    return WINDOWS_EXE.test(path.split(/[\\/]/).pop() ?? '') ? [path] : [];
  }
  if (depth === 0 || !isDir(path)) return [];

  const found: string[] = [];
  for (const entry of safeReaddir(path)) {
    if (!/^godot/i.test(entry)) continue;
    // The *_console.exe wrapper is for terminals; the main exe works headless too
    if (/_console\.exe$/i.test(entry)) continue;
    found.push(...expandWindowsCandidate(join(path, entry), depth - 1));
  }
  return found;
}

function windowsCandidates(): Array<{ path: string; source: string }> {
  const home = process.env.USERPROFILE || homedir();
  const localAppData = process.env.LOCALAPPDATA || join(home, 'AppData', 'Local');
  const roots: Array<[string, string]> = [
    [join(home, 'Downloads'), 'Downloads folder'],
    [join(home, 'Desktop'), 'Desktop'],
    [join(home, 'Documents'), 'Documents folder'],
    [join(home, 'Godot'), 'home folder'],
    [process.env.ProgramFiles || 'C:\\Program Files', 'Program Files'],
    [process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', 'Program Files (x86)'],
    [join(localAppData, 'Programs'), 'AppData\\Local\\Programs'],
    [join(home, 'scoop', 'apps', 'godot', 'current'), 'Scoop'],
    [join(localAppData, 'Microsoft', 'WinGet', 'Packages'), 'WinGet'],
    ['C:\\Program Files (x86)\\Steam\\steamapps\\common\\Godot Engine', 'Steam'],
    ['C:\\Program Files\\Steam\\steamapps\\common\\Godot Engine', 'Steam'],
  ];

  const result: Array<{ path: string; source: string }> = [];
  for (const [root, source] of roots) {
    const isGodotFolder = /godot/i.test(root);
    const paths = isGodotFolder
      ? safeReaddir(root).filter((e) => WINDOWS_EXE.test(e) && !/_console/i.test(e)).map((e) => join(root, e))
      : expandWindowsCandidate(root);
    for (const path of paths) result.push({ path, source });
  }
  return result;
}

function unixCandidates(): Array<{ path: string; source: string }> {
  const home = process.env.HOME || homedir();
  const result: Array<{ path: string; source: string }> = [];

  if (process.platform === 'darwin') {
    for (const appsDir of ['/Applications', join(home, 'Applications')]) {
      for (const entry of safeReaddir(appsDir)) {
        if (/^godot.*\.app$/i.test(entry)) {
          result.push({ path: join(appsDir, entry, 'Contents', 'MacOS', 'Godot'), source: appsDir });
        }
      }
    }
    result.push({
      path: join(home, 'Library/Application Support/Steam/steamapps/common/Godot Engine/Godot.app/Contents/MacOS/Godot'),
      source: 'Steam',
    });
  } else {
    for (const path of [
      '/usr/bin/godot',
      '/usr/local/bin/godot',
      '/snap/bin/godot',
      '/var/lib/flatpak/exports/bin/org.godotengine.Godot',
      join(home, '.local/share/flatpak/exports/bin/org.godotengine.Godot'),
      join(home, '.local/bin/godot'),
    ]) {
      result.push({ path, source: 'system' });
    }
    for (const dir of [join(home, 'Downloads'), join(home, 'Applications'), join(home, 'Godot')]) {
      for (const entry of safeReaddir(dir)) {
        if (/^godot.*(x86_64|arm64|\.x86_64|linux)/i.test(entry) && isFile(join(dir, entry))) {
          result.push({ path: join(dir, entry), source: dir });
        }
      }
    }
  }
  return result;
}

function pathCandidates(): Array<{ path: string; source: string }> {
  const names = process.platform === 'win32'
    ? ['godot.exe', 'godot4.exe', 'Godot.exe']
    : ['godot', 'godot4'];
  const result: Array<{ path: string; source: string }> = [];
  for (const dir of (process.env.PATH || '').split(delimiter)) {
    if (!dir) continue;
    for (const name of names) {
      const full = join(dir, name);
      if (existsSync(full)) result.push({ path: full, source: 'PATH' });
    }
  }
  return result;
}

export interface GodotSearch {
  best: GodotInstall | null;
  all: GodotInstall[];
  /** Set when GODOT_PATH was given but did not work */
  envProblem?: string;
}

/**
 * Find Godot. GODOT_PATH wins if it works (it may point at the exe or at the
 * folder containing it); otherwise every common location is checked and the
 * newest Godot 4 version found is used.
 */
export async function findGodot(): Promise<GodotSearch> {
  let envProblem: string | undefined;

  if (process.env.GODOT_PATH) {
    const envPath = normalize(process.env.GODOT_PATH.trim().replace(/^"|"$/g, ''));
    const candidates = process.platform === 'win32' && isDir(envPath)
      ? expandWindowsCandidate(envPath)
      : [envPath];
    for (const path of candidates) {
      const version = await probeGodot(path);
      if (version) {
        const install = { path, version, source: 'GODOT_PATH' };
        return { best: install, all: [install] };
      }
    }
    envProblem = `GODOT_PATH is set to "${process.env.GODOT_PATH}" but no working Godot 4 executable was found there.`;
  }

  const raw = [
    ...pathCandidates(),
    ...(process.platform === 'win32' ? windowsCandidates() : unixCandidates()),
  ];

  const seen = new Set<string>();
  const all: GodotInstall[] = [];
  for (const { path, source } of raw) {
    const key = process.platform === 'win32' ? path.toLowerCase() : path;
    if (seen.has(key) || !existsSync(path)) continue;
    seen.add(key);
    if (seen.size > 25) break; // keep startup fast on cluttered machines
    const version = await probeGodot(path);
    if (version) all.push({ path, version, source });
  }

  // Newest version first; prefer the standard build over the .NET (mono) build on ties
  all.sort((a, b) => {
    const byVersion = compareVersions(b.version, a.version);
    if (byVersion !== 0) return byVersion;
    return Number(/mono/i.test(a.path)) - Number(/mono/i.test(b.path));
  });

  return { best: all[0] ?? null, all, envProblem };
}
