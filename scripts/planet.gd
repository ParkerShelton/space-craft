class_name Planet
extends Node3D

## A finite, roughly-spherical voxel world.
##
## The planet owns no big voxel array: terrain is a pure function of position
## (generation_sample), and only *player edits* are stored in `edits`. This keeps
## memory tiny and lets chunks stream in/out freely -- terrain is reproduced from
## the seed, edits are overlaid on top. Chunk nodes are children of the planet, so
## everything moves/rotates with the planet transform automatically.

const CS := Blocks.CHUNK_SIZE

# --- configuration (set via configure()) ---
var planet_name := "Planet"
var radius := 64.0          # nominal surface radius in voxels
var terrain_amp := 6.0      # +/- surface variation from noise
var surface_gravity := 12.0 # m/s^2 at the surface; drives walk-vs-float feel

# block palette
var pal_top := Blocks.GRASS
var pal_sub := Blocks.DIRT
var pal_rock := Blocks.ROCK
var pal_ore := Blocks.IRON_ORE
var pal_core := Blocks.CORE

var _seed := 0
var surface_noise := FastNoiseLite.new()
var ore_noise := FastNoiseLite.new()

# --- caves (worm-tunnel networks carved from the rock layer) ---
# Two independent scales, unioned together: BIG (sparse, wide) makes the rare
# giant caverns; FINE (common, narrow) is a pervasive vein network so digging
# straight down from almost anywhere eventually breaks into a tunnel.
var cave_noise := FastNoiseLite.new()   # BIG: ridged 3D noise; tunnels where the ridge is thin
var cave_noise2 := FastNoiseLite.new()  # BIG: second field, multiplied with the first -> branching
var cave_noise3 := FastNoiseLite.new()  # FINE: same technique, higher frequency, more common
var cave_noise4 := FastNoiseLite.new()  # FINE: branching partner for cave_noise3
var cave_enabled := false
var cave_threshold := 0.04         # BIG: higher = thinner/rarer caverns
var cave_threshold_fine := 0.04    # FINE: higher = thinner/rarer veins
var cave_min_depth := 5.0          # normal tunnels need at least this much roof
var cave_breach_threshold := 1.0       # BIG: only the strongest cores punch through shallower/to the surface
var cave_breach_threshold_fine := 1.0  # FINE: same idea for the vein network

var shape_cube := false  # true => cube-shaped planet (Chebyshev distance)

# --- atmosphere (for lighting/sky; set via configure) ---
var has_atmosphere := false
var atmo_color := Color(0.45, 0.68, 1.0)
var atmo_height := 90.0  # how far above the surface the sky fades to space

# --- environmental hazard (survival) ---
var hazard := "none"     # "none" / "cold" / "heat"
var hazard_dps := 0.0    # health/sec when exposed on the surface without protection

# --- flora (derived from seed in configure) ---
const TREE_CELL := 7          # avg spacing grid for tree placement
var tree_density := 0.0       # 0 = desert (no trees), up to ~0.6 = dense forest
var flora_leaves: Array = []  # this planet's leaf-color palette (subset of Blocks.LEAF_IDS)
var flora_wood := Blocks.WOOD
var flora_shape := 0          # 0 round, 1 tall/pine, 2 wide
var trunk_min := 3
var trunk_max := 6
var canopy_min := 2.0
var canopy_max := 4.0
var tree_reach := 0.0         # how far above the surface trees can extend

# --- ores (procedural per planet, derived from seed) ---
var ore_threshold := 10.0      # ore_noise above this => an ore vein (lower = richer)
# each def: {block, name, color, tier, props{h,d,e,r}, hardness, min_power, w, mind}
var ore_defs: Array = []
var _ore_by_block := {}       # block id (ORE_0..3) -> def, for fast lookup
var _ore_wsum := 0.0

# --- water (derived from seed unless overridden) ---
const WATER_NONE := 0
const WATER_LIQUID := 1
const WATER_ICE := 2
var water_style := WATER_NONE
var water_level := 0.0         # everything above the terrain and below this is water/ice

# --- fauna (procedural creatures, derived from seed like ores) ---
var fauna_land: Array = []     # surface species defs (see _make_species)
var fauna_fish: Array = []     # fish species defs; only non-empty on liquid-water planets
var fauna_cave: Array = []     # underground species defs; found only inside carved tunnels
var fauna_air: Array = []      # flying species defs; wander an altitude band above the surface
var _creatures: Array = []     # live Creature nodes currently spawned here
const MAX_CREATURES := 10
const CREATURE_SPAWN_RADIUS := 70.0   # spawn attempts land within this of the player
const CREATURE_CAVE_MAX_DEPTH := 55.0 # how far down a cave spawn search will probe
const CREATURE_DESPAWN_RADIUS := 160.0
const CREATURE_SPAWN_INTERVAL := 3.0
var _spawn_timer := 0.0

var lod_sphere: MeshInstance3D  # low-res far-away representation (hidden when close)

# player edits grouped by chunk: Vector3i(chunk) -> { Vector3i(voxel) -> id }
var _edits_by_chunk := {}
# currently loaded chunk nodes: Vector3i(chunk coord) -> Chunk
var loaded_chunks := {}
# chunks waiting to be dispatched to a worker thread
var _load_queue: Array[Vector3i] = []

# --- threaded meshing state ---
const MAX_INFLIGHT := 24     # concurrent worker tasks in flight
const APPLY_PER_FRAME := 6   # results turned into meshes per frame (main-thread cost)
var _inflight := {}          # cc -> WorkerThreadPool task id
var _ready_data := {}        # cc -> mesh data dict (filled by workers)
var _ready_mutex := Mutex.new()
var _dirty := {}             # loaded chunks needing an (async) re-mesh


