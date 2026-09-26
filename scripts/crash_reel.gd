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

## The reel in four beats.
##
## It used to open on the climax: alarms already screaming, ship already coming
## apart, tumble already at full spin. Nothing read as WRONG, because there was
## no right to compare it to -- it was just loud. An alarm is only frightening
## if you heard the room before it.
##
## So now:
##
##   0 .. CALM     Inside. Level flight, a steady hum, a panel saying every
##                 number is fine. Your hands on it. And, for the last second
##                 of it, something coming in through the window.
##   CALM          The asteroid lands. The frame is thrown, the panel dies, the
##                 hum stops and the alarm starts -- from nothing, so you hear
##                 it begin.
##   CALM .. CUT   Still inside, in the dark, being thrown about.
##   CUT ..        Outside: the chase shot, the tumble winding up from zero.
##                 The cut IS the moment you were thrown clear of your own point
##                 of view. This part loops for as long as the world takes.
##   play_impact   The ground. Unchanged.
##   .. + HOLD     Black, with wind coming up under it, before the world opens.
const CALM := 2.6                  # level flight, before anything has happened
const CUT := CALM + 0.45           # ...and how long you stay inside after it has
const ROCK_IN := CALM - 1.25       # when the asteroid first shows in the window
const MIN_OUTSIDE := 1.6           # the chase shot gets at least this long
const HOLD_BLACK := 1.15           # black, and wind, before the world opens

const FALL_SPIN := Vector3(0.9, 0.35, 1.7)   # radians/sec of tumble, per axis
const GROUND_Y := -260.0                     # how far below the ship the ground starts
const IMPACT_TIME := 3.0                     # seconds from "world is ready" to black
const CONTACT := 0.58                        # fraction of that at which it lands
const SHIP_SCALE := 0.80
## The interior set is its own little room, parked a long way above the falling
## ship so the two can never see each other. One camera visits both.
const INSIDE_Y := 3000.0

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
var _boom: CPUParticles3D
var _debris: CPUParticles3D
var _smoke: CPUParticles3D
var _blew := false
var _shake := 0.0
var _alarm: AudioStreamPlayer
var _bang: AudioStreamPlayer
var _red: TextureRect
var _alarm_t := 0.0
var _beep := 0
var _rng := RandomNumberGenerator.new()
var _inside: Node3D          # the cockpit set
var _panel: Node3D           # the lit face of the console, which dies
var _panel_text: Array = []  # the Label3Ds on it
var _rock: Node3D            # the asteroid, seen through the window
var _rock_out: Node3D        # ...and tumbling away behind you after the cut
var _hum: AudioStreamPlayer  # everything being fine
var _strike: AudioStreamPlayer
var _wind: AudioStreamPlayer
var _rock_bits: CPUParticles3D
var _struck := false
var _holding := 0.0          # counts up once the screen is black


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
	# Red round the edges, pulsing with the alarm. Under the flash and the black,
	# so the white-out still swallows everything at the end.
	_red = TextureRect.new()
	_red.texture = _vignette_texture()
	_red.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_red.stretch_mode = TextureRect.STRETCH_SCALE
	_red.set_anchors_preset(Control.PRESET_FULL_RECT)
	_red.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_red.modulate = Color(1.0, 0.12, 0.08, 0.0)
	add_child(_red)
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
	_build_blast()
	_build_alarm()
	_build_bang()
	_build_inside()
	_build_rock()
	_build_hum()
	_build_strike()
	_build_wind()
	_pose(0.0)


## A soft frame: clear in the middle, solid at the edges. Tinted and pulsed by
## _process, which is what turns it into a warning light rather than a filter.
func _vignette_texture() -> ImageTexture:
	const N := 96
	var img := Image.create(N, N, false, Image.FORMAT_RGBA8)
	for y in N:
		for x in N:
			var u := (float(x) / float(N - 1)) * 2.0 - 1.0
			var v := (float(y) / float(N - 1)) * 2.0 - 1.0
			# Distance to the nearest edge rather than to the centre: a frame,
			# not a circle, so the corners do not go darker than the sides.
			var d: float = maxf(absf(u), absf(v))
			# Kept hard against the edge. A gentle falloff from halfway out
			# reads as a red filter over the whole shot rather than as a warning
			# light at the rim.
			var a: float = clampf((d - 0.74) / 0.26, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a * a))
	return ImageTexture.create_from_image(img)


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


