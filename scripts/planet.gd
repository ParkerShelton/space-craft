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

# Settlements (civilization buildings) and NPCs turned off for now -- see the
# comment where this is used in configure(). Building generation was a real
# per-chunk cost contributor and complicates loading-perf debugging, so it's
# out of the picture entirely until it's brought back deliberately.
const SETTLEMENTS_DISABLED := true

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
## Procedural block-texturing material for this planet (see Chunk._get_material).
## Per planet so no two worlds' trees share a grain pattern.
var block_material: ShaderMaterial
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

# --- settlements (procedural villages/towns/cities, derived from seed like ores) ---
const SETTLEMENT_SLOTS := 10   # candidate locations spread around the planet
# Local grid spacing for buildings within a settlement. MUST stay > 2*(max
# half-width + SETTLEMENT_PAD) below, or neighboring buildings' grading pads
# overlap and fight over the ground height at the seam -- that fight is exactly
# what caused walls to float/sink where two buildings met (max footprint is 8,
# half-width 4; pad 4 -> need > 16; kept a margin above the minimum).
const BUILDING_CELL := 20.0
const SETTLEMENT_TIER_NAMES := ["Outpost", "Village", "Town", "City"]
const SETTLEMENT_TIER_RADIUS := [22.0, 42.0, 68.0, 100.0]
const SETTLEMENT_TIER_DENSITY := [0.32, 0.42, 0.5, 0.58]  # chance a building-cell in range holds a building
var settlements: Array = []    # each: {dir, up, u, v, anchor, tier, radius, density, wall_mat, roof_mat, seed}
var settlements_enabled := true  # false = this planet never gets a settlement (set by civ tier)
var settlement_tier_cap := 3     # highest settlement tier this planet may roll (set by civ tier)
# The system's civilization tier (Galaxy.CIV_*). Beyond gating WHETHER a planet
# is settled, this decides what its architecture looks like: a primitive colony
# builds low cottages out of whatever the planet provides, while an advanced
# empire builds tall metal-and-glass towers that look the same on any world.
var civ_tier := 2
var settlement_reach := 0.0    # tallest a building can get, for streaming/reach purposes

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

# --- NPCs (settlement residents, derived from seed like ores/fauna) -- v1 is
# population only: they exist, wander their home town, and are never hostile
# (no law/faction system yet to give that a reason). Trading/dialogue/guards
# are explicitly future work, not attempted here.
var npc_species: Array = []
const MAX_NPCS := 8
const NPC_SPAWN_INTERVAL := 4.0
const NPC_DESPAWN_RADIUS := 160.0
var _npcs: Array = []
var _npc_spawn_timer := 0.0

var lod_sphere: MeshInstance3D  # low-res far-away representation (hidden when close)

# player edits grouped by chunk: Vector3i(chunk) -> { Vector3i(voxel) -> id }
var _edits_by_chunk := {}
# currently loaded chunk nodes: Vector3i(chunk coord) -> Chunk
var loaded_chunks := {}
# chunks waiting to be dispatched to a worker thread
var _load_queue: Array[Vector3i] = []
var _load_queue_set := {}  # mirrors _load_queue's contents for O(1) membership checks

# --- threaded meshing state ---
# Variables, not consts: main.gd's loading screen temporarily raises these
# while it's shown -- frame smoothness doesn't matter behind an opaque
# loading screen, so we can push far more chunks through at once to shorten
# the wait, then drop back to the normal pacing once gameplay is visible.
var MAX_INFLIGHT := 24        # concurrent worker tasks in flight
var APPLY_PER_FRAME := 6      # results turned into meshes per frame (main-thread cost)
const MAX_INFLIGHT_NORMAL := 24
const APPLY_PER_FRAME_NORMAL := 6
const MAX_INFLIGHT_FAST_LOAD := 64
const APPLY_PER_FRAME_FAST_LOAD := 24

## Called by main.gd's loading screen: push far more chunks through per frame
## while the screen hides any jank, then restore normal pacing once the world
## is revealed.
func set_fast_loading(enabled: bool) -> void:
	MAX_INFLIGHT = MAX_INFLIGHT_FAST_LOAD if enabled else MAX_INFLIGHT_NORMAL
	APPLY_PER_FRAME = APPLY_PER_FRAME_FAST_LOAD if enabled else APPLY_PER_FRAME_NORMAL
var _inflight := {}          # cc -> WorkerThreadPool task id
var _ready_data := {}        # cc -> mesh data dict (filled by workers)
var _ready_mutex := Mutex.new()
var _dirty := {}             # loaded chunks needing an (async) re-mesh
var _edit_priority := {}     # dirty chunks caused by a player edit -- applied first


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
	_derive_fauna(cfg.get("force_hostile_enemy", false))  # after water: fish generation depends on water_style
	# after flora/water: siting depends on both. A system's civilization tier
	# (see galaxy.gd) decides whether THIS planet is allowed settlements at all,
	# how big they're allowed to get, and whether one is force-guaranteed.
	# Settlements/buildings/NPCs disabled for now (2026-09-01, user request) --
	# flip SETTLEMENTS_DISABLED back to false to re-enable; the cfg value is
	# still read so re-enabling doesn't require touching any other file.
	settlements_enabled = false if SETTLEMENTS_DISABLED else cfg.get("settlements_enabled", true)
	settlement_tier_cap = cfg.get("settlement_tier_cap", 3)
	civ_tier = cfg.get("civ_tier", 2)
	_derive_settlements(cfg.get("force_settlement", false))
	_derive_npcs()  # after settlements: NPCs only exist where there's a town to live in
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

var _forced_enemy_species: Dictionary = {}  # set by _derive_fauna when force_hostile_enemy is true

func _derive_fauna(force_hostile_enemy: bool = false) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed + 6060
	var n_land := rng.randi_range(2, 4)
	for i in n_land:
		fauna_land.append(_make_species(rng, "land"))
	if force_hostile_enemy:
		# Guaranteed on top of the normal roll (not instead of it) -- for combat
		# testing on the home planet regardless of what the random wildlife mix
		# would otherwise be. Independent of settlements/civ tier.
		var enemy_sp := _make_species(rng, "enemy")
		fauna_land.append(enemy_sp)
		_forced_enemy_species = enemy_sp
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


# A handful of resident "professions" (really just look/behavior archetypes,
# same idea as fauna species) shared by every settlement on the planet. Only
# generated at all if there's actually a settlement to live in.
func _derive_npcs() -> void:
	npc_species.clear()
	if settlements.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed + 6767
	var n := rng.randi_range(2, 3)
	for i in n:
		npc_species.append(_make_species(rng, "npc"))


