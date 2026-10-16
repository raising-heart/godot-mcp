@tool
extends EditorPlugin

const AgentDock := preload("res://addons/agent_dock/agent_dock.gd")

var _dock: AgentDock
## Godot 4.6+ wraps docks in an EditorDock; older versions take the control directly.
var _editor_dock: Node


func _enter_tree() -> void:
	_dock = AgentDock.new()
	_dock.name = "Agent"
	if ClassDB.class_exists("EditorDock"):
		_editor_dock = ClassDB.instantiate("EditorDock")
		_editor_dock.set("title", "Agent")
		_editor_dock.set("layout_key", "agent_dock")
		_editor_dock.set("default_slot", DOCK_SLOT_RIGHT_UL)
		_editor_dock.add_child(_dock)
		call("add_dock", _editor_dock)
	else:
		add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	main_screen_changed.connect(_dock.set_main_screen)


func _exit_tree() -> void:
	if not is_instance_valid(_dock):
		return
	_dock.shutdown()
	if _editor_dock:
		call("remove_dock", _editor_dock)
		_editor_dock.queue_free()
		_editor_dock = null
	else:
		remove_control_from_docks(_dock)
		_dock.queue_free()
	_dock = null
