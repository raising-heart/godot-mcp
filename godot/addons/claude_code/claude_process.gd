@tool
extends RefCounted
## Runs `claude -p` in stream-json mode and turns its stdout into events.
## Reading happens on background threads; call poll() every frame to receive
## the events on the main thread.

signal event_received(data: Dictionary)
signal stderr_received(text: String)
signal exited

var _pid := -1
var _stdio: FileAccess
var _stderr: FileAccess
var _threads: Array[Thread] = []
var _mutex := Mutex.new()
var _queue: Array = []
var _readers_done := 0
var _running := false


func start(executable: String, arguments: PackedStringArray) -> Error:
	if _running:
		return ERR_ALREADY_IN_USE
	var info := OS.execute_with_pipe(executable, arguments, true)
	if info.is_empty():
		return FAILED
	_pid = info.pid
	_stdio = info.stdio
	_stderr = info.stderr
	_readers_done = 0
	_running = true
	_threads.clear()
	for pair in [[_stdio, "out"], [_stderr, "err"]]:
		var thread := Thread.new()
		thread.start(_read_lines.bind(pair[0], pair[1]))
		_threads.append(thread)
	return OK


func is_running() -> bool:
	return _running


## Send one JSON message on stdin.
func send(message: Dictionary) -> bool:
	if not _running or _stdio == null:
		return false
	_stdio.store_buffer((JSON.stringify(message) + "\n").to_utf8_buffer())
	_stdio.flush()
	return true


func stop() -> void:
	if _running and _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)


## Deliver queued output as signals. Call from _process().
func poll() -> void:
	_mutex.lock()
	var items := _queue.duplicate()
	_queue.clear()
	var done := _readers_done
	_mutex.unlock()

	for item in items:
		if item[0] == "out":
			var parsed = JSON.parse_string(item[1])
			if parsed is Dictionary:
				event_received.emit(parsed)
			else:
				stderr_received.emit(item[1])
		else:
			stderr_received.emit(item[1])

	if _running and done >= 2:
		_finish()


## Stop the process and wait for the reader threads. Safe to call twice.
func shutdown() -> void:
	stop()
	for thread in _threads:
		if thread.is_started():
			thread.wait_to_finish()
	_threads.clear()
	_running = false


func _finish() -> void:
	for thread in _threads:
		if thread.is_started():
			thread.wait_to_finish()
	_threads.clear()
	_running = false
	_pid = -1
	exited.emit()


func _read_lines(file: FileAccess, stream: String) -> void:
	while true:
		var line := file.get_line()
		var error := file.get_error()
		line = line.strip_edges()
		if line != "":
			_mutex.lock()
			_queue.append([stream, line])
			_mutex.unlock()
		if error != OK:
			break
	_mutex.lock()
	_readers_done += 1
	_mutex.unlock()