## Called once per physics frame for the ACTIVE planet only (see WorldManager),
## same shape as update_fauna: despawn anyone who's drifted far from the
## player, then occasionally try to populate a nearby settlement a bit more.
func update_npcs(delta: float, player_pos: Vector3, world: WorldManager) -> void:
	_npcs = _npcs.filter(func(c): return is_instance_valid(c))
	for c in _npcs.duplicate():
		if c.global_position.distance_to(player_pos) > NPC_DESPAWN_RADIUS:
			c.queue_free()
	_npcs = _npcs.filter(func(c): return is_instance_valid(c))

	if npc_species.is_empty():
		return
	_npc_spawn_timer -= delta
	if _npc_spawn_timer > 0.0 or _npcs.size() >= MAX_NPCS:
		return
	_npc_spawn_timer = NPC_SPAWN_INTERVAL
	_try_spawn_npc(player_pos, world)


## Immediately clears all NPCs (this planet stopped being the active one).
func clear_npcs() -> void:
	for c in _npcs:
		if is_instance_valid(c):
			c.queue_free()
	_npcs.clear()


# Only spawns when the player is actually near a settlement -- an NPC's home
# is that settlement (anchor + radius, see Creature's leash), and its start
# position is a real building's doorway within it, not an arbitrary point.
func _try_spawn_npc(player_pos: Vector3, world: WorldManager) -> void:
	var local_player := to_local(player_pos)
	var st: Dictionary = {}
	for s in settlements:
		if local_player.distance_to(s["anchor"]) <= float(s["radius"]) + 40.0:
			st = s
			break
	if st.is_empty():
		return
	var buildings := _nearby_buildings(local_player, st, 40.0)
	if buildings.is_empty():
		return
	var anchor: Vector3 = st["anchor"]
	var up: Vector3 = st["up"]
	var u: Vector3 = st["u"]
	var v: Vector3 = st["v"]
	var b = buildings[randi() % buildings.size()]
	var plan := _building_plan(b["cx"], b["cy"], st)
	var door := _building_door_point(b["cu"], b["cv"], plan)
	var door_local := _building_base(anchor, u, v, door.x, door.y)  # correctly graded ground height
	var ground_v := world_to_voxel(to_global(door_local - up * 0.5))
	var stand_v := world_to_voxel(to_global(door_local + up * 0.3))
	var gid := get_id(ground_v)
	if gid == Blocks.AIR or gid == Blocks.WATER:
		return  # no solid ground here
	if get_id(stand_v) != Blocks.AIR:
		return  # no headroom
	var spawn_pos := to_global(door_local + up * 0.05)
	if not _chunk_ready_at(spawn_pos):
		return  # ground is correct in theory but no real collision here yet
	var sp: Dictionary = npc_species[randi() % npc_species.size()]
	var c := Creature.new()
	add_child(c)
	c.global_position = spawn_pos
	c.configure(sp, self, world, to_global(anchor), float(st["radius"]))
	_npcs.append(c)


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
		"npc": body = "biped"  # settlement residents always stand upright
		"enemy": body = "biped"  # hostile humanoid -- see _make_species's "enemy" branch below
		"cave": body = ["serpent", "serpent", "quad", "biped"][rng.randi() % 4]
		_: body = ["quad", "quad", "biped", "serpent"][rng.randi() % 4]  # land
	var scale: float = rng.randf_range(0.85, 1.15) if kind in ["npc", "enemy"] \
		else (rng.randf_range(0.5, 2.0) if kind in ["land", "cave"] else rng.randf_range(0.4, 1.6))
	# an enemy's hue is biased toward red/purple -- a "this is dangerous" read at
	# a glance, distinct from an NPC's muted clothing tones or wildlife's full range
	var hue := rng.randf_range(-0.06, 0.08) if kind == "enemy" else rng.randf()
	if hue < 0.0:
		hue += 1.0
	# NPCs read as clothing (muted, everyday colors), not animal hide/plumage
	var sat := rng.randf_range(0.25, 0.55) if kind == "npc" else rng.randf_range(0.35, 0.85)
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
	if kind == "npc":
		# Settlement residents are never hostile in v1 -- there's no law/faction
		# system yet to give an unprovoked attack a reason, so "aggressive
		# civilians" would just read as a bug. Mostly neutral (going about their
		# day), a modest passive slice (shy around a stranger).
		temperament = "passive" if roll < 0.25 else "neutral"
	elif kind == "enemy":
		temperament = "hostile"  # that's the whole point of this kind
	else:
		# Most non-hostile wildlife just ignores you (neutral) -- only a small
		# slice is actually skittish enough to run (passive). Neutral gets the
		# bulk of the remaining probability; passive gets whatever's left
		# (roughly 4-10%).
		var hostile_cut := 0.15 + hostile_bias
		var neutral_cut := hostile_cut + 0.75
		if roll < hostile_cut:
			temperament = "hostile"
		elif roll < neutral_cut:
			temperament = "neutral"
		else:
			temperament = "passive"
	var base_speed: float = {"quad": 5.0, "biped": 4.0, "serpent": 4.0, "fish": 3.0, "flyer": 6.0}.get(body, 4.0)
	var speed := (base_speed * 0.6 if kind == "npc" else base_speed) * rng.randf_range(0.8, 1.3) / maxf(scale * 0.6, 0.6)
	var health := rng.randf_range(18.0, 45.0) * scale
	var damage := rng.randf_range(4.0, 14.0) if temperament == "hostile" else 0.0
	var aggro := rng.randf_range(9.0, 17.0) if temperament == "hostile" else 0.0
	var flee := rng.randf_range(8.0, 14.0) if temperament == "passive" else 0.0
	var sp := {
		"name": sname, "kind": kind, "body": body, "scale": scale,
		"color": color, "accent": accent, "temperament": temperament,
		"speed": speed, "health": health, "damage": damage,
		"aggro_range": aggro, "flee_range": flee,
		"arm_count": 2, "leg_count": 2,  # data-driven for future limb variety; unused past 2/2 today
	}
	if kind == "enemy":
		# "lunger" is the only attack pattern today: chase -> telegraph (real
		# dodge window) -> dash-and-hit -> recover. See Creature's state machine.
		sp["pattern"] = "lunger"
		# A real, readable windup -- was 0.35-0.55s, which barely gave a
		# player time to register the pose let alone react to it. Dark
		# Souls-style enemies telegraph for the better part of a second.
		sp["telegraph_time"] = rng.randf_range(0.7, 1.1)
		sp["attack_range"] = rng.randf_range(2.2, 2.6)
		sp["stagger_max"] = rng.randf_range(2.0, 3.5)
		# Every block/feint/timing probability in Creature's lunger AI derives
		# from this single 0..1 dial (see _lunger_ai). Pinned to the MAX for
		# now (2026-09-01, user request) so testing always sees the hardest
		# version of the AI -- that's what you need in front of you to judge
		# where the actual difficulty limits should be. Real skill TIERS
		# (some enemies bad at this, some good) are deliberately future work;
		# when that lands it's "roll this per spawn instead of a constant,"
		# not a rewrite of the mechanics.
		sp["skill"] = 1.0
	return sp


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


