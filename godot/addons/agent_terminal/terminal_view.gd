@tool
extends Control
## Draws a TerminalBuffer and turns keyboard/mouse input into terminal bytes.

signal input_bytes(data: PackedByteArray)
signal grid_resized(cols: int, rows: int)

const TerminalBuffer := preload("res://addons/agent_terminal/terminal_buffer.gd")

## Windows Terminal "Campbell" palette for the 16 basic colours
const PALETTE_16 := [
	Color8(12, 12, 12), Color8(197, 15, 31), Color8(19, 161, 14), Color8(193, 156, 0),
	Color8(0, 55, 218), Color8(136, 23, 152), Color8(58, 150, 221), Color8(204, 204, 204),
	Color8(118, 118, 118), Color8(231, 72, 86), Color8(22, 198, 12), Color8(249, 241, 165),
	Color8(59, 120, 255), Color8(180, 0, 158), Color8(97, 214, 214), Color8(242, 242, 242),
]
const DEFAULT_FG := Color8(204, 204, 204)
const DEFAULT_BG := Color8(24, 24, 24)
const SELECTION := Color(0.3, 0.5, 0.9, 0.45)

var buffer: TerminalBuffer
var font: Font
var font_size := 14
var scroll_offset := 0  ## lines scrolled back from the bottom

var _cell := Vector2(8, 16)
var _ascent := 12.0
var _bold_font: FontVariation
var _italic_font: FontVariation
var _drawn_revision := -1
var _last_grid := Vector2i.ZERO
var _selecting := false
var _sel_start := Vector2i(-1, -1)
var _sel_end := Vector2i(-1, -1)
var _menu: PopupMenu
var _palette_256: Array[Color] = []


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	clip_contents = true
	mouse_default_cursor_shape = Control.CURSOR_IBEAM
	_build_palette()
	_menu = PopupMenu.new()
	_menu.add_item("Copy", 0)
	_menu.add_item("Paste", 1)
	_menu.add_separator()
	_menu.add_item("Select all", 2)
	_menu.add_item("Clear scrollback", 3)
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	update_font()


