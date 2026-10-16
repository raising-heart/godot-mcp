@tool
extends RefCounted
## The terminal's screen: parses the VT/xterm escape codes a shell writes
## and keeps the grid of characters, colours and the cursor.

signal reply(data: PackedByteArray)  ## answers to status queries, sent back to the shell
signal title_changed(title: String)
signal bell

const DEFAULT := -1                  ## colour slot meaning "theme default"
const TRUECOLOR := 0x1000000         ## flag bit for 24-bit colours (0x1RRGGBB)

const BOLD := 1
const DIM := 2
const ITALIC := 4
const UNDERLINE := 8
const INVERSE := 16
const WIDE_TAIL := 32                ## right half of a double-width character
const STRIKE := 64
const HIDDEN := 128

const MAX_SCROLLBACK := 5000

enum { GROUND, ESCAPE, ESCAPE_INTERMEDIATE, CSI, OSC, STRING }


class Line:
	var chars := PackedStringArray()
	var fg := PackedInt32Array()
	var bg := PackedInt32Array()
	var flags := PackedInt32Array()
	var wrapped := false

	func _init(width: int, background: int = -1) -> void:
		chars.resize(width)
		chars.fill(" ")
		fg.resize(width)
		fg.fill(-1)
		bg.resize(width)
		bg.fill(background)
		flags.resize(width)
		flags.fill(0)

	func resize(width: int) -> void:
		var old := chars.size()
		chars.resize(width)
		fg.resize(width)
		bg.resize(width)
		flags.resize(width)
		for i in range(old, width):
			chars[i] = " "
			fg[i] = -1
			bg[i] = -1
			flags[i] = 0

	func clear_range(from: int, to: int, background: int) -> void:
		for i in range(maxi(0, from), mini(to, chars.size())):
			chars[i] = " "
			fg[i] = -1
			bg[i] = background
			flags[i] = 0

	func text() -> String:
		var out := ""
		for i in chars.size():
			if flags[i] & WIDE_TAIL == 0:
				out += chars[i]
		return out


var cols := 80
var rows := 24
var scrollback: Array[Line] = []
var cursor_x := 0
var cursor_y := 0
var cursor_visible := true
var app_cursor_keys := false
var bracketed_paste := false
var focus_events := false
var alt_screen := false
var title := ""
## Bumped on every change, so the view knows when to redraw
var revision := 0

var _main: Array[Line] = []
var _alt: Array[Line] = []
var _lines: Array[Line] = []
var _fg := DEFAULT
var _bg := DEFAULT
var _flags := 0
var _pending_wrap := false
var _autowrap := true
var _insert_mode := false
var _scroll_top := 0
var _scroll_bottom := 23
var _saved := {}
var _saved_main := {}

var _state := GROUND
var _params := ""
var _intermediate := ""
var _osc := ""
var _string_escape := false
var _utf8_tail := PackedByteArray()


func _init(width: int = 80, height: int = 24) -> void:
	cols = width
	rows = height
	_main = _blank_screen()
	_alt = _blank_screen()
	_lines = _main
	_scroll_bottom = rows - 1
	_save_cursor(_saved)


func _blank_screen() -> Array[Line]:
	var screen: Array[Line] = []
	for i in rows:
		screen.append(Line.new(cols))
	return screen


# ---------------------------------------------------------------- public API

func line_count() -> int:
	return (0 if alt_screen else scrollback.size()) + rows


## Line by absolute index: scrollback first, then the screen.
func get_line(index: int) -> Line:
	var back := 0 if alt_screen else scrollback.size()
	if index < back:
		return scrollback[index]
	return _lines[clampi(index - back, 0, rows - 1)]


func screen_start() -> int:
	return 0 if alt_screen else scrollback.size()


func clear_scrollback() -> void:
	scrollback.clear()
	revision += 1