## Directly spawns the forced enemy species (see _derive_fauna's
## force_hostile_enemy) close enough to actually be seen right away, instead
## of leaving it to the normal random spawner -- that only guarantees the
## species EXISTS in the pool, and measured up to a minute+ (sometimes a full
## miss within a minute) before the random roll happened to land on it, which
## defeats the purpose of a "guaranteed enemy for testing" flag. Safe to call
## even with no forced species (no-op) or multiple times (only ever spawns
## the one).
func spawn_hostile_enemy_near(player_pos: Vector3, world: WorldManager) -> void:
	if _forced_enemy_species.is_empty():
		return
	for c in _creatures:
		if is_instance_valid(c) and c.species.get("pattern", "") == "lunger":
			return  # already out there
	var local_player := to_local(player_pos)
	var player_d := local_player.length()
	if player_d < 1.0:
		return
	var base_dir := local_player / player_d
	var t1 := base_dir.cross(Vector3.UP)
	if t1.length() < 0.1:
		t1 = base_dir.cross(Vector3.RIGHT)
	t1 = t1.normalized()
	var t2 := base_dir.cross(t1).normalized()
	for attempt in 24:
		var ang := randf() * TAU
		var r := randf_range(12.0, 30.0)  # close enough to be immediately visible
		var offset := (t1 * cos(ang) + t2 * sin(ang)) * r
		var dir := (base_dir * player_d + offset).normalized()
		var surface_pt := _surface_point(dir)
		var up := _axis_of(dir) if shape_cube else dir
		var ground_v := world_to_voxel(to_global(surface_pt - up * 0.5))
		var stand_v := world_to_voxel(to_global(surface_pt + up * 0.3))
		var head_v := world_to_voxel(to_global(surface_pt + up * 1.3))
		var gid := get_id(ground_v)
		if gid == Blocks.AIR or gid == Blocks.WATER:
			continue
		if get_id(stand_v) != Blocks.AIR or get_id(head_v) != Blocks.AIR:
			continue
		_spawn_at(to_global(surface_pt + up * 0.05), _forced_enemy_species, world)
		return


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


## Is the chunk at this world point actually streamed in (real collision mesh
## applied), not just "generation_sample says solid ground here"? Terrain is a
## pure function so get_id/generation_sample answer instantly everywhere on the
## planet regardless of streaming state -- but there's nothing to physically
## stand on until the chunk's mesh/collision has actually been built and
## applied on the main thread. Spawning without this check let creatures/NPCs
## land on ground that was correct in theory but not yet solid in practice,
## and they'd fall straight through into the void until it eventually streamed in.
func _chunk_ready_at(world_pos: Vector3) -> bool:
	return loaded_chunks.has(chunk_of(world_to_voxel(world_pos)))


func _spawn_at(world_pos: Vector3, sp: Dictionary, world: WorldManager) -> void:
	if not _chunk_ready_at(world_pos):
		return
	var c := Creature.new()
	add_child(c)
	c.global_position = world_pos
	c.configure(sp, self, world)
	_creatures.append(c)


# How far from center anything (terrain, trees, buildings, or water) can possibly exist.
func _max_reach() -> float:
	return maxf(radius + terrain_amp + maxf(tree_reach, settlement_reach), water_level)


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


