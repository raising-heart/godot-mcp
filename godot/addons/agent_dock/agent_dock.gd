@tool
extends VBoxContainer
## The Agent Dock: a transcript, an input box, permission prompts,
## and the glue that tells Claude what you are looking at in the editor.

const ClaudeProcess := preload("res://addons/agent_dock/claude_process.gd")
const ClaudeLocator := preload("res://addons/agent_dock/claude_locator.gd")

const SETTING_PATH := "agent_dock/claude_path"
const SETTING_MODEL := "agent_dock/model"
const SETTING_MODE := "agent_dock/permission_mode"
const SETTING_CONTEXT := "agent_dock/send_editor_context"
const SETTING_SAVE := "agent_dock/save_scenes_before_sending"

const MODES := [
	["Ask before changes", "default"],
	["Auto-accept file edits", "acceptEdits"],
	["Plan only (no changes)", "plan"],
]
const GODOT_READ_ONLY_TOOLS := ["get_project_info", "get_scene_tree", "check_scripts", "get_godot_version", "list_projects", "get_uid", "get_debug_output"]
## Internal tools that would only clutter the transcript
const HIDDEN_TOOLS := ["ToolSearch"]
const MODELS := [["Default model", ""], ["Opus", "opus"], ["Sonnet", "sonnet"], ["Haiku", "haiku"]]

const SYSTEM_NOTE := "You are running inside a chat dock in the Godot editor. The user is looking at the editor next to this chat, so keep replies short and practical. Each message may start with a godot_editor_context block describing the open scene, selected nodes and script. When the godot MCP tools are available use them: check_scripts after editing GDScript, run_project to test, capture_screenshot to look at visual changes. The editor rescans the project and reloads changed scenes after each of your replies."

var _claude := ClaudeProcess.new()
var _session_id := ""
var _busy := false
var _restart_needed := false
var _main_screen := ""
var _turn_started_msec := 0
var _scene_mtimes := {}
var _always_allowed := {}
var _pending_request_id := ""
var _pending_tool := ""
var _pending_input := {}
var _assistant_open := false
var _streamed_messages := {}
var _current_message_id := ""
var _tool_names := {}
var _stderr_tail: Array[String] = []

var _status: Label
var _mode_select: OptionButton
var _model_select: OptionButton
var _new_button: Button
var _stop_button: Button
var _settings_menu: MenuButton
var _transcript: RichTextLabel
var _permission_panel: PanelContainer
var _permission_title: Label
var _permission_detail: Label
var _context_label: Label
var _prompt_box: TextEdit
var _send_button: Button
var _context_timer: Timer


func _ready() -> void:
	_register_settings()
	_build_ui()
	_claude.event_received.connect(_on_event)
	_claude.stderr_received.connect(_on_stderr)
	_claude.exited.connect(_on_exited)
	_show_welcome()


func _process(_delta: float) -> void:
	_claude.poll()


func shutdown() -> void:
	_claude.shutdown()


func set_main_screen(screen_name: String) -> void:
	_main_screen = screen_name


# ---------------------------------------------------------------- settings

func _settings() -> EditorSettings:
	return EditorInterface.get_editor_settings()


func _register_settings() -> void:
	var settings := _settings()
	var defaults := {
		SETTING_PATH: "",
		SETTING_MODEL: "",
		SETTING_MODE: "default",
		SETTING_CONTEXT: true,
		SETTING_SAVE: true,
	}
	for key in defaults:
		if not settings.has_setting(key):
			settings.set_setting(key, defaults[key])
		settings.set_initial_value(key, defaults[key], false)
	settings.add_property_info({
		"name": SETTING_PATH,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_GLOBAL_FILE,
		"hint_string": "",
	})


func _get_setting(key: String, fallback: Variant) -> Variant:
	var settings := _settings()
	return settings.get_setting(key) if settings.has_setting(key) else fallback


# ---------------------------------------------------------------- UI

