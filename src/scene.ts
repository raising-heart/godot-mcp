/**
 * Read-only parsing of text scenes (.tscn) into a node tree, without
 * starting Godot or running any project code.
 */

import { bracketBalance as balance, unquote } from './settings.js';

export interface SceneNode {
  name: string;
  path: string;
  type?: string;
  /** res:// path of the scene this node instances */
  instance?: string;
  script?: string;
  groups: string[];
  uniqueName: boolean;
  properties: Record<string, string>;
  children: SceneNode[];
}

export interface ParsedScene {
  uid?: string;
  root: SceneNode | null;
  extResources: Array<{ id: string; type: string; path: string; uid?: string }>;
  subResources: Array<{ id: string; type: string }>;
  connections: Array<{ signal: string; from: string; to: string; method: string }>;
  nodeCount: number;
}

/** Split `key=value key2="v 2" key3=ExtResource("1")` respecting quotes and brackets. */
function parseAttributes(text: string): Record<string, string> {
  const attrs: Record<string, string> = {};
  let i = 0;
  while (i < text.length) {
    while (text[i] === ' ') i++;
    const eq = text.indexOf('=', i);
    if (eq === -1) break;
    const key = text.slice(i, eq).trim();
    let j = eq + 1;
    let depth = 0;
    let inString = false;
    for (; j < text.length; j++) {
      const ch = text[j];
      if (inString) {
        if (ch === '\\') j++;
        else if (ch === '"') inString = false;
      } else if (ch === '"') inString = true;
      else if ('([{'.includes(ch)) depth++;
      else if (')]}'.includes(ch)) depth--;
      else if (ch === ' ' && depth === 0) break;
    }
    attrs[key] = text.slice(eq + 1, j);
    i = j + 1;
  }
  return attrs;
}

export function parseTscn(text: string): ParsedScene {
  const scene: ParsedScene = { root: null, extResources: [], subResources: [], connections: [], nodeCount: 0 };
  const extById = new Map<string, string>();
  const nodesByPath = new Map<string, SceneNode>();
  let currentNode: SceneNode | null = null;

  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i];
    if (!line.trim() || line.startsWith(';')) continue;

    if (line.startsWith('[')) {
      // Headers can wrap across lines when they hold long arrays
      while (balance(line) > 0 && i + 1 < lines.length) line += ' ' + lines[++i].trim();
      const header = line.match(/^\[(\w+)\s*(.*)\]$/);
      currentNode = null;
      if (!header) continue;
      const [, kind, rest] = header;
      const attrs = parseAttributes(rest);

      if (kind === 'gd_scene') {
        scene.uid = unquote(attrs.uid);
      } else if (kind === 'ext_resource') {
        const res = { id: unquote(attrs.id) ?? '', type: unquote(attrs.type) ?? '', path: unquote(attrs.path) ?? '', uid: unquote(attrs.uid) };
        scene.extResources.push(res);
        extById.set(res.id, res.path);
      } else if (kind === 'sub_resource') {
        scene.subResources.push({ id: unquote(attrs.id) ?? '', type: unquote(attrs.type) ?? '' });
      } else if (kind === 'connection') {
        scene.connections.push({
          signal: unquote(attrs.signal) ?? '',
          from: unquote(attrs.from) ?? '',
          to: unquote(attrs.to) ?? '',
          method: unquote(attrs.method) ?? '',
        });
      } else if (kind === 'node') {
        const name = unquote(attrs.name) ?? '?';
        const parent = unquote(attrs.parent);
        const instanceId = attrs.instance?.match(/ExtResource\(\s*"([^"]+)"\s*\)/)?.[1];
        const node: SceneNode = {
          name,
          path: parent === undefined ? '.' : parent === '.' ? name : `${parent}/${name}`,
          type: unquote(attrs.type),
          instance: instanceId ? extById.get(instanceId) ?? `ExtResource(${instanceId})` : undefined,
          groups: (attrs.groups?.match(/"((?:[^"\\]|\\.)*)"/g) ?? []).map((g) => g.slice(1, -1)),
          uniqueName: false,
          properties: {},
          children: [],
        };
        scene.nodeCount++;
        currentNode = node;
        if (parent === undefined) {
          scene.root = node;
        } else {
          const parentNode = parent === '.' ? scene.root : nodesByPath.get(parent);
          (parentNode ?? scene.root)?.children.push(node);
        }
        nodesByPath.set(node.path, node);
      }
      continue;
    }

    if (currentNode) {
      const eq = line.indexOf(' = ');
      if (eq === -1) continue;
      const key = line.slice(0, eq).trim();
      let value = line.slice(eq + 3).trim();
      while (balance(value) > 0 && i + 1 < lines.length) value += '\n' + lines[++i];

      if (key === 'script') {
        const id = value.match(/ExtResource\(\s*"([^"]+)"\s*\)/)?.[1];
        currentNode.script = id ? extById.get(id) ?? value : value;
      } else if (key === 'unique_name_in_owner') {
        currentNode.uniqueName = value === 'true';
      } else {
        currentNode.properties[key] = value;
      }
    }
  }
  return scene;
}

function shorten(value: string, max = 80): string {
  const oneLine = value.replace(/\s*\n\s*/g, ' ');
  return oneLine.length > max ? oneLine.slice(0, max - 1) + '…' : oneLine;
}

/** Render the tree the way the Scene dock shows it. */
export function formatSceneTree(scene: ParsedScene, includeProperties: boolean): string {
  if (!scene.root) return '(scene has no nodes)';
  const lines: string[] = [];

  const describe = (node: SceneNode): string => {
    const label = `${node.uniqueName ? '%' : ''}${node.name}`;
    const parts = [node.type ? `${label} (${node.type})` : label];
    if (node.instance) parts.push(`[instance of ${node.instance}]`);
    if (node.script) parts.push(`script=${node.script}`);
    if (node.groups.length) parts.push(`groups=[${node.groups.join(', ')}]`);
    return parts.join(' ');
  };

  const walk = (node: SceneNode, prefix: string, isLast: boolean, isRoot: boolean) => {
    lines.push(isRoot ? describe(node) : `${prefix}${isLast ? '└─ ' : '├─ '}${describe(node)}`);
    const childPrefix = isRoot ? '' : prefix + (isLast ? '   ' : '│  ');
    if (includeProperties) {
      const propPrefix = childPrefix + (node.children.length ? '│    ' : '     ');
      for (const [key, value] of Object.entries(node.properties)) {
        lines.push(`${propPrefix}${key} = ${shorten(value)}`);
      }
    }
    node.children.forEach((child, index) => walk(child, childPrefix, index === node.children.length - 1, false));
  };
  walk(scene.root, '', true, true);
  return lines.join('\n');
}