# --- settlements: invent small-to-large civilizations from the seed, exactly ----
# like ores/fauna -- a handful of candidate sites spread around the planet, each
# independently rolling whether it holds a settlement and how big. Materials are
# picked to match the planet (wood on forested worlds, ice on frost worlds, stone
# everywhere else) so they read as built FROM the world they're on, not pasted in.
func _derive_settlements(force_one: bool) -> void:
	settlements.clear()
	settlement_reach = 0.0
	if not settlements_enabled:
		return  # this system's civilization tier doesn't put anyone on this planet
	# how hospitable this world is -- shapes both how likely a site is to be
	# settled at all, and how big it grows when it is
	var hab := 0.0
	if has_atmosphere:
		hab += 1.0
	if hazard == "none":
		hab += 1.0
	if water_style != WATER_NONE:
		hab += 0.3
	if tree_density > 0.1:
		hab += 0.3

	# An ADVANCED empire ships its own prefab materials in, so its architecture
	# reads the same on every world it colonizes -- metal and glass, not local
	# stone. A primitive colony builds from whatever the planet itself provides.
	var advanced: bool = civ_tier >= 3
	var wall_mat: int
	var roof_mat: int
	if advanced:
		wall_mat = Blocks.METAL
		roof_mat = Blocks.ROOF_SLAB
	elif tree_density > 0.0:
		wall_mat = flora_wood
		roof_mat = Blocks.WOOD_DARK
	elif pal_top == Blocks.SNOW or pal_top == Blocks.ICE:
		wall_mat = Blocks.ICE
		roof_mat = Blocks.METAL
	elif pal_top == Blocks.REGOLITH:
		wall_mat = Blocks.REGOLITH
		roof_mat = Blocks.METAL
	else:
		wall_mat = pal_rock
		roof_mat = Blocks.METAL

	# candidate directions spread evenly around the whole planet (a Fibonacci
	# sphere), so settlements aren't clustered near one pole -- works for both
	# cube and sphere shapes since only the DIRECTION matters here
	var golden := PI * (3.0 - sqrt(5.0))
	for i in SETTLEMENT_SLOTS:
		var y := 1.0 - (float(i) / float(maxi(SETTLEMENT_SLOTS - 1, 1))) * 2.0
		var rr := sqrt(maxf(0.0, 1.0 - y * y))
		var theta := golden * float(i)
		var dir := Vector3(cos(theta) * rr, y, sin(theta) * rr).normalized()

		var forced: bool = force_one and i == 0
		if not forced:
			var prob := clampf(0.10 + hab * 0.09, 0.05, 0.45)
			if _hash01(Vector3i(i, 4242, 0), 31) >= prob:
				continue
		else:
			# The forced test settlement uses the SAME dry-land search (same seed
			# salt, 4040) that find_spawn_point uses for Vector3.UP -- so instead of
			# a fixed direction that could land underwater (silently skipping the
			# "guaranteed" settlement entirely) or just be far from wherever the
			# player actually spawns, this always lands dry AND right next to spawn.
			dir = _dry_land_dir(Vector3.UP, 4040)

		var anchor := _surface_point(dir)
		if not forced and water_style != WATER_NONE and _norm(anchor) <= water_level + 2.0:
			continue  # no (non-forced) settlements underwater

		var srng := RandomNumberGenerator.new()
		var sseed := _seed + i * 7907 + 5151
		srng.seed = sseed
		var troll := srng.randf() - hab * 0.18
		var tier := 3 if troll < 0.08 else (2 if troll < 0.30 else (1 if troll < 0.65 else 0))
		if forced:
			tier = maxi(tier, 1)  # a forced settlement is at least a Village
		tier = mini(tier, settlement_tier_cap)  # a low-civ system never rolls higher than this

		var up := _axis_of(dir) if shape_cube else dir
		var tang := up.cross(Vector3.RIGHT)
		if tang.length() < 0.1:
			tang = up.cross(Vector3.FORWARD)
		var u := tang.normalized()
		var v := up.cross(u).normalized()

		# An advanced empire builds UP: taller towers, packed tighter, over a
		# wider footprint -- the difference between a village and a real city.
		# Even a modest town (tier >= 2) mixes in the occasional 2-story house.
		var max_floors: int = 6 if advanced else (2 if tier >= 2 else 1)
		var radius: float = SETTLEMENT_TIER_RADIUS[tier] * (1.5 if advanced else 1.0)
		var density: float = minf(SETTLEMENT_TIER_DENSITY[tier] * (1.25 if advanced else 1.0), 0.85)
		settlements.append({
			"dir": dir, "up": up, "u": u, "v": v, "anchor": anchor,
			"tier": tier, "radius": radius, "density": density,
			"wall_mat": wall_mat, "roof_mat": roof_mat, "seed": sseed,
			"advanced": advanced, "max_floors": max_floors,
		})
		# tallest possible building (or the even-taller central spire) + roof,
		# so chunks containing tower/spire tops stream in
		var reach_floors := max_floors + (LANDMARK_EXTRA_FLOORS if advanced else 0)
		settlement_reach = maxf(settlement_reach, _settlement_max_height(reach_floors))


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
## Jitter away from `prefer` until landing on dry ground, deterministically (same
## seed salt always finds the same spot). Shared by find_spawn_point and the
## forced test settlement in _derive_settlements so the two can be guaranteed to
## coincide -- see the comment there for why that matters.
func _dry_land_dir(prefer: Vector3, seed_salt: int) -> Vector3:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed + seed_salt
	prefer = prefer.normalized()
	var dir := prefer
	for attempt in 80:
		if attempt > 0:
			dir = (prefer + Vector3(rng.randf() * 2 - 1, rng.randf() * 2 - 1, rng.randf() * 2 - 1) * 0.6).normalized()
		if water_style == WATER_NONE or _surf(dir) > water_level + 3.0:
			break
	return dir


func find_spawn_point(prefer: Vector3) -> Vector3:
	var dir := _dry_land_dir(prefer, 4040)
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

	# A settlement grades its own ground: each building sits on a small flat pad
	# at ITS OWN local terrain height (not a single height for the whole
	# settlement), blending smoothly back to the natural surface just past its
	# walls -- otherwise a building the noisy terrain didn't happen to match ends
	# up half-buried on one side and floating on the other.
	#
	# The vertical guard below is a real perf fix, not just tidiness: without it,
	# EVERY voxel query anywhere on the planet -- the core, bedrock on the far
	# side, anywhere -- paid for a full settlement/building lookup the instant
	# any settlement existed at all, since this ran unconditionally before even
	# checking how far the voxel was from the surface. Grading only ever affects
	# a thin band near the surface (a little below it, up to a building's own
	# height above it), so anything outside that band can never be touched by it.
	var settle: Dictionary = {}
	if not settlements.is_empty() and d > surf - 20.0 and d < surf + settlement_reach + 10.0:
		settle = _settlement_at(p, surf)
		if float(settle.get("surf", -1.0)) >= 0.0:
			surf = settle["surf"]

	if d > surf:
		# above the terrain: a building takes priority (so trees don't grow through
		# houses), then water fills anything up to the water level, otherwise maybe
		# a tree, otherwise air
		if not settle.is_empty() and int(settle.get("block", Blocks.AIR)) != Blocks.AIR:
			return int(settle["block"])
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
		if not settlements.is_empty():
			var path_id := _settlement_path_block(p)
			if path_id != Blocks.AIR:
				return path_id
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
				# no trees rooted inside a settlement -- rejecting at the ROOT
				# (not per-voxel) means a canopy can never end up sliced in half
				# by a wall; the land people build on reads as actually cleared
				if not settlements.is_empty() and _tree_blocked_by_settlement(base):
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


# --- settlement buildings ------------------------------------------------------
#
# Buildings are laid out in EXACT INTEGER voxel coordinates. On a cube planet
# (the default) a settlement's up/u/v frame is three cardinal axes, so once the
# building's base voxel is snapped to integers every local coordinate is an
# exact integer and each wall is a complete, gap-free ring.
#
# This replaced float-tolerance tests ("absf(lu) >= hw - 0.6"), which captured
# 0, 1, or 2 voxels depending on where a building's center happened to fall
# between grid lines -- that inconsistency is why walls and roofs went missing.
#
# Footprints are always ODD-sized (2*hw+1 by 2*hd+1) so every building has a
# true center voxel for doors and windows to align to.

const STORY_HEIGHT := 5   # wall height of one floor in a multi-story building

# Building styles, in order of how developed the settlement is.
const B_HUT := 0     # one cramped room, hip roof -- an outpost or frontier village
const B_HOUSE := 1   # proper home: gable roof, eaves, windows all round, 2 rooms
const B_TOWER := 2   # advanced city block: setback storys, flat roof, glass curtain walls

# A tower's footprint steps inward every couple of floors -- a stepped
# "arcology" spire instead of a plain rectangular box -- floored at a minimum
# so top floors stay usable. This is the single biggest visual signal that
# separates an advanced city from a primitive one just being "the same
# buildings, bigger." Every floor was tried first; stepping every 2 reads as
# more deliberate architecture and halves how many setback boundaries exist
# for the floor-slab/wall-ring interaction below to have to get right.
const TOWER_MIN_HALF := 3
const TOWER_SETBACK_EVERY := 1

