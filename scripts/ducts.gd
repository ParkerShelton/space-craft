class_name Ducts
extends Node
## Moving things from one box to another, without building a computer to do it.
##
## Three pieces and no logic. A DUCT is a run of pipe. A LOADER empties the
## container it is bolted to into that run. Everything else touching the run
## receives, and where a thing ends up comes down to one rule:
##
##     a container that already holds some of it wants it more than one that
##     does not.
##
## That is the whole of sorting. Put one plank in the plank chest and planks
## find it from then on -- the setup is tidying up once, which you were going
## to do anyway. A FILTER overrides the guess where being told is better, and
## an unfiltered chest with room in it catches whatever nothing else claimed.
##
## There is deliberately no signal, no delay and no state to reason about. Two
## blocks whose interaction you have to work out is the line between pipes and
## redstone, and this stays the near side of it.
##
## Nothing else in the game knows this file exists. Delete it and the ducts
## stop moving things; everything else carries on.

const TICK := 0.55            # seconds between one loader and its next parcel
const REACH := 2048           # duct cells followed before giving up
const SPEED := 5.5            # cells per second a parcel travels
const PARCEL_SIZE := 0.22

var world: WorldManager
var _t := 0.0
var _flying: Array = []       # parcels in the air: {node, path, at}


func _process(delta: float) -> void:
	_move_parcels(delta)
	if world == null:
		return
	_t -= delta
	if _t > 0.0:
		return
	_t = TICK
	for st in world._stations:
		var s: Station = st
		if is_instance_valid(s) and s.kind == Blocks.DUCT_LOADER and s.active:
			_run_loader(s)


# --- one loader, one parcel ------------------------------------------------------

func _run_loader(loader: Station) -> void:
	var p: Planet = world.nearest_planet(loader.global_position)
	if p == null:
		return
	var here := p.world_to_voxel(loader.global_position)
	var boxes := _containers_on(p)
	# What it is emptying: a container against the loader itself.
	var src: Station = null
	for n in _NEIGH6:
		var cand = boxes.get(here + n)
		if cand != null and _holds_items(cand):
			src = cand
			break
	if src == null:
		return
	# Everything the run can reach, and how to get there.
	var paths := _reachable(p, here)
	if paths.is_empty():
		return
	# Take the first thing in the source that somewhere else wants more than
	# the source does.
	for i in src.storage.size():
		var slot: Dictionary = src.storage[i]
		var id := int(slot.get("id", Blocks.AIR))
		if id == Blocks.AIR or int(slot.get("count", 0)) <= 0:
			continue
		var mine := _want(src, id)
		var best: Station = null
		var best_score := mine
		var best_cell := here
		for cell in paths:
			for n2 in _NEIGH6:
				var dst = boxes.get((cell as Vector3i) + n2)
				if dst == null or dst == src or dst == loader:
					continue
				var w := _want(dst, id)
				if w > best_score and _has_room(dst, slot):
					best = dst
					best_score = w
					best_cell = cell
		if best == null:
			continue
		_send(p, src, i, best, paths[best_cell] as Array)
		return


## How much a container wants one of these, higher being keener.
##
##   3  a filter on it names this exactly
##   2  it already holds some -- the whole of sort-by-example
##   1  it has room and nothing to say about what goes in it
##  -1  a filter on it names something else
func _want(box: Station, id: int) -> int:
	var f := _filter_on(box)
	if f != Blocks.AIR:
		return 3 if f == id else -1
	for slot in box.storage:
		if int(slot.get("id", Blocks.AIR)) == id and int(slot.get("count", 0)) > 0:
			return 2
	return 1


## The filter guarding this container, or AIR. A Filter station standing
## against a container speaks for it.
func _filter_on(box: Station) -> int:
	if world == null:
		return Blocks.AIR
	var p: Planet = world.nearest_planet(box.global_position)
	if p == null:
		return Blocks.AIR
	var at := p.world_to_voxel(box.global_position)
	for n in _NEIGH6:
		for st in world._stations:
			var s: Station = st
			if not is_instance_valid(s) or s.kind != Blocks.DUCT_FILTER:
				continue
			if p.world_to_voxel(s.global_position) != at + n:
				continue
			if s.storage.is_empty():
				continue
			return int(s.storage[0].get("id", Blocks.AIR))
	return Blocks.AIR


