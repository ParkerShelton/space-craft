class_name Ship
extends CharacterBody3D

## An independent, player-built voxel grid. While you build it, it sits still and
## you can stand on it (per-block box colliders). Once it has a cockpit + a
## thruster + enough blocks, you can pilot it: scripted arcade flight where thrust
## fights the planet's radial gravity, so you must out-thrust the world to lift off
## and then coast free once gravity fades in space.

var blocks := {}       # Vector3i(local voxel) -> block id
var block_meta := {}   # Vector3i -> {h,d,e,r} material stats for crafted blocks (Shipworks)
var _habitable := false  # sealed interior + a Life Support block => safe to breathe inside
var _sealed := false      # cached: interior has an enclosed air pocket
var _sealed_cells := {}   # the enclosed interior air cells (local voxel -> true)
var _bbox_min := Vector3i.ZERO  # cached block bounding box (local voxels)
var _bbox_max := Vector3i.ZERO
var flying := false
## If this ship is the wreck a world starts in: the cells it woke up missing,
## cell -> the block that belongs there. Emptied as they are put back, which is
## what the ship's computer reads its checklist from (see ShipComputer).
var wreck_missing := {}
## What has happened to this ship, in the order it happened. Shown by the
## computer once she flies.
var ship_log: Array = []
## The cells that have to be solid before the cabin holds air -- the wings and
## the tail are not among them. Set on the wreck a world starts in.
var cabin_cells: Array = []
## The sections that came off in the crash, one entry per piece, each a list of
## the cells it was made of. Used once, when the world places the wreck, to lay
## the pieces out on the ground nearby -- after that they are terrain, so this
## is never saved.
var wreck_debris: Array = []
## Where the pilot's seat stands, in ship space, or ZERO for a ship without one.
## Built as a model rather than out of blocks: a seat is a thing you sit in.
var seat_at := Vector3.ZERO
var _props: Node3D
var world: WorldManager  # set on spawn; used for gravity while coasting
var in_gravity := false  # true while in launch/landing-assist mode (HUD)
var landed := false      # resting on the ground (HUD)

# --- flight tuning ---
const THRUST_UNIT := 350.0    # base thrust per thruster; scaled by its material's Energy
const HULL_MASS_BASE := 0.6   # every block has some mass...
const HULL_MASS_DENSITY := 0.8  # ...plus more for denser material (heavier -> less agile)
const SHIP_DRAG := 0.6        # velocity damping (arcade feel + control)
const YAW_SENS := 0.0022
const PITCH_SENS := 0.0022
const ROLL_SPEED := 1.6
const GRAVITY_FLIGHT := 3.0    # above this gravity => in a planet's pull
const ASSIST_ALT := 280.0      # within this altitude of a surface => landing assist
const LEVEL_SPEED := 2.5       # how fast the ship auto-levels toward belly-down
const CAM_LOOK_SENS := 0.005
# landing feel: the ship HOVERS (gravity cancelled) and you fly it gently over the
# terrain, camera-relative, then descend to touch down. Speeds are capped so you
# can never slam in.
const LAND_SPEED := 24.0       # horizontal move speed while landing
const LAND_VSPEED := 16.0      # climb/descend speed while landing
const LAND_ACCEL := 3.5        # how quickly velocity eases to the target
const LAND_MAX := 45.0         # hard speed cap on entering assist (kills a fast dive)

var _reticle: MeshInstance3D   # ring projected on the ground showing the landing spot

var _mi: MeshInstance3D
var _col_shapes: Array[CollisionShape3D] = []
var _chase_cam: Camera3D
var _cam_pivot: Node3D          # lets the camera free-look while landing without turning the ship
var _cam_yaw := 0.0
var _cam_pitch := 0.0

const FACES := [
	{"n": Vector3i(1, 0, 0),  "d": 0, "s": 1,  "c": [Vector3(1,0,0), Vector3(1,1,0), Vector3(1,1,1), Vector3(1,0,1)]},
	{"n": Vector3i(-1, 0, 0), "d": 0, "s": -1, "c": [Vector3(0,0,0), Vector3(0,0,1), Vector3(0,1,1), Vector3(0,1,0)]},
	{"n": Vector3i(0, 1, 0),  "d": 1, "s": 1,  "c": [Vector3(0,1,0), Vector3(0,1,1), Vector3(1,1,1), Vector3(1,1,0)]},
	{"n": Vector3i(0, -1, 0), "d": 1, "s": -1, "c": [Vector3(0,0,0), Vector3(1,0,0), Vector3(1,0,1), Vector3(0,0,1)]},
	{"n": Vector3i(0, 0, 1),  "d": 2, "s": 1,  "c": [Vector3(0,0,1), Vector3(1,0,1), Vector3(1,1,1), Vector3(0,1,1)]},
	{"n": Vector3i(0, 0, -1), "d": 2, "s": -1, "c": [Vector3(0,0,0), Vector3(0,1,0), Vector3(1,1,0), Vector3(1,0,0)]},
]


