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
	if blocks.is_empty():
		queue_free()
		return
	rebuild()


func get_status() -> Dictionary:
	var has_cockpit := false
	var thrusters := 0
	var life_support := false
	for v in blocks:
		match blocks[v]:
			Blocks.COCKPIT: has_cockpit = true
			Blocks.THRUSTER: thrusters += 1
			Blocks.LIFE_SUPPORT: life_support = true
	return {
		"count": blocks.size(),
		"cockpit": has_cockpit,
		"thrusters": thrusters,
		"can_fly": has_cockpit and thrusters >= 1 and blocks.size() >= 4,
		"life_support": life_support,
		"sealed": _sealed,
		"habitable": _habitable,
	}


## The ship keeps you alive inside (breathing, climate) only when it has a Life
## Support block AND a sealed interior (an enclosed air pocket).
func is_habitable() -> bool:
	return _habitable


## Is a world point physically inside this habitable ship's sealed interior? This
## is what makes standing inside the cabin safe (not merely being in the cockpit).
func is_inside_pressurized(world_pos: Vector3) -> bool:
	if not _habitable or _sealed_cells.is_empty():
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
	return not blocks.has(c) or blocks[c] == Blocks.DOOR_OPEN


const MAX_DOOR_GROUP := 9  # a door wall opens/closes together, up to a 3x3-ish patch
const _DOOR_NEIGH6 := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]

## Toggle a door block open/closed (by local voxel). Returns true if it was a door.
## Cube doors are built edge-to-edge as a wall, so opening one opens every door
## cell touching it (flood-fill, capped at MAX_DOOR_GROUP) rather than just itself.
func toggle_door(local_v: Vector3i) -> bool:
	var id: int = blocks.get(local_v, Blocks.AIR)
	if not Blocks.is_door(id):
		return false
	var new_id := Blocks.door_toggle_of(id)
	for v in _door_group(local_v):
		set_block(v, new_id, block_meta.get(v, {}))
	return true


func _door_group(start: Vector3i) -> Array:
	var seen := {start: true}
	var queue: Array = [start]
	var result: Array = [start]
	var qi := 0
	while qi < queue.size() and result.size() < MAX_DOOR_GROUP:
		var cur: Vector3i = queue[qi]
		qi += 1
		for d in _DOOR_NEIGH6:
			var nb: Vector3i = cur + d
			if seen.has(nb):
				continue
			seen[nb] = true
			if Blocks.is_door(blocks.get(nb, Blocks.AIR)):
				result.append(nb)
				queue.append(nb)
				if result.size() >= MAX_DOOR_GROUP:
					break
	return result


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
		if id == Blocks.AIR or id == Blocks.DOOR_OPEN:
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
			m.surface_set_material(m.get_surface_count() - 1, Chunk._get_material())
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
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3.ONE
		cs.shape = box
		cs.position = Vector3(v) + Vector3(0.5, 0.5, 0.5)
		add_child(cs)
		_col_shapes.append(cs)