func _build_ui() -> void:
	add_theme_constant_override("separation", 6)
	var ui_scale := EditorInterface.get_editor_scale()
	custom_minimum_size = Vector2(260, 200) * ui_scale

	var header := HBoxContainer.new()
	add_child(header)
	_status = Label.new()
	_status.text = "Ready"
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	header.add_child(_status)

	_stop_button = Button.new()
	_stop_button.text = "Stop"
	_stop_button.tooltip_text = "Stop Claude's current reply"
	_stop_button.disabled = true
	_stop_button.pressed.connect(_on_stop_pressed)
	header.add_child(_stop_button)

	_new_button = Button.new()
	_new_button.text = "New chat"
	_new_button.tooltip_text = "Forget this conversation and start fresh"
	_new_button.pressed.connect(_on_new_chat_pressed)
	header.add_child(_new_button)

	_settings_menu = MenuButton.new()
	_settings_menu.text = "⋯"
	_settings_menu.tooltip_text = "Settings"
	_settings_menu.flat = false
	header.add_child(_settings_menu)
	var popup := _settings_menu.get_popup()
	popup.add_check_item("Send editor context (scene, selection, script)", 0)
	popup.add_check_item("Save open scenes before sending", 1)
	popup.add_separator()
	popup.add_item("Set Claude program path… (Editor Settings)", 2)
	popup.set_item_checked(0, _get_setting(SETTING_CONTEXT, true))
	popup.set_item_checked(1, _get_setting(SETTING_SAVE, true))
	popup.id_pressed.connect(_on_settings_menu)

	var options := HBoxContainer.new()
	add_child(options)
	_mode_select = OptionButton.new()
	_mode_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_select.tooltip_text = "What Claude may do without asking"
	for i in MODES.size():
		_mode_select.add_item(MODES[i][0], i)
		if MODES[i][1] == _get_setting(SETTING_MODE, "default"):
			_mode_select.select(i)
	_mode_select.item_selected.connect(_on_mode_selected)
	options.add_child(_mode_select)

	_model_select = OptionButton.new()
	_model_select.tooltip_text = "Claude model"
	for i in MODELS.size():
		_model_select.add_item(MODELS[i][0], i)
		if MODELS[i][1] == _get_setting(SETTING_MODEL, ""):
			_model_select.select(i)
	_model_select.item_selected.connect(_on_model_selected)
	options.add_child(_model_select)

	_transcript = RichTextLabel.new()
	_transcript.bbcode_enabled = true
	_transcript.scroll_following = true
	_transcript.selection_enabled = true
	_transcript.context_menu_enabled = true
	_transcript.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_transcript.custom_minimum_size = Vector2(0, 120) * ui_scale
	_transcript.focus_mode = Control.FOCUS_CLICK
	add_child(_transcript)

	_build_permission_panel()

	_context_label = Label.new()
	_context_label.clip_text = true
	_context_label.add_theme_color_override("font_color", _dim_color())
	_context_label.add_theme_font_size_override("font_size", _small_font_size())
	add_child(_context_label)

	var input_row := HBoxContainer.new()
	add_child(input_row)
	_prompt_box = TextEdit.new()
	_prompt_box.placeholder_text = "Ask Claude… (Enter to send)"
	_prompt_box.tooltip_text = "Enter sends, Shift+Enter adds a new line"
	_prompt_box.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_prompt_box.custom_minimum_size = Vector2(0, 90) * ui_scale
	_prompt_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prompt_box.gui_input.connect(_on_prompt_gui_input)
	input_row.add_child(_prompt_box)

	_send_button = Button.new()
	_send_button.text = "Send"
	_send_button.pressed.connect(_send_current)
	input_row.add_child(_send_button)

	_context_timer = Timer.new()
	_context_timer.wait_time = 1.0
	_context_timer.autostart = true
	_context_timer.timeout.connect(_update_context_label)
	add_child(_context_timer)