func configure(cfg: Dictionary) -> void:
	planet_name = cfg.get("name", planet_name)
	radius = cfg.get("radius", radius)
	terrain_amp = cfg.get("amp", terrain_amp)
	surface_gravity = cfg.get("gravity", surface_gravity)
	_seed = cfg.get("seed", 0)
	pal_top = cfg.get("top", pal_top)
	pal_sub = cfg.get("sub", pal_sub)
	pal_rock = cfg.get("rock", pal_rock)
	pal_ore = cfg.get("ore", pal_ore)
	pal_core = cfg.get("core", pal_core)
	has_atmosphere = cfg.get("atmosphere", false)
	atmo_color = cfg.get("atmo_color", atmo_color)
	atmo_height = cfg.get("atmo_height", atmo_height)
	hazard = cfg.get("hazard", "none")
	hazard_dps = cfg.get("hazard_dps", 0.0)
	shape_cube = cfg.get("cube", true)  # cube-planet-test branch: cubes by default

	surface_noise.seed = _seed
	# Several rolling hills across the surface, regardless of planet size.
	surface_noise.frequency = 3.0 / maxf(radius, 1.0)
	surface_noise.fractal_octaves = 4
	surface_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH

	ore_noise.seed = _seed + 777
	ore_noise.frequency = 0.14
	ore_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX

	_derive_flora(cfg.get("tree_density", 0.0))
	_derive_ores()
	_derive_caves(cfg.get("cave_amount", -1.0))
	_derive_water(cfg)
	_derive_fauna()  # after water: fish generation depends on water_style
	_add_distant_sphere()


# Randomly give the planet water from its seed (unless the config overrides it):
# rivers/lakes/oceans (liquid), a frozen surface (ice), an ocean world (no land),
# or bone dry. `water_amount` 0..1 sets how high the water sits vs the terrain.
func _derive_water(cfg: Dictionary) -> void:
	var wr := RandomNumberGenerator.new()
	wr.seed = _seed + 321
	var style: String = cfg.get("water_style", "")
	match style:
		"none": water_style = WATER_NONE
		"liquid": water_style = WATER_LIQUID
		"ice": water_style = WATER_ICE
		_:
			var roll := wr.randf()
			water_style = WATER_NONE if roll < 0.28 else (WATER_ICE if roll < 0.5 else WATER_LIQUID)
	if water_style == WATER_NONE:
		return
	var amt: float = cfg.get("water_amount", wr.randf())
	water_level = radius + lerpf(-terrain_amp * 0.8, terrain_amp * 1.6, amt)


func _water_block() -> int:
	return Blocks.WATER if water_style == WATER_LIQUID else Blocks.ICE


# --- fauna: invent this planet's creatures from its seed, exactly like ores ----

func _derive_fauna() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed + 6060
	var n_land := rng.randi_range(2, 4)
	for i in n_land:
		fauna_land.append(_make_species(rng, "land"))
	if water_style == WATER_LIQUID:
		var rng2 := RandomNumberGenerator.new()
		rng2.seed = _seed + 7070
		var n_fish := rng2.randi_range(1, 3)
		for i in n_fish:
			fauna_fish.append(_make_species(rng2, "fish"))
	if cave_enabled:
		var rng3 := RandomNumberGenerator.new()
		rng3.seed = _seed + 8282
		var n_cave := rng3.randi_range(1, 3)
		for i in n_cave:
			fauna_cave.append(_make_species(rng3, "cave"))
	var rng4 := RandomNumberGenerator.new()
	rng4.seed = _seed + 9292
	var n_air := rng4.randi_range(1, 3)
	for i in n_air:
		fauna_air.append(_make_species(rng4, "air"))


# Invent one species: a unique name, body plan, size, color, and behavior. Harsher
# (hazardous) planets skew a bit more toward hostile wildlife; cave dwellers skew
# hostile and dark-colored (no sunlight down there).
func _make_species(rng: RandomNumberGenerator, kind: String) -> Dictionary:
	var sname: String = Blocks.FAUNA_NAME_PRE[rng.randi() % Blocks.FAUNA_NAME_PRE.size()] \
		+ Blocks.FAUNA_NAME_SUF[rng.randi() % Blocks.FAUNA_NAME_SUF.size()]
	var body: String
	match kind:
		"fish": body = "fish"
		"air": body = "flyer"
		"cave": body = ["serpent", "serpent", "quad", "biped"][rng.randi() % 4]
		_: body = ["quad", "quad", "biped", "serpent"][rng.randi() % 4]  # land
	var scale: float = rng.randf_range(0.5, 2.0) if kind in ["land", "cave"] else rng.randf_range(0.4, 1.6)
	var hue := rng.randf()
	var sat := rng.randf_range(0.35, 0.85)
	# cave dwellers are dim/dark (no sun down there); everything else reads bright
	var val := rng.randf_range(0.12, 0.35) if kind == "cave" else rng.randf_range(0.35, 0.85)
	var color := Color.from_hsv(hue, sat, val)
	var accent := Color.from_hsv(fmod(hue + rng.randf_range(0.08, 0.18), 1.0),
		clampf(sat * 0.8, 0.2, 0.9), clampf(val * 1.15, 0.2, 0.95))
	var hostile_bias := 0.06 if hazard != "none" else 0.0
	if kind == "cave":
		hostile_bias += 0.30  # things in the dark bite
	var roll := rng.randf()
	var temperament: String
	if roll < 0.15 + hostile_bias:
		temperament = "hostile"
	elif roll < 0.55:
		temperament = "neutral"
	else:
		temperament = "passive"
	var base_speed: float = {"quad": 5.0, "biped": 4.0, "serpent": 4.0, "fish": 3.0, "flyer": 6.0}.get(body, 4.0)
	var speed := base_speed * rng.randf_range(0.8, 1.3) / maxf(scale * 0.6, 0.6)
	var health := rng.randf_range(18.0, 45.0) * scale
	var damage := rng.randf_range(4.0, 14.0) if temperament == "hostile" else 0.0
	var aggro := rng.randf_range(9.0, 17.0) if temperament == "hostile" else 0.0
	var flee := rng.randf_range(8.0, 14.0) if temperament == "passive" else 0.0
	return {
		"name": sname, "kind": kind, "body": body, "scale": scale,
		"color": color, "accent": accent, "temperament": temperament,
		"speed": speed, "health": health, "damage": damage,
		"aggro_range": aggro, "flee_range": flee,
	}


# A point at `d_target` distance-from-center along `dir`, shape-aware (mirrors
# _surface_point but for an arbitrary target distance, not just the terrain height).
func _point_at_height(dir: Vector3, d_target: float) -> Vector3:
	if shape_cube:
		var m := maxf(maxf(absf(dir.x), absf(dir.y)), absf(dir.z))
		return dir * (d_target / maxf(m, 0.0001))
	return dir * d_target


