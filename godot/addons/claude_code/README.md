# Claude Code dock for Godot

Chat with Claude Code in a dock inside the Godot editor.

- **Knows what you're looking at:** each message can include the open scene, the selected nodes, and the script and line you're on, so "make this node bounce" just works.
- **Asks before changing things:** Allow / Allow for this chat / Deny buttons, with a before/after preview of the edit or the command. Read-only Godot tools (project info, scene tree, script check) run without asking.
- **Three modes:** *Ask before changes*, *Auto-accept file edits*, and *Plan only (no changes)*.
- **Keeps the editor in sync:** saves your open scenes before sending, then rescans the project and reloads scenes that Claude changed.
- **Uses the Godot MCP tools** (if installed) to check scripts, run the game and take screenshots.
- Remembers the conversation until you press **New chat**. Pure GDScript, no extra programs.

## Requirements

- Godot **4.4 or newer** (tested on 4.7.2)
- [Claude Code](https://claude.com/claude-code) installed, and logged in once from a terminal:

  ```bash
  claude auth login
  ```

- Optional but recommended: the Godot MCP server/plugin from this repo, which gives Claude the Godot tools.

## Install

1. Copy the `claude_code` folder into your project's `addons/` folder (so you have `res://addons/claude_code/plugin.cfg`).
2. In Godot: **Project → Project Settings → Plugins**, enable **Claude Code**.
3. The **Claude** dock appears on the right, next to the Inspector. Drag its tab anywhere you like.

## Use

Type in the box and press **Enter** (**Shift+Enter** for a new line). The line above the box shows what context is sent; switch it off in the **⋯** menu.

| Control | What it does |
|---|---|
| Mode menu | *Ask before changes* shows Allow/Deny for edits and commands. *Auto-accept file edits* lets Claude edit files without asking (commands still ask). *Plan only* lets Claude read and plan but not change anything. |
| Model menu | Default, Opus, Sonnet or Haiku |
| Stop | Stops the current reply |
| New chat | Starts a fresh conversation |
| ⋯ | Editor context on/off, saving scenes before sending on/off, where to set the Claude path |

If Claude Code is installed somewhere unusual, set **Editor Settings → Claude Code → Claude Path**.

## Good to know

- Claude runs in your project folder with your normal Claude Code settings and plugins.
- If a script you have open in Godot was changed by Claude, Godot may ask to reload it; choose **Reload**.
- Keep your project in git so you can review and undo Claude's changes.