## The fittings that are models rather than blocks. Rebuilt rather than saved:
## they are decided by what the ship IS, so a loaded ship grows its own back.
func build_props() -> void:
	if _props != null and is_instance_valid(_props):
		_props.queue_free()
	_props = null
	_props = Node3D.new()
	add_child(_props)
	# Every ship's controls get a console standing over the block, so the thing
	# you talk to looks like something you would talk to rather than a painted
	# cube. The block itself stays where it is: it is what the hull is built
	# from and what your crosshair finds.
	for v in blocks:
		var bid := int(blocks[v])
		var mesh: ArrayMesh = null
		if bid == Blocks.COCKPIT:
			mesh = _console_mesh()
		elif FITTINGS.has(bid):
			mesh = _fitting_mesh(bid)
		if mesh == null:
			continue
		var con := MeshInstance3D.new()
		con.mesh = mesh
		con.position = Vector3(v as Vector3i)
		con.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_props.add_child(con)
	if seat_at == Vector3.ZERO:
		return
	var seat := MeshInstance3D.new()
	seat.mesh = _seat_mesh()
	seat.position = seat_at
	seat.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_props.add_child(seat)


## Blocks that are built as MODELS rather than drawn as cubes. They still sit
## in `blocks` -- they are part of the hull and of what the ship can do -- they
## are just not boxes to look at.
const FITTINGS := {Blocks.LIFE_SUPPORT: true, Blocks.THRUSTER: true}


## A fitting's model, in its own cell, oriented to the ship: -Z is the nose.
static func _fitting_mesh(id: int) -> ArrayMesh:
	const CASE := Color(0.30, 0.33, 0.36)
	const DEEP := Color(0.17, 0.19, 0.22)
	const PIPE := Color(0.46, 0.49, 0.54)
	const AIR_G := Color(0.40, 0.90, 0.75)
	const BURN := Color(1.00, 0.55, 0.18)
	var body: Array = []
	var lit: Array = []
	if id == Blocks.LIFE_SUPPORT:
		# A scrubber: a cabinet with a filter drum on the front, pipework up the
		# side and an intake grille you can see is breathing.
		body = [
			[Vector3(0.5, 0.06, 0.5), Vector3(0.86, 0.12, 0.86), DEEP],    # plinth
			[Vector3(0.5, 0.52, 0.5), Vector3(0.80, 0.82, 0.76), CASE],    # cabinet
			[Vector3(0.5, 0.96, 0.5), Vector3(0.88, 0.10, 0.84), DEEP],    # cap
			[Vector3(0.5, 0.60, 0.10), Vector3(0.52, 0.52, 0.12), DEEP],   # drum recess
			[Vector3(0.5, 0.60, 0.06), Vector3(0.44, 0.44, 0.06), PIPE],   # filter drum
			[Vector3(0.16, 0.52, 0.12), Vector3(0.10, 0.74, 0.10), PIPE],  # riser
			[Vector3(0.84, 0.52, 0.12), Vector3(0.10, 0.74, 0.10), PIPE],
			[Vector3(0.5, 0.90, 0.16), Vector3(0.60, 0.08, 0.10), PIPE],   # header
		]
		for i in 3:
			body.append([Vector3(0.5, 0.26 + float(i) * 0.06, 0.09),
				Vector3(0.56, 0.03, 0.10), DEEP])                          # intake grille
		lit = [
			[Vector3(0.5, 0.60, 0.028), Vector3(0.26, 0.26, 0.02), AIR_G],
			[Vector3(0.72, 0.86, 0.09), Vector3(0.07, 0.05, 0.03), AIR_G],
		]
	else:
		# A thruster: a mounting ring in the cell and a bell stepping out of the
		# tail behind it (+Z is aft), with the throat glowing.
		body = [
			[Vector3(0.5, 0.5, 0.30), Vector3(0.92, 0.92, 0.60), CASE],    # mount block
			[Vector3(0.5, 0.5, 0.64), Vector3(0.74, 0.74, 0.12), DEEP],    # collar
			[Vector3(0.5, 0.5, 0.78), Vector3(0.60, 0.60, 0.18), PIPE],    # bell, first step
			[Vector3(0.5, 0.5, 0.94), Vector3(0.76, 0.76, 0.16), PIPE],    # bell, flare
			[Vector3(0.5, 0.5, 1.06), Vector3(0.90, 0.90, 0.10), DEEP],    # lip
		]
		for sx in [-1.0, 1.0]:
			body.append([Vector3(0.5 + sx * 0.40, 0.5, 0.46),
				Vector3(0.10, 0.56, 0.30), PIPE])                          # feed lines
		lit = [
			[Vector3(0.5, 0.5, 1.02), Vector3(0.46, 0.46, 0.03), BURN],    # throat
			[Vector3(0.5, 0.86, 0.22), Vector3(0.10, 0.06, 0.04), BURN],   # status lamp
		]
	var m := ArrayMesh.new()
	_add_boxes(m, body, false)
	_add_boxes(m, lit, true)
	return m


