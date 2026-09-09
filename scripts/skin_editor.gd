class_name SkinEditor
extends Control

## Painting a character.
##
## The canvas is the atlas itself rather than a 3D figure you draw onto. Drawing
## onto a model is nicer to use and far harder to build -- it needs picking, and
## a brush that behaves across a seam -- and the atlas has one real advantage
## besides being tractable: every pixel is reachable, including the ones on faces
## the camera cannot see from any single angle.
##
## What makes the atlas usable rather than a wall of squares is the labelling:
## each face is outlined and named, so "the back of the left leg" is somewhere
## you can find rather than somewhere you count grid cells to.

signal closed(saved: bool)

const PALETTE := [
	Color("#000000"), Color("#3f3f3f"), Color("#6b6b6b"), Color("#9c9c9c"),
	Color("#cdcdcd"), Color("#ffffff"), Color("#5a2b12"), Color("#8b4a1e"),
	Color("#c07a3e"), Color("#e6b077"), Color("#f2d6b3"), Color("#ffe9d0"),
	Color("#7a0d0d"), Color("#c11f1f"), Color("#e85d3a"), Color("#f2a03d"),
	Color("#f5d13b"), Color("#b7d43a"), Color("#4f9b2e"), Color("#1f6b3a"),
	Color("#1d7f7a"), Color("#2aa8c4"), Color("#2f6ec4"), Color("#26408f"),
	Color("#4b2f8f"), Color("#7a3fbf"), Color("#b25fd1"), Color("#e07ab8"),
	Color("#f2a8c4"), Color("#3a2a24"), Color("#1a1f2b"), Color("#0b0d12"),
]

enum Tool { PENCIL, ERASER, PICKER, FILL }

var img: Image
var skin_name := ""

var _tool: int = Tool.PENCIL
var _colour := Color("#2aa8c4")
var _zoom := 6
var _painting := false
var _undo: Array = []
const UNDO_MAX := 40

var _canvas: Control
var _tex: ImageTexture
var _swatch: ColorRect
var _preview_skin: RemotePlayer
var _tool_btns := {}

# The figure you paint on. Orbit rather than a fixed view, because half a skin
# is on faces a fixed camera never shows.
var _rig: Node3D
var _cam: Camera3D
var _view: SubViewportContainer
var _vp: SubViewport
var _yaw := 0.0
var _pitch := 0.15
var _dist := 2.4
var _orbiting := false
var _spin := 0.0
var _touched := false   # stop the idle turn the moment it is being used


func setup(name: String, image: Image) -> void:
	skin_name = name
	img = image.duplicate()
	img.convert(Image.FORMAT_RGBA8)
	_build()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.09, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := HBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 18)
	root.offset_left = 24
	root.offset_top = 20
	root.offset_right = -24
	root.offset_bottom = -20
	add_child(root)

	root.add_child(_build_tools())

	# The FIGURE is the canvas now, and gets the room. Painting where the thing
	# actually is beats painting a sheet and checking what happened.
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 6)
	root.add_child(mid)
	var title := Label.new()
	title.text = "Painting  %s" % (skin_name if skin_name != "" else "a new character")
	title.add_theme_font_size_override("font_size", 20)
	mid.add_child(title)
	var how := Label.new()
	how.text = "paint on the figure  ·  scroll to zoom  ·  hold the middle button to turn it"
	how.add_theme_font_size_override("font_size", 12)
	how.modulate = Color(1, 1, 1, 0.5)
	mid.add_child(how)
	mid.add_child(_build_paint_view())

	root.add_child(_build_sheet())
	_refresh()


