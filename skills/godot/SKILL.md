---
name: godot
description: Use when working on a Godot 4 game or any project with a project.godot file - writing or fixing GDScript, editing .tscn scenes, adding gameplay, or debugging errors. Covers the Godot MCP tools workflow and Godot 3 vs 4 pitfalls.
---

# Working on Godot 4 projects

The `godot` MCP server gives you the real engine. Use it to check your work instead of guessing.

## Workflow

1. **Orient first.** Call `get_project_info` (main scene, autoloads, input actions, scenes, scripts) and `get_scene_tree` on the scenes you will touch. `projectPath` can be left out when Claude Code runs inside the project.
2. **Edit files directly** with your normal file tools: `.gd` scripts and `.tscn` scenes are plain text.
3. **After every batch of script edits, run `check_scripts`.** It compiles with the real engine and reports errors with file and line. Fix them before running the game.
4. **Run it.** `run_project` starts the game, waits a few seconds and returns output and errors. Use `get_debug_output` (only new lines by default; `errorsOnly: true` to filter) and `stop_project` when done.
5. **Look at it.** For anything visual (UI, layout, sprites, camera), call `capture_screenshot` and check the image rather than assuming it looks right.
6. **Tests.** If the project has test scripts that extend `SceneTree`, run them with `run_project` and `script: "res://tests/..."`, `headless: true`.

Tell the user what you verified (scripts compile, game ran without errors, screenshot checked) and what you could not check (gameplay feel, input you could not simulate).

## Editing .tscn files by hand

- Each `[ext_resource]` needs a unique `id`; reference it as `ExtResource("id")`. `[sub_resource]` the same with `SubResource("id")`.
- `parent="."` means a child of the root; deeper nodes use paths like `parent="Player/Sprite"`. A parent must appear before its children.
- Signal connections go at the end: `[connection signal="pressed" from="Button" to="." method="_on_button_pressed"]`.
- Leave `uid="uid://..."` values alone; never invent them. Omitting `uid` on a new `ext_resource` is fine (the `path` is used).
- After editing, call `get_scene_tree` to confirm the structure parses as you intended.
- For simple additions `create_scene` / `add_node` do this safely through Godot.

Never edit the `.godot/` folder, `*.import` files or `*.uid` files; Godot generates them.

## GDScript: Godot 4, not Godot 3

Old tutorials and memory often produce Godot 3 code. Use the Godot 4 forms:

| Godot 3 (wrong) | Godot 4 (right) |
|---|---|
| `export var speed = 10` | `@export var speed := 10.0` |
| `onready var sprite = $Sprite` | `@onready var sprite: Sprite2D = $Sprite2D` |
| `tool` | `@tool` |
| `KinematicBody2D`, `move_and_slide(velocity, Vector2.UP)` | `CharacterBody2D`, set `velocity` then `move_and_slide()` |
| `Spatial`, `Position2D` | `Node3D`, `Marker2D` |
| `yield(get_tree().create_timer(1), "timeout")` | `await get_tree().create_timer(1.0).timeout` |
| `connect("pressed", self, "_on_pressed")` | `pressed.connect(_on_pressed)` |
| `emit_signal("died", x)` | `died.emit(x)` |
| `scene.instance()` | `scene.instantiate()` |
| `get_tree().change_scene("res://x.tscn")` | `get_tree().change_scene_to_file("res://x.tscn")` |
| `File`, `Directory` | `FileAccess`, `DirAccess` |
| `rand_range(a, b)`, `deg2rad()` | `randf_range(a, b)`, `deg_to_rad()` |
| `var x setget set_x` | `var x: int: set = set_x` (or an inline `set(value):`) |
| `OS.get_ticks_msec()` | `Time.get_ticks_msec()` |
| `Tween` node | `var tween := create_tween()` |

Prefer static types (`var hp: int = 3`, `func hit(amount: int) -> void:`); the compiler catches more mistakes and `check_scripts` reports them.

Autoload names from `get_project_info` are global identifiers (e.g. `GameState.score`). Input action names must exist in the project's input map; check the list before using `Input.is_action_pressed("jump")`.

## If the Godot editor is open

The editor reloads scripts changed on disk, but unsaved editor changes can overwrite your edits (or ask the user to choose). Ask the user to save in the editor before you edit the same files, and to reload if Godot asks.