## The ship's controls: a hooded screen leaning out of the panel with a keyboard
## shelf under it and a couple of lamps on the corners. Built in the block's own
## unit cell and hung off the side the PILOT stands on (+Z, aft), so the screen
## and the shelf lean out toward whoever is reading them. The cockpit block's
## other face is the windscreen the hull mesher paints, and that stays outboard.
##
## Two surfaces: the casing is lit like anything else, and the screen and lamps
## are unshaded, so a dark cabin has a computer glowing in the nose of it.
static func _console_mesh() -> ArrayMesh:
	const BODY := Color(0.20, 0.22, 0.26)
	const TRIM := Color(0.40, 0.42, 0.48)
	const DARK := Color(0.05, 0.09, 0.13)
	const GLOW := Color(0.45, 0.95, 1.00)
	const AMBER := Color(1.00, 0.62, 0.18)
	var casing := [
		[Vector3(0.5, 0.93, 1.13), Vector3(0.94, 0.10, 0.36), TRIM],    # hood
		[Vector3(0.5, 0.64, 1.08), Vector3(0.88, 0.52, 0.20), BODY],    # bezel
		[Vector3(0.07, 0.64, 1.1), Vector3(0.10, 0.54, 0.22), TRIM],   # left post
		[Vector3(0.93, 0.64, 1.1), Vector3(0.10, 0.54, 0.22), TRIM],   # right post
		[Vector3(0.5, 0.64, 1.185), Vector3(0.74, 0.42, 0.03), DARK],   # screen face
		[Vector3(0.5, 0.35, 1.22), Vector3(0.86, 0.07, 0.40), BODY],    # keyboard shelf
		[Vector3(0.5, 0.31, 1.41), Vector3(0.86, 0.06, 0.06), TRIM],    # shelf lip
		[Vector3(0.5, 0.16, 1.1), Vector3(0.70, 0.24, 0.20), BODY],    # pedestal under it
	]
	var lit := [
		[Vector3(0.5, 0.75, 1.205), Vector3(0.52, 0.035, 0.01), GLOW],
		[Vector3(0.44, 0.67, 1.205), Vector3(0.38, 0.030, 0.01), GLOW],
		[Vector3(0.48, 0.59, 1.205), Vector3(0.46, 0.030, 0.01), GLOW],
		[Vector3(0.40, 0.51, 1.205), Vector3(0.28, 0.030, 0.01), AMBER],
		[Vector3(0.5, 0.395, 1.30), Vector3(0.64, 0.020, 0.07), GLOW],  # keys, faintly lit
		# Lamps stand PROUD of the shelf lip rather than inside it. Sunk into it
		# they shared a face with it, and two faces in the same plane flicker
		# against each other from any distance.
		[Vector3(0.15, 0.31, 1.465), Vector3(0.07, 0.045, 0.05), AMBER],
		[Vector3(0.85, 0.31, 1.465), Vector3(0.07, 0.045, 0.05), GLOW],
	]
	var m := ArrayMesh.new()
	_add_boxes(m, casing, false)
	_add_boxes(m, lit, true)
	return m


## One surface of box geometry onto `m`. `unshaded` is what separates a screen
## from the casing round it.
static func _add_boxes(m: ArrayMesh, boxes: Array, unshaded: bool) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in boxes:
		var c: Color = b[2]
		var p0: Vector3 = (b[0] as Vector3) - (b[1] as Vector3) * 0.5
		var p1: Vector3 = (b[0] as Vector3) + (b[1] as Vector3) * 0.5
		for fi in 6:
			st.set_color(c)
			st.set_normal(Vector3(Chunk._WFACE[fi]))
			var q := Chunk._box_face(p0, p1, fi)
			st.add_vertex(q[0]); st.add_vertex(q[2]); st.add_vertex(q[1])
			st.add_vertex(q[0]); st.add_vertex(q[3]); st.add_vertex(q[2])
	var sub := st.commit()
	if sub.get_surface_count() == 0:
		return
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	if unshaded:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	else:
		mat.roughness = 0.55
		mat.metallic = 0.25
	var arrays := sub.surface_get_arrays(0)
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	m.surface_set_material(m.get_surface_count() - 1, mat)


## A pilot's seat: a pan to sit on, a raked back, head rest, arms and a pedestal
## -- the same box-model treatment the stations get. Y is measured from the FOOT
## of the seat, so `seat_at` is a point on the floor and the chair stands on it
## rather than sinking half a metre through the deck plate.
static func _seat_mesh() -> ArrayMesh:
	const FRAME := Color(0.26, 0.27, 0.30)
	const PAD := Color(0.42, 0.13, 0.15)
	const TRIM := Color(0.55, 0.57, 0.6)
	var boxes := [
		[Vector3(0, 0.10, 0), Vector3(0.30, 0.20, 0.30), FRAME],        # pedestal
		[Vector3(0, 0.24, 0), Vector3(0.50, 0.10, 0.48), FRAME],        # swivel plate
		[Vector3(0, 0.36, 0.02), Vector3(0.64, 0.14, 0.60), PAD],       # the pan
		[Vector3(0, 0.34, -0.30), Vector3(0.64, 0.10, 0.08), FRAME],    # front lip
		[Vector3(0, 0.06, -0.34), Vector3(0.40, 0.08, 0.16), TRIM],     # foot rail
		[Vector3(0, 0.85, 0.30), Vector3(0.66, 1.00, 0.12), FRAME],     # back frame
		[Vector3(0, 0.80, 0.21), Vector3(0.54, 0.84, 0.10), PAD],       # back pad
		[Vector3(0, 1.42, 0.28), Vector3(0.40, 0.22, 0.16), PAD],       # head rest
		[Vector3(0, 1.45, 0.35), Vector3(0.46, 0.28, 0.06), FRAME],
	]
	for sx in [-1.0, 1.0]:
		boxes.append([Vector3(sx * 0.28, 0.78, 0.22), Vector3(0.08, 0.80, 0.12), FRAME]) # bolster
		boxes.append([Vector3(sx * 0.34, 0.56, -0.02), Vector3(0.08, 0.10, 0.44), TRIM]) # arm
		boxes.append([Vector3(sx * 0.34, 0.47, 0.14), Vector3(0.07, 0.22, 0.07), TRIM])  # post
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in boxes:
		var c: Color = b[2]
		var p0: Vector3 = (b[0] as Vector3) - (b[1] as Vector3) * 0.5
		var p1: Vector3 = (b[0] as Vector3) + (b[1] as Vector3) * 0.5
		for fi in 6:
			st.set_color(c)
			st.set_normal(Vector3(Chunk._WFACE[fi]))
			var q := Chunk._box_face(p0, p1, fi)
			# Reversed on purpose. Chunk._box_face lists each quad in the order
			# the voxel mesher wants, and that mesher only gets away with it
			# because voxel_block.gdshader sets cull_disabled (see the note at
			# the top of it). A model lit by an ordinary material culls its back
			# faces, so laid out that way you see the INSIDE of every box and
			# the shading comes out inverted -- the top of a seat darker than
			# its sides. Wound the other way round, it culls correctly.
			st.add_vertex(q[0]); st.add_vertex(q[2]); st.add_vertex(q[1])
			st.add_vertex(q[0]); st.add_vertex(q[3]); st.add_vertex(q[2])
	var m := st.commit()
	if m.get_surface_count() > 0:
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.75
		m.surface_set_material(0, mat)
	return m