## The figure, paintable. Everything about it is a lie told to a raycast: there
## is no canvas here, only a mesh whose triangles carry the UVs of the skin, so
## a click lands on a texel by asking which triangle it hit and where.
func _build_paint_view() -> Control:
	_vp = SubViewport.new()
	_vp.size = Vector2i(720, 720)
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_view = SubViewportContainer.new()
	_view.stretch = true
	_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.mouse_filter = Control.MOUSE_FILTER_STOP
	_view.add_child(_vp)
	_view.gui_input.connect(_view_input)

	var lamp := DirectionalLight3D.new()
	lamp.rotation_degrees = Vector3(-30, 35, 0)
	lamp.light_energy = 0.75
	_vp.add_child(lamp)
	var fill_light := DirectionalLight3D.new()
	fill_light.rotation_degrees = Vector3(-10, -150, 0)
	fill_light.light_energy = 0.3
	_vp.add_child(fill_light)
	# A rig the camera orbits, so turning the view never turns the figure -- if
	# the figure span instead, "the left arm" would depend on when you looked.
	_rig = Node3D.new()
	_vp.add_child(_rig)
	_cam = Camera3D.new()
	_vp.add_child(_cam)
	_preview_skin = RemotePlayer.new()
	_vp.add_child(_preview_skin)
	_preview_skin.setup(1)
	_preview_skin.show_nameplate(false)
	_place_camera()
	return _view


func _build_tools() -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(190, 0)
	col.add_theme_constant_override("separation", 6)

	var lbl := Label.new()
	lbl.text = "Tools"
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.modulate = Color(1, 1, 1, 0.6)
	col.add_child(lbl)
	var row := HBoxContainer.new()
	col.add_child(row)
	for t in [[Tool.PENCIL, "Pencil"], [Tool.ERASER, "Eraser"],
			[Tool.PICKER, "Pick"], [Tool.FILL, "Fill"]]:
		var b := Button.new()
		b.text = str(t[1])
		b.toggle_mode = true
		b.button_pressed = _tool == int(t[0])
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func():
			_tool = int(t[0])
			for k in _tool_btns:
				(_tool_btns[k] as Button).button_pressed = k == _tool)
		_tool_btns[int(t[0])] = b
		row.add_child(b)

	var cl := Label.new()
	cl.text = "Colour"
	cl.add_theme_font_size_override("font_size", 13)
	cl.modulate = Color(1, 1, 1, 0.6)
	col.add_child(cl)
	_swatch = ColorRect.new()
	_swatch.custom_minimum_size = Vector2(0, 26)
	_swatch.color = _colour
	col.add_child(_swatch)
	var grid := GridContainer.new()
	grid.columns = 8
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	col.add_child(grid)
	for c in PALETTE:
		var sw := Button.new()
		sw.custom_minimum_size = Vector2(21, 21)
		var sb := StyleBoxFlat.new()
		sb.bg_color = c
		sw.add_theme_stylebox_override("normal", sb)
		sw.add_theme_stylebox_override("hover", sb)
		sw.add_theme_stylebox_override("pressed", sb)
		sw.pressed.connect(func():
			_colour = c
			_swatch.color = c
			_set_tool(Tool.PENCIL))
		grid.add_child(sw)
	var pick := ColorPickerButton.new()
	pick.text = "Any colour..."
	pick.color = _colour
	pick.custom_minimum_size = Vector2(0, 28)
	pick.color_changed.connect(func(c: Color):
		_colour = c
		_swatch.color = c
		_set_tool(Tool.PENCIL))
	col.add_child(pick)

	col.add_child(_spacer(10))
	var zoom_row := HBoxContainer.new()
	col.add_child(zoom_row)
	for z in [4, 6, 8, 12]:
		var zb := Button.new()
		zb.text = "%dx" % z
		zb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		zb.pressed.connect(func():
			_zoom = z
			_canvas.custom_minimum_size = Vector2(PlayerSkin.ATLAS, PlayerSkin.ATLAS) * _zoom
			_canvas.queue_redraw())
		zoom_row.add_child(zb)

	col.add_child(_spacer(10))
	var undo := Button.new()
	undo.text = "Undo"
	undo.pressed.connect(_undo_step)
	col.add_child(undo)

	col.add_child(_spacer(16))
	var save := Button.new()
	save.text = "Save"
	save.custom_minimum_size = Vector2(0, 36)
	save.pressed.connect(func(): closed.emit(true))
	col.add_child(save)
	var cancel := Button.new()
	cancel.text = "Discard changes"
	cancel.pressed.connect(func(): closed.emit(false))
	col.add_child(cancel)
	return col