## Called once per physics frame for the ACTIVE planet only (see WorldManager).
## Despawns creatures that drifted too far from the player, then occasionally
## attempts to spawn a new one nearby.
func update_fauna(delta: float, player_pos: Vector3, world: WorldManager) -> void:
	_creatures = _creatures.filter(func(c): return is_instance_valid(c))
	for c in _creatures.duplicate():
		if c.global_position.distance_to(player_pos) > CREATURE_DESPAWN_RADIUS:
			c.queue_free()
	_creatures = _creatures.filter(func(c): return is_instance_valid(c))

	_spawn_timer -= delta
	if _spawn_timer > 0.0 or _creatures.size() >= MAX_CREATURES:
		return
	_spawn_timer = CREATURE_SPAWN_INTERVAL
	_try_spawn_creature(player_pos, world)


## Immediately clears all fauna (called when this planet stops being the active
## one -- wildlife only exists meaningfully near the player).
func clear_fauna() -> void:
	for c in _creatures:
		if is_instance_valid(c):
			c.queue_free()
	_creatures.clear()


func _try_spawn_creature(player_pos: Vector3, world: WorldManager) -> void:
	if fauna_land.is_empty() and fauna_fish.is_empty() and fauna_cave.is_empty() and fauna_air.is_empty():
		return
	var local_player := to_local(player_pos)
	var player_d := local_player.length()
	if player_d < 1.0:
		return
	var base_dir := local_player / player_d
	# Build a tangent frame at the player's location so spawn points can be offset
	# by an actual DISTANCE (blocks), not a fixed jitter on the unit direction --
	# jittering the direction vector put spawns anywhere from a few blocks to
	# thousands away depending on planet radius (a small direction nudge on a
	# radius-1500 world is a huge arc distance), so they spawned way outside
	# render/despawn range and were gone before ever being seen.
	var t1 := base_dir.cross(Vector3.UP)
	if t1.length() < 0.1:
		t1 = base_dir.cross(Vector3.RIGHT)
	t1 = t1.normalized()
	var t2 := base_dir.cross(t1).normalized()

	# pick a habitat to try this attempt-set, weighted by what's available; cave
	# only gets picked (and will only actually succeed) where a real tunnel exists,
	# so cave fauna naturally shows up once you're near/inside one
	var habitats := []
	if not fauna_land.is_empty(): habitats.append("land")
	if not fauna_fish.is_empty(): habitats.append("fish")
	if not fauna_cave.is_empty(): habitats.append("cave")
	if not fauna_air.is_empty(): habitats.append("air")
	if habitats.is_empty():
		return
	var habitat: String = habitats[randi() % habitats.size()]

	for attempt in 6:
		var ang := randf() * TAU
		var r := randf_range(15.0, CREATURE_SPAWN_RADIUS)
		var offset := (t1 * cos(ang) + t2 * sin(ang)) * r
		var dir := (base_dir * player_d + offset).normalized()
		match habitat:
			"fish":
				var surf := _surf(dir)
				if surf >= water_level - 2.0:
					continue  # not enough water depth in this direction
				var d := lerpf(surf + 0.5, water_level - 0.5, randf_range(0.3, 0.8))
				var local_pos := _point_at_height(dir, d)
				var v := world_to_voxel(to_global(local_pos))
				if get_id(v) != Blocks.WATER:
					continue
				_spawn_at(to_global(local_pos), fauna_fish[randi() % fauna_fish.size()], world)
				return
			"air":
				var surf := _surf(dir)
				var d := surf + randf_range(Creature.FLY_MIN_ALT, Creature.FLY_MAX_ALT)
				var local_pos := _point_at_height(dir, d)
				var v := world_to_voxel(to_global(local_pos))
				if get_id(v) != Blocks.AIR:
					continue
				_spawn_at(to_global(local_pos), fauna_air[randi() % fauna_air.size()], world)
				return
			"cave":
				var found := _find_cave_spawn(dir)
				if found.is_empty():
					continue
				_spawn_at(found["pos"], fauna_cave[randi() % fauna_cave.size()], world)
				return
			_:  # land
				var surface_pt := _surface_point(dir)
				var up := _axis_of(dir) if shape_cube else dir
				var ground_v := world_to_voxel(to_global(surface_pt - up * 0.5))
				var stand_v := world_to_voxel(to_global(surface_pt + up * 0.3))
				var head_v := world_to_voxel(to_global(surface_pt + up * 1.3))
				var gid := get_id(ground_v)
				if gid == Blocks.AIR or gid == Blocks.WATER:
					continue  # no solid ground here
				if get_id(stand_v) != Blocks.AIR or get_id(head_v) != Blocks.AIR:
					continue  # no headroom
				_spawn_at(to_global(surface_pt + up * 0.05), fauna_land[randi() % fauna_land.size()], world)
				return


# Look for an actual carved cave pocket along `dir`, scanning depth from
# cave_min_depth down to CREATURE_CAVE_MAX_DEPTH. Returns {} if none found within
# range (most attempts on a random direction won't hit one -- that's fine, cave
# fauna will simply show up more once you're actually near/inside a tunnel).
func _find_cave_spawn(dir: Vector3) -> Dictionary:
	var surf := _surf(dir)
	var up := _axis_of(dir) if shape_cube else dir
	var depth := cave_min_depth
	while depth <= CREATURE_CAVE_MAX_DEPTH:
		var local_pos := _point_at_height(dir, surf - depth)
		var v := world_to_voxel(to_global(local_pos))
		if get_id(v) == Blocks.AIR:
			# confirm there's a bit of headroom (one step further in) so the
			# creature doesn't spawn wedged right against the ceiling
			var local_pos2 := _point_at_height(dir, surf - (depth + 1.0))
			var v2 := world_to_voxel(to_global(local_pos2))
			if get_id(v2) == Blocks.AIR:
				return {"pos": to_global(local_pos2)}
		depth += 1.0
	return {}


func _spawn_at(world_pos: Vector3, sp: Dictionary, world: WorldManager) -> void:
	var c := Creature.new()
	add_child(c)
	c.global_position = world_pos
	c.configure(sp, self, world)
	_creatures.append(c)


# How far from center anything (terrain, trees, or water) can possibly exist.
func _max_reach() -> float:
	return maxf(radius + terrain_amp + tree_reach, water_level)


