class_name TreeFall
extends Node3D
## A tree that has been cut through, toppling.
##
## Not physics: the tree is lifted out of the world whole, drawn as one mesh,
## tipped over about its stump with a scripted swing, and put back into the grid
## where it lands. Logs come down lying on their side; leaves burst on impact
## and leave behind the saplings they would have given had you broken them one
## at a time, dropped on the ground where they fell.

## The whole swing, stump to ground, if nothing stops it sooner.
const FALL_TIME := 1.15
## A tree is not searched past this many blocks, so an enormous one costs one
## bounded walk -- anything bigger simply stays standing.
const MAX_LOGS := 200
const MAX_LEAVES := 900
## How far out from its own logs a leaf still counts as this tree's rather than
## a neighbour's.
const LEAF_REACH := 4
## At most this many leaf bursts per tree. Every leaf bursting is hundreds of
## particle systems in one frame; a handful spread through the crown reads the
## same.
const MAX_BURSTS := 24

var planet: Planet
var world: WorldManager
var player: Node
var logs := {}          # Vector3i -> raw id, where they stood
var leaves := {}
var pivot := Vector3.ZERO   # planet space: the top of the cut, on the fall side
var up := Vector3i.ZERO
var fall := Vector3i.ZERO   # which way it goes over

var _t := 0.0
var _angle := 0.0
var _axis := Vector3.ZERO
var _mesh: MeshInstance3D
var _done := false


## Is this log part of a tree that no longer reaches the ground? If so, cut it
## loose and start it falling. `cut` is the cell just emptied.
static func try_fell(p: Planet, wm: WorldManager, pl: Node3D, cut: Vector3i) -> bool:
	var upf := -p.gravity_at(p.to_global(Vector3(cut) + Vector3(0.5, 0.5, 0.5)))
	upf = (p.global_transform.basis.inverse() * upf).normalized()
	var upi := _snap_axis(upf)
	if upi == Vector3i.ZERO:
		return false
	# Every piece of trunk touching the cut is a candidate: the stump below will
	# turn out to be grounded and stay, the part above will not.
	for n in _N26:
		var s: Vector3i = cut + n
		if not _is_tree_log(p, s):
			continue
		var found := _gather_logs(p, s)
		if found.is_empty():
			continue      # grounded, or too big to be a tree
		var tf := TreeFall.new()
		tf.planet = p
		tf.world = wm
		tf.player = pl
		tf.logs = found
		tf.leaves = _gather_leaves(p, found)
		tf.up = upi
		# Away from whoever cut it, along a grid axis so it lands on the grid.
		var away := p.to_local(pl.global_position)
		away = (Vector3(cut) + Vector3(0.5, 0.5, 0.5)) - away
		away -= Vector3(upi) * away.dot(Vector3(upi))
		tf.fall = _snap_axis(away)
		if tf.fall == Vector3i.ZERO or tf.fall == upi or tf.fall == -upi:
			tf.fall = _perp(upi)
		# Hinge at the top of the cut, on the edge it tips toward.
		tf.pivot = Vector3(cut) + Vector3(0.5, 0.5, 0.5) + Vector3(upi) * 0.5 \
			+ Vector3(tf.fall) * 0.5
		tf._begin()
		return true
	return false


## A log the world grew, as opposed to one somebody placed: a cabin wall with
## its bottom row knocked out is not a tree, and must not fall over.
static func _is_tree_log(p: Planet, v: Vector3i) -> bool:
	if not Blocks.is_wood(Blocks.bottom_of(p.get_id(v))):
		return false
	var d = p._edits_by_chunk.get(p.chunk_of(v))
	return d == null or not (d as Dictionary).has(v)


static func _is_tree_leaf(p: Planet, v: Vector3i) -> bool:
	if not Blocks.is_leaf(Blocks.bottom_of(p.get_id(v))):
		return false
	var d = p._edits_by_chunk.get(p.chunk_of(v))
	return d == null or not (d as Dictionary).has(v)


