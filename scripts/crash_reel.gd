class_name CrashReel
extends Control
## The crash, played over the loading screen.
##
## A new world takes a few seconds to generate and those seconds used to be a
## progress counter. They are the crash instead: the ship you are about to wake
## up inside, coming apart on the way down. Nothing is explained -- no voice, no
## distress call, no reason. A ship falls and that is all you get, which is the
## same restraint the ship's computer keeps when it tells you the battery is
## flat without saying how it got that way.
##
## It is deliberately SELF-CONTAINED. Everything here lives in its own World3D
## inside a SubViewport, so it cannot see or be seen by the real world, cannot
## be lit by it, and cannot leave anything behind. The real terrain does not
## exist yet anyway -- that is what is loading.
##
## To take it out again: delete this file, and the three lines in main.gd that
## mention CrashReel (they are all guarded by MAIN's CRASH_REEL constant).

## Emitted when the impact has played out and the screen is black.
signal done

const FALL_SPIN := Vector3(0.9, 0.35, 1.7)   # radians/sec of tumble, per axis
const GROUND_Y := -260.0                     # how far below the ship the ground starts
const IMPACT_TIME := 2.1                     # seconds from "world is ready" to black
const SHIP_SCALE := 0.80

var _vp: SubViewport
var _ship: Node3D
var _cam: Camera3D
var _ground: MeshInstance3D
var _clouds: Array = []
var _flash: ColorRect
var _black: ColorRect
var _t := 0.0
var _ending := 0.0      # counts UP once the impact has started
var _impacting := false
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_rng.randomize()
	# The viewport lives in its own container so that the flash and the black
	# over it are ordinary Controls, stacked on top, rather than children of a
	# container whose whole job is to stretch a viewport.
	var box := SubViewportContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.stretch = true
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	box.add_child(_vp)
	_build_sky()
	_build_ground()
	_build_ship()
	_cam = Camera3D.new()
	_cam.fov = 62.0
	_vp.add_child(_cam)
	_cam.current = true
	# The flash and the black are Controls over the viewport rather than
	# anything in the 3D scene: a white-out is a screen effect, not an object.
	_flash = ColorRect.new()
	_flash.color = Color(1, 1, 1, 0)
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_flash)
	_black = ColorRect.new()
	_black.color = Color(0, 0, 0, 0)
	_black.set_anchors_preset(Control.PRESET_FULL_RECT)
	_black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_black)
	_pose(0.0)


## A sky to fall through: thin and cold up top, hazy where the ground is.
func _build_sky() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.05, 0.08, 0.16)
	mat.sky_horizon_color = Color(0.42, 0.46, 0.55)
	mat.ground_bottom_color = Color(0.10, 0.11, 0.13)
	mat.ground_horizon_color = Color(0.36, 0.38, 0.42)
	mat.sun_angle_max = 30.0
	sky.sky_material = mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.fog_enabled = true
	env.fog_light_color = Color(0.45, 0.48, 0.55)
	env.fog_density = 0.0016
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.5
	sun.light_color = Color(1.0, 0.92, 0.8)
	sun.rotation = Vector3(deg_to_rad(-28.0), deg_to_rad(40.0), 0)
	_vp.add_child(sun)


## What she is falling toward. A long way down for most of it, and then not.
func _build_ground() -> void:
	_ground = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(4000, 8, 4000)
	_ground.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.29, 0.34, 0.26)
	m.roughness = 1.0
	_ground.material_override = m
	_ground.position = Vector3(0, GROUND_Y, 0)
	_vp.add_child(_ground)
	# Something ON it, so it is a landscape rushing up rather than a grey plane
	# that gets bigger.
	for i2 in 90:
		var lump := MeshInstance3D.new()
		var lm := BoxMesh.new()
		lm.size = Vector3(_rng.randf_range(8.0, 34.0), _rng.randf_range(3.0, 16.0),
			_rng.randf_range(8.0, 34.0))
		lump.mesh = lm
		var lmat := StandardMaterial3D.new()
		var g := _rng.randf_range(0.16, 0.34)
		lmat.albedo_color = Color(g * 0.9, g * 1.1, g * 0.8)
		lmat.roughness = 1.0
		lump.material_override = lmat
		lump.position = Vector3(_rng.randf_range(-700.0, 700.0),
			4.0 + (lm.size.y * 0.5), _rng.randf_range(-700.0, 700.0))
		_ground.add_child(lump)
	# Cloud decks between her and it. Nothing is moving the camera downward --
	# the sky is empty and a fall through empty sky looks like hanging still --
	# so these stream past instead, and that is the whole sensation of speed.
	for i in 26:
		var deck := MeshInstance3D.new()
		var dm := BoxMesh.new()
		dm.size = Vector3(_rng.randf_range(30.0, 85.0), 2.0, _rng.randf_range(30.0, 85.0))
		deck.mesh = dm
		var cm := StandardMaterial3D.new()
		cm.albedo_color = Color(0.86, 0.89, 0.94, 0.34)
		cm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		deck.material_override = cm
		deck.position = _deck_spot(_rng.randf_range(GROUND_Y + 20.0, 60.0))
		_vp.add_child(deck)
		_clouds.append(deck)