## What the ship is falling toward. A long way down for most of it, and then not.
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
	# Cloud decks between the ship and it. Nothing is moving the camera downward --
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


## The ship, as it was before -- built from the same plan the wreck is torn
## from, so what comes down is recognisably what you wake up in. A few pieces
## are already gone: it is coming apart, not arriving.
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


## One flat box, the vocabulary everything in this game is built from.
func _slab(parent: Node3D, at: Vector3, size: Vector3, col: Color,
		unshaded: bool = false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.85
	# Culling off, because this same helper builds a room you are standing IN.
	# A box only draws its outward faces, so with culling on, every wall of the
	# cockpit is invisible from the one side anybody ever sees it from.
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = m
	mi.position = at
	parent.add_child(mi)
	return mi


## The cockpit you are sitting in for the first three seconds.
##
## Built here rather than borrowed from the wreck, like everything else in this
## file, so that deleting the file takes the whole reel with it. It is small on
## purpose: a console, a window, and your hands. You are not meant to look round
## the room -- you are meant to be looking at the one thing that is about to
## stop working.
##
## The window is a HOLE, not glass: the sky behind it is the viewport's own sky,
## so it costs nothing and it is the same sky the ship falls through.
func _build_inside() -> void:
	_inside = Node3D.new()
	_inside.position = Vector3(0, INSIDE_Y, 0)
	_vp.add_child(_inside)
	# Dark. The panel has to be the brightest thing in here, or its going out
	# changes nothing -- and a cockpit lit as evenly as a kitchen was why the
	# first pass of this shot had no mood to lose.
	var wall := Color(0.075, 0.082, 0.095)
	var dark := Color(0.045, 0.05, 0.058)
	var trim := Color(0.115, 0.12, 0.135)
	# Floor, ceiling and the two side walls.
	_slab(_inside, Vector3(0, -0.5, -0.4), Vector3(3.2, 0.1, 4.0), dark)
	_slab(_inside, Vector3(0, 1.7, -0.4), Vector3(3.2, 0.1, 4.0), wall)
	_slab(_inside, Vector3(-1.55, 0.6, -0.4), Vector3(0.1, 2.3, 4.0), wall)
	_slab(_inside, Vector3(1.55, 0.6, -0.4), Vector3(0.1, 2.3, 4.0), wall)
	# The front bulkhead, in four pieces round a window. Left, right, over, under.
	_slab(_inside, Vector3(-1.05, 0.75, -2.3), Vector3(1.1, 2.0, 0.12), wall)
	_slab(_inside, Vector3(1.05, 0.75, -2.3), Vector3(1.1, 2.0, 0.12), wall)
	_slab(_inside, Vector3(0, 1.45, -2.3), Vector3(1.1, 0.6, 0.12), wall)
	_slab(_inside, Vector3(0, 0.05, -2.3), Vector3(1.1, 0.8, 0.12), wall)
	# A frame round the hole, one step proud, so the window reads as built.
	_slab(_inside, Vector3(0, 1.13, -2.24), Vector3(1.24, 0.08, 0.06), trim)
	_slab(_inside, Vector3(0, 0.48, -2.24), Vector3(1.24, 0.08, 0.06), trim)
	_slab(_inside, Vector3(-0.58, 0.8, -2.24), Vector3(0.08, 0.72, 0.06), trim)
	_slab(_inside, Vector3(0.58, 0.8, -2.24), Vector3(0.08, 0.72, 0.06), trim)
	# The console: a body, and a face raked back toward you.
	_slab(_inside, Vector3(0, 0.12, -1.5), Vector3(2.0, 0.6, 0.7), Color(0.062, 0.068, 0.078))
	_panel = Node3D.new()
	_panel.position = Vector3(0, 0.66, -1.52)
	# Raked BACK toward the seat. The sign matters: the other way round tips the
	# face into the bulkhead and you read the console edge-on as a black line.
	_panel.rotation = Vector3(deg_to_rad(34.0), 0, 0)
	_inside.add_child(_panel)
	_slab(_panel, Vector3.ZERO, Vector3(1.9, 0.02, 0.62), Color(0.09, 0.10, 0.11))
	# The lit face, and the readout on it. Unshaded, because a screen makes its
	# own light and is the brightest thing in a dim cockpit.
	_slab(_panel, Vector3(0, 0.013, 0.0), Vector3(1.66, 0.01, 0.46),
		Color(0.05, 0.13, 0.11), true)
	# Three lines in the ship computer's own flat voice. It does not say what is
	# happening or why -- it says the numbers, and every one of them is fine.
	# That is the whole point of it being on screen at all.
	var rows := [["ATMOSPHERIC ENTRY    NOMINAL", Color(0.42, 0.95, 0.72)],
		["HULL  100%        POWER  100%", Color(0.42, 0.95, 0.72)]]
	for i in rows.size():
		var lb := Label3D.new()
		lb.text = str(rows[i][0])
		lb.modulate = rows[i][1]
		lb.font_size = 64
		lb.pixel_size = 0.0015
		lb.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		lb.shaded = false
		lb.double_sided = true
		lb.no_depth_test = false
		lb.rotation = Vector3(deg_to_rad(-90.0), 0, 0)
		lb.position = Vector3(0, 0.02, -0.14 + float(i) * 0.14)
		_panel.add_child(lb)
		_panel_text.append(lb)
	# No indicator lamps. There were two, and at any size worth seeing they sat
	# on the ends of the top line. The words are the readout.
	# Your hands on the edge of it. Not modelled -- suggested. Two gloved shapes
	# at the bottom of the frame are enough to make the shot yours.
	for hx in [-0.46, 0.46]:
		var arm := Color(0.13, 0.14, 0.16)
		# Forearm running away from you into the frame, then the hand on the
		# near lip of the console. Coming from BEHIND the camera is what makes
		# them yours rather than someone else's, sat opposite.
		_slab(_inside, Vector3(hx, 0.42, -0.72), Vector3(0.17, 0.15, 0.62), arm)
		_slab(_inside, Vector3(hx * 0.92, 0.465, -1.16), Vector3(0.21, 0.11, 0.26),
			Color(0.19, 0.20, 0.23))
	# One dim lamp so the room is lit at all, and dies with the panel.
	var gl := OmniLight3D.new()
	gl.light_color = Color(0.55, 0.85, 0.75)
	gl.light_energy = 2.6
	gl.omni_range = 4.6
	gl.position = Vector3(0, 1.0, -1.25)
	_inside.add_child(gl)
	_panel_text.append(gl)


## The asteroid. A lump, not a ball: a body with smaller bodies stuck to it, the
## same way every rock in this game is made.
##
## Two of them. One flies at the window and is what hits you; the other is
## already tumbling away behind the ship when the shot cuts outside, so the
## thing you felt and the thing you then see are the same thing.
func _build_rock() -> void:
	_rock = _rock_lump(_inside)
	_rock_out = _rock_lump(_vp)
	_rock_out.visible = false
	_rock_bits = _burst(70, 2.2, 30.0, Vector3(0.9, 0.9, 0.9),
		Color(0.42, 0.38, 0.34, 1.0), Color(0.26, 0.24, 0.22, 0.0), 8.0)


func _rock_lump(parent: Node) -> Node3D:
	var n := Node3D.new()
	parent.add_child(n)
	var base := Color(0.27, 0.25, 0.23)
	_slab(n, Vector3.ZERO, Vector3(1.0, 0.88, 0.94), base)
	for i in 7:
		var g := _rng.randf_range(0.8, 1.2)
		_slab(n, Vector3(_rng.randf_range(-0.45, 0.45), _rng.randf_range(-0.4, 0.4),
			_rng.randf_range(-0.45, 0.45)),
			Vector3(_rng.randf_range(0.3, 0.6), _rng.randf_range(0.3, 0.55),
			_rng.randf_range(0.3, 0.6)),
			Color(base.r * g, base.g * g, base.b * g))
	return n


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


## Something burning, trailing off it. CPU particles rather than GPU ones --
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
## a deck that wraps in directly under the ship slaps the camera rather than sliding
## past it.
func _deck_spot(y: float) -> Vector3:
	var a := _rng.randf_range(0.0, TAU)
	var r := _rng.randf_range(55.0, 210.0)
	return Vector3(cos(a) * r, y, sin(a) * r)


## The blast itself, held ready and fired once. Three bursts at the same spot:
## the fireball, the pieces of it thrown out, and the smoke that stays.
func _build_blast() -> void:
	_boom = _burst(240, 1.6, 34.0, Vector3(2.6, 2.6, 2.6),
		Color(1.0, 0.95, 0.6, 1.0), Color(0.9, 0.22, 0.05, 0.0), 80.0)
	_debris = _burst(90, 2.6, 46.0, Vector3(1.1, 1.1, 1.1),
		Color(0.32, 0.30, 0.28, 1.0), Color(0.22, 0.20, 0.19, 0.0), 30.0)
	_smoke = _burst(120, 3.4, 12.0, Vector3(4.5, 4.5, 4.5),
		Color(0.24, 0.22, 0.21, 0.85), Color(0.30, 0.29, 0.28, 0.0), -3.0)


func _burst(n: int, life: float, speed: float, size: Vector3,
		from: Color, to: Color, gravity: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = n
	p.lifetime = life
	p.local_coords = false
	var m := BoxMesh.new()
	m.size = size
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.material = mat
	p.mesh = m
	p.direction = Vector3(0, 1, 0)
	p.spread = 80.0
	p.initial_velocity_min = speed * 0.35
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, -gravity, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.8
	var ramp := Gradient.new()
	ramp.set_color(0, from)
	ramp.set_color(1, to)
	p.color_ramp = ramp
	_vp.add_child(p)
	return p


## A cockpit alarm, synthesised rather than recorded -- two short tones and a
## gap, over and over, the way every warning that has ever mattered sounds. It
## is built here so that deleting this file takes the sound with it.
func _build_alarm() -> void:
	_alarm = AudioStreamPlayer.new()
	_alarm.stream = _beep_stream()
	_alarm.volume_db = -14.0
	if AudioServer.get_bus_index("Effects") >= 0:
		_alarm.bus = "Effects"
	add_child(_alarm)


## The impact itself. A recording rather than anything synthesised here -- some
## sounds you cannot fake with two sine waves.
func _build_bang() -> void:
	var stream = load("res://sounds/intro-explosion.wav")
	if stream == null:
		return
	_bang = AudioStreamPlayer.new()
	_bang.stream = stream
	_bang.volume_db = -1.0
	if AudioServer.get_bus_index("Effects") >= 0:
		_bang.bus = "Effects"
	add_child(_bang)


## Everything being fine, as a sound.
##
## This is the half of the reel that was missing. The alarm was always there and
## it never landed, because there was nothing for it to interrupt. A low hum
## under a quiet cockpit for three seconds is what makes the next three seconds
## frightening, and it costs one looping tone.
func _build_hum() -> void:
	_hum = AudioStreamPlayer.new()
	_hum.stream = _hum_stream()
	_hum.volume_db = -19.0
	if AudioServer.get_bus_index("Effects") >= 0:
		_hum.bus = "Effects"
	add_child(_hum)
	_hum.play()


## The strike. The same recording the landing uses, pitched up and cut down --
## an impact, not the end of one.
func _build_strike() -> void:
	if _bang == null:
		return
	_strike = AudioStreamPlayer.new()
	_strike.stream = _bang.stream
	_strike.volume_db = -5.0
	_strike.pitch_scale = 1.35
	if AudioServer.get_bus_index("Effects") >= 0:
		_strike.bus = "Effects"
	add_child(_strike)


## Wind, for the black at the end. Faded up under it so the world you are about
## to be standing in arrives before the picture does.
func _build_wind() -> void:
	_wind = AudioStreamPlayer.new()
	_wind.stream = _wind_stream()
	_wind.volume_db = -60.0
	if AudioServer.get_bus_index("Effects") >= 0:
		_wind.bus = "Effects"
	add_child(_wind)


## Engines: a low tone with a second one a hair off it, so the two beat slowly
## against each other. That slow throb is what makes it machinery rather than a
## test tone, and it is why the loop can be short without sounding short.
func _hum_stream() -> AudioStreamWAV:
	const RATE := 22050
	# Two seconds, and both frequencies chosen to complete a whole number of
	# cycles in it -- otherwise the loop clicks every time round.
	const SECS := 2.0
	var n := int(RATE * SECS)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var tt: float = float(i) / float(RATE)
		var v: float = sin(TAU * 62.0 * tt) * 0.62
		v += sin(TAU * 64.5 * tt) * 0.5
		v += sin(TAU * 186.0 * tt) * 0.1
		var sm: int = clampi(int(v * 11000.0), -32768, 32767)
		if sm < 0:
			sm += 65536
		data[i * 2] = sm & 0xFF
		data[i * 2 + 1] = (sm >> 8) & 0xFF
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	return w


## Wind: filtered noise. A running average over the noise is the filter -- it
## takes the hiss off and leaves the rush, which is the difference between wind
## and static.
func _wind_stream() -> AudioStreamWAV:
	const RATE := 22050
	const SECS := 2.0
	var n := int(RATE * SECS)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var lp := 0.0
	var lp2 := 0.0
	for i in n:
		lp = lp * 0.93 + rng.randf_range(-1.0, 1.0) * 0.07
		lp2 = lp2 * 0.86 + lp * 0.14
		# A slow swell over the whole loop so it gusts rather than sits.
		var sw: float = 0.7 + 0.3 * sin(TAU * float(i) / float(n))
		var sm: int = clampi(int(lp2 * sw * 78000.0), -32768, 32767)
		if sm < 0:
			sm += 65536
		data[i * 2] = sm & 0xFF
		data[i * 2 + 1] = (sm >> 8) & 0xFF
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	return w


func _beep_stream() -> AudioStreamWAV:
	const RATE := 22050
	const SECS := 0.20
	var n := int(RATE * SECS)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var tt: float = float(i) / float(RATE)
		# A SQUARE wave, held flat. That is the whole difference between a
		# klaxon and a musical note: an alarm is a buzzer, and a buzzer is full
		# of odd harmonics. A sine -- however you slide it about -- comes out
		# sounding like a doorbell, which is what the last one did.
		var ph: float = fposmod(tt * 620.0, 1.0)
		var sq: float = 1.0 if ph < 0.5 else -1.0
		# A second square a fifth up, quieter, so it has some edge to it rather
		# than being a pure tone.
		var ph2: float = fposmod(tt * 930.0, 1.0)
		sq += (0.35 if ph2 < 0.5 else -0.35)
		# Flat through the middle with just enough ramp not to click.
		var env: float = clampf(tt / 0.006, 0.0, 1.0) 			* clampf((SECS - tt) / 0.010, 0.0, 1.0)
		var sm: int = clampi(int(sq * env * 15000.0), -32768, 32767)
		if sm < 0:
			sm += 65536
		data[i * 2] = sm & 0xFF
		data[i * 2 + 1] = (sm >> 8) & 0xFF
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w


## Two beeps, a short gap, repeat, and faster than is comfortable. Stops the
## moment it hits -- after that there is nothing left to warn anybody about.
func _tick_alarm(delta: float) -> void:
	# Nothing to warn anybody about until the rock arrives.
	if _alarm == null or _blew or not _struck:
		return
	_alarm_t -= delta
	if _alarm_t > 0.0:
		return
	# Hi-lo, alternating. One pitch repeated is a smoke detector; two pitches
	# swapping is an alarm on a ship, and it costs one line to say so.
	_alarm.pitch_scale = 1.0 if (_beep % 2) == 0 else 0.78
	_alarm.play()
	_beep += 1
	_alarm_t = 0.36


## Where everything is at time `t`. Written as a function of t rather than as
## accumulated state so the loop can run for four seconds or forty and look the
## same either way.
func _pose(t: float) -> void:
	if t < CUT:
		_pose_inside(t)
		return
	_pose_outside(t - CUT)


## Inside, before you were thrown out of your own point of view.
##
## Almost nothing moves. That is the job: a shot that is nearly still for three
## seconds, so the one that follows reads as violence rather than as more of the
## same. The only thing in the frame with any urgency is the rock, and it is only
## there for the last second.
func _pose_inside(t: float) -> void:
	_inside.visible = true
	# A gentle ride, and then not. Buffet climbs a little through the calm --
	# entry is bumpy even when it is going well -- and the strike slams it.
	var bump: float = 0.004 + 0.006 * clampf(t / CALM, 0.0, 1.0)
	var eye := Vector3(0.0, 1.02, -0.30)
	var at := Vector3(0.0, 0.60, -1.58)
	if _struck:
		# Thrown. The head goes one way and the aim another, so you are looking
		# at nothing in particular -- which is what being hit looks like.
		var k: float = clampf((t - CALM) / (CUT - CALM), 0.0, 1.0)
		var a: float = (1.0 - k * 0.45) * 0.42
		eye += Vector3(sin(t * 71.0) * a, sin(t * 53.0) * a * 0.8, cos(t * 61.0) * a * 0.5)
		at += Vector3(sin(t * 44.0) * a * 2.4, -0.7 * k + sin(t * 37.0) * a,
			sin(t * 29.0) * a)
	else:
		eye += Vector3(sin(t * 8.0) * bump, sin(t * 11.0) * bump, 0.0)
	# The rock, coming in off the bow. Small and far for most of it; the last
	# third is the only part that reads as fast.
	if _rock != null:
		var rk: float = clampf((t - ROCK_IN) / maxf(CALM - ROCK_IN, 0.01), 0.0, 1.0)
		_rock.visible = rk > 0.0 and not _struck
		if _rock.visible:
			# Flown down a line THROUGH the window rather than to a point in
			# space. Picking two world positions and interpolating put it behind
			# the bulkhead for most of the run -- the window is a small hole and
			# almost nothing outside it is in shot. So: choose where on the
			# window it should appear, choose how far away it is, and work back.
			var e: float = pow(rk, 1.8)
			var d: float = lerpf(38.0, 2.6, e)
			var wx: float = lerpf(-0.38, -0.06, e)
			var wy: float = lerpf(1.02, 0.86, e)
			var base := Vector3(0.0, 1.02, -0.30)     # the eye, before buffet
			const PANE := -1.94                        # ...to the window plane
			_rock.position = base + Vector3(wx - base.x, wy - base.y, PANE) 				* (d / -PANE)
			_rock.scale = Vector3.ONE * 2.5
			_rock.rotation = Vector3(t * 1.3, t * 0.8, t * 1.9)
	_cam.look_at_from_position(_inside.position + eye, _inside.position + at, Vector3.UP)


func _pose_outside(t: float) -> void:
	if _inside != null:
		_inside.visible = false
	# The rock that hit you, tumbling away below and behind. Gone in a second --
	# long enough to be recognised, not long enough to be studied.
	if _rock_out != null:
		_rock_out.visible = t < 1.4
		if _rock_out.visible:
			_rock_out.scale = Vector3.ONE * 3.6
			_rock_out.position = _ship.position + Vector3(-6.0 - t * 2.0,
				3.0 - t * 11.0, -8.0 - t * 5.0)
			_rock_out.rotation = Vector3(t * 1.1, t * 0.7, t * 1.5)
	# The fall itself: it drops, tumbles, and drifts sideways a little. The
	# drop is wrapped, so the loop never runs out of sky.
	var drop: float = fposmod(t * 26.0, 150.0)
	var y: float = 40.0 - drop
	@warning_ignore("unassigned_variable")
	if _impacting:
		# Once the world is ready it stops looping and goes in. It holds its
		# height and the ground comes up to meet it -- which looks identical
		# from the camera and keeps everything in frame.
		y = 0.0
		if _blew:
			# Nothing tumbles after it lands.
			_ship.rotation = _ship.rotation
	_ship.position = Vector3(sin(t * 0.35) * 7.0, y, cos(t * 0.27) * 5.0)
	# The ground is kept a fixed way below the ship while it is falling -- so it
	# is a floor a long way down, not something it is approaching -- and then
	# closes in once it is going in. Moving IT is what makes the last two
	# seconds read as ground rushing up rather than a ship shrinking into haze.
	var gap: float = 260.0
	if _impacting:
		var kg: float = clampf((_ending / IMPACT_TIME) / CONTACT, 0.0, 1.0)
		gap = lerpf(260.0, 3.0, kg * kg)
	_ground.position = Vector3(0, _ship.position.y - gap, 0)
	# The decks rise past it at a fixed rate and wrap round underneath, so
	# there is always something streaming up through the shot.
	for cd in _clouds:
		var d: MeshInstance3D = cd
		var pz: Vector3 = d.position
		pz.y += 42.0 * get_process_delta_time()
		if pz.y > _ship.position.y + 70.0:
			pz = _deck_spot(_ship.position.y - 170.0)
		d.position = pz
	# Winding up rather than already at speed: the tumble began when the rock
	# landed, and you watched that happen. A ship already spinning flat out in
	# the first frame of the shot has no cause.
	var spin: float = clampf(t / 2.2, 0.0, 1.0)
	spin = spin * spin * (3.0 - 2.0 * spin)
	_ship.rotation = Vector3(t * FALL_SPIN.x, t * FALL_SPIN.y, t * FALL_SPIN.z) * spin
	# The camera hangs off it at an angle, swinging slowly round, always
	# looking at it -- a chase plane that cannot keep up.
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
	# Aimed a little BELOW it, so the horizon sits high in the frame and what
	# is under the shot is the ground it is going to meet.
	# Buffeting all the way down: it is coming apart in atmosphere, and a
	# camera that holds perfectly still says none of that. Small, constant, and
	# on three different frequencies so it never settles into a rhythm.
	var buffet: float = 0.10 + 0.05 * sin(t * 0.7)
	eye += Vector3(sin(t * 23.0) * buffet, sin(t * 31.0) * buffet * 0.8,
		cos(t * 19.0) * buffet)
	if _shake > 0.0:
		# Thrown about, settling. The camera is the only thing here that was not
		# aboard, so it is the only thing that can flinch on your behalf.
		var a := _shake * _shake * 4.0
		eye += Vector3(sin(t * 61.0) * a, sin(t * 47.0) * a, cos(t * 53.0) * a)
	_cam.look_at_from_position(eye, _ship.position - Vector3(0, 3.0, 0), Vector3.UP)


func _process(delta: float) -> void:
	_t += delta
	if not _struck and _t >= CALM:
		_take_the_hit()
	_tick_alarm(delta)
	_shake = maxf(_shake - delta * 1.6, 0.0)
	if _red != null:
		# In time with the beeps, and harder the longer it has been falling --
		# then held at full while it goes in. Off entirely until the rock lands:
		# a warning light over a cockpit where nothing is wrong was the tell that
		# the whole reel was set at one pitch.
		var lvl := 0.0
		if _struck:
			var beat: float = 0.5 + 0.5 * sin(_t * 9.5)
			lvl = lerpf(0.30, 0.75, beat)
			if _impacting:
				lvl = 0.85
			# Up from nothing over the first half second, so it comes ON.
			lvl *= clampf((_t - CALM) / 0.5, 0.0, 1.0)
		_red.modulate = Color(1.0, 0.12, 0.08, lvl)
	# The white-out of the strike, which is also what hides the cut.
	if _struck and not _impacting and _t < CUT + 0.25:
		var sf: float = clampf(1.0 - (_t - CALM) / 0.35, 0.0, 1.0)
		var cf: float = clampf(1.0 - absf(_t - CUT) / 0.12, 0.0, 1.0)
		_flash.color = Color(1, 1, 1, maxf(sf * 0.8, cf * 0.55))
	if _impacting:
		_ending += delta
	_pose(_t)
	if not _impacting:
		return
	var k: float = clampf(_ending / IMPACT_TIME, 0.0, 1.0)
	if k >= CONTACT and not _blew:
		_blow_up()
	# It goes up, and THEN the screen does -- the blast is something you watch
	# for a moment before the white takes it.
	if k > 0.86:
		var f: float = (k - 0.86) / 0.14
		_flash.color = Color(1, 1, 1, clampf(1.0 - f * 1.6, 0.0, 1.0) * 0.85)
		_black.color = Color(0, 0, 0, clampf(f * 1.9 - 0.15, 0.0, 1.0))
	elif k > CONTACT:
		_flash.color = Color(1, 1, 1, clampf((k - CONTACT) * 0.55, 0.0, 0.5))
	if _ending < IMPACT_TIME:
		return
	# Black. And then a beat of it, with wind coming up -- so the place you are
	# about to be standing in arrives before the picture of it does, and the
	# last thing the reel does is hand you over rather than cut.
	_black.color = Color(0, 0, 0, 1)
	if _holding <= 0.0 and _wind != null:
		_wind.play()
	_holding += delta
	if _wind != null:
		_wind.volume_db = lerpf(-46.0, -13.0, clampf(_holding / HOLD_BLACK, 0.0, 1.0))
	if _holding >= HOLD_BLACK:
		set_process(false)
		if _wind != null:
			# Handed over to the world's own wind, not cut off. Half a second,
			# because that is how long the loading layer above this lives after
			# `done` -- a longer fade is just cut off partway through.
			var tw := create_tween()
			tw.tween_property(_wind, "volume_db", -60.0, 0.5)
			tw.tween_callback(_wind.stop)
		done.emit()


## The asteroid arrives.
##
## Everything that was fine stops being fine in one frame: the panel dies, the
## hum stops, the alarm starts from silence, and the fall begins. This is the
## beat the reel never had -- the moment things GO wrong, rather than a reel that
## opens with them already wrong.
func _take_the_hit() -> void:
	_struck = true
	_shake = 1.0
	if _hum != null:
		_hum.stop()
	if _strike != null:
		_strike.play()
	# The panel goes out. Not a warning on it -- out. A dead console is the same
	# fact you will find when you wake up and the battery is flat, and it says it
	# without a word.
	for n in _panel_text:
		var nd := n as Node3D
		if nd != null:
			nd.visible = false
	if _panel != null:
		for c in _panel.get_children():
			var mi := c as MeshInstance3D
			if mi != null and mi.material_override is StandardMaterial3D:
				(mi.material_override as StandardMaterial3D).albedo_color = \
					Color(0.05, 0.05, 0.06)
	# Rock, where the rock was.
	if _rock_bits != null and _rock != null:
		_rock_bits.position = _rock.global_position
		_rock_bits.emitting = true
	if _rock != null:
		_rock.visible = false
	_alarm_t = 0.12


## It lands. The hull goes, three bursts go off where it was, the camera is
## thrown about, and the alarm has nothing left to say.
func _blow_up() -> void:
	_blew = true
	_shake = 1.0
	var at: Vector3 = _ship.position
	for b in [_boom, _debris, _smoke]:
		var q: CPUParticles3D = b
		q.position = at
		q.emitting = true
	for c in _ship.get_children():
		var ch := c as Node3D
		if ch != null:
			ch.visible = false
	if _alarm != null:
		_alarm.stop()
	if _bang != null:
		_bang.play()


## The world is ready: stop falling and land. Returns when the screen is black.
func play_impact() -> void:
	if _impacting:
		return
	# The world can be ready before the reel has said anything. Every beat gets
	# its time: the cockpit, the strike, and enough of the chase shot to see the
	# ship coming apart in. Generation takes longer than this anyway on anything
	# but the fastest machine -- this is a floor, not a delay.
	while _t < CUT + MIN_OUTSIDE:
		await get_tree().process_frame
	_impacting = true
	_ending = 0.0
	await done