# Each planet gets a random ore mix + abundance from its seed: which ores it holds,
# how common they are, and how deep. So planets are rich in different things.
func _derive_ores() -> void:
	var orng := RandomNumberGenerator.new()
	orng.seed = _seed + 999
	var richness := orng.randf_range(0.04, 0.11)  # fraction of rock that is ore
	ore_threshold = 0.72 - richness * 3.2          # lower threshold => more ore
	var n := orng.randi_range(2, 4)
	# tiers: guarantee at least one hand-mineable (tier 0/1) so a fresh planet is
	# never a dead end, then spread the rest across all tiers.
	var tiers: Array[int] = [orng.randi_range(0, 1)]
	for i in n - 1:
		tiers.append(orng.randi_range(0, 3))
	for i in n:
		var tier: int = tiers[i]
		ore_defs.append(_make_ore(orng, i, tier))
		_ore_by_block[ore_defs[i]["block"]] = ore_defs[i]
		_ore_wsum += ore_defs[i]["w"]


# Invent one ore: a unique name & color for this planet, with tier-derived stats.
func _make_ore(orng: RandomNumberGenerator, slot: int, tier: int) -> Dictionary:
	var name: String = Blocks.ORE_NAME_PRE[orng.randi() % Blocks.ORE_NAME_PRE.size()] \
		+ Blocks.ORE_NAME_SUF[orng.randi() % Blocks.ORE_NAME_SUF.size()]
	# colour: random hue, saturation/value that read as a mineral; a touch brighter
	# and more saturated at higher tiers so exotic ores catch the eye.
	var hue := orng.randf()
	var sat := 0.45 + 0.12 * tier + orng.randf_range(-0.05, 0.05)
	var val := 0.55 + 0.08 * tier + orng.randf_range(-0.05, 0.05)
	var color := Color.from_hsv(hue, clampf(sat, 0.3, 0.95), clampf(val, 0.4, 0.9))
	# props: tier archetype +/- per-ore variance
	var base: Dictionary = Blocks.TIER_PROPS[tier]
	var props := {}
	for k in Blocks.PROP_KEYS:
		props[k] = clampi(int(round(float(base[k]) * orng.randf_range(0.85, 1.15))), 1, 100)
	var hardness: float = Blocks.TIER_HARDNESS[tier] * orng.randf_range(0.9, 1.1)
	var deep := tier >= 2 or orng.randf() < 0.4   # rarer ores tend to sit deeper
	var mind := maxf(radius * 0.25, 8.0) if deep else 4.0
	return {
		"block": Blocks.ORE_SLOT_IDS[slot], "name": name, "color": color, "tier": tier,
		"props": props, "hardness": hardness, "min_power": Blocks.TIER_MIN_POWER[tier],
		"w": orng.randf_range(0.3, 1.0), "mind": mind,
	}


# --- per-planet ore lookups (block id is a generic ORE slot) ------------------
func ore_def(block_id: int) -> Dictionary:
	return _ore_by_block.get(block_id, {})

func ore_color(block_id: int) -> Color:
	var d := ore_def(block_id)
	return d["color"] if d.has("color") else Blocks.color_of(block_id)

func ore_hardness(block_id: int) -> float:
	var d := ore_def(block_id)
	return d["hardness"] if d.has("hardness") else 1.0

func ore_min_power(block_id: int) -> float:
	var d := ore_def(block_id)
	return d["min_power"] if d.has("min_power") else 1.0


# Decide how cave-riddled this planet is. `amount` overrides (0=none, 1=extreme);
# -1 rolls randomly from the seed. Every planet gets AT LEAST a light network (the
# floor is raised well above the enable threshold) so caves are a near-universal
# feature you can dig into anywhere, while size/density still scale with amount --
# some worlds are barely-there, most are modest, a few are honeycombed.
func _derive_caves(amount: float) -> void:
	var a := amount
	if a < 0.0:
		var rng := RandomNumberGenerator.new()
		rng.seed = _seed + 8181
		a = clampf(rng.randf_range(0.12, 1.12), 0.0, 1.0)
	cave_enabled = a > 0.02
	if not cave_enabled:
		return

	# BIG network: sparse, wide -> the rare giant caverns. More amount -> lower
	# threshold (denser) and lower frequency (bigger rooms).
	cave_threshold = lerpf(0.90, 0.62, a)
	cave_breach_threshold = minf(cave_threshold + 0.09, 0.985)
	var freq := lerpf(4.5, 1.4, a) / maxf(radius, 1.0)
	cave_noise.seed = _seed + 2020
	cave_noise.frequency = freq
	cave_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	cave_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	cave_noise.fractal_octaves = 2
	cave_noise2.seed = _seed + 3030
	cave_noise2.frequency = freq * 1.37   # different frequency -> branching, not parallel tubes
	cave_noise2.noise_type = FastNoiseLite.TYPE_SIMPLEX
	cave_noise2.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	cave_noise2.fractal_octaves = 2

	# FINE network: common, narrow veins that spread everywhere -- tuned so a
	# straight shaft dug down from almost any spot eventually breaks into one,
	# without requiring you to stumble on a rare big cavern. Present even on
	# "barely-there" (low amount) worlds so digging down always has a decent shot.
	cave_threshold_fine = lerpf(0.62, 0.42, a)
	# breach uses a near-absolute bar (NOT a small margin over the base threshold,
	# which is tuned low for deep diggability and would make breaches everywhere)
	# so surface entrances from the fine network stay rare regardless of density
	cave_breach_threshold_fine = lerpf(0.965, 0.93, a)
	var freq_fine := lerpf(9.0, 6.0, a) / maxf(radius, 1.0)
	cave_noise3.seed = _seed + 4040
	cave_noise3.frequency = freq_fine
	cave_noise3.noise_type = FastNoiseLite.TYPE_SIMPLEX
	cave_noise3.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	cave_noise3.fractal_octaves = 2
	cave_noise4.seed = _seed + 5050
	cave_noise4.frequency = freq_fine * 1.31
	cave_noise4.noise_type = FastNoiseLite.TYPE_SIMPLEX
	cave_noise4.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	cave_noise4.fractal_octaves = 2


# Raw tunnel strength at a cell (0..1ish): how deep inside a carved tunnel this
# point sits. Two ridged noise fields multiplied together carve branching,
# worm-like networks instead of straight parallel tubes.
func _cave_strength(gx: int, gy: int, gz: int) -> float:
	var r1 := cave_noise.get_noise_3d(gx, gy, gz) * 0.5 + 0.5
	var r2 := cave_noise2.get_noise_3d(gx, gy, gz) * 0.5 + 0.5
	return r1 * r2


