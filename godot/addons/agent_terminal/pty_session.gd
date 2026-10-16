@tool
extends RefCounted
## Runs a shell inside a Windows pseudo console through pty_host.exe.
## pty_host.exe is compiled on first use from pty_host.cs (next to this file)
## with the C# compiler that comes with Windows, and cached by source hash.

signal output(data: PackedByteArray)
signal exited(exit_code: int)

const SOURCE := "res://addons/agent_terminal/pty_host.cs"

var _pid := -1
var _stdio: FileAccess
var _stderr: FileAccess
var _threads: Array[Thread] = []
var _mutex := Mutex.new()
var _chunks: Array[PackedByteArray] = []
var _errors := PackedStringArray()
var _readers_done := 0
var _running := false


func is_running() -> bool:
	return _running


## Starts `command` (e.g. "powershell.exe -NoLogo") in `cwd`. Returns "" or an error message.
func start(cwd: String, cols: int, rows: int, command: String) -> String:
	if OS.get_name() != "Windows":
		return "Agent Terminal currently works on Windows only."
	if _running:
		return "Already running."
	var host := _ensure_host()
	if host.begins_with("ERROR:"):
		return host.trim_prefix("ERROR:")

	var info := OS.execute_with_pipe(host, [_windows_dir_arg(cwd), str(cols), str(rows), command], true)
	if info.is_empty():
		return "Could not start the console helper (%s)." % host
	_pid = info.pid
	_stdio = info.stdio
	_stderr = info.stderr
	_readers_done = 0
	_errors.clear()
	_running = true
	for stream in [_stdio, _stderr]:
		var thread := Thread.new()
		thread.start(_read.bind(stream, stream == _stderr))
		_threads.append(thread)
	return ""


func write(data: PackedByteArray) -> void:
	if _running and _stdio and not data.is_empty():
		_stdio.store_buffer(data)
		_stdio.flush()


func resize(cols: int, rows: int) -> void:
	write(("\u001b]7777;%d;%d\u0007" % [cols, rows]).to_ascii_buffer())


## Call every frame: delivers output and notices when the shell has exited.
func poll() -> void:
	_mutex.lock()
	var chunks := _chunks.duplicate()
	_chunks.clear()
	var done := _readers_done
	_mutex.unlock()
	for chunk in chunks:
		output.emit(chunk)
	if _running and done >= 2:
		_join()
		_running = false
		var code := OS.get_process_exit_code(_pid) if _pid > 0 else -1
		_pid = -1
		exited.emit(code)


func error_text() -> String:
	return "\n".join(_errors)


func stop() -> void:
	if _running and _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_join()
	_running = false
	_pid = -1


func _join() -> void:
	for thread in _threads:
		if thread.is_started():
			thread.wait_to_finish()
	_threads.clear()


func _read(file: FileAccess, is_stderr: bool) -> void:
	while true:
		var data := file.get_buffer(65536)
		if not data.is_empty():
			_mutex.lock()
			if is_stderr:
				_errors.append(data.get_string_from_utf8().strip_edges())
			else:
				_chunks.append(data)
			_mutex.unlock()
		elif file.get_error() != OK and not OS.is_process_running(_pid):
			break
		else:
			OS.delay_msec(5)
	_mutex.lock()
	_readers_done += 1
	_mutex.unlock()


## A path argument must not end with a backslash, or Windows reads the closing quote as escaped.
static func _windows_dir_arg(path: String) -> String:
	var windows := path.replace("/", "\\")
	if windows.ends_with("\\"):
		windows = windows.trim_suffix("\\")
	if windows.ends_with(":"):
		windows += "\\."
	return windows


## Returns the path of pty_host.exe, compiling it first if needed, or "ERROR:<message>".
static func _ensure_host() -> String:
	var source := FileAccess.get_file_as_string(SOURCE)
	if source == "":
		return "ERROR:Missing %s." % SOURCE
	var dir := EditorInterface.get_editor_paths().get_data_dir().path_join("agent_terminal")
	DirAccess.make_dir_recursive_absolute(dir)
	var exe := dir.path_join("pty_host-%s.exe" % source.md5_text().left(12))
	if FileAccess.file_exists(exe):
		return exe

	var windir := OS.get_environment("WINDIR")
	var compiler := ""
	for candidate in [
		windir.path_join("Microsoft.NET/Framework64/v4.0.30319/csc.exe"),
		windir.path_join("Microsoft.NET/Framework/v4.0.30319/csc.exe"),
	]:
		if FileAccess.file_exists(candidate):
			compiler = candidate
			break
	if compiler == "":
		return "ERROR:The C# compiler that ships with Windows (.NET Framework 4, csc.exe) was not found."

	var out := []
	var code := OS.execute(compiler, [
		"-nologo", "-optimize+", "-target:exe",
		"-out:" + exe.replace("/", "\\"),
		ProjectSettings.globalize_path(SOURCE).replace("/", "\\"),
	], out, true)
	if code != 0 or not FileAccess.file_exists(exe):
		return "ERROR:Compiling the console helper failed:\n%s" % "\n".join(out)
	return exe
