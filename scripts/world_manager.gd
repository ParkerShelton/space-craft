class_name WorldManager
extends Node3D

## Owns every planet, decides which one you're closest to, streams that planet's
## chunks around you, and answers gravity queries for the player controller.

const RENDER_DISTANCE := 5        # chunk radius streamed around the player
const LOADS_PER_FRAME := 4        # chunks meshed per frame (spreads out hitches)
const STREAM_MARGIN := 48.0       # extra reach (voxels) beyond a planet's surface

var planets: Array[Planet] = []
var player: Node3D
var _ships: Array[Ship] = []
var _stations: Array[Station] = []

const SAVE_PATH := "user://spacecraft_save.dat"
const SAVE_BAK := "user://spacecraft_save.bak"
const SAVE_VERSION := 1

var world_seed := 0   # master seed the planets were generated from (persisted)


## Read just the saved world seed (so planets can be regenerated identically before
## the rest of the save is applied). Returns -1 if there is no save.
func saved_world_seed() -> int:
	var d = _read_save(SAVE_PATH)
	if typeof(d) != TYPE_DICTIONARY:
		d = _read_save(SAVE_BAK)
	if typeof(d) == TYPE_DICTIONARY:
		return int(d.get("world_seed", -1))
	return -1


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH) or FileAccess.file_exists(SAVE_BAK)


func _read_save(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var d = f.get_var()
	f.close()
	return d


## Write the whole mutable world to disk. Terrain, ores, flora and water are all
## pure functions of each planet's seed (defined in code), so we only persist what
## the player changed: block edits per planet, the player's state, and any ships.
func save_game() -> bool:
	var data := {
		"version": SAVE_VERSION,
		"world_seed": world_seed,
		"player": {},
		"planets": {},   # planet name -> edits_by_chunk
		"ships": [],
		"stations": [],
	}
	if player != null:
		var pl = player  # untyped: reach Player-specific members off the Node3D ref
		data["player"] = {
			"pos": pl.global_position,
			"basis": pl.global_transform.basis,
			"inv": pl.inv,
			"active_slot": pl.active_slot,
		}
	for p in planets:
		if not p._edits_by_chunk.is_empty():
			data["planets"][p.planet_name] = p._edits_by_chunk
	var ship_index := {}
	for s in _ships:
		if is_instance_valid(s) and not s.blocks.is_empty():
			ship_index[s] = data["ships"].size()
			data["ships"].append({"blocks": s.blocks, "xform": s.global_transform, "meta": s.block_meta})
	for st in _stations:
		if not is_instance_valid(st):
			continue
		var entry := {"kind": st.kind, "storage": st.storage}
		var par := st.get_parent()
		if par is Ship and ship_index.has(par):
			entry["ship"] = ship_index[par]   # mounted -> save relative to its ship
			entry["local"] = st.transform
		else:
			entry["xform"] = st.global_transform
		data["stations"].append(entry)

	# Keep the previous save as a backup before overwriting, so a bad/interrupted
	# write can never lose the last good world.
	if FileAccess.file_exists(SAVE_PATH):
		var prev := FileAccess.get_file_as_bytes(SAVE_PATH)
		if prev.size() > 0:
			var b := FileAccess.open(SAVE_BAK, FileAccess.WRITE)
			if b != null:
				b.store_buffer(prev)
				b.close()

	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("save_game: could not open " + SAVE_PATH)
		return false
	f.store_var(data)  # binary Variant serialization handles Vector3i keys natively
	f.close()
	return true


## Restore a saved world. Safe to call at startup (nothing streamed yet) or live
## while on foot -- edited chunks that are already loaded get re-meshed.
func load_game() -> bool:
	if not has_save():
		return false
	# prefer the primary save; fall back to the backup if it's missing or corrupt
	var data = _read_save(SAVE_PATH)
	if typeof(data) != TYPE_DICTIONARY:
		data = _read_save(SAVE_BAK)
	if typeof(data) != TYPE_DICTIONARY:
		return false

	# planets: swap in the saved edits and re-mesh anything already loaded
	var pedits: Dictionary = data.get("planets", {})
	for p in planets:
		p.load_edits(pedits.get(p.planet_name, {}))

	# ships: rebuild from scratch
	for s in _ships:
		if is_instance_valid(s):
			s.queue_free()
	_ships.clear()
	for sd in data.get("ships", []):
		var ship := Ship.new()
		ship.world = self
		add_child(ship)
		ship.blocks = sd.get("blocks", {})
		ship.block_meta = sd.get("meta", {})
		ship.global_transform = sd.get("xform", Transform3D.IDENTITY)
		ship.rebuild()
		_ships.append(ship)

	# stations: rebuild from scratch
	for st in _stations:
		if is_instance_valid(st):
			st.queue_free()
	_stations.clear()
	for std in data.get("stations", []):
		var station := Station.new()
		var skind: int = std.get("kind", Blocks.SMELTER)
		if std.has("ship") and int(std["ship"]) >= 0 and int(std["ship"]) < _ships.size():
			var ship: Ship = _ships[int(std["ship"])]
			ship.add_child(station)
			station.configure(skind, self)
			station.transform = std.get("local", Transform3D.IDENTITY)
			ship.add_collision_exception_with(station)
		else:
			add_child(station)
			station.configure(skind, self)
			station.global_transform = std.get("xform", Transform3D.IDENTITY)
		if std.has("storage"):
			station.storage = std["storage"]
		_stations.append(station)

	# player
	var pd: Dictionary = data.get("player", {})
	if player != null and not pd.is_empty():
		var pl = player  # untyped: reach Player-specific members off the Node3D ref
		if pd.has("pos"):
			pl.global_position = pd["pos"]
		if pd.has("basis"):
			var t: Transform3D = pl.global_transform
			t.basis = pd["basis"]
			pl.global_transform = t
		if pd.has("inv"):
			pl.inv = pd["inv"]
		pl.active_slot = pd.get("active_slot", 0)
		pl.velocity = Vector3.ZERO
		pl._refresh_slots()
	return true


## Create a new ship seeded with a cockpit. Snaps orientation to the block grid
## (axis-aligned, parallel to the floor) and position to whole cells, so it lines
## up with the world instead of sitting at an odd angle.
func spawn_ship(pos: Vector3, up: Vector3, fwd: Vector3) -> Ship:
	var ship := Ship.new()
	ship.world = self
	add_child(ship)

	var y := _snap_axis(up)                          # up = the face axis you're on
	var f := _snap_axis(fwd - y * fwd.dot(y))        # forward = nearest grid axis you face
	if f == Vector3.ZERO or absf(f.dot(y)) > 0.5:
		f = _any_perp(y)
	var z := -f                                      # forward is -Z
	var x := y.cross(z)
	ship.global_transform = Transform3D(Basis(x, y, z), pos.round())

	ship.set_block(Vector3i.ZERO, Blocks.COCKPIT)
	_ships.append(ship)
	return ship


# Nearest outward cardinal axis to v (Vector3.ZERO if v is ~zero).
func _snap_axis(v: Vector3) -> Vector3:
	if v.length() < 0.001:
		return Vector3.ZERO
	var ax := absf(v.x)
	var ay := absf(v.y)
	var az := absf(v.z)
	if ax >= ay and ax >= az:
		return Vector3(signf(v.x), 0, 0)
	elif ay >= az:
		return Vector3(0, signf(v.y), 0)
	return Vector3(0, 0, signf(v.z))


# A cardinal axis perpendicular to `axis`.
func _any_perp(axis: Vector3) -> Vector3:
	for c in [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 1, 0)]:
		if absf(c.dot(axis)) < 0.5:
			return c
	return Vector3(0, 0, -1)


