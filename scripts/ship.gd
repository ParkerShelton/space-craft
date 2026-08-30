class_name Ship
extends CharacterBody3D

## An independent, player-built voxel grid. While you build it, it sits still and
## you can stand on it (per-block box colliders). Once it has a cockpit + a
## thruster + enough blocks, you can pilot it: scripted arcade flight where thrust
## fights the planet's radial gravity, so you must out-thrust the world to lift off
## and then coast free once gravity fades in space.

var blocks := {}  # Vector3i(local voxel) -> block id
var flying := false
var world: WorldManager  # set on spawn; used for gravity while coasting
var in_gravity := false  # true while in launch/landing-assist mode (HUD)
var landed := false      # resting on the ground (HUD)

# --- flight tuning ---
const THRUST_PER := 300.0     # thrust accel per thruster, divided by block count
const SHIP_DRAG := 0.6        # velocity damping (arcade feel + control)
const YAW_SENS := 0.0022
const PITCH_SENS := 0.0022
const ROLL_SPEED := 1.6
const GRAVITY_FLIGHT := 3.0    # above this gravity => launch/landing assist mode
const LEVEL_SPEED := 2.5       # how fast the ship auto-levels toward belly-down

var _mi: MeshInstance3D
var _col_shapes: Array[CollisionShape3D] = []
var _chase_cam: Camera3D

const FACES := [
	{"n": Vector3i(1, 0, 0),  "d": 0, "s": 1,  "c": [Vector3(1,0,0), Vector3(1,1,0), Vector3(1,1,1), Vector3(1,0,1)]},
	{"n": Vector3i(-1, 0, 0), "d": 0, "s": -1, "c": [Vector3(0,0,0), Vector3(0,0,1), Vector3(0,1,1), Vector3(0,1,0)]},
	{"n": Vector3i(0, 1, 0),  "d": 1, "s": 1,  "c": [Vector3(0,1,0), Vector3(0,1,1), Vector3(1,1,1), Vector3(1,1,0)]},
	{"n": Vector3i(0, -1, 0), "d": 1, "s": -1, "c": [Vector3(0,0,0), Vector3(1,0,0), Vector3(1,0,1), Vector3(0,0,1)]},
	{"n": Vector3i(0, 0, 1),  "d": 2, "s": 1,  "c": [Vector3(0,0,1), Vector3(1,0,1), Vector3(1,1,1), Vector3(0,1,1)]},
	{"n": Vector3i(0, 0, -1), "d": 2, "s": -1, "c": [Vector3(0,0,0), Vector3(0,1,0), Vector3(1,1,0), Vector3(1,0,0)]},
]


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


func set_block(v: Vector3i, id: int) -> void:
	if id == Blocks.AIR:
		blocks.erase(v)
	else:
		blocks[v] = id
	if blocks.is_empty():
		queue_free()
		return
	rebuild()


func get_status() -> Dictionary:
	var has_cockpit := false
	var thrusters := 0
	for v in blocks:
		match blocks[v]:
			Blocks.COCKPIT: has_cockpit = true
			Blocks.THRUSTER: thrusters += 1
	return {
		"count": blocks.size(),
		"cockpit": has_cockpit,
		"thrusters": thrusters,
		"can_fly": has_cockpit and thrusters >= 1 and blocks.size() >= 4,
	}


## Available thrust acceleration (m/s^2). Must beat local gravity to lift off.
func thrust_accel() -> float:
	var st := get_status()
	if st["count"] == 0:
		return 0.0
	return THRUST_PER * float(st["thrusters"]) / float(st["count"])


# --- piloting -----------------------------------------------------------------

func enable_chase_camera() -> void:
	if _chase_cam == null:
		_chase_cam = Camera3D.new()
		_chase_cam.far = 4000.0
		_chase_cam.rotation.x = deg_to_rad(-12)
		add_child(_chase_cam)
	var c := center_local()
	_chase_cam.position = c + Vector3(0, 4, 13)
	_chase_cam.make_current()