func _build_permission_panel() -> void:
	_permission_panel = PanelContainer.new()
	_permission_panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = _accent_color().darkened(0.6)
	style.border_color = _accent_color()
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	_permission_panel.add_theme_stylebox_override("panel", style)
	add_child(_permission_panel)

	var box := VBoxContainer.new()
	_permission_panel.add_child(box)
	_permission_title = Label.new()
	_permission_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_permission_title)
	_permission_detail = Label.new()
	_permission_detail.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_permission_detail.add_theme_font_override("font", get_theme_font("source", "EditorFonts"))
	_permission_detail.add_theme_font_size_override("font_size", _small_font_size())
	_permission_detail.max_lines_visible = 14
	box.add_child(_permission_detail)

	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	var allow := Button.new()
	allow.text = "Allow"
	allow.pressed.connect(_answer_permission.bind(true, false))
	buttons.add_child(allow)
	var always := Button.new()
	always.text = "Allow for this chat"
	always.tooltip_text = "Don't ask again for this tool until you start a new chat"
	always.pressed.connect(_answer_permission.bind(true, true))
	buttons.add_child(always)
	var deny := Button.new()
	deny.text = "Deny"
	deny.pressed.connect(_answer_permission.bind(false, false))
	buttons.add_child(deny)


func _accent_color() -> Color:
	return get_theme_color("accent_color", "Editor") if has_theme_color("accent_color", "Editor") else Color(0.44, 0.73, 0.98)


func _dim_color() -> Color:
	return get_theme_color("font_disabled_color", "Editor") if has_theme_color("font_disabled_color", "Editor") else Color(0.6, 0.6, 0.6)


func _error_color() -> Color:
	return get_theme_color("error_color", "Editor") if has_theme_color("error_color", "Editor") else Color(1, 0.45, 0.45)


func _success_color() -> Color:
	return get_theme_color("success_color", "Editor") if has_theme_color("success_color", "Editor") else Color(0.45, 0.9, 0.55)


func _small_font_size() -> int:
	return int(12 * EditorInterface.get_editor_scale())


# ---------------------------------------------------------------- transcript

static func _escape(text: String) -> String:
	return text.replace("[", "[lb]")


func _append_line(bbcode: String) -> void:
	_close_assistant()
	_transcript.append_text(bbcode + "\n")


func _append_note(text: String, color: Color) -> void:
	_append_line("[color=#%s]%s[/color]" % [color.to_html(false), _escape(text)])


func _open_assistant() -> void:
	if _assistant_open:
		return
	_transcript.append_text("\n[b][color=#%s]Claude[/color][/b]\n" % _accent_color().to_html(false))
	_assistant_open = true


func _close_assistant() -> void:
	if _assistant_open:
		_transcript.append_text("\n")
		_assistant_open = false


func _show_welcome() -> void:
	_append_line("[b]Agent Dock[/b]")
	_append_note("Chat with Claude Code about your project, or ask for changes. It sees the open scene, selected nodes and script (toggle in ⋯). Choose how much it may do without asking in the menu above. Uses your own Claude Code login. Unofficial; not affiliated with Anthropic.", _dim_color())


# ---------------------------------------------------------------- sending

func _on_prompt_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER) and not event.shift_pressed:
			_prompt_box.accept_event()
			_send_current()


func _send_current() -> void:
	var text := _prompt_box.text.strip_edges()
	if text == "" or _busy:
		return
	if not _ensure_process():
		return

	if _get_setting(SETTING_SAVE, true):
		EditorInterface.save_all_scenes()
	_remember_scene_mtimes()

	var context := _editor_context() if _get_setting(SETTING_CONTEXT, true) else ""
	_close_assistant()
	_transcript.append_text("\n[b]You[/b]\n%s\n" % _escape(text))
	if context != "":
		_append_note("(with editor context: %s)" % _context_summary(), _dim_color())

	var sent := _claude.send({
		"type": "user",
		"message": {"role": "user", "content": context + text},
	})
	if not sent:
		_append_note("Could not reach Claude. Try again or start a new chat.", _error_color())
		return
	_prompt_box.text = ""
	_set_busy(true)