## The flat sheet, kept as a side panel rather than thrown away.
##
## Painting on the figure is better for everything you can see, and there are
## pixels you cannot: the soles of the feet, the top of the head, the inside of
## an arm. The sheet reaches all of them, and it is also where you go to check
## that a face is what you think it is.
func _build_sheet() -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(400, 0)
	col.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = "The whole sheet"
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.modulate = Color(1, 1, 1, 0.6)
	col.add_child(lbl)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	_canvas = Control.new()
	_canvas.custom_minimum_size = Vector2(PlayerSkin.ATLAS, PlayerSkin.ATLAS) * _zoom
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_canvas)
	_canvas.gui_input.connect(_canvas_input)
	scroll.add_child(_canvas)
	var hint := Label.new()
	hint.text = "Faces the figure cannot show you -- soles, scalp, inner arms -- are reachable here."
	hint.add_theme_font_size_override("font_size", 12)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.5)
	col.add_child(hint)
	return col


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _set_tool(t: int) -> void:
	_tool = t
	for k in _tool_btns:
		(_tool_btns[k] as Button).button_pressed = k == t


func _process(delta: float) -> void:
	# Turns gently on its own until you take hold of it, then stays where you
	# put it. A model that keeps moving while you aim at it is unpaintable.
	if _touched or _cam == null:
		return
	_spin += delta * 0.4
	_yaw = _spin
	_place_camera()


# --- canvas -------------------------------------------------------------------

func _draw_canvas() -> void:
	if img == null:
		return
	var z := float(_zoom)
	# The skin itself, drawn from the texture so it is one call rather than 4096.
	_canvas.draw_texture_rect(_tex,
		Rect2(Vector2.ZERO, Vector2(PlayerSkin.ATLAS, PlayerSkin.ATLAS) * z), false)
	# A grid, but only once the squares are big enough for it to help rather
	# than turn the whole canvas into lines.
	if _zoom >= 6:
		var faint := Color(1, 1, 1, 0.06)
		for i in range(PlayerSkin.ATLAS + 1):
			_canvas.draw_line(Vector2(i * z, 0), Vector2(i * z, PlayerSkin.ATLAS * z), faint)
			_canvas.draw_line(Vector2(0, i * z), Vector2(PlayerSkin.ATLAS * z, i * z), faint)
	# Face outlines and names: what turns an atlas into a map.
	var font := ThemeDB.fallback_font
	for part in PlayerSkin.PARTS:
		for face in PlayerSkin.LAYOUT[part]:
			var r: Rect2i = PlayerSkin.LAYOUT[part][face]
			var rr := Rect2(Vector2(r.position) * z, Vector2(r.size) * z)
			_canvas.draw_rect(rr, Color(1, 1, 1, 0.30), false, 1.0)
			if _zoom >= 8:
				# Only a label that FITS. A narrow face is four texels across
				# and "LA front" is not, so on those the name spilled over its
				# neighbours and three limbs read as one smear of text.
				var full := _short(part, face)
				var size := font.get_string_size(full, HORIZONTAL_ALIGNMENT_LEFT, -1, 9)
				var text := full
				if size.x > rr.size.x - 4.0:
					text = _abbr(part)
					if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x > rr.size.x - 4.0:
						text = ""
				if text != "":
					_canvas.draw_string(font, rr.position + Vector2(3, 11),
						text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(1, 1, 1, 0.5))


## "left_arm"/"front" -> "LA front". Short enough to sit inside a 4-texel face
## without covering the pixels being painted.
func _short(part: String, face: String) -> String:
	return "%s %s" % [_abbr(part), face]


func _abbr(part: String) -> String:
	var out := ""
	for b in part.split("_"):
		out += str(b)[0].to_upper()
	return out


func _canvas_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed:
				_push_undo()
				_painting = true
				_paint_at(e.position)
			else:
				_painting = false
		elif e.button_index == MOUSE_BUTTON_RIGHT and e.pressed:
			# Right-click picks, wherever you are and whatever tool is held. It
			# is the one thing you want constantly and never want to switch to.
			_pick_at(e.position)
	elif e is InputEventMouseMotion and _painting:
		_paint_at(e.position)