func _ready() -> void:
	if _mi == null:
		_mi = MeshInstance3D.new()
		add_child(_mi)


## While not being piloted, a ship coasts on its momentum (true space drift, so
## you can leave the seat mid-cruise and walk around as it keeps traveling), and
## falls if it drifts into a gravity well. At rest it stays put.
func _physics_process(delta: float) -> void:
	if flying:
		return  # the pilot drives movement via fly()
	if velocity.length() < 0.05:
		velocity = Vector3.ZERO
		return
	if world != null:
		velocity += world.gravity_at(global_position) * delta
	var col := move_and_collide(velocity * delta)
	if col != null:
		velocity = velocity.slide(col.get_normal())


func world_to_voxel(world_pos: Vector3) -> Vector3i:
	var l := to_local(world_pos)
	return Vector3i(floori(l.x), floori(l.y), floori(l.z))


func get_id(v: Vector3i) -> int:
	return blocks.get(v, Blocks.AIR)


## Local position (block coords) of the cockpit block, or the center if none.
func cockpit_local() -> Vector3:
	for v in blocks:
		if blocks[v] == Blocks.COCKPIT:
			return Vector3(v)
	return center_local() - Vector3(0.5, 0.5, 0.5)


func center_local() -> Vector3:
	if blocks.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for v in blocks:
		sum += Vector3(v) + Vector3(0.5, 0.5, 0.5)
	return sum / blocks.size()


func set_block(v: Vector3i, id: int, meta: Dictionary = {}) -> void:
	if id == Blocks.AIR:
		blocks.erase(v)
		block_meta.erase(v)
	else:
		blocks[v] = id
		if meta != null and not meta.is_empty():
			block_meta[v] = meta   # crafted block carries its material stats
		else:
			block_meta.erase(v)
		# Putting something back where the crash tore something out: a hole in
		# the shell takes any solid plate, but a system has to be the system.
		if wreck_missing.has(v):
			var want := int(wreck_missing[v])
			var structural: bool = want == Blocks.METAL or want == Blocks.GLASS
			if id == want or (structural and Blocks.is_placeable_block(Blocks.bottom_of(id))):
				wreck_missing.erase(v)
	if blocks.is_empty():
		queue_free()
		return
	rebuild()


# --- ship tanks --------------------------------------------------------------
#
# A ship makes nothing of its own. Its Life Support is a TANK: you fill it from
# a planet base (via Batteries and a Power Bay) and it keeps you alive until it
# runs out. Running dry is what pulls you home.
var air := 1.0      # 0..1 breathable air left in the cabin
var charge := 1.0   # 0..1 stored power, run down by life support and systems

const AIR_DRAIN := 0.0055     # per second while you are inside breathing it
const CHARGE_DRAIN := 0.0035  # per second while life support is running


## Burn a slice of the tanks. Driven by the player, so a parked empty ship does
## not quietly drain itself while you are off doing something else.
func consume_life_support(delta: float) -> void:
	if not _habitable:
		return
	charge = maxf(charge - CHARGE_DRAIN * delta, 0.0)
	if charge <= 0.0:
		air = maxf(air - AIR_DRAIN * 2.0 * delta, 0.0)  # no power, no scrubbing
	else:
		air = maxf(air - AIR_DRAIN * delta, 0.0)


func get_status() -> Dictionary:
	var has_cockpit := false
	var thrusters := 0
	var life_support := false
	var warp_drive := false
	for v in blocks:
		match blocks[v]:
			Blocks.COCKPIT: has_cockpit = true
			Blocks.THRUSTER: thrusters += 1
			Blocks.LIFE_SUPPORT: life_support = true
			Blocks.WARP_DRIVE: warp_drive = true
	return {
		"count": blocks.size(),
		"cockpit": has_cockpit,
		"thrusters": thrusters,
		"can_fly": has_cockpit and thrusters >= 1 and blocks.size() >= 4,
		"life_support": life_support,
		"warp_drive": warp_drive,
		"sealed": _sealed,
		"habitable": is_habitable(),
		"air": air,
		"charge": charge,
	}