func _cave_strength_fine(gx: int, gy: int, gz: int) -> float:
	var r1 := cave_noise3.get_noise_3d(gx, gy, gz) * 0.5 + 0.5
	var r2 := cave_noise4.get_noise_3d(gx, gy, gz) * 0.5 + 0.5
	return r1 * r2


func _is_cave(gx: int, gy: int, gz: int) -> bool:
	if not cave_enabled:
		return false
	return _cave_strength(gx, gy, gz) > cave_threshold \
		or _cave_strength_fine(gx, gy, gz) > cave_threshold_fine


# Give each planet a distinct forest: color palette, wood tone, canopy shape and
# size, all derived from the seed so no two planets feel the same.
func _derive_flora(density: float) -> void:
	tree_density = density
	if tree_density <= 0.0:
		return
	var fr := RandomNumberGenerator.new()
	fr.seed = _seed + 555
	var pool: Array = Blocks.LEAF_IDS.duplicate()
	var n := fr.randi_range(1, 3)
	for i in n:
		flora_leaves.append(pool.pop_at(fr.randi() % pool.size()))
	flora_wood = Blocks.WOOD_IDS[fr.randi() % Blocks.WOOD_IDS.size()]
	flora_shape = fr.randi() % 3
	trunk_min = fr.randi_range(3, 4)
	trunk_max = trunk_min + fr.randi_range(2, 4)
	canopy_min = fr.randf_range(2.5, 3.5)
	canopy_max = canopy_min + fr.randf_range(1.5, 3.0)
	tree_reach = float(trunk_max) + canopy_max * 2.0 + 2.0


# A simple lit sphere just below the surface so the planet is visible from afar
# (chunks only stream in when you're close). Sized under the lowest terrain so the
# real voxel surface covers it once you arrive.
func _add_distant_sphere() -> void:
	var vis := MeshInstance3D.new()
	# keep it just below the LOWEST terrain so it never pokes through valleys
	var r := maxf(radius - terrain_amp - 2.0, radius * 0.5)
	if shape_cube:
		var bm := BoxMesh.new()
		bm.size = Vector3(r * 2.0, r * 2.0, r * 2.0)
		vis.mesh = bm
	else:
		var sm := SphereMesh.new()
		sm.radius = r
		sm.height = r * 2.0
		sm.radial_segments = 48
		sm.rings = 24
		vis.mesh = sm
	var mat := StandardMaterial3D.new()
	var c := Blocks.color_of(pal_top)
	mat.albedo_color = Color(c.r * 0.7, c.g * 0.7, c.b * 0.7)  # match the shaded voxel tone
	mat.roughness = 1.0
	vis.material_override = mat
	add_child(vis)
	lod_sphere = vis


# --- terrain sampling ---------------------------------------------------------

func _surf(dir: Vector3) -> float:
	return radius + surface_noise.get_noise_3d(dir.x * radius, dir.y * radius, dir.z * radius) * terrain_amp


# Distance-from-center metric that defines the planet's shape: Euclidean = sphere,
# Chebyshev (max axis) = cube.
func _norm(p: Vector3) -> float:
	if shape_cube:
		return maxf(maxf(absf(p.x), absf(p.y)), absf(p.z))
	return p.length()


# Nearest outward cardinal axis to `v` (which cube face a direction belongs to).
func _axis_of(v: Vector3) -> Vector3:
	var ax := absf(v.x)
	var ay := absf(v.y)
	var az := absf(v.z)
	if ax >= ay and ax >= az:
		return Vector3(signf(v.x), 0, 0)
	elif ay >= az:
		return Vector3(0, signf(v.y), 0)
	return Vector3(0, 0, signf(v.z))


# Shape-aware distance from a world point to this planet's center / surface. Use
# these everywhere instead of raw Euclidean distance so cube planets stream and
# report altitude correctly out to their edges and corners.
func center_distance(world_pos: Vector3) -> float:
	return _norm(to_local(world_pos))

func altitude(world_pos: Vector3) -> float:
	return _norm(to_local(world_pos)) - radius


# A world point above dry land near `prefer` (so the player doesn't spawn underwater).
func find_spawn_point(prefer: Vector3) -> Vector3:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed + 4040
	prefer = prefer.normalized()
	var dir := prefer
	for attempt in 80:
		if attempt > 0:
			dir = (prefer + Vector3(rng.randf() * 2 - 1, rng.randf() * 2 - 1, rng.randf() * 2 - 1) * 0.6).normalized()
		if water_style == WATER_NONE or _surf(dir) > water_level + 3.0:
			break
	return to_global(_surface_point(dir) + dir * 8.0)


# World-space point on the surface in unit direction `dir` (for rooting trees).
func _surface_point(dir: Vector3) -> Vector3:
	var s := _surf(dir)
	if shape_cube:
		var m := maxf(maxf(absf(dir.x), absf(dir.y)), absf(dir.z))
		return dir * (s / maxf(m, 0.0001))
	return dir * s


## Pure terrain function: what block id would be here with no player edits.
func generation_sample(gx: int, gy: int, gz: int) -> int:
	var p := Vector3(gx, gy, gz)
	var d := _norm(p)
	if d > _max_reach() + 2.0:
		return Blocks.AIR
	var l2 := p.length()
	var dir := p / maxf(l2, 0.0001)
	var surf := _surf(dir)

	if d > surf:
		# above the terrain: water first (fills anything up to the water level),
		# otherwise maybe a tree, otherwise air
		if water_style != WATER_NONE and d <= water_level:
			return _water_block()
		if tree_density > 0.0 and d <= surf + tree_reach:
			return _tree_at(p, dir, surf)
		return Blocks.AIR

	var depth := surf - d
	if d < radius * 0.22:
		return pal_core
	# caves: hollowed from the rock layer -- a sparse BIG network (rare giant
	# caverns) unioned with a common FINE network (pervasive veins, so digging
	# straight down from almost anywhere breaks into a tunnel eventually). Normal
	# tunnels need a solid roof (cave_min_depth) and stay clear of the core; only
	# the STRONGEST cores of either network breach shallower -- including straight
	# through topsoil -- for occasional natural cave mouths you can walk into.
	if cave_enabled and d > radius * 0.22 + 6.0:
		var near_surface := depth < cave_min_depth
		var big := _cave_strength(gx, gy, gz) > (cave_breach_threshold if near_surface else cave_threshold)
		var fine := _cave_strength_fine(gx, gy, gz) > (cave_breach_threshold_fine if near_surface else cave_threshold_fine)
		if big or fine:
			return Blocks.AIR
	if depth < 1.0:
		return pal_top
	if depth < 4.0:
		return pal_sub
	# rock layer: sometimes an ore vein
	if not ore_defs.is_empty() and ore_noise.get_noise_3d(gx, gy, gz) > ore_threshold:
		var o := _pick_ore(gx, gy, gz, depth)
		if o != Blocks.AIR:
			return o
	return pal_rock


