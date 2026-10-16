# Agent Terminal for Godot

A real terminal in the Godot editor's bottom panel that **opens in your project folder**: no `cd` needed. Type `claude` (or press **Run claude**) and you get the normal, full Claude Code, just inside Godot. It's also a regular PowerShell / Command Prompt for git, npm and anything else.

> Unofficial community project. Not affiliated with, endorsed by, or supported by Anthropic. Claude and Claude Code are trademarks of Anthropic.

**Windows 10 (1809+) / 11 only for now.** Requires Godot 4.4+ (tested on 4.7.2).

## Install

1. Copy the `agent_terminal` folder into your project's `addons/` folder (so you have `res://addons/agent_terminal/plugin.cfg`).
2. In Godot: **Project → Project Settings → Plugins**, enable **Agent Terminal**.
3. Open the **Terminal** tab in the bottom panel (next to Output and Debugger).

To use Claude Code in it, install [Claude Code](https://claude.com/claude-code) and log in once (`claude auth login`), then type `claude`.

## Using it

| Action | How |
|---|---|
| Copy | Select with the mouse, then **Ctrl+C** (or Ctrl+Shift+C, or right-click → Copy). Without a selection, Ctrl+C is sent to the program as usual. |
| Paste | **Ctrl+V**, Ctrl+Shift+V, Shift+Insert, or right-click → Paste |
| Scroll back | Mouse wheel, or Shift+PageUp / Shift+PageDown. Typing jumps back to the bottom. |
| Select a word | Double-click |
| New shell | **Restart**, or press Enter after the shell has exited |
| Change shell | PowerShell, PowerShell 7 or Command Prompt in the toolbar |

The panel can be resized; the terminal follows.

## How it works, and why it's safe

Godot can't create a real console by itself, so the plugin uses a small helper, `pty_host.cs`. It's about 300 lines of readable C# next to this README, and it uses the Windows pseudo console API (ConPTY), the same one Windows Terminal uses.

- **No prebuilt programs.** The repo contains only source code. On first use the helper is compiled on your computer by the C# compiler that ships with Windows (`csc.exe` from .NET Framework 4). The result is cached in Godot's editor data folder (`%APPDATA%\Godot\agent_terminal\`) and is rebuilt automatically if the source changes.
- **No network.** The helper only relays keyboard input and screen output between Godot and the shell.
- **Nothing left behind.** The shell runs inside a Windows job object, so closing Godot (even a crash) ends the shell and everything started in it, including Claude Code.
- **Nothing special about Claude.** It's an ordinary terminal; Claude Code runs exactly as it would in Windows Terminal, with your own login.

## Limitations

- Windows only (macOS/Linux would need a different helper).
- No mouse reporting to programs, and no IME composition window.
- A few symbols may render from a fallback font and look slightly different than in Windows Terminal.