## Whether store_add would actually take one. Asked the way the store itself
## answers it: a station slot has no ceiling, so there is room if some slot
## already holds this very stack, or if any slot is genuinely empty -- empty
## meaning no count AND no loose eighths, because a slot holding change is not
## a free slot.
func _has_room(box: Station, slot: Dictionary) -> bool:
	for s in box.storage:
		if int(s.get("count", 0)) > 0 and Blocks.same_stack(s, slot):
			return true
		if int(s.get("count", 0)) == 0 and int(s.get("eighths", 0)) == 0:
			return true
	return false


func _holds_items(box: Station) -> bool:
	for s in box.storage:
		if int(s.get("count", 0)) > 0:
			return true
	return false


# --- the run ----------------------------------------------------------------------

const _NEIGH6 := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]


## Every duct cell the run reaches from `from`, with the way back to it. The
## loader itself is the start, so a loader has to be touching its own pipe.
func _reachable(p: Planet, from: Vector3i) -> Dictionary:
	var seen := {}
	var q: Array[Vector3i] = []
	for n in _NEIGH6:
		var a: Vector3i = from + n
		if Blocks.is_duct(p.get_id(a)):
			seen[a] = [p.to_global(Vector3(a) + Vector3(0.5, 0.5, 0.5))]
			q.append(a)
	var head := 0
	while head < q.size() and seen.size() < REACH:
		var c: Vector3i = q[head]
		head += 1
		for n2 in _NEIGH6:
			var b: Vector3i = c + n2
			if seen.has(b) or not Blocks.is_duct(p.get_id(b)):
				continue
			var path: Array = (seen[c] as Array).duplicate()
			path.append(p.to_global(Vector3(b) + Vector3(0.5, 0.5, 0.5)))
			seen[b] = path
			q.append(b)
	return seen


## Every container on this world that a run could feed, by cell.
func _containers_on(p: Planet) -> Dictionary:
	var out := {}
	for st in world._stations:
		var s: Station = st
		if not is_instance_valid(s) or s.storage.is_empty():
			continue
		if s.kind == Blocks.DUCT_FILTER:
			continue     # it speaks for its neighbour; it is not a destination
		out[p.world_to_voxel(s.global_position)] = s
	return out


# --- the parcel ---------------------------------------------------------------------

func _send(p: Planet, src: Station, slot_i: int, dst: Station, path: Array) -> void:
	var slot: Dictionary = src.storage[slot_i]
	var id := int(slot["id"])
	var props: Dictionary = (slot.get("props", {}) as Dictionary).duplicate(true)
	var srcname := str(slot.get("src", ""))
	var mat: Dictionary = (slot.get("mat", {}) as Dictionary).duplicate(true)
	if dst.store_add(id, 1, props, srcname, mat) > 0:
		return     # it did not fit after all; leave it where it is
	slot["count"] = int(slot["count"]) - 1
	if int(slot["count"]) <= 0:
		slot["id"] = Blocks.AIR
		slot["props"] = {}
		slot["src"] = ""
		slot["mat"] = {}
	# ...and something to watch. The item is already delivered -- this is the
	# picture of it going, which is allowed to be a moment behind.
	var full: Array = path.duplicate()
	full.append(dst.global_position + Vector3(0, 0.4, 0))
	_spawn_parcel(id, mat, full)


## A small one of whatever it is, sliding along the run.
func _spawn_parcel(id: int, mat: Dictionary, path: Array) -> void:
	if path.size() < 2:
		return
	var mi := MeshInstance3D.new()
	var col: Color = mat.get("color", Blocks.color_of(id))
	if ItemModels.has_model(id):
		mi.mesh = ItemModels.mesh(id)
		mi.scale = Vector3.ONE * (PARCEL_SIZE * 1.6)
	else:
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE * PARCEL_SIZE
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = 0.9
		bm.material = m
		mi.mesh = bm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	mi.global_position = path[0]
	_flying.append({"node": mi, "path": path, "at": 0.0})


func _move_parcels(delta: float) -> void:
	if _flying.is_empty():
		return
	var live: Array = []
	for f in _flying:
		var p: Dictionary = f
		var mi := p["node"] as MeshInstance3D
		if mi == null or not is_instance_valid(mi):
			continue
		var path: Array = p["path"]
		var at: float = float(p["at"]) + delta * SPEED
		if at >= float(path.size() - 1):
			mi.queue_free()
			continue
		p["at"] = at
		var i := int(at)
		var t: float = at - float(i)
		mi.global_position = (path[i] as Vector3).lerp(path[i + 1] as Vector3, t)
		mi.rotate_y(delta * 2.2)
		live.append(p)
	_flying = live