func _tower_tier(hw: int, hd: int, floor_idx: int) -> Vector2i:
	var steps := floor_idx / TOWER_SETBACK_EVERY
	return Vector2i(maxi(hw - steps, TOWER_MIN_HALF), maxi(hd - steps, TOWER_MIN_HALF))


# A single guaranteed landmark spire at the exact center of every advanced
# settlement's plaza -- taller and wider than any regular tower, so a city's
# skyline reads as having a deliberate centerpiece, not just "some boxes."
const LANDMARK_CELL_X := 999999
const LANDMARK_CELL_Y := 999999
const LANDMARK_EXTRA_FLOORS := 3


## Everything about one building, derived from its cell. Every consumer (the
## voxel renderer, the ground grading, the path layout, tree clearing) goes
## through this ONE function so they can never disagree about a building's
## extent -- the class of bug that caused floating walls earlier.
func _building_plan(cx: int, cy: int, st: Dictionary) -> Dictionary:
	if cx == LANDMARK_CELL_X and cy == LANDMARK_CELL_Y:
		var lfloors: int = int(st.get("max_floors", 4)) + LANDMARK_EXTRA_FLOORS
		return {"hw": 8, "hd": 8, "h": lfloors * STORY_HEIGHT, "style": B_TOWER, "floors": lfloors}

	var seed_val = st["seed"]
	var advanced: bool = bool(st.get("advanced", false))
	var tier := int(st["tier"])
	var r_style := _hash01(Vector3i(cx, cy, 11), seed_val)

	# Style ladder: what a settlement builds depends on how developed it is, but
	# always with a couple of humbler buildings mixed in so a town doesn't read
	# as one repeated stamp.
	var style: int
	if advanced:
		style = B_TOWER if r_style < 0.75 else B_HOUSE
	elif tier >= 2:
		style = B_HOUSE if r_style < 0.8 else B_HUT
	elif tier == 1:
		style = B_HOUSE if r_style < 0.45 else B_HUT
	else:
		style = B_HUT

	var hw := 2
	var hd := 2
	var floors := 1
	var h := 3
	match style:
		B_HUT:
			hw = 2 + int(_hash01(Vector3i(cx, cy, 1), seed_val) * 2.0)   # 2..3 -> 5..7 wide
			hd = 2 + int(_hash01(Vector3i(cx, cy, 2), seed_val) * 2.0)
			h = 3
		B_HOUSE:
			hw = 3 + int(_hash01(Vector3i(cx, cy, 1), seed_val) * 2.0)   # 3..4 -> 7..9 wide
			hd = 2 + int(_hash01(Vector3i(cx, cy, 2), seed_val) * 3.0)   # 2..4
			# a town/city grows a second storey onto some homes
			floors = 2 if (tier >= 2 and _hash01(Vector3i(cx, cy, 12), seed_val) < 0.35) else 1
			h = floors * STORY_HEIGHT - 1
		B_TOWER:
			hw = 5 + int(_hash01(Vector3i(cx, cy, 1), seed_val) * 3.0)   # 5..7 -> wide base to taper from
			hd = 5 + int(_hash01(Vector3i(cx, cy, 2), seed_val) * 3.0)
			# pow() bias keeps most towers short so the few tall ones read as a
			# skyline instead of every block being the same height
			var max_floors := int(st.get("max_floors", 6))
			floors = 2 + int(pow(_hash01(Vector3i(cx, cy, 3), seed_val), 1.6) * float(max_floors - 1))
			h = floors * STORY_HEIGHT
	return {"hw": hw, "hd": hd, "h": h, "style": style, "floors": floors}


## Tallest anything a building of this style can reach above its base, used for
## streaming reach and for the early-out in generation_sample.
func _settlement_max_height(max_floors: int) -> float:
	return float(maxi(max_floors, 1)) * float(STORY_HEIGHT) + 8.0


## Which wall the door sits on: the one facing back toward the plaza centre.
## Returns (axis_is_u, sign). Shared by the renderer AND the path layout.
func _building_door_axis(cu: float, cv: float) -> Vector2:
	var door_axis_u: bool = absf(cu) >= absf(cv)
	var raw: float = cu if door_axis_u else cv
	var door_sign: float = -1.0 if raw >= 0.0 else 1.0
	return Vector2(1.0 if door_axis_u else 0.0, door_sign)


## The exact voxel a building's ground floor rests on, snapped to integers so
## the whole structure lands on voxel boundaries (see the block comment above).
func _building_base(anchor: Vector3, u: Vector3, v: Vector3, cu: float, cv: float) -> Vector3:
	var d := _building_base_dir(anchor, u, v, cu, cv)
	var s := _surface_point(d)
	return Vector3(roundi(s.x), roundi(s.y), roundi(s.z))


# The direction (from planet center) toward a building's footprint center.
func _building_base_dir(anchor: Vector3, u: Vector3, v: Vector3, cu: float, cv: float) -> Vector3:
	return (anchor + u * cu + v * cv).normalized()


## Every building-cell candidate near world point `p`, for one settlement, as
## {cx, cy, cu, cv} dicts. Centralises the cell-neighbourhood scan that the
## renderer, grading, and path layout all need, so they can never disagree
## about which buildings are nearby.
func _nearby_buildings(p: Vector3, st: Dictionary, margin: float) -> Array:
	var out: Array = []
	var anchor: Vector3 = st["anchor"]
	var u: Vector3 = st["u"]
	var v: Vector3 = st["v"]
	var rel := p - anchor
	var su := rel.dot(u)
	var sv := rel.dot(v)
	if Vector2(su, sv).length() > float(st["radius"]) + margin:
		return out
	var cell := BUILDING_CELL
	var ccx := floori(su / cell)
	var ccy := floori(sv / cell)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var cx := ccx + dx
			var cy := ccy + dy
			var cu := (float(cx) + 0.5) * cell
			var cv := (float(cy) + 0.5) * cell
			if _building_exists(cx, cy, cu, cv, st):
				out.append({"cx": cx, "cy": cy, "cu": cu, "cv": cv})
	return out


## Does a building stand in this cell? The plaza centre is kept clear as a
## village green / town square (and, for an advanced settlement, room for its
## central landmark spire), which makes the paths radiating from it read as a
## deliberate layout rather than random dirt. Checked against the CANDIDATE's
## own near edge, not just its cell-center distance -- a wide tower whose
## center sits just past the clear radius can still physically overlap
## whatever's at the centre if its own half-width isn't subtracted first (this
## is exactly what let a regular tower overlap the landmark spire earlier).
func _building_exists(cx: int, cy: int, cu: float, cv: float, st: Dictionary) -> bool:
	var dist := Vector2(cu, cv).length()
	if dist > float(st["radius"]):
		return false
	var plan := _building_plan(cx, cy, st)
	var near_edge := dist - maxf(float(plan["hw"]), float(plan["hd"]))
	if near_edge < PLAZA_CLEAR:
		return false
	return _hash01(Vector3i(cx, cy, 0), st["seed"]) < float(st["density"])