func resize(width: int, height: int) -> void:
	width = maxi(width, 2)
	height = maxi(height, 2)
	if width == cols and height == rows:
		return
	for screen in [_main, _alt]:
		for line in screen:
			line.resize(width)
	for line in scrollback:
		line.resize(width)

	if height < rows:
		# Keep the cursor on screen: move lines above it into the scrollback
		var excess := maxi(0, cursor_y - (height - 1))
		for i in excess:
			var top: Line = _main.pop_front()
			if not alt_screen:
				_push_scrollback(top)
			_alt.pop_front()
		while _main.size() > height:
			_main.pop_back()
		while _alt.size() > height:
			_alt.pop_back()
		cursor_y -= excess
	else:
		while _main.size() < height:
			_main.append(Line.new(width))
		while _alt.size() < height:
			_alt.append(Line.new(width))

	cols = width
	rows = height
	_lines = _alt if alt_screen else _main
	_scroll_top = 0
	_scroll_bottom = rows - 1
	cursor_x = clampi(cursor_x, 0, cols - 1)
	cursor_y = clampi(cursor_y, 0, rows - 1)
	_pending_wrap = false
	revision += 1


## Feed raw bytes from the shell.
func feed(data: PackedByteArray) -> void:
	if data.is_empty():
		return
	var bytes := _utf8_tail + data
	# Keep an incomplete UTF-8 sequence at the end for the next chunk
	var cut := bytes.size()
	for back in range(1, mini(4, bytes.size()) + 1):
		var b := bytes[bytes.size() - back]
		if b & 0xC0 == 0x80:
			continue
		if b & 0x80 == 0:
			break
		var needed := 2 if b & 0xE0 == 0xC0 else (3 if b & 0xF0 == 0xE0 else 4)
		if back < needed:
			cut = bytes.size() - back
		break
	_utf8_tail = bytes.slice(cut)
	var text := bytes.slice(0, cut).get_string_from_utf8()
	for i in text.length():
		_consume(text.unicode_at(i))
	revision += 1


## The selected text between two absolute (line, column) points.
func text_between(from: Vector2i, to: Vector2i) -> String:
	if to.y < from.y or (to.y == from.y and to.x < from.x):
		var swap := from
		from = to
		to = swap
	var parts := PackedStringArray()
	for y in range(from.y, to.y + 1):
		var line := get_line(y)
		var start := from.x if y == from.y else 0
		var end := to.x + 1 if y == to.y else cols
		var piece := ""
		for x in range(start, mini(end, cols)):
			if line.flags[x] & WIDE_TAIL == 0:
				piece += line.chars[x]
		piece = piece.rstrip(" ")
		if y < to.y and not line.wrapped:
			piece += "\n"
		parts.append(piece)
	return "".join(parts)


# ---------------------------------------------------------------- parser

func _consume(c: int) -> void:
	match _state:
		GROUND:
			if c < 0x20 or c == 0x7f:
				_control(c)
			else:
				_print(c)
		ESCAPE:
			_escape(c)
		ESCAPE_INTERMEDIATE:
			# Character set designation and similar: ESC ( B etc. Ignored.
			_state = GROUND
		CSI:
			if c >= 0x40 and c <= 0x7e:
				_state = GROUND
				_csi(char(c))
			elif c >= 0x20 and c <= 0x2f:
				_intermediate += char(c)
			elif c == 0x1b:
				_state = ESCAPE
			elif c >= 0x30 and c <= 0x3f:
				_params += char(c)
			elif c < 0x20:
				_control(c)
		OSC:
			if c == 0x07:
				_state = GROUND
				_osc_done()
			elif c == 0x1b:
				_string_escape = true
			elif _string_escape:
				_string_escape = false
				if c == 0x5c:  # ESC \ ends the string
					_state = GROUND
					_osc_done()
			elif _osc.length() < 4096:
				_osc += char(c)
		STRING:
			# DCS / SOS / PM / APC: ignored until the string terminator
			if c == 0x1b:
				_string_escape = true
			elif _string_escape:
				_string_escape = false
				if c == 0x5c:
					_state = GROUND


func _control(c: int) -> void:
	match c:
		0x07:
			bell.emit()
		0x08:
			if cursor_x > 0:
				cursor_x -= 1
			_pending_wrap = false
		0x09:
			cursor_x = mini(cols - 1, (cursor_x / 8 + 1) * 8)
		0x0a, 0x0b, 0x0c:
			_linefeed()
		0x0d:
			cursor_x = 0
			_pending_wrap = false
		0x1b:
			_state = ESCAPE


