class_name WorldManager
extends Node3D

## Owns every planet, decides which one you're closest to, streams that planet's
## chunks around you, and answers gravity queries for the player controller.

## Chunk radius streamed around the player. 5 was 80 blocks -- close enough that
## terrain visibly arrived a chunk ahead of your feet. Raising it is only
## affordable because terrain generation got much cheaper (see the tree cache in
## Planet.generation_sample); the cold fill still happens behind the loading
## screen, and walking only ever pays for the shell entering the sphere.
## Chunk radius streamed around the player. A setting now rather than a
## constant: it is the one number that decides both how far you can see and how
## hard the machine has to work, and which of those matters more is not
## something this file can know.
var render_distance := RENDER_DISTANCE_DEFAULT
const RENDER_DISTANCE_DEFAULT := 10
const RENDER_DISTANCE_MIN := 4
const RENDER_DISTANCE_MAX := 16
const LOADS_PER_FRAME := 4        # chunks meshed per frame (spreads out hitches)
const STREAM_MARGIN := 48.0       # extra reach (voxels) beyond a planet's surface

var planets: Array[Planet] = []
var player: Node3D
## Set by Main when a co-op session starts; null in single player.
var net: Net
var _ships: Array[Ship] = []
var _stations: Array[Station] = []

## Every world you have, newest played first. One line per world: which slot's
## files it lives in, what you called it, and when you were last in it. The save
## files themselves are the truth about a world's CONTENTS -- this is only the
## shelf they sit on, so losing it costs you the names, not the worlds.
const INDEX_PATH := "user://worlds.json"


## What is written down, whether or not the files are still there.
static func _read_index() -> Array:
	var out: Array = []
	if FileAccess.file_exists(INDEX_PATH):
		var f := FileAccess.open(INDEX_PATH, FileAccess.READ)
		if f != null:
			var got = JSON.parse_string(f.get_as_text())
			if got is Array:
				out = got
	return out


## Worlds made before stations became models cannot be played: their benches
## are eighth-blocks that no longer mean anything. Rather than half-load one,
## every world from before that is cleared out once, and the shelf starts empty.
const FORMAT := 2


static func purge_old_worlds() -> int:
	var gone := 0
	for w in _read_index():
		if int((w as Dictionary).get("fmt", 1)) < FORMAT:
			forget_world(str((w as Dictionary).get("slot", "")))
			gone += 1
	# ...and the nameless save from before there was a shelf at all.
	for legacy in [SAVE_PATH, SAVE_BAK]:
		if FileAccess.file_exists(legacy):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy))
			gone += 1
	_write_index(_read_index().filter(func(w): return int((w as Dictionary).get("fmt", 1)) >= FORMAT))
	return gone


## The worlds you have, most recently played first. A world whose files have
## gone is dropped from what is shown, but see note_world: it is not dropped
## from what is WRITTEN, or a world made and not yet saved would vanish the
## moment another was made.
static func list_worlds() -> Array:
	var out: Array = _read_index()
	# A save from before worlds had names still has to be playable, so it is
	# taken onto the shelf the first time this is asked.
	var legacy := FileAccess.file_exists(SAVE_PATH) or FileAccess.file_exists(SAVE_BAK)
	var has_legacy := false
	for w in out:
		if str((w as Dictionary).get("slot", "")) == "":
			has_legacy = true
	if legacy and not has_legacy:
		out.append({"slot": "", "name": "My World", "played": 0})
	out = out.filter(func(w):
		var sl := str((w as Dictionary).get("slot", ""))
		return FileAccess.file_exists(_path_for(sl)) or FileAccess.file_exists(_bak_for(sl)))
	out.sort_custom(func(a, b): return int(a.get("played", 0)) > int(b.get("played", 0)))
	return out


static func _path_for(slot: String) -> String:
	return SAVE_PATH if slot == "" else "user://%s.dat" % slot


static func _bak_for(slot: String) -> String:
	return SAVE_BAK if slot == "" else "user://%s.bak" % slot


static func _write_index(arr: Array) -> void:
	var f := FileAccess.open(INDEX_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(arr))


## Remember this world, or bring it to the top of the list because it has just
## been played.
static func note_world(slot: String, wname: String) -> void:
	var arr := _read_index()
	var found := false
	for w in arr:
		if str((w as Dictionary).get("slot", "")) == slot:
			found = true
			if wname != "":
				(w as Dictionary)["name"] = wname
			(w as Dictionary)["played"] = int(Time.get_unix_time_from_system())
	if not found:
		arr.append({"slot": slot, "name": wname, "fmt": FORMAT,
			"played": int(Time.get_unix_time_from_system())})
	_write_index(arr)