## The ship, as she was before -- built from the same plan the wreck is torn
## from, so what comes down is recognisably what you wake up in. A few pieces
## are already gone: she is coming apart, not arriving.
func _build_ship() -> void:
	_ship = Node3D.new()
	_ship.scale = Vector3.ONE * SHIP_SCALE
	_vp.add_child(_ship)
	var plan: Dictionary = CrashSite._plan()
	var cells := {}
	for v in plan:
		cells[v] = int(plan[v])
	# Shed a wing tip and a bit of tail on the way down.
	var shed: Array = []
	for v2 in cells:
		var c: Vector3i = v2
		if absi(c.x) >= 4 or c.z >= CrashSite.TAIL - 1:
			shed.append(c)
	shed.shuffle()
	for i in mini(shed.size(), 14):
		cells.erase(shed[i])
	var mi := MeshInstance3D.new()
	mi.mesh = _hull_mesh(cells)
	_ship.add_child(mi)
	# Centre the model on the node so it tumbles about itself rather than about
	# a corner of its own block grid.
	mi.position = -Vector3(0, 1.5, (CrashSite.NOSE + CrashSite.TAIL) * 0.5)
	_add_fire(Vector3(0, 1.5, CrashSite.TAIL + 1.0) + mi.position)
	_add_fire(Vector3(2.5, 1.5, 1.0) + mi.position)


## A block map to a mesh: every face that is not up against another block. The
## same flat-box vocabulary as everything else, kept local so that deleting this
## file takes the whole reel with it.
func _hull_mesh(cells: Dictionary) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in cells:
		var c: Vector3i = v
		var base := Blocks.color_of(int(cells[c]))
		for fi in 6:
			if cells.has(c + (Chunk._WFACE[fi] as Vector3i)):
				continue
			var sh: float = Chunk._face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
			st.set_color(Color(base.r * sh, base.g * sh, base.b * sh, 1.0))
			st.set_normal(Vector3(Chunk._WFACE[fi]))
			var q := Chunk._box_face(Vector3(c), Vector3(c) + Vector3.ONE, fi)
			st.add_vertex(q[0]); st.add_vertex(q[2]); st.add_vertex(q[1])
			st.add_vertex(q[0]); st.add_vertex(q[3]); st.add_vertex(q[2])
	var m := st.commit()
	if m.get_surface_count() > 0:
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.8
		m.surface_set_material(0, mat)
	return m


## Something burning, trailing off her. CPU particles rather than GPU ones --
## this project runs the Compatibility renderer.
func _add_fire(at: Vector3) -> void:
	var p := CPUParticles3D.new()
	p.amount = 140
	p.lifetime = 1.1
	p.explosiveness = 0.0
	p.local_coords = false
	var pm := BoxMesh.new()
	pm.size = Vector3(0.6, 0.6, 0.6)
	var pmat := StandardMaterial3D.new()
	pmat.vertex_color_use_as_albedo = true
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pm.material = pmat
	p.mesh = pm
	p.direction = Vector3(0, 1, 0)
	p.spread = 25.0
	p.initial_velocity_min = 6.0
	p.initial_velocity_max = 14.0
	p.scale_amount_min = 0.7
	p.scale_amount_max = 2.2
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.85, 0.35, 1.0))
	ramp.set_color(1, Color(0.25, 0.22, 0.22, 0.0))
	ramp.add_point(0.35, Color(1.0, 0.35, 0.08, 0.95))
	p.color_ramp = ramp
	# CPUParticles3D calls it scale_amount_curve; scale_curve is the GPU one's
	# process material, and assigning it here silently did nothing.
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.35))
	sc.add_point(Vector2(0.3, 1.0))
	sc.add_point(Vector2(1, 0.1))
	p.scale_amount_curve = sc
	p.position = at
	p.emitting = true
	_ship.add_child(p)