# Choose which ore is here, weighted by the planet's mix and respecting each ore's
# minimum depth. Deterministic via a position hash.
func _pick_ore(gx: int, gy: int, gz: int, depth: float) -> int:
	var wsum := 0.0
	for o in ore_defs:
		if depth >= o["mind"]:
			wsum += o["w"]
	if wsum <= 0.0:
		return Blocks.AIR
	var r := _hash01(Vector3i(gx, gy, gz), 11) * wsum
	for o in ore_defs:
		if depth >= o["mind"]:
			r -= o["w"]
			if r <= 0.0:
				return o["block"]
	return Blocks.AIR


# Deterministic 0..1 hash of a cell coordinate (+ salt) using the planet seed.
func _hash01(c: Vector3i, salt: int) -> float:
	var n: int = c.x * 73856093
	n ^= c.y * 19349663
	n ^= c.z * 83492791
	n ^= (_seed + salt * 100003) * 2654435761
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0x7fffffff) / 2147483647.0


# Is voxel p (air, near the surface) part of a tree? Trees are scattered on a grid
# over the surface; we check the cells around p's surface projection.
func _tree_at(p: Vector3, dir: Vector3, _surf_unused: float) -> int:
	var c := float(TREE_CELL)
	var sp := _surface_point(dir)  # surface point beneath p (cube- or sphere-aware)
	var scell := Vector3i(floori(sp.x / c), floori(sp.y / c), floori(sp.z / c))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var cc := scell + Vector3i(dx, dy, dz)
				if _hash01(cc, 0) >= tree_density:
					continue
				var cdir := (Vector3(cc) * c + Vector3(c * 0.5, c * 0.5, c * 0.5)).normalized()
				var base := _surface_point(cdir)
				# one tree per cell: only if its base actually sits in this cell
				if Vector3i(floori(base.x / c), floori(base.y / c), floori(base.z / c)) != cc:
					continue
				# no trees standing in water -- skip if the base is at/below sea level
				if water_style != WATER_NONE and _norm(base) <= water_level:
					continue
				# On a cube, trees grow straight out of the flat face (axis-aligned),
				# not toward the center -- otherwise they lean on diagonal faces.
				var up := _axis_of(cdir) if shape_cube else cdir
				var th := trunk_min + int(_hash01(cc, 1) * float(trunk_max - trunk_min + 1))
				var cr := canopy_min + _hash01(cc, 2) * (canopy_max - canopy_min)
				var rel := p - base
				var along := rel.dot(up)
				var horiz := (rel - up * along).length()
				# trunk
				if along >= 0.0 and along <= float(th) and horiz < 0.7:
					return flora_wood
				# canopy (ellipsoid, shape-dependent, with lumpy edge)
				var vscale := 1.5 if flora_shape == 1 else (0.7 if flora_shape == 2 else 1.0)
				var ch := cr * vscale
				var center := base + up * (float(th) + ch * 0.4)
				var rc := p - center
				var cvert := rc.dot(up)
				var choriz := (rc - up * cvert).length()
				var rad := cr
				if flora_shape == 1:  # pine: taper toward the top
					var t := clampf((cvert + ch) / (2.0 * ch), 0.0, 1.0)
					rad = cr * (1.0 - t * 0.8)
				var e := (choriz * choriz) / maxf(rad * rad, 0.01) + (cvert * cvert) / maxf(ch * ch, 0.01)
				var lump := _hash01(Vector3i(floori(p.x), floori(p.y), floori(p.z)), 7) * 0.35 - 0.15
				if e < 1.0 + lump:
					var li: int = flora_leaves[int(_hash01(cc, 3) * flora_leaves.size()) % flora_leaves.size()]
					return li
	return Blocks.AIR


## Block id at a voxel, with player edits taking precedence over terrain.
func get_id(v: Vector3i) -> int:
	var d = _edits_by_chunk.get(chunk_of(v))
	if d != null and d.has(v):
		return d[v]
	return generation_sample(v.x, v.y, v.z)


func is_solid(v: Vector3i) -> bool:
	return get_id(v) != Blocks.AIR


# --- gravity ------------------------------------------------------------------

## Gravity acceleration vector (world space) this planet exerts at a world point.
func gravity_at(world_pos: Vector3) -> Vector3:
	var to_center := global_position - world_pos
	var d := to_center.length()
	if d < 0.001:
		return Vector3.ZERO
	var dir := to_center / d
	var g: float
	if d >= radius:
		g = surface_gravity * (radius * radius) / (d * d)  # inverse-square falloff outside
	else:
		g = surface_gravity * (d / radius)                 # falls linearly to 0 at the core
	return dir * g


# --- coordinate helpers -------------------------------------------------------

func world_to_voxel(world_pos: Vector3) -> Vector3i:
	var local := to_local(world_pos)
	return Vector3i(floori(local.x), floori(local.y), floori(local.z))

func chunk_of(v: Vector3i) -> Vector3i:
	return Vector3i(floori(float(v.x) / CS), floori(float(v.y) / CS), floori(float(v.z) / CS))


# --- streaming ----------------------------------------------------------------

## Keep chunks within `rd` (chunk radius) of `center_voxel` loaded; unload the rest.
func stream(center_voxel: Vector3i, rd: int) -> void:
	var cc0 := chunk_of(center_voxel)
	var wanted := {}
	for dx in range(-rd, rd + 1):
		for dy in range(-rd, rd + 1):
			for dz in range(-rd, rd + 1):
				var cc := cc0 + Vector3i(dx, dy, dz)
				if _chunk_possibly_solid(cc):
					wanted[cc] = true
					if not loaded_chunks.has(cc) and not _load_queue.has(cc):
						_load_queue.append(cc)
	# unload chunks we no longer want (but let in-flight builds finish first)
	for cc in loaded_chunks.keys():
		if not wanted.has(cc) and not _inflight.has(cc):
			var node: Node = loaded_chunks[cc]
			loaded_chunks.erase(cc)
			node.queue_free()
	# drop queued loads that are no longer wanted
	_load_queue = _load_queue.filter(func(cc): return wanted.has(cc))
	# nearest-first so the world fills outward from the player
	_load_queue.sort_custom(func(a, b): return (a - cc0).length_squared() < (b - cc0).length_squared())


