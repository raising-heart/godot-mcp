# Godot MCP for Claude Code

A Claude Code friendly fork of [Coding-Solo/godot-mcp](https://github.com/Coding-Solo/godot-mcp) (MIT). It lets Claude understand your Godot 4 project, check GDScript with the real engine, run the game and read its errors, and look at screenshots of what it renders.

## What's different from upstream

- **Zero setup for Godot.** Finds Godot by itself, including an unzipped download in your Downloads folder. `npm run doctor` prints the exact `claude mcp add` command.
- **No project path juggling.** Tools use the project Claude Code is running in. `projectPath` is optional everywhere, and paths can be `res://...`.
- **New tools:** `check_scripts` (compile errors with file and line), `get_scene_tree` (the Scene dock as text), `capture_screenshot` (Claude sees the game), and a much richer `get_project_info` (autoloads, input actions, scenes, scripts).
- **Better game runs:** `run_project` waits and returns the first output and errors in one call, can run headless test scripts, and `get_debug_output` returns only new lines (or only errors).
- **Claude Code plugin** with a Godot skill that teaches the check → run → screenshot workflow and the Godot 3 → 4 syntax traps.
- **Fixes:** scripts that use autoloads no longer fail inside the helper (it now waits for autoloads to register); new `class_name` scripts are picked up automatically; the editor is started detached instead of writing into a pipe nobody reads; `run_project` no longer uses the stdin debugger that can pause the game on an error; the project name is read correctly; every Godot call has a timeout.
- **Safer:** see [Safety](#safety).

## Install

You need [Node.js](https://nodejs.org) 18+ and Godot 4.

```bash
git clone https://github.com/raising-heart/godot-mcp.git
cd godot-mcp
npm install
npm run doctor
```

`npm install` also builds the server. `doctor` checks Node and Godot, then prints the setup command for your machine.

### Option A: as a Claude Code plugin (recommended)

Gives you the MCP server **and** the Godot skill. In Claude Code:

```text
/plugin marketplace add C:\path\to\godot-mcp
/plugin install godot@godot-mcp-local
```

Or from a terminal: `claude plugin marketplace add C:\path\to\godot-mcp`, then `claude plugin install godot@godot-mcp-local`.

When you enable it you can optionally set the Godot executable and read-only mode; leave them empty to auto-detect.

### Option B: just the MCP server

Copy the command `npm run doctor` prints, which looks like:

```bash
claude mcp add godot --scope user -e GODOT_PATH="C:\path\to\Godot.exe" -- node "C:\path\to\godot-mcp\build\index.js"
```

Then open Claude Code inside your Godot project and run `/mcp` to check that `godot` is connected.

## Tools

| Tool | What it does | Changes files? |
|---|---|---|
| `get_project_info` | Name, main scene, features, renderer, viewport, autoloads, input actions, plugins, scenes and scripts | No |
| `get_scene_tree` | Node tree of a `.tscn` with types, scripts, instances, groups, signal connections (optionally properties) | No |
| `check_scripts` | Compiles GDScript with the engine; reports errors with file and line | No |
| `run_project` | Runs the game, a scene, or a `SceneTree` test script (optionally headless); returns the first output | No |
| `get_debug_output` | New output since last read, or the full log; `errorsOnly` filter | No |
| `stop_project` | Stops the game and returns its last output | No |
| `capture_screenshot` | Runs a scene briefly via Movie Maker and returns a PNG | No (saves to temp) |
| `launch_editor` | Opens the Godot editor for the user | No |
| `get_godot_version` | Which Godot is used and which other installs were found | No |
| `list_projects` | Finds Godot projects in a folder | No |
| `get_uid` | `uid://` of a file (Godot 4.4+) | No |
| `create_scene` | New scene with a root node (refuses to overwrite) | Yes |
| `add_node` | Adds a node with properties to a scene | Yes |
| `load_sprite` | Sets a sprite/texture rect texture | Yes |
| `save_scene` | Re-saves a scene, optionally to a new path | Yes |
| `export_mesh_library` | Exports a 3D scene as a MeshLibrary | Yes |
| `update_project_uids` | Re-saves resources to refresh UIDs (4.4+) | Yes |

## Settings

| Environment variable | Meaning |
|---|---|
| `GODOT_PATH` | Godot executable, or the folder that contains it. Default: auto-detect (newest Godot 4 found) |
| `GODOT_PROJECT` | Default project folder. Default: the folder Claude Code runs in |
| `GODOT_MCP_READ_ONLY=1` | Hide every tool that changes files |

## Safety

- **No network.** The server talks to Claude Code over stdio only. It opens no ports and sends nothing anywhere.
- **Stays inside your project.** Every file path is resolved against the project folder; `..`, absolute paths elsewhere, other URL schemes and symlinks that lead outside are refused.
- **No arbitrary code tool.** There is no "run this code" tool. Node types must be plain class names, so a script path can't be smuggled in as a node type (upstream CVE-2026-25546 and the April 2026 fix are both included).
- **No shell.** Godot is always started with an argument list, never through a shell.
- **Your code does run** when you use `run_project`, `capture_screenshot`, `check_scripts` (autoloads start) or the editing tools, just as it would if you pressed Play. Keep the project in git so you can review and undo any change Claude makes.
- **Read-only mode** (`GODOT_MCP_READ_ONLY=1`) removes every tool that changes files.

## Development

```bash
npm run build     # compile to build/
npm test          # end-to-end test against real Godot (SKIP_SCREENSHOT=1 without a display)
npm run doctor    # check the setup
```

`test/smoke.mjs` copies `test/fixture` to a temp folder and calls every tool through a real MCP client.

## Credits

Based on [godot-mcp](https://github.com/Coding-Solo/godot-mcp) by Solomon Elias (Coding-Solo) and contributors, MIT licensed.