func _escape(c: int) -> void:
	_state = GROUND
	match char(c):
		"[":
			_state = CSI
			_params = ""
			_intermediate = ""
		"]":
			_state = OSC
			_osc = ""
			_string_escape = false
		"P", "X", "^", "_":
			_state = STRING
			_string_escape = false
		"(", ")", "*", "+", "#", "%":
			_state = ESCAPE_INTERMEDIATE
		"7":
			_save_cursor(_saved)
		"8":
			_restore_cursor(_saved)
		"D":
			_linefeed()
		"E":
			cursor_x = 0
			_linefeed()
		"M":
			_reverse_index()
		"c":
			_full_reset()
		"=", ">":
			pass


func _osc_done() -> void:
	var sep := _osc.find(";")
	if sep < 0:
		return
	var kind := _osc.substr(0, sep)
	if kind == "0" or kind == "2":
		title = _osc.substr(sep + 1)
		title_changed.emit(title)


func _int_params() -> PackedInt32Array:
	var result := PackedInt32Array()
	var raw := _params.trim_prefix("?").trim_prefix(">").trim_prefix("=")
	if raw == "":
		return result
	for part in raw.split(";"):
		var sub := part.split(":")[0]
		result.append(int(sub) if sub.is_valid_int() else 0)
	return result


func _p(params: PackedInt32Array, index: int, fallback: int) -> int:
	if index < params.size() and params[index] != 0:
		return params[index]
	return fallback


func _csi(final: String) -> void:
	var params := _int_params()
	var private := _params.begins_with("?")
	if _intermediate != "":
		# e.g. "CSI 2 SP q" (cursor shape), "CSI ! p" (soft reset)
		if _intermediate == "!" and final == "p":
			_soft_reset()
		return
	if _params.begins_with(">") or _params.begins_with("="):
		if final == "c":
			reply.emit("\u001b[>0;10;1c".to_utf8_buffer())
		return

	match final:
		"A":
			cursor_y = maxi(_top_limit(), cursor_y - _p(params, 0, 1))
		"B", "e":
			cursor_y = mini(_bottom_limit(), cursor_y + _p(params, 0, 1))
		"C", "a":
			cursor_x = mini(cols - 1, cursor_x + _p(params, 0, 1))
		"D":
			cursor_x = maxi(0, cursor_x - _p(params, 0, 1))
		"E":
			cursor_x = 0
			cursor_y = mini(_bottom_limit(), cursor_y + _p(params, 0, 1))
		"F":
			cursor_x = 0
			cursor_y = maxi(_top_limit(), cursor_y - _p(params, 0, 1))
		"G", "`":
			cursor_x = clampi(_p(params, 0, 1) - 1, 0, cols - 1)
		"H", "f":
			cursor_y = clampi(_p(params, 0, 1) - 1, 0, rows - 1)
			cursor_x = clampi(_p(params, 1, 1) - 1, 0, cols - 1)
		"d":
			cursor_y = clampi(_p(params, 0, 1) - 1, 0, rows - 1)
		"J":
			_erase_display(params[0] if params.size() > 0 else 0)
		"K":
			_erase_line(params[0] if params.size() > 0 else 0)
		"L":
			_insert_lines(_p(params, 0, 1))
		"M":
			_delete_lines(_p(params, 0, 1))
		"@":
			_insert_chars(_p(params, 0, 1))
		"P":
			_delete_chars(_p(params, 0, 1))
		"X":
			_lines[cursor_y].clear_range(cursor_x, cursor_x + _p(params, 0, 1), _bg)
		"S":
			for i in _p(params, 0, 1):
				_scroll_up()
		"T":
			for i in _p(params, 0, 1):
				_scroll_down()
		"r":
			var top := _p(params, 0, 1) - 1
			var bottom := _p(params, 1, rows) - 1
			if top < bottom and bottom < rows:
				_scroll_top = top
				_scroll_bottom = bottom
				cursor_x = 0
				cursor_y = 0
		"m":
			_sgr(params)
		"h", "l":
			_set_modes(params, private, final == "h")
		"s":
			if not private:
				_save_cursor(_saved)
		"u":
			if not private:
				_restore_cursor(_saved)
		"n":
			var kind := params[0] if params.size() > 0 else 0
			if kind == 5:
				reply.emit("\u001b[0n".to_utf8_buffer())
			elif kind == 6:
				reply.emit(("\u001b[%d;%dR" % [cursor_y + 1, cursor_x + 1]).to_utf8_buffer())
		"c":
			reply.emit("\u001b[?1;2c".to_utf8_buffer())
	_pending_wrap = false if final in ["A", "B", "C", "D", "E", "F", "G", "H", "f", "d", "`"] else _pending_wrap