## Apply finished worker results, then dispatch more build tasks. `budget` is unused
## now (kept for call-site compatibility); pacing is via APPLY_PER_FRAME / MAX_INFLIGHT.
func process_load_queue(_budget: int) -> int:
	# 1) apply results the workers have finished (main-thread mesh construction)
	_ready_mutex.lock()
	var ready_ccs: Array = _ready_data.keys()
	_ready_mutex.unlock()
	var applied := 0
	for cc in ready_ccs:
		if applied >= APPLY_PER_FRAME:
			break
		_ready_mutex.lock()
		var data: Dictionary = _ready_data.get(cc, {})
		_ready_data.erase(cc)
		_ready_mutex.unlock()
		if _inflight.has(cc):
			WorkerThreadPool.wait_for_task_completion(_inflight[cc])
			_inflight.erase(cc)
		var node = loaded_chunks.get(cc)
		if node != null and is_instance_valid(node):
			node.apply_mesh_data(data)
		applied += 1

	# 2) re-mesh dirty (edited / flowed) chunks FIRST -- player edits and flowing
	# water must update promptly, not wait behind chunk streaming
	for cc in _dirty.keys():
		if _inflight.size() >= MAX_INFLIGHT:
			break
		if _inflight.has(cc):
			continue  # already meshing; stays dirty and re-dispatches next frame
		_dirty.erase(cc)
		if not loaded_chunks.has(cc):
			continue
		var s := _edits_snapshot(cc)
		var t := WorkerThreadPool.add_task(Callable(self, "_build_task").bind(cc, s, _wlev_snapshot(s)))
		_inflight[cc] = t

	# 3) dispatch new chunk loads with whatever capacity remains
	while _inflight.size() < MAX_INFLIGHT and not _load_queue.is_empty():
		var cc: Vector3i = _load_queue.pop_front()
		if loaded_chunks.has(cc):
			continue
		_spawn_chunk_node(cc)
		var snap := _edits_snapshot(cc)
		var tid := WorkerThreadPool.add_task(Callable(self, "_build_task").bind(cc, snap, _wlev_snapshot(snap)))
		_inflight[cc] = tid
	return applied


func _spawn_chunk_node(cc: Vector3i) -> Chunk:
	var chunk := Chunk.new()
	chunk.planet = self
	chunk.cc = cc
	chunk.position = Vector3(cc * CS)
	add_child(chunk)
	loaded_chunks[cc] = chunk
	return chunk


# Make sure no worker thread is still meshing against us when we get freed
# (otherwise it reads a half-destroyed planet and the app hangs on shutdown).
func _exit_tree() -> void:
	for tid in _inflight.values():
		WorkerThreadPool.wait_for_task_completion(tid)
	_inflight.clear()


# Runs on a worker thread: pure computation, results deposited under a mutex.
func _build_task(cc: Vector3i, snap: Dictionary, wsnap: Dictionary) -> void:
	var data := Chunk.build_mesh_data(self, cc, snap, wsnap)
	_ready_mutex.lock()
	_ready_data[cc] = data
	_ready_mutex.unlock()


# Copy edits for a chunk and its 6 face-neighbors into a plain dict for a worker.
func _edits_snapshot(cc: Vector3i) -> Dictionary:
	var snap := {}
	const OFFS := [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	for off in OFFS:
		var d = _edits_by_chunk.get(cc + off)
		if d != null:
			for k in d:
				snap[k] = d[k]
	return snap


# Water levels for the WATER cells in an edits snapshot (thread-safe copy so the
# mesher can render partial-height water). Ocean cells default to full in the mesher.
func _wlev_snapshot(snap: Dictionary) -> Dictionary:
	var w := {}
	for v in snap:
		if snap[v] == Blocks.WATER:
			w[v] = _wlev.get(v, W_FULL)
	return w


## Build one chunk synchronously on the main thread (used at spawn so there's
## ground under the player immediately).
func build_chunk_sync(cc: Vector3i) -> void:
	if loaded_chunks.has(cc):
		return
	if not _chunk_possibly_solid(cc):
		return
	var node := _spawn_chunk_node(cc)
	var snap := _edits_snapshot(cc)
	node.apply_mesh_data(Chunk.build_mesh_data(self, cc, snap, _wlev_snapshot(snap)))


## Quick reject: is any part of this chunk possibly inside the solid body?
func _chunk_possibly_solid(cc: Vector3i) -> bool:
	# nearest point of the chunk AABB to the planet center
	var lo := Vector3(cc * CS)
	var hi := lo + Vector3(CS, CS, CS)
	var nearest := Vector3(
		clampf(0.0, lo.x, hi.x),
		clampf(0.0, lo.y, hi.y),
		clampf(0.0, lo.z, hi.z))
	return _norm(nearest) <= _max_reach() + 1.0


# --- editing ------------------------------------------------------------------

## Replace all player edits (used by the save system). Any chunks already loaded
## are queued for an async re-mesh so they reflect the loaded edits.
func load_edits(e: Dictionary) -> void:
	_edits_by_chunk = e if e != null else {}
	for cc in loaded_chunks.keys():
		_dirty[cc] = true


func set_block(v: Vector3i, id: int) -> void:
	var cc := chunk_of(v)
	if not _edits_by_chunk.has(cc):
		_edits_by_chunk[cc] = {}
	_edits_by_chunk[cc][v] = id
	_rebuild_if_loaded(cc)
	# a change on a chunk border also changes the neighbor's visible faces
	var local := v - cc * CS
	if local.x == 0: _rebuild_if_loaded(cc + Vector3i(-1, 0, 0))
	if local.x == CS - 1: _rebuild_if_loaded(cc + Vector3i(1, 0, 0))
	if local.y == 0: _rebuild_if_loaded(cc + Vector3i(0, -1, 0))
	if local.y == CS - 1: _rebuild_if_loaded(cc + Vector3i(0, 1, 0))
	if local.z == 0: _rebuild_if_loaded(cc + Vector3i(0, 0, -1))
	if local.z == CS - 1: _rebuild_if_loaded(cc + Vector3i(0, 0, 1))


## Planet doors are placed as TWO stacked voxels (see Player._edit_block) so they
## read as one two-block-tall doorway. Toggling either half toggles both -- look
## one cell outward and one cell inward along the local up axis for the partner.
func toggle_door(v: Vector3i) -> bool:
	var id := get_id(v)
	if not Blocks.is_door(id):
		return false
	var new_id := Blocks.door_toggle_of(id)
	set_block(v, new_id)
	var axis: Vector3i = Vector3i(_axis_of(Vector3(v) + Vector3(0.5, 0.5, 0.5)))
	for nb in [v + axis, v - axis]:
		if Blocks.is_door(get_id(nb)):
			set_block(nb, new_id)
	return true


# Queue a loaded chunk to be re-meshed on a worker thread (never blocks the main
# thread). Applied a frame or two later via process_load_queue.
func _rebuild_if_loaded(cc: Vector3i) -> void:
	if loaded_chunks.has(cc):
		_dirty[cc] = true


const _NEIGH6 := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]