func _ensure_process() -> bool:
	if _claude.is_running() and not _restart_needed:
		return true
	if _claude.is_running():
		_claude.shutdown()
	_restart_needed = false

	var executable := ClaudeLocator.find(str(_get_setting(SETTING_PATH, "")))
	if executable == "":
		_append_note("Claude Code was not found on this computer.", _error_color())
		_append_note("Install it (https://claude.com/claude-code), run \"claude auth login\" once in a terminal, then try again. If it is installed in an unusual place, set Editor Settings > Agent Dock > Claude Path.", _dim_color())
		return false

	var args := PackedStringArray([
		"-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--verbose",
		"--include-partial-messages",
		"--permission-prompt-tool", "stdio",
		"--permission-mode", MODES[_mode_select.selected][1],
		"--append-system-prompt", SYSTEM_NOTE,
		"--allowedTools",
	])
	# Read-only Godot MCP tools never need approval (plugin and `claude mcp add` names)
	for tool in GODOT_READ_ONLY_TOOLS:
		args.append_array(["mcp__plugin_godot_godot__" + tool, "mcp__godot__" + tool])
	var model: String = MODELS[_model_select.selected][1]
	if model != "":
		args.append_array(["--model", model])
	if _session_id != "":
		args.append_array(["--resume", _session_id])

	_stderr_tail.clear()
	var error := _claude.start(executable, args)
	if error != OK:
		_append_note("Could not start Claude Code at %s (error %d)." % [executable, error], _error_color())
		return false
	_status.text = "Claude · starting…"
	return true


func _set_busy(busy: bool) -> void:
	_busy = busy
	_send_button.disabled = busy
	_stop_button.disabled = not busy
	if busy:
		_turn_started_msec = Time.get_ticks_msec()
		_status.text = "Claude · thinking…"
	else:
		_status.text = "Ready"


func _on_stop_pressed() -> void:
	if not _busy:
		return
	_hide_permission()
	_claude.stop()
	_append_note("Stopped.", _dim_color())


func _on_new_chat_pressed() -> void:
	_claude.shutdown()
	_session_id = ""
	_always_allowed.clear()
	_streamed_messages.clear()
	_hide_permission()
	_set_busy(false)
	_assistant_open = false
	_transcript.clear()
	_show_welcome()


func _on_mode_selected(index: int) -> void:
	_settings().set_setting(SETTING_MODE, MODES[index][1])
	_restart_needed = _claude.is_running()
	if _busy:
		_append_note("The new mode applies from your next message.", _dim_color())


func _on_model_selected(index: int) -> void:
	_settings().set_setting(SETTING_MODEL, MODELS[index][1])
	_restart_needed = _claude.is_running()


func _on_settings_menu(id: int) -> void:
	var popup := _settings_menu.get_popup()
	match id:
		0, 1:
			var index := popup.get_item_index(id)
			var checked := not popup.is_item_checked(index)
			popup.set_item_checked(index, checked)
			_settings().set_setting(SETTING_CONTEXT if id == 0 else SETTING_SAVE, checked)
			_update_context_label()
		2:
			_append_note("Open Editor > Editor Settings, search for \"Claude Path\" and pick the claude executable. Leave it empty to find it automatically.", _dim_color())


# ---------------------------------------------------------------- events from Claude

