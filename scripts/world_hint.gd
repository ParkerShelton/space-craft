class_name WorldHint
extends Node3D
## A line of teaching text that lives in the WORLD, pointing at the thing it is
## about.
##
## Text across the middle of the screen is an interruption: it is not attached
## to anything, so it has to be read, understood and then MAPPED onto whatever
## it was talking about. A label floating over the console with a line drawn
## down to it skips every part of that -- you have already looked at the thing
## before you have finished reading the words.
##
## It fades with distance and angle rather than switching off, hides itself when
## you are close enough to be reading it through your own hands, and can either
## time out or stay until whatever it is teaching has been done.
##
## Nothing else depends on this file. Deleting it takes the hints with it and
## leaves everything else working.

const NEAR := 1.4        # closer than this and you are inside it; fade out
const FULL := 3.0        # between here and FAR it is at full strength
const FAR := 22.0        # beyond this it is gone
const RISE := 0.85       # how far above the target the text floats

var life := -1.0         # seconds left; negative means "until dismissed"
var hint_id := ""

var _label: Label3D
var _line: MeshInstance3D
var _ring: MeshInstance3D
var _age := 0.0
var _fade := 0.0         # eased 0..1, so it arrives and leaves rather than pops


## `text` is what it says, `life` in seconds or negative to stay put. The node
## is placed by its caller -- parent it to a ship and it rides along.
func setup(text: String, seconds: float, colour := Color(1.0, 0.86, 0.45)) -> void:
	life = seconds
	_label = Label3D.new()
	_label.text = text
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.render_priority = 4
	_label.outline_render_priority = 3
	_label.font_size = 48
	_label.pixel_size = 0.0022
	_label.modulate = colour
	_label.outline_modulate = Color(0, 0, 0, 0.85)
	_label.outline_size = 12
	_label.position = Vector3(0, RISE, 0)
	add_child(_label)

	# The leader: a thin post from the thing up to the text. This is the whole
	# point of the hint being in the world, so it is drawn as geometry rather
	# than implied by the text sitting nearby.
	_line = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.012
	cyl.bottom_radius = 0.012
	cyl.height = RISE - 0.16
	cyl.radial_segments = 6
	cyl.rings = 0
	_line.mesh = cyl
	_line.position = Vector3(0, (RISE - 0.16) * 0.5 + 0.06, 0)
	_line.material_override = _flat(colour)
	_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_line)

	# And a small ring where the line lands, so the line points AT something
	# rather than just ending.
	_ring = MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = 0.10
	tor.outer_radius = 0.14
	tor.rings = 10
	tor.ring_segments = 6
	_ring.mesh = tor
	_ring.position = Vector3(0, 0.05, 0)
	_ring.material_override = _flat(colour)
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)
	_apply(0.0)


static func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	m.render_priority = 3
	return m


func _process(delta: float) -> void:
	_age += delta
	if life >= 0.0:
		life -= delta
		if life <= 0.0:
			queue_free()
			return
	var cam := get_viewport().get_camera_3d()
	var want := 1.0
	if cam != null:
		var d := global_position.distance_to(cam.global_position)
		if d > FAR or d < NEAR * 0.5:
			want = 0.0
		elif d < FULL:
			# Standing on top of it: fade down, because a label you are inside
			# is a wall of text rather than a pointer.
			want = clampf((d - NEAR) / (FULL - NEAR), 0.0, 1.0)
		else:
			want = clampf((FAR - d) / (FAR * 0.35), 0.0, 1.0)
	# Fading out over its last second, so it leaves rather than vanishes.
	if life >= 0.0 and life < 1.0:
		want = minf(want, life)
	_fade = move_toward(_fade, want, delta * 3.0)
	# A slow bob. Enough to catch the eye in a still frame, not enough to read
	# as an animation.
	_apply(sin(_age * 1.7) * 0.05)


func _apply(bob: float) -> void:
	if _label == null or not is_instance_valid(_label):
		return
	_label.position.y = RISE + bob
	var a := clampf(_fade, 0.0, 1.0)
	_label.modulate.a = a
	_label.outline_modulate.a = a * 0.85
	for mi in [_line, _ring]:
		var m := mi as MeshInstance3D
		if m == null or not is_instance_valid(m):
			continue
		m.visible = a > 0.02
		var mat := m.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color.a = a * 0.75


## Take it away early -- the thing it was teaching has been done.
func dismiss() -> void:
	life = minf(life if life >= 0.0 else 999.0, 0.45)