## A world and everything in it, gone.
static func forget_world(slot: String) -> void:
	for p in [_path_for(slot), _bak_for(slot)]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	var arr := _read_index().filter(func(w): return str((w as Dictionary).get("slot", "")) != slot)
	_write_index(arr)


## A slot name nothing else is using.
static func new_slot() -> String:
	return "world_%d_%d" % [int(Time.get_unix_time_from_system()), randi() % 1000]


const SAVE_PATH := "user://spacecraft_save.dat"
const SAVE_BAK := "user://spacecraft_save.bak"
const SAVE_VERSION := 1

## Which file this world reads and writes. Empty means the single-player save.
## A dedicated server sets its own slot, which is the whole point: the server may
## well be running on the same machine as somebody's game, and a world with no
## player in it must never be able to write over one that has.
var save_slot := ""

func save_path() -> String:
	return SAVE_PATH if save_slot == "" else "user://%s.dat" % save_slot


func bak_path() -> String:
	return SAVE_BAK if save_slot == "" else "user://%s.bak" % save_slot

var world_seed := 0   # master seed the planets were generated from (persisted)

# --- galaxy + warp travel ---
# The galaxy itself is a pure function of world_seed (like everything else),
# so it's rebuilt on load rather than saved; only WHICH system is current needs
# persisting. `planets` above are always just the current system's planets.
var galaxy: Galaxy
var current_system_index := 0
# main.gd points this at its own _generate_planets so WorldManager can rebuild
# a system's planets without needing to know anything about Main's type.
var planet_generator: Callable

func current_system() -> Dictionary:
	if galaxy == null or current_system_index < 0 or current_system_index >= galaxy.systems.size():
		return {}
	return galaxy.systems[current_system_index]


## Tear down the current system and generate a different one in its place. If
## `warp_ship` is given (the ship performing the warp -- it needs a Warp Drive
## and must already be in space, enforced by player.gd before calling this),
## that ship travels along and arrives in space above the new home world,
## along with anything mounted on it; the player rides along already (piloting
## slaves the player's position to the ship every physics tick). Otherwise the
## player itself is placed at the new home world's spawn point on foot.
## No travel time/fuel/distance yet -- this is instant, not real flight.
## KNOWN LIMITATION: anything else in the old system -- other ships, world-
## placed stations, a base you built -- is NOT preserved. There's no per-system
## save state yet, only "whatever's currently loaded," so it's simply gone.
func warp_to_system(index: int, warp_ship: Ship = null) -> Dictionary:
	if galaxy == null or index < 0 or index >= galaxy.systems.size() or not planet_generator.is_valid():
		return {}
	var keep_ship := warp_ship if (warp_ship != null and is_instance_valid(warp_ship)) else null
	for s in _ships:
		if is_instance_valid(s) and s != keep_ship:
			s.queue_free()
	_ships.clear()
	if keep_ship != null:
		_ships.append(keep_ship)
	var kept_stations: Array[Station] = []
	for st in _stations:
		if not is_instance_valid(st):
			continue
		if keep_ship != null and st.get_parent() == keep_ship:
			kept_stations.append(st)  # mounted on the warping ship -- travels with it
		else:
			st.queue_free()
	_stations = kept_stations
	for p in planets:
		if is_instance_valid(p):
			p.queue_free()
	planets.clear()

	current_system_index = index
	var sysdef: Dictionary = galaxy.systems[index]
	planet_generator.call(self, sysdef)
	if planets.is_empty():
		return sysdef
	var home: Planet = planets[0]

	if keep_ship != null:
		var arrive: Vector3 = home.to_global(
			home._point_at_height(Vector3.UP, home.radius + home.atmo_height + 300.0))
		keep_ship.global_position = arrive
		keep_ship.velocity = Vector3.ZERO
	elif player != null:
		var pl = player  # untyped: reach Player-specific members off the Node3D ref
		pl.global_position = home.find_spawn_point(Vector3.UP)
		pl.velocity = Vector3.ZERO
		if home.altitude(pl.global_position) < 96.0:
			var pcc := home.chunk_of(home.world_to_voxel(pl.global_position))
			for dy in range(1, -4, -1):
				home.build_chunk_sync(pcc + Vector3i(0, dy, 0))
	return sysdef


