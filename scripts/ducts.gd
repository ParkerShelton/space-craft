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
## Fallback only: a run carries at the speed of its own pipe (see
## Blocks.duct_speed), and the slowest length in a run sets the pace, the way
## the narrowest pipe does.
const SPEED := 3.0
const PARCEL_SIZE := 0.22

var world: WorldManager
var _t := 0.0
var _flying: Array = []       # parcels in the air: {node, path, at, pace}
var _pace := 0.0              # the slowest pipe in the run just walked


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
	var boxes := _sources_on(p)
	# What it is emptying: a container against the loader itself.
	var src: Station = null
	for n in _NEIGH6:
		var cand = boxes.get(here + n)
		if cand != null and _holds_items(cand):
			src = cand
			break
	if src == null:
		return
	var paths := _reachable(p, here)
	if paths.is_empty():
		return
	var ports := _ports_on(p)
	# Take the first thing in the source that somewhere else wants more than
	# the source does.
	for i in src.storage.size():
		var slot: Dictionary = src.storage[i]
		var id := int(slot.get("id", Blocks.AIR))
		if id == Blocks.AIR or int(slot.get("count", 0)) <= 0:
			continue
		var mine := _want_src(src, id)
		var best: Station = null
		var best_port: Station = null
		var best_score := mine
		var best_prio := -99
		var best_path: Array = []
		for cell in paths:
			for n2 in _NEIGH6:
				var entry = ports.get((cell as Vector3i) + n2)
				if entry == null:
					continue
				var port: Station = entry["port"]
				var dst: Station = entry["box"]
				if dst == src or dst == loader:
					continue
				var w := _want(port, dst, id)
				if w < 0:
					continue
				# Better wanting wins; a tie goes to the higher priority, which
				# is the only number in the whole system and does nothing else.
				if w > best_score or (w == best_score and w > mine
						and port.port_priority > best_prio):
					if not _has_room(dst, slot):
						continue
					best = dst
					best_port = port
					best_score = w
					best_prio = port.port_priority
					best_path = paths[cell] as Array
		if best == null:
			continue
		_send(p, src, i, best, best_path)
		return


## How much a container wants one of these, higher being keener.
##
##   3  a filter on it names this exactly
##   2  it already holds some -- the whole of sort-by-example
##   1  it has room and nothing to say about what goes in it
##  -1  a filter on it names something else
func _want(port: Station, box: Station, id: int) -> int:
	if not port.port_allows(id):
		return -1
	if port.port_names(id):
		return 3
	for slot in box.storage:
		if int(slot.get("id", Blocks.AIR)) == id and int(slot.get("count", 0)) > 0:
			return 2
	return 1


## How much the SOURCE wants to keep it, on the same scale -- a parcel only
## moves somewhere that wants it more than where it already is, which is what
## stops two chests holding the same thing passing it back and forth forever.
func _want_src(_box: Station, _id: int) -> int:
	# Nothing. A loader is bolted to this box in order to empty it, so the box
	# holding some of a thing is not a claim on it -- which is the whole point
	# of having put a loader there.
	#
	# This returned 1, and a destination has to want it MORE than the source
	# does, so an ordinary empty chest -- which also scores 1 -- could never
	# win. Two chests, a loader and a port, correctly built, and nothing ever
	# moved: the only deliveries that could happen were into a box that already
	# held some or had a filter naming it. The comment three functions up has
	# always said an unfiltered chest with room catches whatever nothing else
	# claimed; it just never did.
	return 0


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
	_pace = 1e9
	var seen := {}
	var q: Array[Vector3i] = []
	for n in _NEIGH6:
		var a: Vector3i = from + n
		if Blocks.is_duct(p.get_id(a)):
			seen[a] = [p.to_global(Vector3(a) + Vector3(0.5, 0.5, 0.5))]
			_pace = minf(_pace, Blocks.duct_speed(p.get_id(a), p.block_tags.get(a, {})))
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
			_pace = minf(_pace, Blocks.duct_speed(p.get_id(b), p.block_tags.get(b, {})))
			q.append(b)
	return seen


## Every PORT on this world, by cell, with the container it speaks for.
##
## A run used to feed anything it happened to touch, which meant a pipe could
## not be taken past a chest without filling it. Things enter a container
## through a Port and nowhere else now, so a network says plainly where things
## go in and where they come out, and a line can cross a room without leaking
## into it.
func _ports_on(p: Planet) -> Dictionary:
	var boxes := {}
	for st in world._stations:
		var s: Station = st
		if is_instance_valid(s) and not s.storage.is_empty() and s.kind != Blocks.DUCT_PORT:
			boxes[p.world_to_voxel(s.global_position)] = s
	var out := {}
	for st2 in world._stations:
		var port: Station = st2
		if not is_instance_valid(port) or port.kind != Blocks.DUCT_PORT:
			continue
		var at := p.world_to_voxel(port.global_position)
		for n in _NEIGH6:
			var box = boxes.get(at + n)
			if box != null:
				out[at] = {"port": port, "box": box}
				break
	return out


## Everything that could give things up: a container with a Loader on it.
func _sources_on(p: Planet) -> Dictionary:
	var boxes := {}
	for st in world._stations:
		var s: Station = st
		if is_instance_valid(s) and not s.storage.is_empty() and s.kind != Blocks.DUCT_PORT:
			boxes[p.world_to_voxel(s.global_position)] = s
	return boxes


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
	_flying.append({"node": mi, "path": path, "at": 0.0,
		"pace": SPEED if _pace > 1e8 else _pace})


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
		var at: float = float(p["at"]) + delta * float(p.get("pace", SPEED))
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