func _on_event(data: Dictionary) -> void:
	match str(data.get("type", "")):
		"system":
			if data.get("subtype") == "init":
				_session_id = str(data.get("session_id", _session_id))
				_status.text = "Claude · %s · thinking…" % str(data.get("model", ""))
				for server in data.get("mcp_servers", []):
					if str(server.get("name", "")).contains("godot") and server.get("status") in ["failed", "needs-auth"]:
						_append_note("Godot MCP tools are not connected (%s)." % str(server.get("status")), _dim_color())
		"stream_event":
			_on_stream_event(data)
		"assistant":
			_on_assistant_message(data)
		"user":
			_on_tool_results(data)
		"control_request":
			_on_control_request(data)
		"control_cancel_request":
			if str(data.get("request_id", "")) == _pending_request_id:
				_hide_permission()
		"result":
			_on_result(data)


func _on_stream_event(data: Dictionary) -> void:
	if data.get("parent_tool_use_id") != null:
		return
	var event: Dictionary = data.get("event", {})
	match str(event.get("type", "")):
		"message_start":
			_current_message_id = str(event.get("message", {}).get("id", ""))
		"content_block_delta":
			var delta: Dictionary = event.get("delta", {})
			if delta.get("type") == "text_delta":
				_open_assistant()
				_transcript.append_text(_escape(str(delta.get("text", ""))))
				_streamed_messages[_current_message_id] = true


func _on_assistant_message(data: Dictionary) -> void:
	var message: Dictionary = data.get("message", {})
	var nested := data.get("parent_tool_use_id") != null
	var streamed := _streamed_messages.has(str(message.get("id", "")))
	for block in message.get("content", []):
		match str(block.get("type", "")):
			"text":
				if not streamed and not nested:
					_open_assistant()
					_transcript.append_text(_escape(str(block.get("text", ""))))
					_close_assistant()
			"tool_use":
				_tool_names[str(block.get("id", ""))] = str(block.get("name", ""))
				if HIDDEN_TOOLS.has(str(block.get("name", ""))):
					continue
				var prefix := "    ↳ " if nested else "  → "
				_append_note(prefix + _describe_tool(str(block.get("name", "")), block.get("input", {})), _dim_color())
	if not nested:
		_status.text = "Claude · working…"


func _on_tool_results(data: Dictionary) -> void:
	var content = data.get("message", {}).get("content", [])
	if not content is Array:
		return
	for block in content:
		if block is Dictionary and block.get("type") == "tool_result" and block.get("is_error", false):
			var tool_label := _short_tool_name(str(_tool_names.get(str(block.get("tool_use_id", "")), "tool")))
			var text := _tool_result_text(block.get("content"))
			_append_note("  ✗ %s: %s" % [tool_label, text.left(200)], _error_color())


func _on_result(data: Dictionary) -> void:
	_close_assistant()
	_hide_permission()
	var seconds := float(data.get("duration_ms", Time.get_ticks_msec() - _turn_started_msec)) / 1000.0
	var text := str(data.get("result", ""))
	if text.contains("Not logged in"):
		# Claude already printed "Not logged in"; just say how to fix it
		_append_note("To fix: open a terminal and run  claude auth login  (one time), then send your message again.", _error_color())
	elif data.get("is_error", false):
		_append_note("Claude stopped with an error: %s" % text.left(300), _error_color())
	else:
		_append_note("done · %.1fs" % seconds, _dim_color())
	_set_busy(false)
	_refresh_editor()


func _on_stderr(text: String) -> void:
	_stderr_tail.append(text)
	if _stderr_tail.size() > 20:
		_stderr_tail.pop_front()


func _on_exited() -> void:
	if _busy:
		_close_assistant()
		_hide_permission()
		if not _stderr_tail.is_empty():
			_append_note("Claude exited: " + "\n".join(_stderr_tail.slice(-5)), _error_color())
		_set_busy(false)
		_refresh_editor()


# ---------------------------------------------------------------- permissions