## The connected logs from `start`, or empty if any of them still stands on
## something -- ground, a placed block, anything solid that is not tree.
static func _gather_logs(p: Planet, start: Vector3i) -> Dictionary:
	var out := {start: p.get_id(start)}
	var todo: Array[Vector3i] = [start]
	while not todo.is_empty():
		var c: Vector3i = todo.pop_back()
		for n in _N26:
			var q: Vector3i = c + n
			if out.has(q):
				continue
			if _is_tree_log(p, q):
				out[q] = p.get_id(q)
				if out.size() > MAX_LOGS:
					return {}
				todo.append(q)
				continue
			# Face neighbours only for support: a trunk touching the ground at a
			# corner is not standing on it.
			if absi(n.x) + absi(n.y) + absi(n.z) != 1:
				continue
			# Anything solid that is not this tree holds it up -- including a log
			# somebody PLACED against it, which is why tree logs were taken out
			# above and wood in general is not waved through here.
			var id := Blocks.bottom_of(p.get_id(q))
			if id == Blocks.AIR or id == Blocks.WATER or Blocks.is_leaf(id) \
					or Blocks.is_plant(id):
				continue
			return {}     # standing on something
	return out


static func _gather_leaves(p: Planet, logs_in: Dictionary) -> Dictionary:
	var out := {}
	var dist := {}
	var todo: Array[Vector3i] = []
	for c in logs_in:
		dist[c] = 0
		todo.append(c)
	var i := 0
	while i < todo.size():
		var c: Vector3i = todo[i]
		i += 1
		var dc: int = dist[c]
		if dc >= LEAF_REACH:
			continue
		for n in _N6:
			var q: Vector3i = c + n
			if dist.has(q):
				continue
			if not _is_tree_leaf(p, q):
				continue
			dist[q] = dc + 1
			out[q] = p.get_id(q)
			if out.size() >= MAX_LEAVES:
				return out
			todo.append(q)
	return out


func _begin() -> void:
	# Out of the world in one go: one remesh, not one per block.
	planet.begin_batch()
	for c in logs:
		world.edit_block(planet, c, Blocks.AIR)
	for c in leaves:
		world.edit_block(planet, c, Blocks.AIR)
	planet.end_batch()
	_axis = Vector3(up).cross(Vector3(fall)).normalized()
	planet.add_child(self)
	position = pivot
	_mesh = MeshInstance3D.new()
	_mesh.mesh = _build_mesh()
	add_child(_mesh)


func _build_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for group in [logs, leaves]:
		for c in group:
			var col: Color = planet.color_of(Blocks.bottom_of(int(group[c])))
			var lo := Vector3(c) - pivot
			var hi := lo + Vector3.ONE
			for fi in 6:
				var n: Vector3i = Chunk._WFACE[fi]
				if logs.has(c + n) or leaves.has(c + n):
					continue    # buried inside the tree
				var s := Chunk._face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
				st.set_color(Color(col.r * s, col.g * s, col.b * s))
				var q := Chunk._box_face(lo, hi, fi)
				st.set_normal(Vector3(n))
				st.add_vertex(q[0]); st.add_vertex(q[1]); st.add_vertex(q[2])
				st.add_vertex(q[0]); st.add_vertex(q[2]); st.add_vertex(q[3])
	var m := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 1.0
	m.surface_set_material(0, mat)
	return m


func _physics_process(delta: float) -> void:
	if _done:
		return
	if planet == null or not is_instance_valid(planet):
		queue_free()
		return
	_t += delta
	# Starts slow and speeds up, the way a real one goes: a tree barely moves at
	# first and is flat on the ground a moment later.
	var k := clampf(_t / FALL_TIME, 0.0, 1.0)
	var want := PI * 0.5 * k * k
	# Stop early on a hillside, rather than swinging through it.
	if _hits_ground(want):
		_land()
		return
	_angle = want
	basis = Basis(_axis, _angle)
	if k >= 1.0:
		_land()


## Would any log, at this angle, be inside solid ground?
func _hits_ground(a: float) -> bool:
	var b := Basis(_axis, a)
	for c in logs:
		var p: Vector3 = pivot + b * (Vector3(c) + Vector3(0.5, 0.5, 0.5) - pivot)
		var cell := Vector3i(p.floor())
		if logs.has(cell) or leaves.has(cell):
			continue
		if planet._is_solid_block(cell):
			return true
	return false