const PLAZA_CLEAR := 11.0  # radius of the open square at a settlement's centre
const SETTLEMENT_PAD := 3.0  # how far past a building's walls the ground grading blends out


## Ground height to use at `p`, flattened under any nearby building and blended
## smoothly back to natural terrain past its walls. Returns -1.0 where no
## building is close enough to matter. Each building grades to ITS OWN local
## terrain height, so a village on a slope steps down the hill rather than
## demanding one giant flat shelf.
## The grading contribution of ONE building (any cell, including the landmark
## spire's fixed cell) at world point `p` -- -1.0 if `p` is out of its range.
## Pulled out so the landmark doesn't need its own slightly-different copy of
## this math (the exact divergence-between-copies bug class logged earlier).
## Takes an already-computed plan/base (see _settlement_at) instead of
## recomputing them -- _building_plan does several _hash01 calls and
## _building_base does a real noise sample (_surf), so calling this and
## _building_block separately for the same cell used to pay for both twice.
func _building_pad(p: Vector3, u: Vector3, v: Vector3, base: Vector3, plan: Dictionary, natural_surf: float) -> float:
	var brel := p - base
	var lu := brel.dot(u)
	var lv := brel.dot(v)
	# +0.5 covers the voxel's own extent past its integer centre
	var out_dist := maxf(absf(lu) - (float(plan["hw"]) + 0.5), absf(lv) - (float(plan["hd"]) + 0.5))
	if out_dist > SETTLEMENT_PAD:
		return -1.0
	var t := clampf(out_dist / SETTLEMENT_PAD, 0.0, 1.0)
	return lerpf(_norm(base), natural_surf, smoothstep(0.0, 1.0, t))


## Combined ground-grading + block-id lookup for one voxel. Originally these
## were two completely separate scans (_settlement_pad_surf / _settlement_id_at),
## each independently re-discovering the same nearby buildings and recomputing
## _building_plan for them -- a real, measured performance bug: it roughly
## doubled the cost of every above-ground voxel near a settlement, and a big
## Advanced-tier city (150-unit plaza, multi-story towers with lots of above-
## ground air-space to query) could take ~500ms to mesh a single chunk as a
## result. One pass over the candidate buildings now does both jobs at once.
## Returns {"surf": graded height or -1.0, "block": building's id or AIR}.
func _settlement_at(p: Vector3, natural_surf: float) -> Dictionary:
	var graded := -1.0
	var block := Blocks.AIR
	for st in settlements:
		var anchor: Vector3 = st["anchor"]
		var up: Vector3 = st["up"]
		var u: Vector3 = st["u"]
		var v: Vector3 = st["v"]
		if bool(st.get("advanced", false)):
			var rel0 := p - anchor
			if Vector2(rel0.dot(u), rel0.dot(v)).length() <= 20.0:
				var lplan := _building_plan(LANDMARK_CELL_X, LANDMARK_CELL_Y, st)
				var lbase := _building_base(anchor, u, v, 0.0, 0.0)
				var lb := _building_pad(p, u, v, lbase, lplan, natural_surf)
				if lb >= 0.0:
					graded = lb if graded < 0.0 else maxf(graded, lb)
				if block == Blocks.AIR:
					var lid := _building_block(p, up, u, v, lbase, lplan, 0.0, 0.0, st)
					if lid != Blocks.AIR:
						block = lid
		for b in _nearby_buildings(p, st, 20.0):
			var plan := _building_plan(b["cx"], b["cy"], st)
			var base := _building_base(anchor, u, v, b["cu"], b["cv"])
			var bl := _building_pad(p, u, v, base, plan, natural_surf)
			if bl >= 0.0:
				graded = bl if graded < 0.0 else maxf(graded, bl)
			if block == Blocks.AIR:
				var id := _building_block(p, up, u, v, base, plan, b["cu"], b["cv"], st)
				if id != Blocks.AIR:
					block = id
	return {"surf": graded, "block": block}


## Would a tree rooted at world point `base` collide with a settlement? Trees
## are rejected at their ROOT rather than clipped per-voxel, so a canopy can
## never end up sliced in half by a wall or floating inside a room. The land a
## settlement stands on reads as cleared, which is what people actually do.
func _tree_blocked_by_settlement(base: Vector3) -> bool:
	for st in settlements:
		var anchor: Vector3 = st["anchor"]
		var u: Vector3 = st["u"]
		var v: Vector3 = st["v"]
		var rel := base - anchor
		if Vector2(rel.dot(u), rel.dot(v)).length() <= float(st["radius"]) + 6.0:
			return true
	return false


const PATH_WIDTH := 1.6  # half-width of a settlement path

## Is `p` (on the ground surface) part of a dirt path? Every building gets a
## path from its own doorstep back to the plaza, so the settlement reads as
## connected rather than scattered.
# Advanced empires pave their streets in Metal, not dirt -- ground texture
# alone should say "this isn't a village" even from a distance.
func _settlement_path_block(p: Vector3) -> int:
	for st in settlements:
		var anchor: Vector3 = st["anchor"]
		var u: Vector3 = st["u"]
		var v: Vector3 = st["v"]
		var path_mat: int = Blocks.METAL if bool(st.get("advanced", false)) else Blocks.PATH
		var rel := p - anchor
		var here := Vector2(rel.dot(u), rel.dot(v))
		if here.length() < PLAZA_CLEAR:
			return path_mat  # the open square itself is paved
		for b in _nearby_buildings(p, st, 20.0):
			var plan := _building_plan(b["cx"], b["cy"], st)
			var door := _building_door_point(b["cu"], b["cv"], plan)
			var seg := -door  # plaza centre is local (0,0)
			var seg_len := seg.length()
			if seg_len < 0.01:
				continue
			var seg_dir := seg / seg_len
			var t := clampf((here - door).dot(seg_dir), 0.0, seg_len)
			if here.distance_to(door + seg_dir * t) <= PATH_WIDTH:
				return path_mat
	return Blocks.AIR