## The ship keeps you alive inside (breathing, climate) only when it has a Life
## Support block AND a sealed interior (an enclosed air pocket).
func is_habitable() -> bool:
	# The block and the seal are not enough any more: the tank has to have
	# something in it.
	return _habitable and air > 0.0


## Is a world point physically inside this habitable ship's sealed interior? This
## is what makes standing inside the cabin safe (not merely being in the cockpit).
func is_inside_pressurized(world_pos: Vector3) -> bool:
	if not is_habitable() or _sealed_cells.is_empty():
		return false
	var lp := to_local(world_pos)
	var base := Vector3i(floori(lp.x), floori(lp.y), floori(lp.z))
	# check the cell at the point plus one below/above (feet/body/head in ship frame)
	for dy in [0, -1, 1]:
		if _sealed_cells.has(base + Vector3i(0, dy, 0)):
			return true
	return false


func _recompute_habitable() -> void:
	_sealed = _is_sealed()
	_habitable = _sealed and _has_life_support()


func _has_life_support() -> bool:
	for v in blocks:
		if blocks[v] == Blocks.LIFE_SUPPORT:
			return true
	return false


## Warp travel requires a Warp Drive block actually built onto the ship --
## checked live (not cached) since it's cheap and can change any time you're
## docked, unlike _habitable which only needs recomputing on block edits.
func has_warp_drive() -> bool:
	for v in blocks:
		if blocks[v] == Blocks.WARP_DRIVE:
			return true
	return false


# A cell counts as an airtight wall only if it holds a solid block -- an OPEN door
# is a gap that air escapes through (so it breaks the seal).
func _seals(cell: Vector3i) -> bool:
	return blocks.has(cell) and blocks[cell] != Blocks.DOOR_OPEN


# Sealed if some interior cell can't be reached by air flooding in from outside --
# i.e. there's an enclosed (airtight) pocket. Also caches the bounding box.
func _is_sealed() -> bool:
	_sealed_cells = {}
	if blocks.is_empty():
		return false
	var mn := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var mx := Vector3i(-(1 << 30), -(1 << 30), -(1 << 30))
	for v in blocks:
		mn.x = mini(mn.x, v.x); mn.y = mini(mn.y, v.y); mn.z = mini(mn.z, v.z)
		mx.x = maxi(mx.x, v.x); mx.y = maxi(mx.y, v.y); mx.z = maxi(mx.z, v.z)
	_bbox_min = mn
	_bbox_max = mx
	if blocks.size() < 6:
		return false
	var lo := mn - Vector3i.ONE
	var hi := mx + Vector3i.ONE
	# flood exterior air from a corner outside the ship, bounded to [lo, hi]; air
	# passes through open doors, so an open door lets the outside in (unseals)
	var exterior := {}
	var stack := [lo]
	var neigh := [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,1,0),
		Vector3i(0,-1,0), Vector3i(0,0,1), Vector3i(0,0,-1)]
	while not stack.is_empty():
		var p: Vector3i = stack.pop_back()
		if exterior.has(p) or _seals(p):
			continue
		if p.x < lo.x or p.y < lo.y or p.z < lo.z or p.x > hi.x or p.y > hi.y or p.z > hi.z:
			continue
		exterior[p] = true
		for n in neigh:
			stack.append(p + n)
	# collect every interior cell the exterior flood didn't reach (sealed pocket)
	for x in range(mn.x, mx.x + 1):
		for y in range(mn.y, mx.y + 1):
			for z in range(mn.z, mx.z + 1):
				var c := Vector3i(x, y, z)
				if not _seals(c) and not exterior.has(c):
					_sealed_cells[c] = true
	return not _sealed_cells.is_empty()


## Is a world point inside the ship's hull footprint, in a passable (air/open-door)
## cell? Used to auto-board you when you walk in through an open door.
func contains(world_pos: Vector3) -> bool:
	if blocks.is_empty():
		return false
	var lp := to_local(world_pos)
	var c := Vector3i(floori(lp.x), floori(lp.y), floori(lp.z))
	if c.x < _bbox_min.x or c.y < _bbox_min.y or c.z < _bbox_min.z:
		return false
	if c.x > _bbox_max.x or c.y > _bbox_max.y or c.z > _bbox_max.z:
		return false
	if blocks.has(c) and blocks[c] != Blocks.DOOR_OPEN:
		return false
	# Also require an actual ceiling somewhere overhead -- otherwise this is
	# just an exposed deck/roof (e.g. a ship you're mid-build on), and standing
	# on it shouldn't auto-board you into "aboard" mode.
	for dy in range(1, 5):
		var above := c + Vector3i(0, dy, 0)
		if above.y > _bbox_max.y:
			break
		if blocks.has(above) and blocks[above] != Blocks.DOOR_OPEN:
			return true
	return false