## Read just the saved world seed (so planets can be regenerated identically before
## the rest of the save is applied). Returns -1 if there is no save.
func saved_world_seed() -> int:
	var d = _read_save(save_path())
	if typeof(d) != TYPE_DICTIONARY:
		d = _read_save(bak_path())
	if typeof(d) == TYPE_DICTIONARY:
		return int(d.get("world_seed", -1))
	return -1


## Which system the save is in, read WITHOUT applying the save. A server has to
## know this before it generates anything: load_game overwrites the current
## system index, so generating the home system first and loading afterwards
## would leave the world claiming to be somewhere its planets are not.
func saved_system_index() -> int:
	var d = _read_save(save_path())
	if typeof(d) != TYPE_DICTIONARY:
		d = _read_save(bak_path())
	if typeof(d) == TYPE_DICTIONARY:
		return int(d.get("current_system_index", -1))
	return -1


func has_save() -> bool:
	return FileAccess.file_exists(save_path()) or FileAccess.file_exists(bak_path())


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
## The ONE place a planet is edited from gameplay. Single player writes straight
## through; in co-op it goes via the host, which is the only authority on what
## the world contains. Routing every edit through here is what keeps two worlds
## from drifting apart -- there is no second path to forget about.
func edit_block(p: Planet, v: Vector3i, id: int) -> void:
	if net != null and net.active:
		net.edit_block(p.planet_name, v, id)
	else:
		p.set_block(v, id)


## Many cells as one change. See Planet.set_blocks. In co-op each cell still
## goes out on its own, because that is the message the other side
## understands; alone, it is one bulk write.
func edit_blocks(p: Planet, cells: Dictionary) -> void:
	if net != null and net.active:
		for v in cells:
			net.edit_block(p.planet_name, v, int(cells[v]))
	else:
		p.set_blocks(cells)


## The eighth-block twin of edit_block, and the same reason for existing: one
## choke point that every part change goes through, so nothing can quietly build
## something only the builder can see. An AIR id removes that eighth.
func edit_part(p: Planet, v: Vector3i, sub: int, id: int) -> void:
	if net != null and net.active:
		net.edit_part(p.planet_name, v, sub, id)
	elif id == Blocks.AIR:
		p.clear_part(v, sub)
	else:
		p.set_part(v, sub, id)


## Turning a finished build into a working machine.
##
## The RESULT is not sent, only the fact that it happened: assembly is a pure
## function of the blocks, and the blocks are already replicated, so every
## machine runs the same assembly and arrives at the same station rather than
## being told what to believe.
func assemble(p: Planet, v: Vector3i, parts: bool, require: int = -1) -> Dictionary:
	var res: Dictionary = p.assemble_parts(v, require) if parts else p.assemble_machine(v)
	if res.get("ok", false) and net != null and net.active:
		net.assembled(p.planet_name, v, parts)
	return res


## Commissioning a station into something bigger. Like assembly, only the fact
## travels: every machine re-runs it against blocks it already has.
func grow(p: Planet, v: Vector3i, to: int) -> Dictionary:
	var res := p.grow_station(v, to)
	if res.get("ok", false) and net != null and net.active:
		net.grown(p.planet_name, v, to)
	return res


## Sowing, reaping, and the clock they run on.
##
## Growth belongs to the host alone: two machines counting the same seconds
## arrive at different answers, and a crop that is ripe on one screen and not on
## another is a race over who gets to pull it.
func plant(p: Planet, v: Vector3i, key: String, tree: bool) -> bool:
	var ok := p.plant(v, key, tree)
	if ok and net != null and net.active:
		net.planted(p.planet_name, v, key, tree)
	return ok


## Morning, for everyone on this world. Applied here first so the player who
## asked sees their own night end at once.
func sleep_through_night(p: Planet) -> void:
	p.day_phase = Planet.MORNING_PHASE
	if net != null and net.active:
		net.slept(p.planet_name, Planet.MORNING_PHASE)


## Bone meal on a growing plant. Applied here and now whoever asked, so it
## feels instant, and then told to the network -- which answers with the stage
## it settled on rather than with "one more".
func feed_crop(p: Planet, v: Vector3i) -> bool:
	var stage := p.advance_crop(v)
	if stage == Planet.FEED_NOTHING:
		return false
	if net != null and net.active:
		net.fed(p.planet_name, v, stage)
	return true