func _land() -> void:
	_done = true
	var b := Basis(_axis, _angle)
	var down := -up
	# Lying down, a trunk runs along the fall. Recorded on the log so it draws
	# with its grain that way rather than as a standing trunk on its side.
	var lying := 0 if fall.x != 0 else (1 if fall.y != 0 else 2)
	var laid := {}
	# Lowest first, so a log settles onto the ones already down beneath it.
	var order: Array = logs.keys()
	order.sort_custom(func(a, c):
		return Vector3(a).dot(Vector3(up)) < Vector3(c).dot(Vector3(up)))
	planet.begin_batch()
	for c in order:
		var p: Vector3 = pivot + b * (Vector3(c) + Vector3(0.5, 0.5, 0.5) - pivot)
		var cell := Vector3i(p.floor())
		# Settle: down until something is under it.
		for _i in 40:
			var under: Vector3i = cell + down
			if laid.has(under) or planet._is_solid_block(under):
				break
			cell = under
		var here := planet.get_id(cell)
		if laid.has(cell) or not (here == Blocks.AIR or Blocks.is_washable(here)):
			# Nowhere to put it: it lands as an item instead, where it came down.
			var wid := Blocks.bottom_of(int(logs[c]))
			ItemDrop.spawn(planet, p, wid, 1, {}, "", {}, Blocks.name_of(wid),
				Vector3(up) * 2.0)
			continue
		laid[cell] = true
		world.edit_block(planet, cell, Blocks.make_log(Blocks.bottom_of(int(logs[c])), lying))
	planet.end_batch()
	_burst_leaves(b)
	Audio.at("break_wood", planet.to_global(pivot))
	queue_free()


## Where each leaf would have landed, a burst of leaf-coloured bits -- and the
## saplings those leaves would have given, dropped where they fell.
func _burst_leaves(b: Basis) -> void:
	var keys: Array = leaves.keys()
	var step := maxi(1, keys.size() / MAX_BURSTS)
	var upv := Vector3(up)
	for i in keys.size():
		var c: Vector3i = keys[i]
		var p: Vector3 = pivot + b * (Vector3(c) + Vector3(0.5, 0.5, 0.5) - pivot)
		if i % step == 0:
			_burst(p, planet.color_of(Blocks.bottom_of(int(leaves[c]))))
		# The same chance a leaf broken by hand has.
		if randf() < Blocks.SAPLING_DROP_CHANCE and is_instance_valid(player):
			var item: Dictionary = player.call("_roll_flora_seed", planet, "tree")
			if item.is_empty():
				continue
			var kick := upv * randf_range(2.0, 4.0) \
				+ Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 1.2
			ItemDrop.spawn(planet, p, int(item["id"]), 1, item["props"],
				str(item["src"]), item["mat"], str(item["label"]), kick)


func _burst(where: Vector3, col: Color) -> void:
	var ps := CPUParticles3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 0.13
	ps.mesh = box
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ps.material_override = m
	ps.amount = 10
	ps.lifetime = 0.8
	ps.one_shot = true
	ps.explosiveness = 0.95
	ps.direction = Vector3.UP
	ps.spread = 70.0
	ps.initial_velocity_min = 1.5
	ps.initial_velocity_max = 4.0
	ps.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	ps.emission_box_extents = Vector3.ONE * 0.5
	ps.scale_amount_min = 0.6
	ps.scale_amount_max = 1.4
	var gw := planet.global_transform.basis * -Vector3(up)
	ps.gravity = gw.normalized() * 12.0
	planet.add_child(ps)
	var upg := (planet.global_transform.basis * Vector3(up)).normalized()
	var x := upg.cross(Vector3(0.31, 0.12, 0.94)).normalized()
	ps.global_transform = Transform3D(Basis(x, upg, x.cross(upg)), planet.to_global(where))
	ps.emitting = true
	ps.get_tree().create_timer(ps.lifetime + 0.3).timeout.connect(ps.queue_free)


static func _snap_axis(v: Vector3) -> Vector3i:
	var a := v.abs()
	if a.x < 0.0001 and a.y < 0.0001 and a.z < 0.0001:
		return Vector3i.ZERO
	if a.x >= a.y and a.x >= a.z:
		return Vector3i(signi(int(signf(v.x))), 0, 0)
	if a.y >= a.z:
		return Vector3i(0, int(signf(v.y)), 0)
	return Vector3i(0, 0, int(signf(v.z)))


static func _perp(u: Vector3i) -> Vector3i:
	return Vector3i(1, 0, 0) if u.x == 0 else Vector3i(0, 0, 1)


const _N6: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
static var _N26: Array[Vector3i] = _make_n26()


static func _make_n26() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for x in range(-1, 2):
		for y in range(-1, 2):
			for z in range(-1, 2):
				if x != 0 or y != 0 or z != 0:
					out.append(Vector3i(x, y, z))
	return out
