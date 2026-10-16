@tool
extends EditorPlugin

const TerminalPanel := preload("res://addons/agent_terminal/terminal_panel.gd")

var _panel: TerminalPanel
## Godot 4.6+ wraps docks in an EditorDock; older versions use the bottom panel API.
var _editor_dock: Node


func _enter_tree() -> void:
	_panel = TerminalPanel.new()
	_panel.name = "Terminal"
	if ClassDB.class_exists("EditorDock"):
		_editor_dock = ClassDB.instantiate("EditorDock")
		_editor_dock.set("title", "Terminal")
		_editor_dock.set("layout_key", "agent_terminal")
		_editor_dock.set("default_slot", ClassDB.class_get_integer_constant("EditorDock", "DOCK_SLOT_BOTTOM"))
		_editor_dock.add_child(_panel)
		call("add_dock", _editor_dock)
	else:
		add_control_to_bottom_panel(_panel, "Terminal")


func _exit_tree() -> void:
	if not is_instance_valid(_panel):
		return
	_panel.shutdown()
	if _editor_dock:
		call("remove_dock", _editor_dock)
		_editor_dock.queue_free()
		_editor_dock = null
	else:
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
	_panel = null