func harvest_crop(p: Planet, v: Vector3i) -> Dictionary:
	var got := p.harvest(v)
	if not got.is_empty() and net != null and net.active:
		net.harvested(p.planet_name, v)
	return got


func tick_crops(delta: float) -> void:
	# A client is told what its crops are doing; it does not decide.
	if net != null and net.active and not net.is_host:
		return
	for p in planets:
		var changed: Array = p.grow_crops(delta)
		if not changed.is_empty() and net != null and net.active:
			net.crops_grew(p.planet_name, changed)


## Water moves on the host and is reported, exactly as crops are: see
## Planet.water_simulated for why it is not simulated in both places.
func tick_water(delta: float) -> void:
	var sim := not (net != null and net.active and not net.is_host)
	for p in planets:
		p.water_simulated = sim
	if not sim:
		return
	for p in planets:
		var changed: Array = p.flow_tick(delta)
		if not changed.is_empty() and net != null and net.active:
			net.water_moved(p.planet_name, changed)


func save_game() -> bool:
	var data := {
		"version": SAVE_VERSION,
		"world_seed": world_seed,
		"current_system_index": current_system_index,
		"player": {},
		"planets": {},   # planet name -> edits_by_chunk
		"water": {},     # planet name -> [[voxel, level], ...] for water that flowed
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
			"suit_slot": pl.suit_slot,
			"vanity": pl.vanity,
			"known_recipes": pl.known_recipes,
			"all_known": pl.all_known,
			"bed_planet": pl.bed_planet,
			"bed_pos": pl.bed_pos,
		}
	# What each player was carrying. Only a server has these (in single player the
	# one player's inventory is saved above), and they travel with the world so a
	# restart hands everyone their things back along with their buildings.
	if net != null and not net.profiles.is_empty():
		data["profiles"] = net.profiles
	# Time of day travels with the save, so stepping away and coming back does
	# not snap the world to a different hour.
	data["day_phase"] = {}
	data["machines"] = {}
	data["parts"] = {}
	for p in planets:
		# Not _edits_by_chunk itself: water the simulation placed is left out,
		# because loading the world works it out again. See Planet.saveable_edits.
		var pe: Dictionary = p.saveable_edits()
		if not pe.is_empty():
			data["planets"][p.planet_name] = pe
		# Saved SEPARATELY from the blocks, because a water cell is a block plus
		# a depth: without the depths a reloaded world turns every puddle it had
		# spread into a full one, and a shallow spill becomes a flood.
		var wrows: Array = p.water_rows(true)
		if not wrows.is_empty():
			data["water"][p.planet_name] = wrows
		if not p._parts_by_chunk.is_empty():
			data["parts"][p.planet_name] = p._parts_by_chunk
		data["day_phase"][p.planet_name] = p.day_phase
		# Only the CONTROLLER positions: the blocks already persist, so this
		# stays tiny and can never disagree with the world it describes.
		if not p.machine_cores.is_empty():
			data["machines"][p.planet_name] = p.machine_cores.duplicate()
		# Which of several things each one was commissioned INTO. Derivable from
		# the blocks only up to the point where the player had a choice.
		if not p.machine_kinds.is_empty():
			data.get_or_add("machine_kinds", {})[p.planet_name] = p.machine_kinds.duplicate()
		# A field has to still be there tomorrow, or planting is a waste of an
		# afternoon.
		if not p.sites_opened.is_empty():
			data.get_or_add("sites_opened", {})[p.planet_name] = p.sites_opened.keys()
		var crows: Array = p.crops_snapshot()
		if not crows.is_empty():
			data.get_or_add("crops", {})[p.planet_name] = crows
	var ship_index := {}
	for s in _ships:
		if is_instance_valid(s) and not s.blocks.is_empty():
			ship_index[s] = data["ships"].size()
			data["ships"].append({"blocks": s.blocks, "xform": s.global_transform,
				"meta": s.block_meta, "air": s.air, "charge": s.charge})
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
	if FileAccess.file_exists(save_path()):
		var prev := FileAccess.get_file_as_bytes(save_path())
		if prev.size() > 0:
			var b := FileAccess.open(bak_path(), FileAccess.WRITE)
			if b != null:
				b.store_buffer(prev)
				b.close()

	var f := FileAccess.open(save_path(), FileAccess.WRITE)
	if f == null:
		push_warning("save_game: could not open " + save_path())
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
	var data = _read_save(save_path())
	if typeof(data) != TYPE_DICTIONARY:
		data = _read_save(bak_path())
	if typeof(data) != TYPE_DICTIONARY:
		return false

	# current_system_index just tags along for now (no warp travel yet, so it can
	# never actually differ from what was already generated in main._start_world)
	current_system_index = data.get("current_system_index", 0)

	if net != null:
		net.profiles = data.get("profiles", {})

	# planets: swap in the saved edits and re-mesh anything already loaded
	var pwater: Dictionary = data.get("water", {})
	var pedits: Dictionary = data.get("planets", {})
	var pphase: Dictionary = data.get("day_phase", {})
	for p in planets:
		p._parts_by_chunk = (data.get("parts", {}) as Dictionary).get(p.planet_name, {})
		# Depths first: load_edits re-meshes what is already loaded, and a chunk
		# rebuilt before its levels arrive draws every cell full.
		p.load_water(pwater.get(p.planet_name, []))
		p.load_edits(pedits.get(p.planet_name, {}))
		p.day_phase = float(pphase.get(p.planet_name, p.day_phase))
		p.machine_cores = (data.get("machines", {}).get(p.planet_name, []) as Array).duplicate()
		p.machine_kinds = (data.get("machine_kinds", {}).get(p.planet_name, {}) as Dictionary).duplicate()
		p.load_crops((data.get("crops", {}).get(p.planet_name, []) as Array))
		p.sites_opened = {}
		for sid in (data.get("sites_opened", {}).get(p.planet_name, []) as Array):
			p.sites_opened[str(sid)] = true
		# Re-check each saved machine against the blocks actually present, so a
		# structure someone dismantled while it was unloaded comes back damaged
		# rather than silently still working.
		p.revalidate_machines()

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
		# Ships saved before tanks existed come back full rather than suffocating
		# their owner the moment the world loads.
		ship.air = float(sd.get("air", 1.0))
		ship.charge = float(sd.get("charge", 1.0))
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
		if pd.has("suit_slot"):
			pl.suit_slot = pd["suit_slot"]
		if pd.has("vanity"):
			pl.vanity = pd["vanity"]
		pl.active_slot = pd.get("active_slot", 0)
		# Saves from before the Recipe Book carry no learned set; they keep the
		# blanket "everything known" rather than losing every recipe.
		pl.known_recipes = pd.get("known_recipes", {})
		pl.all_known = bool(pd.get("all_known", true))
		# Saves from before beds existed simply have no bed claimed.
		pl.bed_planet = str(pd.get("bed_planet", ""))
		pl.bed_pos = pd.get("bed_pos", Vector3.ZERO)
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
	# origin = the cell CENTER (corner + 0.5, in world space); the box sits at local
	# zero so it stays centered whatever the orientation basis is. No rounding --
	# planets sit at non-integer positions.
	st.global_transform = Transform3D(Basis(x, y, z), pos + Vector3(0.5, 0.5, 0.5))
	_stations.append(st)
	return st