func _top_limit() -> int:
	return _scroll_top if cursor_y >= _scroll_top else 0


func _bottom_limit() -> int:
	return _scroll_bottom if cursor_y <= _scroll_bottom else rows - 1


func _set_modes(params: PackedInt32Array, private: bool, on: bool) -> void:
	for mode in params:
		if not private:
			if mode == 4:
				_insert_mode = on
			continue
		match mode:
			1:
				app_cursor_keys = on
			7:
				_autowrap = on
			25:
				cursor_visible = on
			47, 1047:
				_switch_screen(on, false)
			1049:
				_switch_screen(on, true)
			1004:
				focus_events = on
			2004:
				bracketed_paste = on


func _switch_screen(to_alt: bool, save_cursor: bool) -> void:
	if to_alt == alt_screen:
		return
	if to_alt:
		if save_cursor:
			_save_cursor(_saved_main)
		_alt = _blank_screen()
		_lines = _alt
	else:
		_lines = _main
		if save_cursor:
			_restore_cursor(_saved_main)
	alt_screen = to_alt
	_scroll_top = 0
	_scroll_bottom = rows - 1


func _sgr(params: PackedInt32Array) -> void:
	if params.is_empty():
		params = PackedInt32Array([0])
	var i := 0
	while i < params.size():
		var p := params[i]
		match p:
			0:
				_fg = DEFAULT
				_bg = DEFAULT
				_flags = 0
			1:
				_flags |= BOLD
			2:
				_flags |= DIM
			3:
				_flags |= ITALIC
			4:
				_flags |= UNDERLINE
			7:
				_flags |= INVERSE
			8:
				_flags |= HIDDEN
			9:
				_flags |= STRIKE
			21, 22:
				_flags &= ~(BOLD | DIM)
			23:
				_flags &= ~ITALIC
			24:
				_flags &= ~UNDERLINE
			27:
				_flags &= ~INVERSE
			28:
				_flags &= ~HIDDEN
			29:
				_flags &= ~STRIKE
			39:
				_fg = DEFAULT
			49:
				_bg = DEFAULT
			38, 48:
				var color := DEFAULT
				if i + 2 < params.size() and params[i + 1] == 5:
					color = params[i + 2]
					i += 2
				elif i + 4 < params.size() and params[i + 1] == 2:
					color = TRUECOLOR | (params[i + 2] << 16) | (params[i + 3] << 8) | params[i + 4]
					i += 4
				if p == 38:
					_fg = color
				else:
					_bg = color
			_:
				if p >= 30 and p <= 37:
					_fg = p - 30
				elif p >= 40 and p <= 47:
					_bg = p - 40
				elif p >= 90 and p <= 97:
					_fg = p - 90 + 8
				elif p >= 100 and p <= 107:
					_bg = p - 100 + 8
		i += 1


# ---------------------------------------------------------------- screen operations