# Local (u,v) point just outside a building's door -- where its path starts.
func _building_door_point(cu: float, cv: float, plan: Dictionary) -> Vector2:
	var door_info := _building_door_axis(cu, cv)
	if door_info.x > 0.5:
		return Vector2(cu + door_info.y * (float(plan["hw"]) + 1.0), cv)
	return Vector2(cu, cv + door_info.y * (float(plan["hd"]) + 1.0))


## One building's voxel at `p`. All comparisons are exact integer tests against
## the building's plan, so walls/roofs are always complete. Takes an already-
## computed plan/base (see _building_pad's comment on why -- calling this and
## _building_pad separately for the same cell used to pay for both twice).
func _building_block(p: Vector3, up: Vector3, u: Vector3, v: Vector3, base: Vector3, plan: Dictionary,
		cu: float, cv: float, st: Dictionary) -> int:
	var hw: int = plan["hw"]
	var hd: int = plan["hd"]
	var h: int = plan["h"]
	var style: int = plan["style"]
	var floors: int = plan["floors"]

	var rel := p - base
	var iu := roundi(rel.dot(u))
	var iv := roundi(rel.dot(v))
	var ih := roundi(rel.dot(up))
	if ih < 1:
		return Blocks.AIR  # ih 0 is the ground voxel the building rests on

	var wall_mat: int = st["wall_mat"]
	var door_info := _building_door_axis(cu, cv)
	var door_axis_u: bool = door_info.x > 0.5
	var door_sign := int(door_info.y)

	# A tower's footprint is per-floor (see _tower_tier) -- everything below the
	# roof (wall extent, windows, floor slabs) must use THIS floor's tier, not
	# the base footprint, or the setback would never actually show up. The roof
	# itself caps the TOP (smallest) tier.
	var floor_idx: int = clampi((ih - 1) / STORY_HEIGHT, 0, floors - 1)
	var cur_hw := hw
	var cur_hd := hd
	if style == B_TOWER:
		var cur_tier := _tower_tier(hw, hd, floor_idx)
		cur_hw = cur_tier.x
		cur_hd = cur_tier.y

	# --- roof ---
	#
	# ROOF_SLAB is a HALF-HEIGHT block (see Chunk._emit_solid_box_cell) -- it
	# must never sit directly beneath another full-height block, or there's a
	# visible half-voxel air gap between the slab's top and the block above it.
	# So a slab is used ONLY where nothing is stacked on top of it: the eave/lip
	# ring that oversteps the nominal footprint (nothing above it but sky), or a
	# tower's roof deck (capped by nothing -- the parapet sits beside it, not on
	# top of it). Anywhere the roof continues upward, that layer is a normal
	# full block so it stacks flush with no gap.
	if ih > h:
		var r := ih - h - 1  # 0 = first roof layer
		match style:
			B_TOWER:
				# flat deck + a parapet LIP at the same layer (not stacked above
				# the deck) -- caps the TOP (smallest) setback tier, not the base
				var top_tier := _tower_tier(hw, hd, floors - 1)
				if r != 0 or absi(iu) > top_tier.x or absi(iv) > top_tier.y:
					return Blocks.AIR
				return wall_mat if (absi(iu) == top_tier.x or absi(iv) == top_tier.y) else Blocks.ROOF_SLAB
			B_HUT:
				# hip roof: pulls in on BOTH axes, so a small square hut comes to
				# a point rather than wearing an oversized gable
				var in_footprint: bool = absi(iu) <= hw and absi(iv) <= hd
				if r == 0:
					if in_footprint:
						return int(st["roof_mat"])
					return Blocks.ROOF_SLAB if (absi(iu) <= hw + 1 and absi(iv) <= hd + 1) else Blocks.AIR
				var shrink := r - 1
				if absi(iu) > hw - shrink or absi(iv) > hd - shrink:
					return Blocks.AIR
				return int(st["roof_mat"])
			_:
				# gable: ridge runs along the LONG axis so only the short axis
				# slopes -- a real house silhouette
				var ridge_u: bool = hw >= hd
				var long_c := iu if ridge_u else iv
				var short_c := iv if ridge_u else iu
				var half_long := hw if ridge_u else hd
				var half_short := hd if ridge_u else hw
				var in_footprint2: bool = absi(long_c) <= half_long and absi(short_c) <= half_short
				if r == 0:
					if in_footprint2:
						return int(st["roof_mat"])
					if absi(long_c) <= half_long + 1 and absi(short_c) <= half_short + 1:
						return Blocks.ROOF_SLAB
					return Blocks.AIR
				var shrink2 := r - 1
				if absi(long_c) > half_long or absi(short_c) > half_short - shrink2:
					return Blocks.AIR
				return int(st["roof_mat"])

	# --- below the roof: strictly inside THIS FLOOR's footprint (cur_hw/cur_hd,
	# not the base hw/hd -- a tower's upper floors are narrower) ---
	if absi(iu) > cur_hw or absi(iv) > cur_hd:
		return Blocks.AIR
	var on_wall: bool = absi(iu) == cur_hw or absi(iv) == cur_hd

	if not on_wall:
		if style == B_TOWER or (style == B_HOUSE and floors > 1):
			# floor slabs divide the storys, with one corner left open the whole
			# height as a stairwell so the floors aren't sealed boxes
			var in_stairwell: bool = iu >= cur_hw - 2 and iv >= cur_hd - 2
			if ih % STORY_HEIGHT == 0 and not in_stairwell:
				# At a tower's setback, the floor ABOVE is narrower, so its wall
				# ring lands somewhere inside THIS floor's (wider) interior --
				# exactly where the slab would otherwise sit with a full wall
				# block on top of it (the same half-voxel gap bug as the roof).
				# Render a low curb there instead: a real, sensible detail at a
				# setback edge, not just a patched-over gap.
				if style == B_TOWER and floor_idx < floors - 1:
					var next_tier := _tower_tier(hw, hd, floor_idx + 1)
					var on_next_ring: bool = (absi(iu) == next_tier.x and absi(iv) <= next_tier.y) \
						or (absi(iv) == next_tier.y and absi(iu) <= next_tier.x)
					if on_next_ring:
						return wall_mat
				return Blocks.ROOF_SLAB
			return Blocks.AIR
		# a house wide enough gets a second room behind a real internal door
		if style == B_HOUSE and hw >= 3 and iu == 0:
			if iv == 0 and ih <= 2:
				return Blocks.DOOR
			return wall_mat
		return Blocks.AIR

	# --- exterior door, on the wall facing the plaza (ground floor, so hw/hd
	# already equal the ground floor's tier) ---
	if ih <= 2:
		if door_axis_u and iu == door_sign * hw and iv == 0:
			return Blocks.DOOR
		if not door_axis_u and iv == door_sign * hd and iu == 0:
			return Blocks.DOOR

	# --- windows ---
	match style:
		B_TOWER:
			# Alternating floors: a full glass curtain wall (corner posts left
			# solid) on even storys, a slimmer window band on odd ones -- a
			# striped, unmistakably artificial rhythm no primitive building has.
			if floor_idx % 2 == 0:
				if absi(iu) == cur_hw and absi(iv) < cur_hd:
					return Blocks.GLASS
				if absi(iv) == cur_hd and absi(iu) < cur_hw:
					return Blocks.GLASS
			else:
				var sl := ih % STORY_HEIGHT
				if sl == 2 or sl == 3:
					if absi(iu) == cur_hw and absi(iv) <= cur_hd - 2:
						return Blocks.GLASS
					if absi(iv) == cur_hd and absi(iu) <= cur_hw - 2:
						return Blocks.GLASS
		B_HUT:
			# one small window opposite the door: a hut is humble
			if ih == 2:
				if door_axis_u and iu == -door_sign * hw and iv == 0:
					return Blocks.GLASS
				if not door_axis_u and iv == -door_sign * hd and iu == 0:
					return Blocks.GLASS
		_:
			# a proper house has a window on every wall of every storey
			var sl2 := ih % STORY_HEIGHT
			if sl2 == 2 or sl2 == 3:
				if absi(iu) == hw and absi(iv) <= hd - 2 and absi(iv) <= 1:
					return Blocks.GLASS
				if absi(iv) == hd and absi(iu) <= hw - 2 and absi(iu) <= 1:
					return Blocks.GLASS
	return wall_mat


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