## Mount a station on a ship at a local grid cell; it rides along with the ship.
func spawn_station_on_ship(kind: int, ship: Ship, local_v: Vector3i) -> Station:
	var st := Station.new()
	ship.add_child(st)
	st.configure(kind, self)
	st.transform = Transform3D(Basis.IDENTITY, Vector3(local_v) + Vector3(0.5, 0.5, 0.5))
	# The station is a static body inside the ship's own volume; without this the
	# ship's move_and_collide would collide with it and the ship couldn't fly.
	ship.add_collision_exception_with(st)
	_stations.append(st)
	return st


## Is this point inside a station that is already standing? Stations are models
## rather than blocks, so nothing in the voxel world knows they are there; this
## is what stops a second bench being built through the first one, or a block
## being walled into one.
func station_blocking(world_pos: Vector3, skip: Station = null) -> bool:
	_stations = _stations.filter(func(s): return is_instance_valid(s))
	for s in _stations:
		if s == skip:
			continue
		var fp := StationModels.footprint(s.kind)
		var local: Vector3 = s.global_transform.affine_inverse() * world_pos
		if absf(local.x) <= float(fp.x) * 0.5 and absf(local.z) <= float(fp.z) * 0.5 				and local.y >= -0.5 and local.y <= float(fp.y) - 0.5:
			return true
	return false


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
	p._world_ref = self   # so built machines can create their headless stations
	_live = self          # so the static perf report has something to ask
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