func _print(c: int) -> void:
	var width := char_width(c)
	if width == 0:
		# Combining mark / variation selector: attach to the previous cell
		var x := cursor_x - (0 if _pending_wrap else 1)
		if x >= 0:
			var line := _lines[cursor_y]
			if line.flags[x] & WIDE_TAIL and x > 0:
				x -= 1
			line.chars[x] = line.chars[x] + char(c)
		return

	if _pending_wrap and _autowrap:
		_lines[cursor_y].wrapped = true
		cursor_x = 0
		_linefeed()
	_pending_wrap = false

	if width == 2 and cursor_x == cols - 1:
		if not _autowrap:
			return
		_lines[cursor_y].clear_range(cursor_x, cols, _bg)
		_lines[cursor_y].wrapped = true
		cursor_x = 0
		_linefeed()

	var line := _lines[cursor_y]
	if _insert_mode:
		_shift_right(line, cursor_x, width)
	# Overwriting half of a wide character clears the other half
	if line.flags[cursor_x] & WIDE_TAIL and cursor_x > 0:
		line.clear_range(cursor_x - 1, cursor_x, _bg)
	if cursor_x + width < cols and line.flags[cursor_x + width] & WIDE_TAIL:
		line.clear_range(cursor_x + width, cursor_x + width + 1, _bg)

	line.chars[cursor_x] = char(c)
	line.fg[cursor_x] = _fg
	line.bg[cursor_x] = _bg
	line.flags[cursor_x] = _flags
	if width == 2:
		line.chars[cursor_x + 1] = ""
		line.fg[cursor_x + 1] = _fg
		line.bg[cursor_x + 1] = _bg
		line.flags[cursor_x + 1] = _flags | WIDE_TAIL

	cursor_x += width
	if cursor_x >= cols:
		cursor_x = cols - 1
		_pending_wrap = true


func _linefeed() -> void:
	if cursor_y == _scroll_bottom:
		_scroll_up()
	elif cursor_y < rows - 1:
		cursor_y += 1


func _reverse_index() -> void:
	if cursor_y == _scroll_top:
		_scroll_down()
	elif cursor_y > 0:
		cursor_y -= 1


func _scroll_up() -> void:
	var top: Line = _lines[_scroll_top]
	_lines.remove_at(_scroll_top)
	_lines.insert(_scroll_bottom, Line.new(cols, _bg))
	if _scroll_top == 0 and not alt_screen:
		_push_scrollback(top)


func _scroll_down() -> void:
	_lines.remove_at(_scroll_bottom)
	_lines.insert(_scroll_top, Line.new(cols, _bg))


func _push_scrollback(line: Line) -> void:
	scrollback.append(line)
	if scrollback.size() > MAX_SCROLLBACK:
		scrollback.pop_front()


func _erase_display(mode: int) -> void:
	match mode:
		0:
			_lines[cursor_y].clear_range(cursor_x, cols, _bg)
			for y in range(cursor_y + 1, rows):
				_lines[y].clear_range(0, cols, _bg)
				_lines[y].wrapped = false
		1:
			_lines[cursor_y].clear_range(0, cursor_x + 1, _bg)
			for y in range(0, cursor_y):
				_lines[y].clear_range(0, cols, _bg)
		2:
			for y in rows:
				_lines[y].clear_range(0, cols, _bg)
				_lines[y].wrapped = false
		3:
			scrollback.clear()


func _erase_line(mode: int) -> void:
	var line := _lines[cursor_y]
	match mode:
		0:
			line.clear_range(cursor_x, cols, _bg)
			line.wrapped = false
		1:
			line.clear_range(0, cursor_x + 1, _bg)
		2:
			line.clear_range(0, cols, _bg)
			line.wrapped = false


func _insert_lines(count: int) -> void:
	if cursor_y < _scroll_top or cursor_y > _scroll_bottom:
		return
	for i in mini(count, _scroll_bottom - cursor_y + 1):
		_lines.remove_at(_scroll_bottom)
		_lines.insert(cursor_y, Line.new(cols, _bg))
	cursor_x = 0


func _delete_lines(count: int) -> void:
	if cursor_y < _scroll_top or cursor_y > _scroll_bottom:
		return
	for i in mini(count, _scroll_bottom - cursor_y + 1):
		_lines.remove_at(cursor_y)
		_lines.insert(_scroll_bottom, Line.new(cols, _bg))
	cursor_x = 0


func _shift_right(line: Line, from: int, count: int) -> void:
	for x in range(cols - 1, from + count - 1, -1):
		line.chars[x] = line.chars[x - count]
		line.fg[x] = line.fg[x - count]
		line.bg[x] = line.bg[x - count]
		line.flags[x] = line.flags[x - count]
	line.clear_range(from, from + count, _bg)


