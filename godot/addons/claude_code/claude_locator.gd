@tool
extends RefCounted
## Finds the Claude Code command-line program on this computer.


static func find(custom_path: String = "") -> String:
	if custom_path != "" and FileAccess.file_exists(custom_path):
		return custom_path

	var candidates: Array[String] = []
	if OS.get_name() == "Windows":
		var appdata := OS.get_environment("APPDATA")
		var home := OS.get_environment("USERPROFILE")
		# npm install -g puts a .cmd shim on PATH; the real program sits next to it
		candidates.append(appdata.path_join("npm/node_modules/@anthropic-ai/claude-code/bin/claude.exe"))
		# Native installer
		candidates.append(home.path_join(".local/bin/claude.exe"))
		var output := []
		if OS.execute("where.exe", ["claude"], output) == 0 and not output.is_empty():
			for line in str(output[0]).split("\n"):
				var path := line.strip_edges()
				if path.ends_with(".exe"):
					candidates.append(path)
				elif path.ends_with(".cmd"):
					var from_shim := _exe_from_cmd_shim(path)
					if from_shim != "":
						candidates.append(from_shim)
	else:
		var home := OS.get_environment("HOME")
		var output := []
		if OS.execute("/bin/sh", ["-lc", "command -v claude"], output) == 0 and not output.is_empty():
			candidates.append(str(output[0]).strip_edges())
		candidates.append_array([
			home.path_join(".local/bin/claude"),
			home.path_join(".claude/local/claude"),
			"/opt/homebrew/bin/claude",
			"/usr/local/bin/claude",
			"/usr/bin/claude",
		])

	for candidate in candidates:
		if candidate != "" and FileAccess.file_exists(candidate):
			return candidate
	return ""


## npm's claude.cmd ends with a line like: "%dp0%\node_modules\...\claude.exe" %*
static func _exe_from_cmd_shim(cmd_path: String) -> String:
	var text := FileAccess.get_file_as_string(cmd_path)
	var regex := RegEx.create_from_string("%dp0%\\\\([^\"]*claude\\.exe)")
	var found := regex.search(text)
	if found == null:
		return ""
	return cmd_path.get_base_dir().path_join(found.get_string(1).replace("\\", "/"))