## Toggle a door block open/closed (by local voxel). Returns true if it was a
## door. Each cube door is independent -- toggling one never touches any
## other door, however close together they're built (this used to flood-fill
## and open every touching door cell together, which read as buggy/unexpected
## in practice rather than useful, so it was removed).
func toggle_door(local_v: Vector3i) -> bool:
	var id: int = blocks.get(local_v, Blocks.AIR)
	if not Blocks.is_door(id):
		return false
	# A doorway is two cells tall and swings as ONE thing: reach for the handle
	# at waist height or at head height and the whole door opens. Its other half
	# is the cell above a bottom or below a top, and only when that cell really
	# is the opposite half -- so two separate doors stacked in a shaft still work
	# independently. Each half is flipped from its OWN state, which is what keeps
	# a top a top.
	var step := Vector3i(0, -1, 0) if Blocks.door_is_top(id) else Vector3i(0, 1, 0)
	var other: Vector3i = local_v + step
	var oid: int = blocks.get(other, Blocks.AIR)
	var paired: bool = Blocks.is_door(oid) and Blocks.door_is_top(oid) != Blocks.door_is_top(id)
	blocks[local_v] = Blocks.door_toggle_of(id)
	if paired:
		blocks[other] = Blocks.door_toggle_of(oid)
	rebuild()
	_recompute_habitable()
	return true


## Available thrust acceleration (m/s^2) = total thrust / total mass. A thruster's
## thrust scales with its material's Energy; every block's mass scales with its
## material's Density. So a light hull with high-energy thrusters is far more
## agile -- crafted (Shipworks) parts carry their material; default parts use
## mid-range stats, so old ships fly as before.
func thrust_accel() -> float:
	var total_thrust := 0.0
	var total_mass := 0.0
	for v in blocks:
		var meta: Dictionary = block_meta.get(v, {})
		var density := float(meta.get("d", 40))
		total_mass += HULL_MASS_BASE + density / 100.0 * HULL_MASS_DENSITY
		if blocks[v] == Blocks.THRUSTER:
			var energy := float(meta.get("e", 50))
			total_thrust += THRUST_UNIT * (0.4 + energy / 100.0)
	if total_mass <= 0.0:
		return 0.0
	return total_thrust / total_mass


# --- piloting -----------------------------------------------------------------

func enable_chase_camera() -> void:
	if _cam_pivot == null:
		_cam_pivot = Node3D.new()
		add_child(_cam_pivot)
		_chase_cam = Camera3D.new()
		_chase_cam.far = 14000.0
		_chase_cam.rotation.x = deg_to_rad(-12)
		_cam_pivot.add_child(_chase_cam)
	_cam_pivot.position = center_local()
	_cam_pivot.rotation = Vector3.ZERO
	_cam_yaw = 0.0
	_cam_pitch = 0.0
	_chase_cam.position = Vector3(0, 4, 13)
	_chase_cam.make_current()


## Called each physics frame by the player while piloting. Two modes: inside a
## planet's gravity it's launch/landing assist (auto-levelled, up/down + gentle
## positioning, no manual rotation); out in space it's full 6-axis flight.
func fly(delta: float, world: WorldManager, input: Dictionary) -> void:
	var g := world.gravity_at(global_position)
	# Assist only when actually near a surface (coming in to land / lifting off) --
	# not way out in the gravity well.
	var alt := 1.0e9
	var p := world.nearest_planet(global_position)
	if p != null:
		alt = p.altitude(global_position)  # shape-aware (cube/sphere)
	in_gravity = alt < ASSIST_ALT and g.length() > 1.0
	if in_gravity:
		_fly_assisted(delta, input, g)
	else:
		landed = false
		_fly_free(delta, input, g)


func hide_landing_reticle() -> void:
	if _reticle != null:
		_reticle.visible = false


# Full 6-DOF: mouse steer + roll, thrust on all axes. Used in space.
func _fly_free(delta: float, input: Dictionary, g: Vector3) -> void:
	hide_landing_reticle()
	# camera rides directly behind the ship again
	if _cam_pivot != null:
		_cam_pivot.rotation = _cam_pivot.rotation.lerp(Vector3.ZERO, clampf(delta * 6.0, 0.0, 1.0))
	_cam_yaw = 0.0
	_cam_pitch = 0.0

	var look: Vector2 = input["look"]
	if look.x != 0.0:
		rotate_object_local(Vector3.UP, -look.x * YAW_SENS)
	if look.y != 0.0:
		rotate_object_local(Vector3.RIGHT, -look.y * PITCH_SENS)
	var roll: float = input["roll"]
	if roll != 0.0:
		rotate_object_local(Vector3.BACK, roll * ROLL_SPEED * delta)

	var b := global_transform.basis
	var move: Vector2 = input["move"]
	var thrust := (-b.z) * move.y * thrust_accel() + b.x * move.x * thrust_accel() + b.y * float(input["ascend"]) * thrust_accel()
	velocity += (g + thrust) * delta
	velocity = velocity.lerp(Vector3.ZERO, clampf(SHIP_DRAG * delta, 0.0, 1.0))
	var col := move_and_collide(velocity * delta)
	if col != null:
		velocity = velocity.slide(col.get_normal())