# --- flowing water (cellular automaton) --------------------------------------
# Water has a level 1..W_FULL. A cell's level is recomputed from its neighbors:
# full if water falls into it from above, otherwise one less than its highest
# horizontal neighbor. Level 0 means it drains (turns back to air). The generated
# ocean acts as an infinite W_FULL source. So water spreads out getting shallower,
# and recedes when its source is cut off. Dynamic water is stored as WATER edits
# (so it renders/collides/streams like any block); `_wlev` holds the levels.
const W_FULL := 8
const FLOW_DT := 0.10          # simulation tick interval (seconds)
const FLOW_BUDGET := 256       # cells evaluated per tick (keeps ticks cheap)
const MAX_WATER := 24000       # safety cap on total dynamic water cells
var _wlev := {}                # Vector3i -> level 1..W_FULL
var _water_active := {}        # cells to (re)evaluate next tick
var _flow_accum := 0.0


# Called after a block is broken at `v`. Flowing water is currently DISABLED --
# generated rivers/lakes/oceans stay put as static full cells. The cellular-automaton
# machinery below (_wake/_sim_water/etc.) is left dormant; re-enable by restoring the
# _wake(v) call here.
func flow_water(_v: Vector3i) -> void:
	return


func _wake(c: Vector3i) -> void:
	_water_active[c] = true
	for n in _NEIGH6:
		_water_active[c + n] = true


func _wdown(c: Vector3i) -> Vector3i:
	var ax := _axis_of(Vector3(c) + Vector3(0.5, 0.5, 0.5))  # outward face axis
	return Vector3i(int(-ax.x), int(-ax.y), int(-ax.z))       # toward center = down


func _is_solid_block(c: Vector3i) -> bool:
	var id := get_id(c)
	return id != Blocks.AIR and id != Blocks.WATER


# Undug, generated ocean = an infinite full source.
func _ocean_source(c: Vector3i) -> bool:
	var d = _edits_by_chunk.get(chunk_of(c))
	if d != null and d.has(c):
		return false
	if _wlev.has(c):
		return false
	return generation_sample(c.x, c.y, c.z) == Blocks.WATER


func _wlevel(c: Vector3i) -> int:
	if _ocean_source(c):
		return W_FULL
	return _wlev.get(c, 0)


func _water_target(c: Vector3i) -> int:
	var down := _wdown(c)
	var above := c - down
	if not _is_solid_block(above) and _wlevel(above) > 0:
		return W_FULL  # water falling straight down fills the cell
	var best := 0
	for n in _NEIGH6:
		if n == down or n == -down:
			continue  # horizontal neighbors only spread sideways
		best = maxi(best, _wlevel(c + n) - 1)
	return best


func _process(delta: float) -> void:
	if water_style != WATER_LIQUID or _water_active.is_empty():
		return
	_flow_accum += delta
	if _flow_accum < FLOW_DT:
		return
	_flow_accum = 0.0
	_sim_water()


func _sim_water() -> void:
	var todo: Array = _water_active.keys()
	_water_active = {}
	var dirty := {}
	var count := 0
	for c in todo:
		if count >= FLOW_BUDGET:
			_water_active[c] = true  # defer to next tick
			continue
		count += 1
		if _ocean_source(c):
			for n in _NEIGH6:
				_water_active[c + n] = true  # ocean keeps feeding its neighbors
			continue
		if _is_solid_block(c):
			if _wlev.has(c):
				_clear_water(c, dirty)
			continue
		var cur: int = _wlev.get(c, 0)
		var t := _water_target(c)
		if t <= 0:
			if cur > 0:
				_clear_water(c, dirty)
				_wake(c)
		elif t != cur and (_wlev.size() < MAX_WATER or _wlev.has(c)):
			_set_water(c, t, dirty)
			_wake(c)
	for cc in dirty:
		_rebuild_if_loaded(cc)  # queues an async re-mesh; won't block the main thread


func _set_water(c: Vector3i, level: int, dirty: Dictionary) -> void:
	_wlev[c] = level
	var cc := chunk_of(c)
	if not _edits_by_chunk.has(cc):
		_edits_by_chunk[cc] = {}
	_edits_by_chunk[cc][c] = Blocks.WATER
	_mark_borders(c, dirty)


func _clear_water(c: Vector3i, dirty: Dictionary) -> void:
	_wlev.erase(c)
	var d = _edits_by_chunk.get(chunk_of(c))
	if d != null:
		d.erase(c)  # revert to generation (air on land, ocean below sea level)
	_mark_borders(c, dirty)


func _mark_borders(c: Vector3i, dirty: Dictionary) -> void:
	var cc := chunk_of(c)
	dirty[cc] = true
	var local := c - cc * CS
	if local.x == 0: dirty[cc + Vector3i(-1, 0, 0)] = true
	if local.x == CS - 1: dirty[cc + Vector3i(1, 0, 0)] = true
	if local.y == 0: dirty[cc + Vector3i(0, -1, 0)] = true
	if local.y == CS - 1: dirty[cc + Vector3i(0, 1, 0)] = true
	if local.z == 0: dirty[cc + Vector3i(0, 0, -1)] = true
	if local.z == CS - 1: dirty[cc + Vector3i(0, 0, 1)] = true
