@tool
extends VBoxContainer
## The Terminal panel: a toolbar plus the terminal itself, running a shell
## that starts in the project folder.

const PtySession := preload("res://addons/agent_terminal/pty_session.gd")
const TerminalBuffer := preload("res://addons/agent_terminal/terminal_buffer.gd")
const TerminalView := preload("res://addons/agent_terminal/terminal_view.gd")

const SETTING_SHELL := "agent_terminal/shell"
const SHELLS := [
	["PowerShell", "powershell.exe -NoLogo"],
	["PowerShell 7", "pwsh.exe -NoLogo"],
	["Command Prompt", "cmd.exe"],
]

var _session := PtySession.new()
var _buffer := TerminalBuffer.new(100, 30)
var _view: TerminalView
var _shell_select: OptionButton
var _title: Label
var _started := false
var _ended := false


func _ready() -> void:
	_build_ui()
	_session.output.connect(_on_output)
	_session.exited.connect(_on_exited)
	_buffer.reply.connect(_session.write)
	_buffer.title_changed.connect(func(t: String) -> void: _title.tooltip_text = t)


func _process(_delta: float) -> void:
	_session.poll()
	# Start lazily the first time the panel is shown, once it has a real size
	if not _started and is_visible_in_tree() and _view.size.x > 0:
		_start()


func shutdown() -> void:
	_session.stop()


func _build_ui() -> void:
	var ui_scale := EditorInterface.get_editor_scale()
	custom_minimum_size = Vector2(0, 180) * ui_scale

	var bar := HBoxContainer.new()
	add_child(bar)
	_title = Label.new()
	_title.text = "Terminal · " + _project_dir()
	_title.clip_text = true
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_title)

	var claude := Button.new()
	claude.text = "Run claude"
	claude.tooltip_text = "Types \"claude\" and presses Enter"
	claude.pressed.connect(func() -> void:
		_session.write("claude\r".to_utf8_buffer())
		_view.grab_focus())
	bar.add_child(claude)

	_shell_select = OptionButton.new()
	var saved := str(_setting(SETTING_SHELL, SHELLS[0][1]))
	for i in SHELLS.size():
		_shell_select.add_item(SHELLS[i][0], i)
		if SHELLS[i][1] == saved:
			_shell_select.select(i)
	_shell_select.item_selected.connect(func(index: int) -> void:
		EditorInterface.get_editor_settings().set_setting(SETTING_SHELL, SHELLS[index][1])
		_restart())
	bar.add_child(_shell_select)

	var restart := Button.new()
	restart.text = "Restart"
	restart.tooltip_text = "Close this shell and start a new one in the project folder"
	restart.pressed.connect(_restart)
	bar.add_child(restart)

	_view = TerminalView.new()
	_view.buffer = _buffer
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view.input_bytes.connect(_on_input)
	_view.grid_resized.connect(_on_grid_resized)
	add_child(_view)


func _setting(key: String, fallback: Variant) -> Variant:
	var settings := EditorInterface.get_editor_settings()
	return settings.get_setting(key) if settings.has_setting(key) else fallback


func _project_dir() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").replace("/", "\\")


func _start() -> void:
	_started = true
	_ended = false
	var grid := _view.grid_size()
	_buffer.resize(grid.x, grid.y)
	var command: String = SHELLS[_shell_select.selected][1]
	var error := _session.start(_project_dir(), grid.x, grid.y, command)
	if error != "":
		_message("\r\n\u001b[31m%s\u001b[0m\r\n" % error.replace("\n", "\r\n"))
		_ended = true


func _restart() -> void:
	_session.stop()
	_buffer.feed("\u001b[0m\u001b[2J\u001b[3J\u001b[H".to_utf8_buffer())
	_buffer.clear_scrollback()
	_started = false


func _message(text: String) -> void:
	_buffer.feed(text.to_utf8_buffer())


func _on_output(data: PackedByteArray) -> void:
	_buffer.feed(data)


func _on_input(data: PackedByteArray) -> void:
	if _ended:
		# After the shell has exited, Enter starts a new one
		if data.size() == 1 and data[0] == 13:
			_restart()
		return
	_session.write(data)


func _on_grid_resized(cols: int, rows: int) -> void:
	_buffer.resize(cols, rows)
	if _session.is_running():
		_session.resize(cols, rows)


func _on_exited(code: int) -> void:
	_ended = true
	var errors := _session.error_text()
	if errors != "":
		_message("\r\n\u001b[31m%s\u001b[0m" % errors.replace("\n", "\r\n"))
	_message("\r\n\u001b[2m[shell exited with code %d · press Enter to start a new one]\u001b[0m\r\n" % code)