# Landing assist: the ship auto-levels and HOVERS (gravity cancelled). You fly it
# gently over the terrain relative to where the camera looks, then hold Shift to
# ease down and touch off. Speeds are capped so you can never slam in, and a ring
# shows the spot on the ground directly below.
func _fly_assisted(delta: float, input: Dictionary, g: Vector3) -> void:
	var up_target := -_snap_to_axis(g)
	_level_to(up_target, delta)

	# Free-look the camera around the ship WITHOUT turning the ship.
	if _cam_pivot != null:
		var look: Vector2 = input["look"]
		_cam_yaw -= look.x * CAM_LOOK_SENS
		_cam_pitch = clampf(_cam_pitch - look.y * CAM_LOOK_SENS, -1.4, 0.5)
		_cam_pivot.rotation = Vector3(_cam_pitch, _cam_yaw, 0.0)

	var up := global_transform.basis.y
	velocity = velocity.limit_length(LAND_MAX)  # tame a fast dive on arrival

	# Move relative to where the camera looks, flattened onto the ground plane.
	var camb := _chase_cam.global_transform.basis if _chase_cam != null else global_transform.basis
	var camf := -camb.z
	var camr := camb.x
	camf = camf - up * camf.dot(up)
	camr = camr - up * camr.dot(up)
	if camf.length() > 0.01: camf = camf.normalized()
	if camr.length() > 0.01: camr = camr.normalized()
	var move: Vector2 = input["move"]
	var wish := camf * move.y + camr * move.x
	if wish.length() > 1.0:
		wish = wish.normalized()

	var target_h := wish * LAND_SPEED
	var target_v := float(input["ascend"]) * LAND_VSPEED  # Space up, Shift down; hover at 0

	var v_up := velocity.dot(up)
	var v_h := velocity - up * v_up
	v_h = v_h.lerp(target_h, clampf(LAND_ACCEL * delta, 0.0, 1.0))
	v_up = lerpf(v_up, target_v, clampf(LAND_ACCEL * delta, 0.0, 1.0))
	velocity = v_h + up * v_up

	var col := move_and_collide(velocity * delta)
	landed = false
	if col != null:
		velocity = velocity.slide(col.get_normal())
		if col.get_normal().dot(up) > 0.4:
			landed = true
	if landed and target_v <= 0.0 and move.length() < 0.01:
		velocity = velocity.lerp(Vector3.ZERO, clampf(10.0 * delta, 0.0, 1.0))

	_update_reticle(up)


# Project a ring onto the ground directly below the ship (the landing spot).
func _update_reticle(up: Vector3) -> void:
	if _reticle == null:
		_reticle = MeshInstance3D.new()
		var t := TorusMesh.new()
		t.inner_radius = 1.6
		t.outer_radius = 2.2
		_reticle.mesh = t
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(0.4, 1.0, 0.55)
		_reticle.material_override = m
		get_parent().add_child(_reticle)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(global_position, global_position - up * (ASSIST_ALT * 2.0))
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		_reticle.visible = false
		return
	var pos: Vector3 = hit["position"] + up * 0.15
	var xb := up.cross(Vector3(1, 0, 0))
	if xb.length() < 0.01:
		xb = up.cross(Vector3(0, 0, 1))
	xb = xb.normalized()
	_reticle.global_transform = Transform3D(Basis(xb, up, xb.cross(up)), pos)
	_reticle.visible = true


# Nearest of the six cardinal directions to `v`, as a unit vector.
func _snap_to_axis(v: Vector3) -> Vector3:
	var ax := absf(v.x)
	var ay := absf(v.y)
	var az := absf(v.z)
	if ax >= ay and ax >= az:
		return Vector3(signf(v.x), 0, 0)
	elif ay >= az:
		return Vector3(0, signf(v.y), 0)
	return Vector3(0, 0, signf(v.z))


# Smoothly rotate so the ship's up aligns to `up_target`, preserving heading.
func _level_to(up_target: Vector3, delta: float) -> void:
	var b := global_transform.basis
	var cur_up := b.y
	var d := clampf(cur_up.dot(up_target), -1.0, 1.0)
	if d < 0.9999:
		var full := Quaternion(cur_up, up_target)
		var step := Quaternion.IDENTITY.slerp(full, clampf(LEVEL_SPEED * delta, 0.0, 1.0))
		global_transform.basis = (Basis(step) * b).orthonormalized()


# --- meshing + collision ------------------------------------------------------