var _stream_last_cc0 := Vector3i(0x7fffffff, 0, 0)  # sentinel: never a real chunk coord
var _stream_last_rd := -1

## Keep chunks within `rd` (chunk radius) of `center_voxel` loaded; unload the rest.
##
## This used to rebuild its whole "wanted" set (up to (2*rd+1)^3 candidates,
## e.g. 1331 at rd=5) AND fully re-sort the load queue with a GDScript lambda
## comparator, on EVERY call -- and it's called every single physics frame
## from WorldManager, whether or not the player has actually moved. That
## dwarfed the actual per-chunk meshing cost during a fresh world load: at
## rd=5 with a large queue, this alone measured as the dominant real-world
## bottleneck, far more than settlement lookups or cave noise. The "wanted"
## set and queue order only change when the player crosses into a new chunk,
## so skip all of this when cc0/rd haven't changed since last call -- queued
## chunks still get dispatched every frame via process_load_queue regardless.
func stream(center_voxel: Vector3i, rd: int) -> void:
	var cc0 := chunk_of(center_voxel)
	if cc0 == _stream_last_cc0 and rd == _stream_last_rd:
		return
	_stream_last_cc0 = cc0
	_stream_last_rd = rd
	var wanted := {}
	for dx in range(-rd, rd + 1):
		for dy in range(-rd, rd + 1):
			for dz in range(-rd, rd + 1):
				var cc := cc0 + Vector3i(dx, dy, dz)
				if _chunk_possibly_solid(cc):
					wanted[cc] = true
					if not loaded_chunks.has(cc) and not _load_queue_set.has(cc):
						_load_queue.append(cc)
						_load_queue_set[cc] = true
	# unload chunks we no longer want (but let in-flight builds finish first)
	for cc in loaded_chunks.keys():
		if not wanted.has(cc) and not _inflight.has(cc):
			var node: Node = loaded_chunks[cc]
			loaded_chunks.erase(cc)
			node.queue_free()
	# drop queued loads that are no longer wanted
	_load_queue = _load_queue.filter(func(cc): return wanted.has(cc))
	_load_queue_set.clear()
	for cc in _load_queue:
		_load_queue_set[cc] = true
	# nearest-first so the world fills outward from the player
	_load_queue.sort_custom(func(a, b): return (a - cc0).length_squared() < (b - cc0).length_squared())


## Apply finished worker results, then dispatch more build tasks. `budget` is unused
## now (kept for call-site compatibility); pacing is via APPLY_PER_FRAME / MAX_INFLIGHT.
func process_load_queue(_budget: int) -> int:
	# 1) apply results the workers have finished (main-thread mesh construction)
	_ready_mutex.lock()
	var ready_ccs: Array = _ready_data.keys()
	_ready_mutex.unlock()
	# Player edits first: _ready_data is an unordered dict, so without this an
	# edited chunk waits behind however many streaming chunks finished with it.
	if not _edit_priority.is_empty():
		var front: Array = []
		var rest: Array = []
		for cc in ready_ccs:
			if _edit_priority.has(cc):
				front.append(cc)
			else:
				rest.append(cc)
		ready_ccs = front + rest
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
		_edit_priority.erase(cc)
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
		_load_queue_set.erase(cc)
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
const _DOOR_NEIGH6 := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]

## Toggle one door voxel and its own other half (the 2-tall pair is always
## exactly 1 voxel apart along SOME axis-aligned direction). Checks all 6
## neighbors rather than recomputing "up" via _axis_of(v) -- that axis is only
## an approximation of the true local up near a cube face's center, and drifts
## for anything far from it (a big Advanced-city plaza can have a 150-unit
## radius, easily far enough to disagree). A wrong axis meant a click could
## flip only ONE of the two door voxels (so it never looked "open" until a
## second click happened to hit the other half), and in the worst case could
## even reach into a completely unrelated door a building over. Checking all 6
## neighbors instead is strictly safer: buildings are spaced far enough apart
## (BUILDING_CELL) that an unrelated door is never voxel-adjacent to this one,
## so this only ever finds this door's own genuine other half.
func toggle_door(v: Vector3i) -> bool:
	var id := get_id(v)
	if not Blocks.is_door(id):
		return false
	var new_id := Blocks.door_toggle_of(id)
	set_block(v, new_id)
	for n: Vector3i in _DOOR_NEIGH6:
		var nb: Vector3i = v + n
		if Blocks.is_door(get_id(nb)):
			set_block(nb, new_id)
	return true


# Queue a loaded chunk to be re-meshed on a worker thread (never blocks the main
# thread). Applied a frame or two later via process_load_queue.
func _rebuild_if_loaded(cc: Vector3i) -> void:
	if loaded_chunks.has(cc):
		_dirty[cc] = true
		# Remember that this one came from an EDIT, so its finished mesh jumps
		# the queue below. Without it a broken block could sit visible for a
		# second or more behind whatever terrain happened to be streaming.
		_edit_priority[cc] = true


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