## Called each physics frame by the player while piloting. Two modes: inside a
## planet's gravity it's launch/landing assist (auto-levelled, up/down + gentle
## positioning, no manual rotation); out in space it's full 6-axis flight.
func fly(delta: float, world: WorldManager, input: Dictionary) -> void:
	var g := world.gravity_at(global_position)
	in_gravity = g.length() > GRAVITY_FLIGHT
	if in_gravity:
		_fly_assisted(delta, input, g)
	else:
		landed = false
		_fly_free(delta, input, g)


# Full 6-DOF: mouse steer + roll, thrust on all axes. Used in space.
func _fly_free(delta: float, input: Dictionary, g: Vector3) -> void:
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


# Launch/landing assist: auto-level belly-down toward the planet, no manual
# rotation. Space/Shift climb & descend; WASD nudges horizontally to line up a
# landing. Settles to rest on touchdown.
func _fly_assisted(delta: float, input: Dictionary, g: Vector3) -> void:
	# Level to the nearest cardinal axis (not raw radial gravity) so the ship sits
	# flat on the axis-aligned voxel terrain and matches how the player stands.
	var up_target := -_snap_to_axis(g)
	_level_to(up_target, delta)

	var b := global_transform.basis
	var up := b.y
	var fwd := -b.z
	var right := b.x
	var ta := thrust_accel()
	var move: Vector2 = input["move"]
	var ascend: float = input["ascend"]
	var thrust := fwd * move.y * ta + right * move.x * ta + up * ascend * ta

	velocity += (g + thrust) * delta
	velocity = velocity.lerp(Vector3.ZERO, clampf(SHIP_DRAG * delta, 0.0, 1.0))

	var col := move_and_collide(velocity * delta)
	landed = false
	if col != null:
		velocity = velocity.slide(col.get_normal())
		if col.get_normal().dot(up) > 0.4:  # touched down on the ground
			landed = true

	# When sitting on the ground with no input, settle to a dead stop (no drift/jitter).
	if landed and ascend <= 0.0 and move.length() < 0.01:
		velocity = velocity.lerp(Vector3.ZERO, clampf(10.0 * delta, 0.0, 1.0))


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

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()

	for v in blocks:
		var id: int = blocks[v]
		if id == Blocks.AIR:
			continue
		var base := Blocks.color_of(id)
		var origin := Vector3(v)
		for face in FACES:
			if blocks.get(v + face["n"], Blocks.AIR) != Blocks.AIR:
				continue
			# Cockpit's forward (-Z) face is a bright windshield so you can always
			# see which way the ship points -- both while building and flying.
			var fcol := base
			if id == Blocks.COCKPIT and face["n"] == Vector3i(0, 0, -1):
				fcol = Color(0.55, 0.95, 1.0)
			var s: float = Chunk._face_shade(face["d"], face["s"])
			var col := Color(fcol.r * s, fcol.g * s, fcol.b * s, 1.0)
			var nrm := Vector3(face["n"])
			var c: Array = face["c"]
			var p0: Vector3 = origin + c[0]
			var p1: Vector3 = origin + c[1]
			var p2: Vector3 = origin + c[2]
			var p3: Vector3 = origin + c[3]
			verts.append(p0); verts.append(p1); verts.append(p2)
			verts.append(p0); verts.append(p2); verts.append(p3)
			for _k in 6:
				normals.append(nrm)
				colors.append(col)

	if verts.is_empty():
		_mi.mesh = null
	else:
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_NORMAL] = normals
		arr[Mesh.ARRAY_COLOR] = colors
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		_mi.mesh = m
		_mi.material_override = Chunk._get_material()

	_rebuild_collision()


# One box collider per block. Works both while the ship is a stationary build
# surface and while it moves (a moving body needs convex shapes, not a trimesh).
func _rebuild_collision() -> void:
	for cs in _col_shapes:
		if is_instance_valid(cs):
			cs.queue_free()
	_col_shapes.clear()
	for v in blocks:
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3.ONE
		cs.shape = box
		cs.position = Vector3(v) + Vector3(0.5, 0.5, 0.5)
		add_child(cs)
		_col_shapes.append(cs)