func _on_control_request(data: Dictionary) -> void:
	var request: Dictionary = data.get("request", {})
	var request_id := str(data.get("request_id", ""))
	if request.get("subtype") != "can_use_tool":
		# Not something the dock handles; answer so Claude doesn't wait forever
		_claude.send({"type": "control_response", "response": {"subtype": "error", "request_id": request_id, "error": "Not supported by the Godot dock"}})
		return

	var tool := str(request.get("tool_name", ""))
	var input: Dictionary = request.get("input", {})
	if _always_allowed.has(tool):
		_reply_permission(request_id, true, input)
		return

	_pending_request_id = request_id
	_pending_tool = tool
	_pending_input = input
	_permission_title.text = "Claude wants to: " + _describe_tool(tool, input)
	_permission_detail.text = _permission_preview(tool, input)
	_permission_detail.visible = _permission_detail.text != ""
	_permission_panel.visible = true
	_status.text = "Claude · waiting for you"


func _answer_permission(allow: bool, remember: bool) -> void:
	if _pending_request_id == "":
		return
	if allow and remember:
		_always_allowed[_pending_tool] = true
	_reply_permission(_pending_request_id, allow, _pending_input)
	_append_note("  %s %s" % ["✓ allowed" if allow else "✗ denied", _short_tool_name(_pending_tool)], _success_color() if allow else _error_color())
	_hide_permission()
	_status.text = "Claude · working…"


func _reply_permission(request_id: String, allow: bool, input: Dictionary) -> void:
	var decision := {"behavior": "allow", "updatedInput": input} if allow else {"behavior": "deny", "message": "The user denied this in the Godot dock."}
	_claude.send({
		"type": "control_response",
		"response": {"subtype": "success", "request_id": request_id, "response": decision},
	})


func _hide_permission() -> void:
	_pending_request_id = ""
	_pending_tool = ""
	_pending_input = {}
	if _permission_panel:
		_permission_panel.visible = false


# ---------------------------------------------------------------- describing tools

static func _short_tool_name(tool: String) -> String:
	if tool.begins_with("mcp__"):
		var parts := tool.split("__")
		return "%s: %s" % [parts[1].trim_prefix("plugin_").trim_suffix("_godot"), parts[parts.size() - 1]]
	return tool


func _project_relative(path: String) -> String:
	var root := ProjectSettings.globalize_path("res://").replace("\\", "/")
	var normalized := path.replace("\\", "/")
	if normalized.to_lower().begins_with(root.to_lower()):
		return "res://" + normalized.substr(root.length())
	return normalized


func _describe_tool(tool: String, input: Dictionary) -> String:
	if tool.begins_with("mcp__"):
		var args := []
		for key in input:
			if key != "projectPath":
				args.append("%s=%s" % [key, str(input[key]).left(60)])
		return _short_tool_name(tool) + (" (" + ", ".join(args) + ")" if not args.is_empty() else "")
	match tool:
		"Bash", "PowerShell":
			return "run a command: " + str(input.get("command", "")).left(200)
		"Write":
			return "write " + _project_relative(str(input.get("file_path", "")))
		"Edit", "MultiEdit":
			return "edit " + _project_relative(str(input.get("file_path", "")))
		"Read":
			return "read " + _project_relative(str(input.get("file_path", "")))
		"Glob", "Grep":
			return "%s %s" % [tool.to_lower(), str(input.get("pattern", ""))]
		"WebFetch":
			return "fetch " + str(input.get("url", ""))
		"WebSearch":
			return "search the web: " + str(input.get("query", ""))
		"TodoWrite":
			return "update its task list"
		_:
			return "%s %s" % [tool, JSON.stringify(input).left(160)]


func _permission_preview(tool: String, input: Dictionary) -> String:
	match tool:
		"Edit":
			return _diff_preview(str(input.get("old_string", "")), str(input.get("new_string", "")))
		"MultiEdit":
			var parts := []
			for edit in input.get("edits", []):
				parts.append(_diff_preview(str(edit.get("old_string", "")), str(edit.get("new_string", ""))))
			return "\n…\n".join(parts)
		"Write":
			var lines := str(input.get("content", "")).split("\n")
			var shown := "\n".join(lines.slice(0, 12))
			return shown + ("\n… (%d lines)" % lines.size() if lines.size() > 12 else "")
		"Bash", "PowerShell":
			return str(input.get("command", "")).left(800)
	return ""