func update_font() -> void:
	font = get_theme_font("source", "EditorFonts") if has_theme_font("source", "EditorFonts") else get_theme_default_font()
	if has_theme_font_size("source_size", "EditorFonts"):
		font_size = get_theme_font_size("source_size", "EditorFonts")
	_bold_font = FontVariation.new()
	_bold_font.base_font = font
	_bold_font.variation_embolden = 0.7
	_italic_font = FontVariation.new()
	_italic_font.base_font = font
	_italic_font.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.2, 1), Vector2.ZERO)
	_cell = Vector2(font.get_string_size("M", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x, font.get_height(font_size)).ceil()
	_ascent = font.get_ascent(font_size)
	_check_grid()
	queue_redraw()


func _process(_delta: float) -> void:
	if buffer and buffer.revision != _drawn_revision:
		queue_redraw()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			_check_grid()
		NOTIFICATION_FOCUS_ENTER, NOTIFICATION_FOCUS_EXIT:
			if buffer and buffer.focus_events:
				input_bytes.emit(("\u001b[I" if what == NOTIFICATION_FOCUS_ENTER else "\u001b[O").to_ascii_buffer())
			queue_redraw()
		NOTIFICATION_THEME_CHANGED:
			if is_inside_tree():
				update_font()


func grid_size() -> Vector2i:
	return Vector2i(maxi(10, int(size.x / _cell.x)), maxi(3, int(size.y / _cell.y)))


func _check_grid() -> void:
	var grid := grid_size()
	if grid != _last_grid and size.x > 0 and size.y > 0:
		_last_grid = grid
		grid_resized.emit(grid.x, grid.y)


# ---------------------------------------------------------------- drawing

func _build_palette() -> void:
	_palette_256.clear()
	_palette_256.append_array(PALETTE_16)
	var steps := [0, 95, 135, 175, 215, 255]
	for r in 6:
		for g in 6:
			for b in 6:
				_palette_256.append(Color8(steps[r], steps[g], steps[b]))
	for i in 24:
		var v := 8 + i * 10
		_palette_256.append(Color8(v, v, v))


func _color(value: int, fallback: Color) -> Color:
	if value == TerminalBuffer.DEFAULT:
		return fallback
	if value & TerminalBuffer.TRUECOLOR:
		return Color8((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff)
	return _palette_256[value] if value < _palette_256.size() else fallback


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), DEFAULT_BG)
	if buffer == null:
		return
	_drawn_revision = buffer.revision
	var first := buffer.line_count() - buffer.rows - scroll_offset
	var sel := _normalized_selection()

	for row in buffer.rows:
		var index := first + row
		if index < 0:
			continue
		var line: TerminalBuffer.Line = buffer.get_line(index)
		var y := row * _cell.y
		var x := 0
		while x < buffer.cols:
			var flags := line.flags[x]
			if flags & TerminalBuffer.WIDE_TAIL:
				x += 1
				continue
			var width := 2 if x + 1 < buffer.cols and line.flags[x + 1] & TerminalBuffer.WIDE_TAIL else 1
			var fg := _color(line.fg[x], DEFAULT_FG)
			var bg := _color(line.bg[x], DEFAULT_BG)
			if flags & TerminalBuffer.BOLD and line.fg[x] >= 0 and line.fg[x] < 8:
				fg = PALETTE_16[line.fg[x] + 8]
			if flags & TerminalBuffer.INVERSE:
				var swap := fg
				fg = bg
				bg = swap
			if flags & TerminalBuffer.DIM:
				fg.a = 0.6
			var cell_rect := Rect2(Vector2(x * _cell.x, y), Vector2(_cell.x * width, _cell.y))
			if bg != DEFAULT_BG:
				draw_rect(cell_rect, bg)
			if not sel.is_empty() and _in_selection(sel, index, x):
				draw_rect(cell_rect, SELECTION)
			var ch := line.chars[x]
			if ch != " " and ch != "" and not flags & TerminalBuffer.HIDDEN:
				var draw_font: Font = _bold_font if flags & TerminalBuffer.BOLD else (_italic_font if flags & TerminalBuffer.ITALIC else font)
				draw_string(draw_font, Vector2(x * _cell.x, y + _ascent), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, fg)
			if flags & TerminalBuffer.UNDERLINE:
				draw_line(Vector2(x * _cell.x, y + _cell.y - 1), Vector2((x + width) * _cell.x, y + _cell.y - 1), fg)
			if flags & TerminalBuffer.STRIKE:
				draw_line(Vector2(x * _cell.x, y + _cell.y / 2), Vector2((x + width) * _cell.x, y + _cell.y / 2), fg)
			x += width

	# Cursor
	if scroll_offset == 0 and buffer.cursor_visible:
		var rect := Rect2(Vector2(buffer.cursor_x * _cell.x, buffer.cursor_y * _cell.y), _cell)
		if has_focus():
			draw_rect(rect, Color(DEFAULT_FG, 0.75))
			var line: TerminalBuffer.Line = buffer.get_line(buffer.screen_start() + buffer.cursor_y)
			var ch := line.chars[buffer.cursor_x]
			if ch != " " and ch != "":
				draw_string(font, Vector2(rect.position.x, rect.position.y + _ascent), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, DEFAULT_BG)
		else:
			draw_rect(rect, Color(DEFAULT_FG, 0.6), false, 1.0)

	if scroll_offset > 0:
		var note := " ↑ %d lines up · scroll down or type to return " % scroll_offset
		var note_size := font.get_string_size(note, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		var pos := Vector2(size.x - note_size.x - 6, 4)
		draw_rect(Rect2(pos - Vector2(0, 2), note_size + Vector2(0, 4)), Color(0.2, 0.35, 0.6, 0.9))
		draw_string(font, pos + Vector2(0, _ascent), note, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


# ---------------------------------------------------------------- selection

func _cell_at(pos: Vector2) -> Vector2i:
	var col := clampi(int(pos.x / _cell.x), 0, buffer.cols - 1)
	var row := clampi(int(pos.y / _cell.y), 0, buffer.rows - 1)
	return Vector2i(col, buffer.line_count() - buffer.rows - scroll_offset + row)


func _normalized_selection() -> Array:
	if _sel_start.y < 0 or _sel_start == _sel_end:
		return []
	var a := _sel_start
	var b := _sel_end
	if b.y < a.y or (b.y == a.y and b.x < a.x):
		var swap := a
		a = b
		b = swap
	return [a, b]


func _in_selection(sel: Array, line: int, col: int) -> bool:
	var a: Vector2i = sel[0]
	var b: Vector2i = sel[1]
	if line < a.y or line > b.y:
		return false
	if line == a.y and col < a.x:
		return false
	if line == b.y and col >= b.x:
		return false
	return true


func has_selection() -> bool:
	return not _normalized_selection().is_empty()


func copy_selection() -> void:
	var sel := _normalized_selection()
	if sel.is_empty():
		return
	var end: Vector2i = sel[1]
	DisplayServer.clipboard_set(buffer.text_between(sel[0], Vector2i(end.x - 1, end.y)))


func clear_selection() -> void:
	_sel_start = Vector2i(-1, -1)
	_sel_end = _sel_start
	queue_redraw()


func paste() -> void:
	var text := DisplayServer.clipboard_get()
	if text == "":
		return
	text = text.replace("\r\n", "\r").replace("\n", "\r")
	if buffer.bracketed_paste:
		text = "\u001b[200~" + text + "\u001b[201~"
	_send(text)


func _on_menu(id: int) -> void:
	match id:
		0:
			copy_selection()
		1:
			paste()
		2:
			_sel_start = Vector2i(0, 0)
			_sel_end = Vector2i(buffer.cols, buffer.line_count() - 1)
			queue_redraw()
		3:
			buffer.clear_scrollback()
			scroll_offset = 0
			clear_selection()


# ---------------------------------------------------------------- input

func _send(text: String) -> void:
	scroll_offset = 0
	input_bytes.emit(text.to_utf8_buffer())


func _gui_input(event: InputEvent) -> void:
	if buffer == null:
		return
	if event is InputEventMouseButton:
		_mouse_button(event)
	elif event is InputEventMouseMotion and _selecting:
		_sel_end = _cell_at(event.position)
		queue_redraw()
		accept_event()
	elif event is InputEventKey and event.pressed:
		if _key(event):
			accept_event()


func _mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not event.pressed:
			return
		var up := event.button_index == MOUSE_BUTTON_WHEEL_UP
		if buffer.alt_screen:
			# Full-screen apps scroll with the arrow keys
			for i in 3:
				_send(_arrow("A" if up else "B"))
		else:
			scroll_offset = clampi(scroll_offset + (3 if up else -3), 0, buffer.scrollback.size())
			queue_redraw()
		accept_event()
	elif event.button_index == MOUSE_BUTTON_LEFT:
		grab_focus()
		if event.pressed:
			if event.double_click:
				_select_word(_cell_at(event.position))
			else:
				_selecting = true
				_sel_start = _cell_at(event.position)
				_sel_end = _sel_start
		else:
			_selecting = false
		queue_redraw()
		accept_event()
	elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		grab_focus()
		_menu.set_item_disabled(0, not has_selection())
		_menu.popup(Rect2i(Vector2i(get_screen_position() + event.position), Vector2i.ZERO))
		accept_event()


func _select_word(at: Vector2i) -> void:
	var line: TerminalBuffer.Line = buffer.get_line(at.y)
	var is_word := func(x: int) -> bool: return line.chars[x].strip_edges() != "" and not line.chars[x] in ["\"", "'", "(", ")", "[", "]", "<", ">", ","]
	if not is_word.call(at.x):
		return
	var a := at.x
	var b := at.x
	while a > 0 and is_word.call(a - 1):
		a -= 1
	while b < buffer.cols - 1 and is_word.call(b + 1):
		b += 1
	_sel_start = Vector2i(a, at.y)
	_sel_end = Vector2i(b + 1, at.y)


func _arrow(letter: String) -> String:
	return ("\u001bO" if buffer.app_cursor_keys else "\u001b[") + letter


func _key(event: InputEventKey) -> bool:
	var ctrl := event.ctrl_pressed
	var shift := event.shift_pressed
	var alt := event.alt_pressed
	var key := event.keycode

	# Clipboard: Ctrl+Shift+C/V, Ctrl+V, Shift+Insert, and Ctrl+C when text is selected
	if ctrl and shift and key == KEY_C:
		copy_selection()
		return true
	if (ctrl and key == KEY_V) or (shift and key == KEY_INSERT):
		paste()
		return true
	if ctrl and not shift and key == KEY_C and has_selection():
		copy_selection()
		clear_selection()
		return true
	if shift and (key == KEY_PAGEUP or key == KEY_PAGEDOWN) and not buffer.alt_screen:
		scroll_offset = clampi(scroll_offset + (buffer.rows - 1) * (1 if key == KEY_PAGEUP else -1), 0, buffer.scrollback.size())
		queue_redraw()
		return true

	var modifier := 1 + (1 if shift else 0) + (2 if alt else 0) + (4 if ctrl else 0)
	var special := ""
	match key:
		KEY_ENTER, KEY_KP_ENTER:
			special = "\r"
		KEY_BACKSPACE:
			special = "\u0008" if ctrl else "\u007f"
		KEY_TAB:
			special = "\u001b[Z" if shift else "\t"
		KEY_ESCAPE:
			special = "\u001b"
		KEY_UP, KEY_DOWN, KEY_RIGHT, KEY_LEFT, KEY_HOME, KEY_END:
			var letter: String = {KEY_UP: "A", KEY_DOWN: "B", KEY_RIGHT: "C", KEY_LEFT: "D", KEY_HOME: "H", KEY_END: "F"}[key]
			special = ("\u001b[1;%d%s" % [modifier, letter]) if modifier > 1 else _arrow(letter)
		KEY_INSERT, KEY_DELETE, KEY_PAGEUP, KEY_PAGEDOWN:
			var number: int = {KEY_INSERT: 2, KEY_DELETE: 3, KEY_PAGEUP: 5, KEY_PAGEDOWN: 6}[key]
			special = ("\u001b[%d;%d~" % [number, modifier]) if modifier > 1 else ("\u001b[%d~" % number)
		KEY_F1, KEY_F2, KEY_F3, KEY_F4:
			special = "\u001bO" + "PQRS"[key - KEY_F1]
		KEY_F5, KEY_F6, KEY_F7, KEY_F8, KEY_F9, KEY_F10, KEY_F11, KEY_F12:
			var codes := [15, 17, 18, 19, 20, 21, 23, 24]
			special = "\u001b[%d~" % codes[key - KEY_F5]
	if special != "":
		if alt and special.length() == 1:
			special = "\u001b" + special
		_send(special)
		return true

	if ctrl and not alt:
		# Ctrl+letter and friends become control characters
		if key >= KEY_A and key <= KEY_Z:
			_send(char(key - KEY_A + 1))
			return true
		var controls := {KEY_SPACE: 0, KEY_BRACKETLEFT: 27, KEY_BACKSLASH: 28, KEY_BRACKETRIGHT: 29, KEY_6: 30, KEY_MINUS: 31}
		if controls.has(key):
			input_bytes.emit(PackedByteArray([controls[key]]))
			scroll_offset = 0
			return true

	if event.unicode > 0:
		var text := char(event.unicode)
		_send(("\u001b" + text) if alt else text)
		if has_selection():
			clear_selection()
		return true
	return false