## Somewhere out to one side at this height. Held clear of the middle, because
## a deck that wraps in directly under her slaps the camera rather than sliding
## past it.
func _deck_spot(y: float) -> Vector3:
	var a := _rng.randf_range(0.0, TAU)
	var r := _rng.randf_range(55.0, 210.0)
	return Vector3(cos(a) * r, y, sin(a) * r)


## Where everything is at time `t`. Written as a function of t rather than as
## accumulated state so the loop can run for four seconds or forty and look the
## same either way.
func _pose(t: float) -> void:
	# The fall itself: she drops, tumbles, and drifts sideways a little. The
	# drop is wrapped, so the loop never runs out of sky.
	var drop: float = fposmod(t * 26.0, 150.0)
	var y: float = 40.0 - drop
	@warning_ignore("unassigned_variable")
	if _impacting:
		# Once the world is ready she stops looping and goes in. She holds her
		# height and the ground comes up to meet her -- which looks identical
		# from the camera and keeps everything in frame.
		y = 0.0
	_ship.position = Vector3(sin(t * 0.35) * 7.0, y, cos(t * 0.27) * 5.0)
	# The ground is kept a fixed way below her while she is falling -- so it is
	# a floor a long way down, not something she is approaching -- and then
	# closes on her once she is going in. Moving IT is what makes the last two
	# seconds read as ground rushing up rather than a ship shrinking into haze.
	var gap: float = 260.0
	if _impacting:
		var kg: float = clampf(_ending / IMPACT_TIME, 0.0, 1.0)
		gap = lerpf(260.0, 3.0, kg * kg)
	_ground.position = Vector3(0, _ship.position.y - gap, 0)
	# The decks rise past her at a fixed rate and wrap round underneath, so
	# there is always something streaming up through the shot.
	for cd in _clouds:
		var d: MeshInstance3D = cd
		var pz: Vector3 = d.position
		pz.y += 42.0 * get_process_delta_time()
		if pz.y > _ship.position.y + 70.0:
			pz = _deck_spot(_ship.position.y - 170.0)
		d.position = pz
	_ship.rotation = Vector3(t * FALL_SPIN.x, t * FALL_SPIN.y, t * FALL_SPIN.z)
	# The camera hangs off her at an angle, swinging slowly round, always
	# looking at her -- a chase plane that cannot keep up.
	var ang: float = t * 0.33
	var dist: float = 24.0 - 4.0 * sin(t * 0.2)
	var high: float = 7.5 + 3.0 * sin(t * 0.45)
	if _impacting:
		# Pulls out and up for the last second, so the ground is in the shot and
		# you can see how little of it is left.
		var k2: float = clampf(_ending / IMPACT_TIME, 0.0, 1.0)
		dist = lerpf(dist, 34.0, k2)
		high = lerpf(high, 22.0, k2)
	var eye: Vector3 = _ship.position + Vector3(
		cos(ang) * dist, high, sin(ang) * dist)
	# Aimed a little BELOW her, so the horizon sits high in the frame and what
	# is under the shot is the ground she is going to meet.
	_cam.look_at_from_position(eye, _ship.position - Vector3(0, 3.0, 0), Vector3.UP)


func _process(delta: float) -> void:
	_t += delta
	if _impacting:
		_ending += delta
	_pose(_t)
	if not _impacting:
		return
	var k: float = clampf(_ending / IMPACT_TIME, 0.0, 1.0)
	# White at the moment she lands, then straight to black.
	if k > 0.82:
		var f: float = (k - 0.82) / 0.18
		_flash.color = Color(1, 1, 1, clampf(1.0 - f * 1.4, 0.0, 1.0) * 0.9)
		_black.color = Color(0, 0, 0, clampf(f * 1.8 - 0.2, 0.0, 1.0))
	elif k > 0.78:
		_flash.color = Color(1, 1, 1, (k - 0.78) / 0.04)
	if _ending >= IMPACT_TIME:
		_black.color = Color(0, 0, 0, 1)
		set_process(false)
		done.emit()


## The world is ready: stop falling and land. Returns when the screen is black.
func play_impact() -> void:
	if _impacting:
		return
	_impacting = true
	_ending = 0.0
	await done