func _texel_at(pos: Vector2) -> Vector2i:
	return Vector2i(int(pos.x) / _zoom, int(pos.y) / _zoom)


func _in_atlas(t: Vector2i) -> bool:
	return t.x >= 0 and t.y >= 0 and t.x < PlayerSkin.ATLAS and t.y < PlayerSkin.ATLAS


func _paint_at(pos: Vector2) -> void:
	var t := _texel_at(pos)
	if not _in_atlas(t):
		return
	match _tool:
		Tool.PENCIL:
			img.set_pixelv(t, _colour)
		Tool.ERASER:
			img.set_pixelv(t, Color(0, 0, 0, 0))
		Tool.PICKER:
			_pick_at(pos)
			return
		Tool.FILL:
			_fill(t)
	_refresh()


func _pick_at(pos: Vector2) -> void:
	var t := _texel_at(pos)
	if not _in_atlas(t):
		return
	_colour = img.get_pixelv(t)
	if _swatch != null:
		_swatch.color = _colour


## Flood fill, penned inside the face that was clicked.
##
## Without the pen a fill would run straight across a rectangle boundary and
## repaint half the figure, because neighbouring rectangles in the atlas are
## unrelated parts of the body that happen to be adjacent on the sheet.
func _fill(start: Vector2i) -> void:
	var pen := _face_rect_at(start)
	if pen == Rect2i():
		return
	var want := img.get_pixelv(start)
	if want.is_equal_approx(_colour):
		return
	var queue: Array[Vector2i] = [start]
	var seen := {start: true}
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		img.set_pixelv(c, _colour)
		for n in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var q: Vector2i = c + n
			if seen.has(q) or not pen.has_point(q):
				continue
			if not img.get_pixelv(q).is_equal_approx(want):
				continue
			seen[q] = true
			queue.append(q)


func _face_rect_at(t: Vector2i) -> Rect2i:
	for part in PlayerSkin.PARTS:
		for face in PlayerSkin.LAYOUT[part]:
			var r: Rect2i = PlayerSkin.LAYOUT[part][face]
			if r.has_point(t):
				return r
	return Rect2i()


# --- undo ---------------------------------------------------------------------

func _push_undo() -> void:
	_undo.append(img.duplicate())
	if _undo.size() > UNDO_MAX:
		_undo.remove_at(0)


func _undo_step() -> void:
	if _undo.is_empty():
		return
	img = _undo.pop_back()
	_refresh()


func _refresh() -> void:
	if _tex == null:
		_tex = ImageTexture.create_from_image(img)
	else:
		_tex.update(img)
	if _canvas != null:
		_canvas.queue_redraw()
	if _preview_skin != null:
		_preview_skin.set_skin(img)


# --- painting on the figure ---------------------------------------------------

const ZOOM_MIN := 1.4
const ZOOM_MAX := 6.0


## Camera on a sphere around the figure's middle. Rebuilt from yaw/pitch/dist
## rather than nudged, so it cannot drift out of shape over a long session.
func _place_camera() -> void:
	if _cam == null:
		return
	var focus := Vector3(0, 0.05, 0)
	# NEGATIVE z at yaw 0, because the figure faces -Z: without the sign the
	# editor opened looking at the back of its head, and every "front" you
	# painted went on the back.
	var dir := Vector3(
		cos(_pitch) * sin(_yaw),
		sin(_pitch),
		-cos(_pitch) * cos(_yaw))
	_cam.position = focus + dir * _dist
	_cam.look_at_from_position(_cam.position, focus, Vector3.UP)