## Place a crafting station at a grid cell, oriented flat to the surface (its up
## axis = the face you're standing on), like spawn_ship.
func spawn_station(kind: int, pos: Vector3, up: Vector3, fwd: Vector3) -> Station:
	var st := Station.new()
	add_child(st)
	st.configure(kind, self)
	var y := _snap_axis(up)
	if y == Vector3.ZERO:
		y = Vector3.UP
	var f := _snap_axis(fwd - y * fwd.dot(y))
	if f == Vector3.ZERO or absf(f.dot(y)) > 0.5:
		f = _any_perp(y)
	var z := -f
	var x := y.cross(z)
	# `pos` is the exact voxel-cell corner in world space; don't round (planets sit
	# at non-integer positions, so rounding would offset the station from the grid)
	st.global_transform = Transform3D(Basis(x, y, z), pos)
	_stations.append(st)
	return st


## Mount a station on a ship at a local grid cell; it rides along with the ship.
func spawn_station_on_ship(kind: int, ship: Ship, local_v: Vector3i) -> Station:
	var st := Station.new()
	ship.add_child(st)
	st.configure(kind, self)
	st.transform = Transform3D(Basis.IDENTITY, Vector3(local_v))
	# The station is a static body inside the ship's own volume; without this the
	# ship's move_and_collide would collide with it and the ship couldn't fly.
	ship.add_collision_exception_with(st)
	_stations.append(st)
	return st


## Nearest still-alive station within `max_dist` of a world point, or null.
func nearest_station(world_pos: Vector3, max_dist: float) -> Station:
	_stations = _stations.filter(func(s): return is_instance_valid(s))
	var best: Station = null
	var best_d := max_dist * max_dist
	for s in _stations:
		var d: float = (s.global_position - world_pos).length_squared()
		if d < best_d:
			best_d = d
			best = s
	return best


## Nearest still-alive ship to a world point, or null.
func nearest_ship(world_pos: Vector3) -> Ship:
	_ships = _ships.filter(func(s): return is_instance_valid(s))
	var best: Ship = null
	var best_d := INF
	for s in _ships:
		var d: float = (s.global_position - world_pos).length_squared()
		if d < best_d:
			best_d = d
			best = s
	return best


func add_planet(cfg: Dictionary) -> Planet:
	var p := Planet.new()
	p.name = cfg.get("name", "Planet")
	p.position = cfg.get("position", Vector3.ZERO)
	add_child(p)
	p.configure(cfg)
	planets.append(p)
	return p


## Strongest gravity contributor wins (avoids fighting fields between planets).
func gravity_at(world_pos: Vector3) -> Vector3:
	var best := Vector3.ZERO
	var best_mag := 0.0
	for p in planets:
		var g := p.gravity_at(world_pos)
		var m := g.length()
		if m > best_mag:
			best_mag = m
			best = g
	return best


## The planet whose surface is nearest the given point (or null if far from all).
func nearest_planet(world_pos: Vector3) -> Planet:
	var best: Planet = null
	var best_d := INF
	for p in planets:
		var surface_dist: float = p.altitude(world_pos)  # shape-aware (cube/sphere)
		if surface_dist < best_d:
			best_d = surface_dist
			best = p
	return best


func _physics_process(_delta: float) -> void:
	if player == null:
		return
	var here := player.global_position
	var active := nearest_planet(here)
	for p in planets:
		if p == active:
			var reach := p.radius + p.terrain_amp + STREAM_MARGIN
			if p.center_distance(here) <= reach + RENDER_DISTANCE * Blocks.CHUNK_SIZE:
				p.stream(p.world_to_voxel(here), RENDER_DISTANCE)
				p.process_load_queue(LOADS_PER_FRAME)
