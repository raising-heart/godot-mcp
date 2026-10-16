/**
 * Read-only parsing of project.godot (Godot's ConfigFile/INI format).
 */

import { readFileSync } from 'fs';
import { join } from 'path';

export type ConfigSections = Map<string, Map<string, string>>;

export function bracketBalance(text: string): number {
  let balance = 0;
  let inString = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inString) {
      if (ch === '\\') i++;
      else if (ch === '"') inString = false;
    } else if (ch === '"') inString = true;
    else if ('{[('.includes(ch)) balance++;
    else if ('}])'.includes(ch)) balance--;
  }
  return balance;
}

/**
 * Parse Godot's ConfigFile text. Values are kept as raw Variant text;
 * multi-line values (dictionaries, arrays) are joined until brackets balance.
 */
export function parseConfig(text: string): ConfigSections {
  const sections: ConfigSections = new Map([['', new Map()]]);
  let current = sections.get('')!;
  const lines = text.split(/\r?\n/);

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line || line.startsWith(';') || line.startsWith('#')) continue;

    const header = line.match(/^\[([^\]]+)\]$/);
    if (header) {
      current = new Map();
      sections.set(header[1], current);
      continue;
    }

    const eq = line.indexOf('=');
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    while (bracketBalance(value) > 0 && i + 1 < lines.length) {
      value += '\n' + lines[++i];
    }
    current.set(key, value);
  }
  return sections;
}

export function unquote(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  const match = value.match(/^"((?:[^"\\]|\\.)*)"$/);
  return match ? match[1].replace(/\\(.)/g, '$1') : value;
}

export interface ProjectSummary {
  name: string;
  description?: string;
  mainScene?: string;
  godotFeatures: string[];
  renderer?: string;
  viewport?: { width: number; height: number };
  autoloads: Array<{ name: string; path: string; singleton: boolean }>;
  inputActions: string[];
  dotnet: boolean;
  plugins: string[];
}

export function readProjectSummary(root: string, fallbackName: string): ProjectSummary {
  const config = parseConfig(readFileSync(join(root, 'project.godot'), 'utf8'));
  const app = config.get('application') ?? new Map();
  const display = config.get('display') ?? new Map();
  const rendering = config.get('rendering') ?? new Map();

  const features = (app.get('config/features')?.match(/"([^"]+)"/g) ?? []).map((s: string) => s.slice(1, -1));

  const width = parseInt(display.get('window/size/viewport_width') ?? '', 10);
  const height = parseInt(display.get('window/size/viewport_height') ?? '', 10);

  const autoloads = [...(config.get('autoload') ?? new Map()).entries()].map(([name, raw]) => {
    const value = unquote(raw) ?? '';
    return { name, path: value.replace(/^\*/, ''), singleton: value.startsWith('*') };
  });

  const plugins = (config.get('editor_plugins')?.get('enabled')?.match(/"([^"]+)"/g) ?? []).map((s: string) => s.slice(1, -1));

  return {
    name: unquote(app.get('config/name')) || fallbackName,
    description: unquote(app.get('config/description')),
    mainScene: unquote(app.get('run/main_scene')),
    godotFeatures: features,
    renderer: unquote(rendering.get('renderer/rendering_method')) ?? (features.find((f: string) => /forward|mobile|compatibility/i.test(f))),
    viewport: Number.isFinite(width) && Number.isFinite(height) ? { width, height } : undefined,
    autoloads,
    inputActions: [...(config.get('input') ?? new Map()).keys()],
    dotnet: config.has('dotnet'),
    plugins,
  };
}