func _insert_chars(count: int) -> void:
	_shift_right(_lines[cursor_y], cursor_x, mini(count, cols - cursor_x))


func _delete_chars(count: int) -> void:
	var line := _lines[cursor_y]
	count = mini(count, cols - cursor_x)
	for x in range(cursor_x, cols - count):
		line.chars[x] = line.chars[x + count]
		line.fg[x] = line.fg[x + count]
		line.bg[x] = line.bg[x + count]
		line.flags[x] = line.flags[x + count]
	line.clear_range(cols - count, cols, _bg)


func _save_cursor(into: Dictionary) -> void:
	into.x = cursor_x
	into.y = cursor_y
	into.fg = _fg
	into.bg = _bg
	into.flags = _flags
	into.wrap = _pending_wrap


func _restore_cursor(from: Dictionary) -> void:
	if from.is_empty():
		return
	cursor_x = clampi(from.x, 0, cols - 1)
	cursor_y = clampi(from.y, 0, rows - 1)
	_fg = from.fg
	_bg = from.bg
	_flags = from.flags
	_pending_wrap = from.wrap


func _soft_reset() -> void:
	cursor_visible = true
	app_cursor_keys = false
	_insert_mode = false
	_autowrap = true
	_scroll_top = 0
	_scroll_bottom = rows - 1
	_fg = DEFAULT
	_bg = DEFAULT
	_flags = 0


func _full_reset() -> void:
	_soft_reset()
	bracketed_paste = false
	focus_events = false
	alt_screen = false
	_main = _blank_screen()
	_alt = _blank_screen()
	_lines = _main
	cursor_x = 0
	cursor_y = 0


# ---------------------------------------------------------------- character width

## 0 for combining marks, 2 for East Asian wide characters and emoji, else 1.
static func char_width(c: int) -> int:
	if c < 0x300:
		return 1
	if (c >= 0x300 and c <= 0x36f) or (c >= 0x200b and c <= 0x200f) or (c >= 0xfe00 and c <= 0xfe0f) \
			or (c >= 0x1ab0 and c <= 0x1aff) or (c >= 0x20d0 and c <= 0x20ff) or (c >= 0xe0100 and c <= 0xe01ef):
		return 0
	if (c >= 0x1100 and c <= 0x115f) or (c >= 0x2e80 and c <= 0x303e) or (c >= 0x3041 and c <= 0x33ff) \
			or (c >= 0x3400 and c <= 0x4dbf) or (c >= 0x4e00 and c <= 0x9fff) or (c >= 0xa000 and c <= 0xa4cf) \
			or (c >= 0xac00 and c <= 0xd7a3) or (c >= 0xf900 and c <= 0xfaff) or (c >= 0xfe30 and c <= 0xfe4f) \
			or (c >= 0xff00 and c <= 0xff60) or (c >= 0xffe0 and c <= 0xffe6) or (c >= 0x1f300 and c <= 0x1f64f) \
			or (c >= 0x1f680 and c <= 0x1f6ff) or (c >= 0x1f900 and c <= 0x1f9ff) or (c >= 0x1fa70 and c <= 0x1faff) \
			or (c >= 0x20000 and c <= 0x3fffd):
		return 2
	# Emoji in the BMP that Unicode marks as wide
	if c in [0x231a, 0x231b, 0x23e9, 0x23ea, 0x23eb, 0x23ec, 0x23f0, 0x23f3, 0x23f8, 0x23f9, 0x23fa,
			0x25fd, 0x25fe, 0x2614, 0x2615, 0x267f, 0x2693, 0x26a1, 0x26aa, 0x26ab, 0x26bd, 0x26be,
			0x26c4, 0x26c5, 0x26ce, 0x26d4, 0x26ea, 0x26f2, 0x26f3, 0x26f5, 0x26fa, 0x26fd, 0x2705,
			0x270a, 0x270b, 0x2728, 0x274c, 0x274e, 0x2753, 0x2754, 0x2755, 0x2757, 0x2795, 0x2796,
			0x2797, 0x27b0, 0x27bf, 0x2b1b, 0x2b1c, 0x2b50, 0x2b55]:
		return 2
	if c >= 0x2648 and c <= 0x2653:
		return 2
	return 1