static func _diff_preview(old_text: String, new_text: String) -> String:
	var out := []
	for line in old_text.split("\n").slice(0, 6):
		out.append("- " + line)
	for line in new_text.split("\n").slice(0, 6):
		out.append("+ " + line)
	return "\n".join(out)


static func _tool_result_text(content: Variant) -> String:
	if content is String:
		return content
	if content is Array:
		var texts := []
		for part in content:
			if part is Dictionary and part.get("type") == "text":
				texts.append(str(part.get("text", "")))
		return " ".join(texts)
	return str(content)


# ---------------------------------------------------------------- editor context

func _editor_context() -> String:
	var lines := []
	lines.append("Project folder: " + ProjectSettings.globalize_path("res://"))
	if _main_screen != "":
		lines.append("Active editor screen: " + _main_screen)
	var root := EditorInterface.get_edited_scene_root()
	if root:
		lines.append("Open scene: %s (root node \"%s\", %s)" % [root.scene_file_path, root.name, root.get_class()])
		var selected := EditorInterface.get_selection().get_selected_nodes()
		if not selected.is_empty():
			var names := []
			for node in selected.slice(0, 20):
				names.append("%s (%s)" % [str(root.get_path_to(node)), node.get_class()])
			lines.append("Selected nodes: " + ", ".join(names))
	var script_editor := EditorInterface.get_script_editor()
	var script := script_editor.get_current_script()
	if script and script.resource_path != "":
		var where := ""
		var selected_code := ""
		var current := script_editor.get_current_editor()
		if current:
			var code := current.get_base_editor()
			if code is TextEdit:
				where = ", cursor on line %d" % (code.get_caret_line() + 1)
				selected_code = code.get_selected_text()
		lines.append("Script open in the script editor: %s%s" % [script.resource_path, where])
		if selected_code != "":
			lines.append("Selected code:\n```gdscript\n%s\n```" % selected_code.left(4000))
	return "<godot_editor_context>\n%s\n</godot_editor_context>\n\n" % "\n".join(lines)


func _context_summary() -> String:
	var parts := []
	var root := EditorInterface.get_edited_scene_root()
	if root:
		parts.append(root.scene_file_path.get_file())
		var selected := EditorInterface.get_selection().get_selected_nodes()
		if selected.size() == 1:
			parts.append(selected[0].name)
		elif selected.size() > 1:
			parts.append("%d nodes" % selected.size())
	var script := EditorInterface.get_script_editor().get_current_script()
	if script and script.resource_path != "":
		var label := script.resource_path.get_file()
		var current := EditorInterface.get_script_editor().get_current_editor()
		if current and current.get_base_editor() is TextEdit:
			label += ":%d" % (current.get_base_editor().get_caret_line() + 1)
		parts.append(label)
	return " · ".join(parts) if not parts.is_empty() else "no scene or script open"


func _update_context_label() -> void:
	if not is_visible_in_tree():
		return
	if _get_setting(SETTING_CONTEXT, true):
		_context_label.text = "Context: " + _context_summary()
	else:
		_context_label.text = "Editor context off"


# ---------------------------------------------------------------- keeping the editor in sync

func _remember_scene_mtimes() -> void:
	_scene_mtimes.clear()
	for path in EditorInterface.get_open_scenes():
		_scene_mtimes[path] = FileAccess.get_modified_time(path)


func _refresh_editor() -> void:
	EditorInterface.get_resource_filesystem().scan()
	for path in _scene_mtimes:
		if FileAccess.file_exists(path) and FileAccess.get_modified_time(path) != _scene_mtimes[path]:
			EditorInterface.reload_scene_from_path(path)
			_append_note("Reloaded %s (changed by Claude)." % path, _dim_color())
	_scene_mtimes.clear()