# --- profiling ----------------------------------------------------------------
#
# A stutter is a thing you FEEL, and the only place the real answer lives is the
# world you felt it in -- not a benchmark of a world built to be measured. So
# the per-frame systems each keep a running total and a worst-single-call, and
# /perf reads them out.
#
# Left on permanently: two clock reads around a call that already costs
# microseconds is not worth a flag, and a profiler you have to enable is a
# profiler you do not have when you need it.
static var perf_total := {}   # system -> microseconds since the last report
static var perf_worst := {}   # system -> worst single call, microseconds
static var perf_calls := {}   # system -> how many times it ran
static var perf_since := 0    # ticks_usec at the last report


static func perf_mark(system: String, started: int) -> void:
	var us := Time.get_ticks_usec() - started
	perf_total[system] = int(perf_total.get(system, 0)) + us
	perf_calls[system] = int(perf_calls.get(system, 0)) + 1
	if us > int(perf_worst.get(system, 0)):
		perf_worst[system] = us


## The last world built, so the static perf report can ask it about its water.
## A static report needs SOMETHING to ask, and there is only ever one world.
static var _live: WorldManager


## What the water is doing, in numbers, so "it is slow" can be a measurement
## rather than a guess. Cells waiting in each lane, chunks waiting to be redrawn,
## and cells parked against terrain that has not loaded.
static func _water_report() -> Array:
	if _live == null or not is_instance_valid(_live):
		return []
	var out: Array = []
	for p in _live.planets:
		if p.water_style != Planet.WATER_LIQUID:
			continue
		if p._water_active.is_empty() and p._water_bg.is_empty() 				and p._water_dirty.is_empty() and p._wlev.is_empty():
			continue
		out.append("water %-9s yours %d, sea %d, redraws %d, stalled %d, wet %d" % [
			p.planet_name, p._water_active.size(), p._water_bg.size(),
			p._water_dirty.size(), p._water_stalled.size(), p._wlev.size()])
	return out


## Worst offenders since the last call, as lines of text, then resets.
static func perf_report() -> Array:
	var span := maxf(float(Time.get_ticks_usec() - perf_since) / 1000000.0, 0.001)
	var rows: Array = []
	for k in perf_total:
		rows.append({"name": k, "total": int(perf_total[k]),
			"worst": int(perf_worst.get(k, 0)), "calls": int(perf_calls.get(k, 0))})
	rows.sort_custom(func(a, b): return a["total"] > b["total"])
	var out: Array = ["over %.1fs -- ms/sec is the steady cost, worst is the spike" % span]
	for r in rows:
		if int(r["total"]) < 200:
			continue   # under 0.2ms in the whole window: not what you felt
		out.append("%-14s %6.2f ms/s   worst %5.2f ms   %d calls" % [
			r["name"], float(r["total"]) / 1000.0 / span,
			float(r["worst"]) / 1000.0, int(r["calls"])])
	if out.size() == 1:
		out.append("nothing measurable")
	perf_total.clear()
	for line in _water_report():
		out.append(line)
	perf_worst.clear()
	perf_calls.clear()
	perf_since = Time.get_ticks_usec()
	return out


func _physics_process(delta: float) -> void:
	if player == null:
		return
	var here := player.global_position
	var active := nearest_planet(here)
	for p in planets:
		if p == active:
			var reach := p.radius + p.terrain_amp + STREAM_MARGIN
			if p.center_distance(here) <= reach + render_distance * Blocks.CHUNK_SIZE:
				var t := Time.get_ticks_usec()
				p.stream(p.world_to_voxel(here), render_distance)
				perf_mark("stream", t)
				t = Time.get_ticks_usec()
				p.process_load_queue(LOADS_PER_FRAME)
				perf_mark("chunk build", t)
				t = Time.get_ticks_usec()
				p.update_fauna(delta, here, self)
				perf_mark("fauna", t)
				t = Time.get_ticks_usec()
				p.update_npcs(delta, here, self)
				perf_mark("npcs", t)
				t = Time.get_ticks_usec()
				p.tick_sites(delta, self)
				perf_mark("sites", t)
		else:
			if not p._creatures.is_empty():
				p.clear_fauna()  # wildlife only exists meaningfully near the player
			if not p._npcs.is_empty():
				p.clear_npcs()