func _view_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		match e.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if e.pressed:
					_touched = true
					_dist = clampf(_dist * 0.88, ZOOM_MIN, ZOOM_MAX)
					_place_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				if e.pressed:
					_touched = true
					_dist = clampf(_dist / 0.88, ZOOM_MIN, ZOOM_MAX)
					_place_camera()
			MOUSE_BUTTON_MIDDLE:
				_touched = true
				_orbiting = e.pressed
			MOUSE_BUTTON_LEFT:
				_touched = true
				if e.pressed:
					_push_undo()
					_painting = true
					_paint_on_figure(e.position)
				else:
					_painting = false
			MOUSE_BUTTON_RIGHT:
				if e.pressed:
					_touched = true
					var hit := _pick_figure(e.position)
					if not hit.is_empty():
						_colour = img.get_pixelv(hit["texel"])
						if _swatch != null:
							_swatch.color = _colour
	elif e is InputEventMouseMotion:
		if _orbiting:
			_yaw -= e.relative.x * 0.01
			# Stopped short of straight up and straight down, where the view
			# flips over and the figure appears to spin on the spot.
			_pitch = clampf(_pitch + e.relative.y * 0.01, -1.35, 1.35)
			_place_camera()
		elif _painting:
			_paint_on_figure(e.position)


func _paint_on_figure(pos: Vector2) -> void:
	var hit := _pick_figure(pos)
	if hit.is_empty():
		return
	var t: Vector2i = hit["texel"]
	match _tool:
		Tool.PENCIL:
			img.set_pixelv(t, _colour)
		Tool.ERASER:
			img.set_pixelv(t, Color(0, 0, 0, 0))
		Tool.PICKER:
			_colour = img.get_pixelv(t)
			if _swatch != null:
				_swatch.color = _colour
		Tool.FILL:
			_fill(t)
	_refresh()


## Which texel is under the cursor.
##
## Done by hand against the triangles rather than with a physics ray, because a
## physics hit gives a point and this needs a UV -- and the meshes are ours: six
## boxes, twelve triangles each, built right here with their UVs attached. Two
## dozen triangles is nothing to test exhaustively, and it is exact.
func _pick_figure(pos: Vector2) -> Dictionary:
	if _cam == null or _view == null or _preview_skin == null:
		return {}
	# The container may be showing the viewport at a different size than it
	# renders at; the ray has to be cast in the viewport's own coordinates.
	var scale_v := Vector2(_vp.size) / _view.size
	var vpos := pos * scale_v
	var from := _cam.project_ray_origin(vpos)
	var dir := _cam.project_ray_normal(vpos)
	var best := INF
	var out := {}
	for piece in _preview_skin.pieces():
		var mi: MeshInstance3D = piece["node"]
		var xf := mi.global_transform
		var inv := xf.affine_inverse()
		var lo := inv * from
		var ld := (inv.basis * dir).normalized()
		var arr := (mi.mesh as ArrayMesh).surface_get_arrays(0)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
		for i in range(0, verts.size(), 3):
			var r := _ray_triangle(lo, ld, verts[i], verts[i + 1], verts[i + 2])
			if r.is_empty():
				continue
			# Compared in LOCAL distance, which is fine because these transforms
			# do not scale -- if they ever do, this has to move to world space.
			var d: float = r["t"]
			if d >= best:
				continue
			best = d
			var b: Vector3 = r["bary"]
			var uv: Vector2 = uvs[i] * b.x + uvs[i + 1] * b.y + uvs[i + 2] * b.z
			var texel := Vector2i(
				clampi(int(uv.x * PlayerSkin.ATLAS), 0, PlayerSkin.ATLAS - 1),
				clampi(int(uv.y * PlayerSkin.ATLAS), 0, PlayerSkin.ATLAS - 1))
			out = {"texel": texel, "part": piece["part"]}
	return out


## Moller-Trumbore. Returns the distance along the ray and the barycentric
## weights, which are what turn a hit into a point on the texture.
func _ray_triangle(o: Vector3, d: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Dictionary:
	const EPS := 0.0000001
	var e1 := b - a
	var e2 := c - a
	var h := d.cross(e2)
	var det := e1.dot(h)
	if absf(det) < EPS:
		return {}   # parallel to the triangle
	var inv := 1.0 / det
	var s := o - a
	var u := inv * s.dot(h)
	if u < 0.0 or u > 1.0:
		return {}
	var q := s.cross(e1)
	var v := inv * d.dot(q)
	if v < 0.0 or u + v > 1.0:
		return {}
	var t := inv * e2.dot(q)
	if t <= EPS:
		return {}   # behind the camera
	return {"t": t, "bary": Vector3(1.0 - u - v, u, v)}