func rebuild() -> void:
	if _mi == null:
		_mi = MeshInstance3D.new()
		add_child(_mi)

	var verts := PackedVector3Array()   # opaque hull (surface 0)
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var gverts := PackedVector3Array()  # glass (surface 1, transparent)
	var gnormals := PackedVector3Array()
	var gcolors := PackedColorArray()

	for v in blocks:
		var id: int = blocks[v]
		if id == Blocks.AIR:
			continue
		# Blocks that are not cubes are not DRAWN as cubes. The hull mesher used
		# to fill every cell, so a door was a slab of wall and a length of cable
		# was a solid metre of it -- which is what made a conduit in the cabin
		# look like somebody had left a crate there.
		var shape := _shape_of(v, id)
		if not shape.is_empty():
			_emit_shape(v, id, shape, verts, normals, colors)
			continue
		# Machinery is a model, built in build_props, not a painted cube. Its
		# cell is still OCCUPIED -- the hull round it draws no faces toward it,
		# so leaving it out here makes no hole.
		if FITTINGS.has(id):
			continue
		if id == Blocks.DOOR_OPEN:
			continue  # open doorways render as an empty gap
		var is_glass: bool = id == Blocks.GLASS
		var base := Blocks.color_of(id)
		var origin := Vector3(v)
		for face in FACES:
			var nid: int = blocks.get(v + face["n"], Blocks.AIR)
			if nid == Blocks.DOOR_OPEN:
				nid = Blocks.AIR  # draw the face that borders an open doorway
			# glass draws only vs open air; opaque draws vs air OR glass (so you can
			# see the hull through a window instead of a hole)
			if is_glass:
				if nid != Blocks.AIR:
					continue
			elif nid != Blocks.AIR and nid != Blocks.GLASS:
				continue
			# Cockpit's forward (-Z) face is a bright windshield so you can always
			# see which way the ship points -- both while building and flying.
			var fcol := base
			if id == Blocks.COCKPIT and face["n"] == Vector3i(0, 0, -1):
				fcol = Color(0.55, 0.95, 1.0)
			var s: float = Chunk._face_shade(face["d"], face["s"])
			var col := Color(fcol.r * s, fcol.g * s, fcol.b * s, base.a if is_glass else 1.0)
			var nrm := Vector3(face["n"])
			var c: Array = face["c"]
			var p0: Vector3 = origin + c[0]
			var p1: Vector3 = origin + c[1]
			var p2: Vector3 = origin + c[2]
			var p3: Vector3 = origin + c[3]
			if is_glass:
				gverts.append(p0); gverts.append(p1); gverts.append(p2)
				gverts.append(p0); gverts.append(p2); gverts.append(p3)
				for _k in 6:
					gnormals.append(nrm)
					gcolors.append(col)
			else:
				verts.append(p0); verts.append(p1); verts.append(p2)
				verts.append(p0); verts.append(p2); verts.append(p3)
				for _k in 6:
					normals.append(nrm)
					colors.append(col)

	if verts.is_empty() and gverts.is_empty():
		_mi.mesh = null
	else:
		var m := ArrayMesh.new()
		if not verts.is_empty():
			var arr := []
			arr.resize(Mesh.ARRAY_MAX)
			arr[Mesh.ARRAY_VERTEX] = verts
			arr[Mesh.ARRAY_NORMAL] = normals
			arr[Mesh.ARRAY_COLOR] = colors
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			m.surface_set_material(m.get_surface_count() - 1, Chunk._get_plain_material())
		if not gverts.is_empty():
			var garr := []
			garr.resize(Mesh.ARRAY_MAX)
			garr[Mesh.ARRAY_VERTEX] = gverts
			garr[Mesh.ARRAY_NORMAL] = gnormals
			garr[Mesh.ARRAY_COLOR] = gcolors
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, garr)
			m.surface_set_material(m.get_surface_count() - 1, Chunk._get_water_material())
		_mi.mesh = m
		_mi.material_override = null

	_rebuild_collision()
	_recompute_habitable()
	# The fittings follow the blocks: fit a cockpit and its console appears,
	# break it and the console goes with it.
	build_props()


## The sub-boxes a block is really made of, in its own cell, or [] when it is
## an honest cube. Chunk.shape_boxes knows every shape the game has; all this
## has to work out is which neighbours a cable should reach toward.
func _shape_of(v: Vector3i, id: int) -> Array:
	var base := Blocks.bottom_of(id)
	var shaped: bool = base == Blocks.WIRE or Blocks.is_door(id) 		or Blocks.is_stair(base) or Blocks.is_slab(base)
	if not shaped:
		return []
	var conn := 0
	if base == Blocks.WIRE:
		for fi in 6:
			var nb: int = blocks.get(v + (Chunk._WFACE[fi] as Vector3i), Blocks.AIR)
			if nb == Blocks.AIR:
				continue
			var nbase := Blocks.bottom_of(nb)
			# Cable runs to other cable and to the machinery it feeds. It does
			# NOT run into plain hull -- a conduit lying on the floor would
			# otherwise sprout an arm into the floor it is lying on.
			if nbase == Blocks.WIRE:
				conn |= 1 << fi
			elif nbase != Blocks.METAL and nbase != Blocks.GLASS and not Blocks.is_door(nb):
				conn |= 1 << fi
	return Chunk.shape_boxes(id, Vector3.UP, conn)


## Every face of every sub-box. Nothing is culled against the neighbours here:
## these shapes do not fill their cell, so the cell next door cannot hide them.
func _emit_shape(v: Vector3i, id: int, boxes: Array, verts: PackedVector3Array,
		normals: PackedVector3Array, colors: PackedColorArray) -> void:
	var base := Blocks.color_of(id)
	var origin := Vector3(v)
	for b in boxes:
		var lo: Vector3 = origin + (b[0] as Vector3)
		var hi: Vector3 = origin + (b[1] as Vector3)
		for fi in 6:
			var sh: float = Chunk._face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
			var col := Color(base.r * sh, base.g * sh, base.b * sh, 1.0)
			var nrm := Vector3(Chunk._WFACE[fi])
			var q := Chunk._box_face(lo, hi, fi)
			verts.append(q[0]); verts.append(q[1]); verts.append(q[2])
			verts.append(q[0]); verts.append(q[2]); verts.append(q[3])
			for _k in 6:
				normals.append(nrm)
				colors.append(col)


# One box collider per block. Works both while the ship is a stationary build
# surface and while it moves (a moving body needs convex shapes, not a trimesh).
func _rebuild_collision() -> void:
	for cs in _col_shapes:
		if is_instance_valid(cs):
			cs.queue_free()
	_col_shapes.clear()
	for v in blocks:
		if blocks[v] == Blocks.DOOR_OPEN:
			continue  # open door has no collider -- walk through it
		if Blocks.bottom_of(int(blocks[v])) == Blocks.WIRE:
			continue  # you step over a cable, you do not climb it
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3.ONE
		cs.shape = box
		cs.position = Vector3(v) + Vector3(0.5, 0.5, 0.5)
		add_child(cs)
		_col_shapes.append(cs)
