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
## Hostile wildlife on or off. On: hostile species spawn, weighted heavily
## toward night (see _pick_land_species), and the home world has its
## guaranteed sword-and-shield enemy among them. Set true to switch every
## hostile species off; the species are still generated from the seed either
## way, so turning it off and on does not change what a world rolls.
const HOSTILES_DISABLED := false
## Night Stalkers on or off. On: they come out once it is properly dark.
const STALKERS_DISABLED := false

# --- configuration (set via configure()) ---
var planet_name := "Planet"
var radius := 64.0          # nominal surface radius in voxels
var terrain_amp := 6.0      # +/- surface variation from noise

# --- mountains ----------------------------------------------------------------
#
# A second height layer, on top of the rolling hills, using RIDGED noise rather
# than more octaves of the same smooth noise. More octaves make the whole surface
# bumpier; ridged noise makes lines of high ground with valleys between them,
# which is what a mountain range is. Everything under a cutoff contributes
# nothing at all, so ranges turn up here and there instead of the entire planet
# rising -- which is what "a few mountains" has to mean.
var mountain_noise := FastNoiseLite.new()
var mountain_amp := 0.0     # 0 disables the layer entirely (and its noise lookup)
## Below this the layer is silent. Tuned against the noise's own distribution,
## which is not symmetric -- its median is 0.31, so a cutoff that sounds high
## still leaves plenty. Measured: 0.58 puts mountains on about a fifth of the
## surface, 0.30 would have put them on half of it, which is a mountain planet
## rather than a planet with mountains.
const MOUNTAIN_CUTOFF := 0.18
## Terracing is what turns a steep slope into a CLIFF. A slope voxelises into a
## staircase you can walk up; a bench voxelises into a wall you have to climb
## around. Only the mountain layer is terraced, so the plains stay smooth.
const TERRACE_STEP := 6.0
const TERRACE_MIX := 0.6
var surface_gravity := 23.0 # m/s^2 at the surface; drives walk-vs-float feel

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
## Seconds for one full day. Seeded per planet so worlds don't share a rhythm --
## a short day makes a planet feel small and frantic, a long one makes it feel
## vast. Only planets WITH an atmosphere run a visible cycle; an airless rock
## has no sky to redden, so it just gets hard light and hard shadow.
## How long one whole turn of the clock takes, and how much of it is daylight.
## Three quarters. Measured over a whole cycle the old two thirds really did
## give twice as much light as dark -- 328 seconds against 169 -- but it did
## not PLAY that way, because night is the part you spend hiding and it is the
## part you notice. When the clock and the feeling disagree about a thing this
## subjective, the feeling is the one worth fixing.
const DAY_SHARE := 0.75
var day_length := 600.0
## How far through the current day, 0..1. Advanced by main's environment update
## rather than by the planet, so it keeps ticking for planets you aren't on.
var day_phase := 0.0
## How many whole days this world has turned since the world began. day_phase
## wraps to 0..1 every cycle, so it cannot answer "which night is this" -- and
## anything that wants one roll per night (an aurora, say) needs a number that
## keeps counting.
var day_count := 0
## Where a brand new world starts its home planet. Sun height is sin(phase*TAU),
## so 0 is sunrise, 0.25 noon and 0.5 sunset: this is early morning, with the sun
## just clear of the horizon and most of the daylight still ahead of you.
## Other planets keep the random phase they derive from the seed -- a system
## where every world is at dawn at once would be a strange sight from orbit.
const MORNING_PHASE := 0.05

## Is the sun below the horizon here? The whole day/night system is this one
## sine of the phase -- the light swings around the up axis rather than the
## world turning -- so asking it here keeps "is it dark" as one answer rather
## than a comparison rewritten at each call site.
func is_night() -> bool:
	return sun_height() < 0.0


## How high the sun is, -1 to 1, at the hour the clock stands at.
##
## Not simply sin(phase): the lit half of the circle is stretched to DAY_SHARE
## of the clock and the dark half squeezed into what is left, so a day really
## is longer than its night while sunrise, noon and sunset keep their shape.
func sun_height() -> float:
	return sin(sun_angle())


## Where the sun is on its circle, in radians -- shared with whatever draws it,
## so the sky and the clock cannot disagree about the hour.
func sun_angle() -> float:
	var t := fposmod(day_phase, 1.0)
	var u := (t / DAY_SHARE) * 0.5 if t < DAY_SHARE 		else 0.5 + (t - DAY_SHARE) / (1.0 - DAY_SHARE) * 0.5
	return u * TAU

# --- stations on this planet ---------------------------------------------------
# Every station is put down whole from the station ring and is a node of its
# own (see Station). The planet keeps no registry of them: when it needs to know
# which ones make up a base, it looks at the stations standing on it (see
# _rebuild_placed).
var _world_ref: WorldManager
## voxel -> the Station filling it, for stations standing on this planet.
## Rebuilt with each base scan, which is the only thing that asks.
var _placed_at: Dictionary = {}
## Cells holding a lit campfire: both the mesher (which draws the flames) and the
## light bake need to know where the fires are. A Campfire station registers its
## own cell when it is put down (see Station._register_fire).
var _fire_cells: Dictionary = {}
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
## "warren" (most worlds): walkable tunnels with rooms off them. "cavern": the
## enormous voids, kept for a minority of planets as a spectacle.
var cave_style := "warren"
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
## Which of the four families this world belongs to ("verdant", "dust",
## "frozen", "scorched"), or "" for a side world. Decides its signature ore.
var family := ""
## What kind of world this is ("Reef world", "Tundra"...), for anything that describes it.
var world_type := ""

# --- planet class -------------------------------------------------------------
#
# DERIVED, never stored. A world's class is the name for what it already is --
# whether it holds air, what its water is doing, and whether it is trying to
# freeze or cook you -- so it can never disagree with the world it describes. A
# player can work out a planet's class by standing on it and looking around,
# which is the whole point of having classes at all.
const CLASS_NAMES := {
	"M": "temperate", "P": "frozen", "H": "arid",
	"Y": "scorched", "O": "ocean", "D": "barren",
}

func planet_class() -> String:
	if not has_atmosphere:
		# No air: what is left to tell them apart is whether there is water.
		return "O" if water_style == WATER_LIQUID else "D"
	if hazard == "cold":
		return "P"
	if hazard == "heat":
		# Scorched worlds are the ones actively cooking you, not merely dry.
		return "Y" if hazard_dps >= 3.0 else "H"
	return "M" if water_style == WATER_LIQUID else "H"


## Which plants actually grow on this world.
##
## Not every species its class allows: each one is rolled for, so two temperate
## worlds are not the same meadow, and a world can quite legitimately come up
## empty. Derived from the seed, so it is the same for everybody without being
## stored or sent.
func flora_here() -> Array:
	if not _flora_here.is_empty() or _flora_rolled:
		return _flora_here
	_flora_rolled = true
	var pool := Blocks.flora_for_class(planet_class())
	if pool.is_empty():
		return _flora_here
	var fr := RandomNumberGenerator.new()
	fr.seed = _seed + 8123
	# A world with no life at all is a real outcome -- but it is the TERRAIN that
	# says so, by growing nothing, not a separate roll here. This used to be its
	# own 18% chance, which could land on a world covered in forest and meadow
	# and leave it with no species at all: every leaf you broke and every tuft
	# you cleared then gave you nothing, for ever, with no way to tell that from
	# bad luck.
	if tree_density <= 0.0 and grass_density <= 0.0:
		return _flora_here
	# SHUFFLED before rolling. Walking the pool in table order and keeping each
	# with 70% chance is not a random subset: whatever is listed first survives
	# nearly every time, so every class M world grew the same first grass and
	# the same first tree, and the seeds you found said so.
	var order: Array = pool.duplicate()
	for i in range(order.size() - 1, 0, -1):
		var j := fr.randi() % (i + 1)
		var tmp = order[i]
		order[i] = order[j]
		order[j] = tmp
	for f in order:
		if fr.randf() < 0.7:
			_flora_here.append(f)
	# Whatever the terrain actually GROWS has to have a species behind it.
	# Generation reads tree_density and grass_density and knows nothing about
	# this list, so the two could disagree: a forested world whose roll happened
	# to keep only bushes had trees you could chop and never a sapling to show
	# for it. Anything you can stand in front of is a thing that grows here.
	_ensure_kind(order, "tree", tree_density > 0.0)
	_ensure_kind(order, "grass", grass_density > 0.0)
	# ...but if the dice took everything, keep one: an empty world should be the
	# roll above saying so, not the leftovers of this one.
	if _flora_here.is_empty():
		_flora_here.append(pool[fr.randi() % pool.size()])
	# Name each of them for THIS world. The species keeps its key -- growth
	# times, yields and what it is good for are all still looked up by that --
	# and only what it is called changes.
	var named: Array = []
	var used := {}
	for f in _flora_here:
		var e: Dictionary = (f as Dictionary).duplicate()
		# Only the front is rolled: the ending belongs to the species, so two
		# plants can no longer end up sharing a name by accident, and a name
		# that DOES turn up on two worlds is the same plant on both.
		var nm := ""
		for _try in 24:
			nm = Blocks.flora_name(fr, e)
			if not used.has(nm):
				break
		# Vanishingly unlikely, but a name is not worth a loop that might not end.
		if used.has(nm):
			nm += " " + str(used.size() + 1)
		used[nm] = true
		e["name"] = nm
		_flora_names[str(e["key"])] = nm
		named.append(e)
	_flora_here = named
	return _flora_here


## Keep at least one species of `kind`, when the terrain grows that kind and
## this world's class has one to give. `pool` is already shuffled, so the one
## taken is a random one rather than whichever the table lists first.
func _ensure_kind(pool: Array, kind: String, grows: bool) -> void:
	if not grows:
		return
	for f in _flora_here:
		if str((f as Dictionary)["kind"]) == kind:
			return
	for f in pool:
		if str((f as Dictionary)["kind"]) == kind:
			_flora_here.append(f)
			return


## One of this world's plants, chosen at random. Empty on a dead world.
func random_flora(rng_v: float) -> Dictionary:
	var here := flora_here()
	if here.is_empty():
		return {}
	return here[int(rng_v * here.size()) % here.size()]


## The name this species goes by on THIS world. Falls back to the table name,
## which is what a species nobody has rolled for is still called.
func flora_name(key: String) -> String:
	if _flora_names.has(key):
		return str(_flora_names[key])
	var sp := Blocks.flora_by_key(key)
	return str(sp.get("name", "Crop")) if not sp.is_empty() else "Crop"


## A species of a given kind growing here ("grass", "tree", "bush"), or {}.
##
## Picked at random from the ones present rather than being the first match. A
## world can grow three grasses, and always handing back the same one made the
## other two invisible -- you could farm a planet for an hour and never learn
## they were there.
func flora_of_kind(kind: String) -> Dictionary:
	var of_kind: Array = []
	for f in flora_here():
		if str(f["kind"]) == kind:
			of_kind.append(f)
	if of_kind.is_empty():
		return {}
	return of_kind[randi() % of_kind.size()]


func class_title() -> String:
	var c := planet_class()
	return "Class %s (%s)" % [c, CLASS_NAMES.get(c, "unknown")]

var hazard_dps := 0.0    # health/sec when exposed on the surface without protection
var _flora_here: Array = []   # memo for flora_here()
var _flora_rolled := false
var _flora_names: Dictionary = {}   # species key -> the name IT has HERE

# --- flora (derived from seed in configure) ---
const TREE_CELL := 7          # default spacing grid for tree placement
# Spacing is PER PLANET, because canopy size and spacing are the same problem:
# a tree may only reach one cell, so a giant needs its trees further apart to be
# allowed a canopy worth the name. Widening the grid instead of widening the
# search keeps the per-voxel cost identical on every world.
var tree_cell := TREE_CELL
# --- alien palette -------------------------------------------------------------
#
# A habitable world is not the same thing as an Earth-like one. Every planet
# recolours its own ground, stone, timber, foliage and water from its seed, so
# "safe to stand on" stops implying green grass and blue sea.
#
# Tints ride on the mesh's VERTEX COLOURS rather than the block registry: block
# ids stay global (a Rock is a Rock everywhere, and so is a recipe), while what
# you see is per world.
var alien_palette := false    # home stays familiar; everywhere else is recoloured
var strangeness := 0.0        # 0 = Earth-like, 1 = properly alien
var tint := {}                # block id -> Color, empty on a default world
var leaf_holes := 1.0         # foliage gappiness, 0 = solid canopy
var leaf_grain := 1.0         # foliage cell size multiplier
var ground_grain := 1.0       # grass/dirt texel size
var ground_levels := 4.0      # how many discrete shades the ground steps through
var ground_contrast := 1.0    # how far those shades spread
var rock_grain := 1.0
var rock_contrast := 1.0

# --- biomes ------------------------------------------------------------------
#
# Regions of ONE world that differ in ground, vegetation and relief.
#
# Big worlds only. A moon you can walk around in a few minutes reads as one
# place, and cutting it into six makes it read as a mess rather than as a
# journey; the size test is what stops a region being smaller than the walk
# across it. Moons generate at 240-420 and planets at 1100-1900, so this line
# falls cleanly between the two kinds of body rather than through the middle of
# either.
const BIOME_MIN_RADIUS := 700.0
## Roughly how many biome-widths fit across a planet. Bigger worlds therefore
## get MORE regions rather than larger ones, which is what keeps a region a
## walk rather than an expedition whatever size the world is.
const BIOME_SCALE := 3.2

## What a region can differ in.
##
## Every one of these is expressed in the planet's OWN materials -- its topsoil,
## its subsoil, its rock -- rather than in a fixed set of earth biomes. A world
## with violet ground and no trees should have regions of violet ground, not a
## pine forest and a savannah; inventing a climate model to stop that happening
## would be a much bigger thing than this, and would still get it wrong.
##
## `top` picks which of the planet's three ground materials is exposed:
## 0 topsoil, 1 subsoil, 2 rock. `trees` and `grass` scale the planet's own
## densities, so a world with no trees stays a world with no trees. `amp` scales
## the height variation and `lift` moves the whole surface up or down -- which,
## since sea level is a property of the planet, is also what turns a basin into
## a lake and a highland into somewhere above the weather.
##
## `lift` is a MULTIPLE of the planet's own terrain amplitude rather than a
## number of blocks. Amplitudes run from a few blocks to sixty depending on the
## world, and a fixed nine-block basin is a canyon on one planet and a dip you
## would not notice on the next.
##
## The ORDER is the axis they are laid out along: neighbours in this list are
## neighbours on the ground, so a basin runs into plains and never straight into
## barrens. Relief is interpolated between neighbours, which is why that matters
## -- a hard edge between amp 0.5 and amp 2.4 is a cliff around the whole region.
## Mostly the world's own TOPSOIL, in different colours, carrying different
## amounts of different plants. Exposing the subsoil or the bare rock is a
## strong statement -- it says "nothing grows here" -- and a table that made
## half its regions out of it produced a world of grass, dirt and stone rather
## than a world with places in it. Two regions at the dry end still do it,
## because a barrens should exist; the rest are all the same soil, told apart by
## what colour it is and what is standing on it.
const BIOME_KINDS := [
	{"name": "Wetland",   "top": 0, "trees": 0.90, "grass": 1.60, "amp": 0.40, "lift": -0.45},
	{"name": "Meadow",    "top": 0, "trees": 0.20, "grass": 1.90, "amp": 0.60, "lift": -0.10},
	{"name": "Woodland",  "top": 0, "trees": 2.60, "grass": 1.00, "amp": 0.90, "lift": 0.00},
	{"name": "Heath",     "top": 0, "trees": 0.35, "grass": 0.70, "amp": 1.00, "lift": 0.12},
	{"name": "Highland",  "top": 0, "trees": 0.55, "grass": 0.50, "amp": 1.90, "lift": 0.50},
	{"name": "Steppe",    "top": 1, "trees": 0.15, "grass": 0.30, "amp": 0.80, "lift": 0.16},
	{"name": "Barrens",   "top": 2, "trees": 0.00, "grass": 0.00, "amp": 1.35, "lift": 0.30},
]

## The biomes this world actually has, as parallel arrays rather than an array of
## dictionaries: these are read per voxel during generation, and a dictionary
## lookup per field per voxel is the kind of cost that only shows up as "the
## world takes longer to load than it used to".
var biome_names: Array = []
var _b_top := PackedInt32Array()
var _b_trees := PackedFloat32Array()
var _b_grass := PackedFloat32Array()
var _b_amp := PackedFloat32Array()
var _b_lift := PackedFloat32Array()
## How each region colours the ground it carpets. A hue turn, and a pull on how
## saturated and how bright -- NOT a colour of its own, because the ground still
## has to be this world's ground. A meadow and a moor are the same soil under a
## different amount of life, and that is what a shift of hue reads as; a flat
## palette swap reads as two planets stitched together.
var _b_hue := PackedFloat32Array()
var _b_sat := PackedFloat32Array()
var _b_val := PackedFloat32Array()
var biome_noise := FastNoiseLite.new()

var tree_density := 0.0       # 0 = desert (no trees), up to ~0.6 = dense forest
## How thickly this world carpets its soil with tall grass. Rolled per planet, so
## some are lush and some are close-cropped.
var grass_density := 0.0
## One entry per biome: the trees THAT region grows. A world's regions differ in
## what stands on them as much as in what they are made of -- a pine wood and a
## broad green wood are the difference between two places far more than another
## shade of dirt is.
##
## Every variant is rolled from the same world, so they read as one biosphere
## with local kinds rather than as a sampler of other planets' trees. And they
## all keep the base roll's SHAPE FAMILY: the grid trees are spaced on is one
## number for the whole world, sized for the biggest canopy it grows, so a
## region of giants next to a region of ordinary trees would leave the ordinary
## ones scattered three cells apart.
var flora_variants: Array = []
var flora_leaves: Array = []  # this planet's leaf-color palette (subset of Blocks.LEAF_IDS)
var flora_wood := Blocks.WOOD
var flora_shape := 0          # see FLORA_* below
## The growth shapes a world may use, one per region. Empty = the old roll
## (recognisable trees on a homely world, giants and coral on a strange one),
## which is what the home world keeps.
var flora_pool: Array = []
## A floor on how strange this world's colours are, 0..1. Away from home most
## worlds are set well clear of Earth-green.
var strange_min := 0.0
# What stands on a world. 0-4 are trees and lobed coral; the rest are the alien
# growths that make a world feel like nowhere on Earth.
const FLORA_ROUND := 0
const FLORA_PINE := 1
const FLORA_WIDE := 2
const FLORA_GIANT := 3
const FLORA_CORAL := 4
const FLORA_MUSHROOM := 5   # a stem as thick as a trunk under a cap you can shelter beneath
const FLORA_DOME := 6       # hollow blisters swelling out of the ground, with smaller ones budding off
const FLORA_BRANCH := 7     # staghorn coral: forking arms reaching up, bright at the tips
const FLORA_TUBE := 8       # tube sponges: clusters of open-topped pipes
const FLORA_SPIRE := 9      # banded needles leaning out of the ground
## Grid spacing each shape wants. A world's spacing is the widest its pool asks for.
const FLORA_CELL := {0: 7, 1: 7, 2: 7, 3: 22, 4: 10, 5: 17, 6: 13, 7: 11, 8: 9, 9: 10}
var trunk_rad := 0.7          # trunk half-width in blocks; a giant is a pillar
var _tree_scan := 1           # neighbouring tree cells to consider per voxel
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
## How teeming this world is, scaling how many creatures are about at once.
var life_density := 1.0
## Extra creatures allowed once it is fully dark, on top of MAX_CREATURES.
const NIGHT_EXTRA_CREATURES := 8
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
var MAX_INFLIGHT := _normal_inflight()   # concurrent worker tasks in flight
var APPLY_PER_FRAME := 6      # results turned into meshes per frame (main-thread cost)
const MAX_INFLIGHT_NORMAL := 24
const APPLY_PER_FRAME_NORMAL := 6
const MAX_INFLIGHT_FAST_LOAD := 64


## How many chunks may be building at once during play.
##
## Not the old flat 24. Godot's worker pool runs about one thread per core, so
## queueing two dozen builds hands every core to chunk generation and the frame
## has to fight for what is left -- which is felt as a stutter while looking
## around, since the camera is the thing that needs the main thread most often.
## Half the cores keeps terrain arriving while leaving the game somewhere to
## run. The loading screen still uses the number above: there is no frame to
## protect behind it.
static func _normal_inflight() -> int:
	return maxi(2, OS.get_processor_count() / 2)
const APPLY_PER_FRAME_FAST_LOAD := 24
## How long a frame may spend turning finished chunks into meshes and collision
## shapes. Six dense chunks in one frame is a hitch you can see; this spends the
## same effort over as many frames as it takes. Ignored during the loading
## screen, where there is no frame to protect and the count above is the point.
const APPLY_BUDGET_US := 4000

## Called by main.gd's loading screen: push far more chunks through per frame
## while the screen hides any jank, then restore normal pacing once the world
## is revealed.
func set_fast_loading(enabled: bool) -> void:
	MAX_INFLIGHT = MAX_INFLIGHT_FAST_LOAD if enabled else _normal_inflight()
	APPLY_PER_FRAME = APPLY_PER_FRAME_FAST_LOAD if enabled else APPLY_PER_FRAME_NORMAL
var _inflight := {}          # cc -> WorkerThreadPool task id
var _ready_data := {}        # cc -> mesh data dict (filled by workers)
## How many times each chunk's contents have changed. Every mesh job records the
## version it was built from, and a result built from OLDER data than the
## chunk now holds is thrown away and rebuilt rather than shown -- see
## _is_stale. Without it, a chunk that was already meshing when an edit landed
## could finish after the edit's own redraw and put the old picture back: the
## trees left standing inside the wreck, the wreckage that only appeared once
## you broke the "leaves" drawn over it.
var _chunk_ver := {}
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
	family = cfg.get("family", "")
	world_type = cfg.get("type", "")
	shape_cube = cfg.get("cube", true)  # cube-planet-test branch: cubes by default

	# 3 to 9 minutes per day, per planet.
	var dr := RandomNumberGenerator.new()
	dr.seed = _seed + 4242
	# Floor raised from 420: a short roll used to give barely five minutes of
	# light, and the whole of a day is meant to be enough to get something done
	# in rather than a dash between nights.
	day_length = dr.randf_range(660.0, 1020.0)
	day_phase = dr.randf()   # so planets aren't all sunrise at world start
	surface_noise.seed = _seed
	# Several rolling hills across the surface, regardless of planet size.
	surface_noise.frequency = 3.0 / maxf(radius, 1.0)
	surface_noise.fractal_octaves = 4
	surface_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH

	mountain_noise.seed = _seed + 9001
	mountain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	mountain_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	mountain_noise.fractal_octaves = 3
	# Three times the base frequency: ranges are smaller than the continents of
	# rolling hills they sit on, so you can see one from end to end.
	mountain_noise.frequency = 3.0 / maxf(radius, 1.0)
	mountain_amp = cfg.get("mountains", terrain_amp * 2.4)

	ore_noise.seed = _seed + 777
	ore_noise.frequency = 0.14
	ore_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX

	alien_palette = cfg.get("alien", false)
	# BEFORE everything below it. Flora siting, ore depth, water and settlements
	# all ask where the surface is, and on a world with regions that answer
	# depends on which region -- and the palette wants to know whether it is
	# dressing one place or six.
	_derive_biomes()
	_derive_relief(cfg)
	flora_pool = cfg.get("flora", [])
	strange_min = float(cfg.get("strange_min", 0.0))
	_derive_palette()
	_derive_flora(cfg.get("tree_density", 0.0))
	var grng := RandomNumberGenerator.new()
	grng.seed = _seed + 3131
	grass_density = 0.0 if grng.randf() < 0.25 else grng.randf_range(0.15, 0.5)
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
	_derive_sites()  # after settlements and water: a site keeps out of both
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


# --- sites: wrecks, outposts, ruins, vaults -----------------------------------

## How likely each kind of site is in any one region of this world (see Sites).
## A kind rolled at zero does not exist here.
var site_density := {}
## Sites whose chests have been put out, by site id -- saved, so a chest you
## emptied is not refilled next time you pass.
var sites_opened := {}
var _site_shared := {}        # region -> its sites; shared by build threads
var _site_mutex := Mutex.new()
var _site_tick := 0.0


func _derive_sites() -> void:
	var r := RandomNumberGenerator.new()
	r.seed = _seed + 4321
	site_density = {}
	var any := false
	for kind in Sites.DENSITY_CHOICES:
		var choices: Array = Sites.DENSITY_CHOICES[kind]
		var d: float = choices[r.randi() % choices.size()]
		site_density[kind] = d
		any = any or d > 0.0
	if not any:
		site_density = {}      # nothing left behind on this world at all


## The sites in one region, worked out once and shared. Worked out OUTSIDE the
## lock: two threads racing on the same region compute the same answer, and
## holding the lock across the terrain sampling would stall every build.
func _sites_in(rk: Vector3i) -> Array:
	_site_mutex.lock()
	var got = _site_shared.get(rk)
	_site_mutex.unlock()
	if got != null:
		return got
	var fresh := Sites.derive_region(self, rk)
	_site_mutex.lock()
	_site_shared[rk] = fresh
	_site_mutex.unlock()
	return fresh


## What a site puts at `c`, or -1. The region's list is kept in the build's own
## cache, so the shared one is asked once per region per chunk, not per cell.
func _site_block(c: Vector3i, tcache) -> int:
	var rk := Sites.region_of(c)
	var list: Array
	if tcache != null:
		var sm = tcache.get("sites")
		if sm == null:
			sm = {}
			tcache["sites"] = sm
		var got = sm.get(rk)
		if got == null:
			got = _sites_in(rk)
			sm[rk] = got
		list = got
	else:
		list = _sites_in(rk)
	for s in list:
		var b := Sites.block_at(self, s, c)
		if b >= 0:
			return b
	return -1


## Put out the chests at any site the player has come near. Chests are real
## stations -- they hold things and are saved -- so unlike the site's blocks
## they are made once, when first needed, and remembered.
func tick_sites(delta: float, world: WorldManager) -> void:
	if site_density.is_empty() or world == null or world.player == null:
		return
	_site_tick -= delta
	if _site_tick > 0.0:
		return
	_site_tick = 1.0
	var lp := to_local(world.player.global_position)
	var rk0 := Sites.region_of(Vector3i(lp.floor()))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				for s in _sites_in(rk0 + Vector3i(dx, dy, dz)):
					_open_site(s, lp, world)


func _open_site(s: Dictionary, lp: Vector3, world: WorldManager) -> void:
	var sid: String = s["id"]
	if sites_opened.has(sid):
		return
	var chests: Array = s["chests"]
	if chests.is_empty() or (Vector3(chests[0] as Vector3i) - lp).length() > 48.0:
		return
	for cc in chests:
		if not loaded_chunks.has(chunk_of(cc)):
			return       # not drawn yet: try again next second
	sites_opened[sid] = true
	var upw := (global_transform.basis * Vector3(s["up"] as Vector3i)).normalized()
	var fw := (global_transform.basis * Vector3(s["u"] as Vector3i)).normalized()
	var i := 0
	for cc in chests:
		var cell: Vector3i = cc
		# Somebody has built or dug here since: no chest in a wall.
		if get_id(cell) == Blocks.AIR:
			var st := world.spawn_station(Blocks.CHEST, to_global(Vector3(cell)), upw, -fw)
			Sites.fill(self, s, st, i)
		i += 1
	if world.player.has_method("_toast"):
		world.player.call("_toast", "Discovered: " + Sites.KIND_NAMES[int(s["kind"])])


# --- fauna: invent this planet's creatures from its seed, exactly like ores ----

var _forced_enemy_species: Dictionary = {}  # set by _derive_fauna when force_hostile_enemy is true

## Drop hostile species from a fauna list, so they are never picked at spawn.
## Filtering the LISTS rather than each of the four spawn sites means a habitat
## whose species were all hostile correctly reports itself as empty.
func _without_hostiles(list: Array) -> Array:
	var keep: Array = []
	for sp in list:
		if (sp as Dictionary).get("temperament", "") != "hostile":
			keep.append(sp)
	return keep


func _derive_fauna(force_hostile_enemy: bool = false) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed + 6060
	# How MUCH life, and of what, is part of what a world is: one teems, the
	# next is nearly empty, and a few have no animals at all. Separate rolls
	# for land, water and air, and a density that scales how many are about.
	var lr := RandomNumberGenerator.new()
	lr.seed = _seed + 6161
	life_density = ([0.45, 0.75, 1.0, 1.0, 1.5] as Array)[lr.randi() % 5]
	var n_land: int = ([0, 1, 2, 3, 3, 4] as Array)[lr.randi() % 6]
	# Except where you start. The home world is where the first meals come
	# from, and a start with nothing to hunt is not a harder game, it is a
	# broken one. (force_hostile_enemy is the flag the home world is built with.)
	if force_hostile_enemy:
		n_land = maxi(n_land, 2)
		life_density = maxf(life_density, 0.75)
	for i in n_land:
		fauna_land.append(_make_species(rng, "land"))
	# How many Night Stalkers can be out at once here after dark: none on some
	# worlds, a pack on others -- and always some where you start, so the night
	# there is something to prepare for.
	spider_cap = ([0, 0, 1, 1, 2, 3] as Array)[lr.randi() % 6]
	# Watchers: every world has at least one abroad at night while they are the
	# thing being tested, some have a few.
	watcher_cap = ([1, 1, 1, 2, 2, 3] as Array)[lr.randi() % 6]
	# ...and what kind they are here: every world's are built their own way.
	var sr := RandomNumberGenerator.new()
	sr.seed = _seed + 7373
	stalker_species = NightSpider.make_species(sr)
	# Every world has at least one out after dark: every kind of monster can
	# turn up at night, wherever you are.
	spider_cap = maxi(spider_cap, 1)
	if force_hostile_enemy and not HOSTILES_DISABLED:
		# Guaranteed on top of the normal roll (not instead of it) -- for combat
		# testing on the home planet regardless of what the random wildlife mix
		# would otherwise be. Independent of settlements/civ tier.
		var enemy_sp := _make_species(rng, "enemy")
		fauna_land.append(enemy_sp)
		_forced_enemy_species = enemy_sp
	if water_style == WATER_LIQUID:
		var rng2 := RandomNumberGenerator.new()
		rng2.seed = _seed + 7070
		var n_fish: int = ([0, 1, 2, 3] as Array)[lr.randi() % 4]
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
	var n_air: int = ([0, 1, 2, 3] as Array)[lr.randi() % 4]
	for i in n_air:
		fauna_air.append(_make_species(rng4, "air"))
	if HOSTILES_DISABLED:
		_forced_enemy_species = {}
		fauna_land = _without_hostiles(fauna_land)
		fauna_fish = _without_hostiles(fauna_fish)
		fauna_cave = _without_hostiles(fauna_cave)
		fauna_air = _without_hostiles(fauna_air)


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
## What a creature leaves behind. Everything edible drops meat scaled by how big
## it was, so hunting something large is worth the trouble; hide and bone come
## only off animals actually built to carry them, which is what makes the choice
## of what to hunt mean something.
func _make_drops(rng: RandomNumberGenerator, kind: String, body: String, scale: float) -> Array:
	if kind == "npc":
		return []
	var drops: Array = []
	var meat := int(round(scale * 2.2))
	if body == "flyer" or body == "fish":
		meat = int(round(scale * 1.4))
	meat = maxi(1, meat)
	drops.append({"id": Blocks.RAW_MEAT, "min": maxi(1, meat - 1), "max": meat + 1})
	if body in ["quad", "grazer", "biped", "hopper"] and scale >= 0.55:
		var hide := maxi(1, int(round(scale * 1.3)))
		drops.append({"id": Blocks.HIDE, "min": maxi(1, hide - 1), "max": hide})
	if scale >= 1.2 and body != "fish":
		drops.append({"id": Blocks.BONE, "min": 1, "max": maxi(1, int(round(scale)))})
	return drops


func _make_species(rng: RandomNumberGenerator, kind: String) -> Dictionary:
	# As with ores: the planet decides it has a creature of this kind, and the
	# creature is then built entirely out of its own name -- from here on `rng`
	# IS the name's stream, so a Grumhide is the same animal wherever you meet
	# one. The ending carries the kind, so a name cannot be a fish on one world
	# and something that walks on the next.
	var sname: String = Blocks.fauna_name(rng, kind)
	rng = Blocks.identity_rng(sname)
	var body: String
	match kind:
		"fish": body = "fish"
		"air": body = "flyer"
		"npc": body = "biped"  # settlement residents always stand upright
		"enemy": body = "biped"  # hostile humanoid -- see _make_species's "enemy" branch below
		"cave": body = ["serpent", "serpent", "crawler", "crawler", "quad", "hopper"][rng.randi() % 6]
		# Land life is the bulk of what you meet, so it gets the widest range of
		# builds: the old four plus a low many-legged crawler, a hopper, and a
		# long-necked grazer.
		# No humanoid shape in the wildlife: the upright biped is what an NPC and
		# a hostile enemy are built from, and an animal wearing it reads as a
		# person rather than as fauna.
		_: body = ["quad", "quad", "grazer", "grazer", "hopper", "hopper",
			"crawler", "serpent"][rng.randi() % 8]
	# Size is rolled in BANDS rather than one flat range, so a world's animals
	# read as different creatures instead of one animal at different zooms. Most
	# are ordinary; a good slice are small enough to be underfoot, and a rare few
	# are genuinely big -- and since health, speed and drops all key off scale, a
	# big one is a real event rather than a bigger sprite.
	var scale: float
	if kind in ["npc", "enemy"]:
		scale = rng.randf_range(0.85, 1.15)
	elif kind in ["land", "cave"]:
		var band := rng.randf()
		if band < 0.22:
			scale = rng.randf_range(0.28, 0.5)       # critter
		elif band < 0.82:
			scale = rng.randf_range(0.6, 1.5)        # ordinary
		elif band < 0.96:
			scale = rng.randf_range(1.6, 2.4)        # large
		else:
			scale = rng.randf_range(2.6, 3.6)        # rare giant
	else:
		scale = rng.randf_range(0.4, 1.6)
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
	# A species' RUNNING speed -- fleeing, chasing. It wanders at a fraction of
	# this (Creature.WANDER_PACE). It used to be divided by size with a floor
	# that made anything small up to two thirds faster again, then boosted
	# another 30% to flee, and animals wandered at the full figure: a small
	# hopper ran at eighteen metres a second against a player walking at 4.6,
	# and nothing could be caught. Land animals now run a little UNDER walking
	# pace, so a chase is one you can win if you commit to it; size makes a
	# small animal only slightly quicker. Birds and fish are only toned down --
	# nobody runs them down on foot.
	var base_speed: float = {"quad": 3.4, "biped": 3.0, "serpent": 2.8, "fish": 2.2,
		"flyer": 5.0, "crawler": 2.4, "hopper": 3.8, "grazer": 2.8}.get(body, 3.0)
	var speed := (base_speed * 0.6 if kind == "npc" else base_speed) * rng.randf_range(0.85, 1.15) \
		/ maxf(sqrt(scale), 0.85)
	if body != "flyer" and body != "fish":
		speed = minf(speed, 4.3)
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
		"drops": _make_drops(rng, kind, body, scale),
		# Markings. Wildlife gets a real coat -- stripes, spots, patches, scales,
		# banding -- while people stay plain, because a striped settler would read
		# as an animal wearing clothes.
		"skin": (0 if kind == "npc" else rng.randi() % 6),
		# Roughly half of warm-blooded land life is furred. Fish, flyers and the
		# insectile crawlers are not -- scales and chitin are their own look.
		"fur": (kind in ["land", "cave"] and body in ["quad", "grazer", "hopper"]
			and rng.randf() < 0.55),
		"skin_scale": rng.randf_range(0.6, 2.2),
		# Herds are what make a planet's wildlife read as alive rather than as lone
		# animals wandering past. Grazers and quads travel together; serpents and
		# crawlers are loners.
		"herd": (rng.randi_range(2, 5) if body in ["grazer", "quad"] and kind == "land" 			else (2 if body == "hopper" and rng.randf() < 0.5 else 1)),
		# Birds that soar in circles, and how many fly together. The rest keep
		# their old habits: wander the sky, land, take off again.
		"soar": body == "flyer" and rng.randf() < 0.65,
		"flock": rng.randi_range(2, 6) if body == "flyer" else 1,
		"graze": body in ["grazer", "quad", "hopper"] and kind != "enemy",
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
## The most creatures allowed alive at once right now -- night lifts it, since
## that is when more of them come out.
func creature_cap() -> int:
	return int(round((MAX_CREATURES + night_factor() * NIGHT_EXTRA_CREATURES) * life_density))


func update_fauna(delta: float, player_pos: Vector3, world: WorldManager) -> void:
	_update_spiders(delta, player_pos, world)
	_update_watchers(delta, player_pos, world)
	_creatures = _creatures.filter(func(c): return is_instance_valid(c))
	for c in _creatures.duplicate():
		# Far from EVERY player, not just this machine's: in co-op one machine
		# runs the wildlife around the group.
		if world.nearest_player_dist(c.global_position) > CREATURE_DESPAWN_RADIUS:
			c.queue_free()
	_creatures = _creatures.filter(func(c): return is_instance_valid(c))
	if not world.spawns_fauna_here():
		return   # someone nearby is spawning for the group

	# Night is when this world gets dangerous. The cycle was purely cosmetic
	# until now; tying spawning to it is what gives the player a reason to build
	# a shelter, light it, and be inside it when the sun goes down.
	_spawn_timer -= delta
	var night := night_factor()
	var cap: int = creature_cap()
	if _spawn_timer > 0.0 or _creatures.size() >= cap:
		return
	# Things come out faster after dark, not merely in greater numbers.
	_spawn_timer = CREATURE_SPAWN_INTERVAL * lerpf(1.0, 0.45, night)
	_try_spawn_creature(player_pos, world)


# --- Night Stalkers ---------------------------------------------------------------

var spider_cap := 0
## How many Watchers this world can have out at once, and the ones that are.
var watcher_cap := 0
var _watchers: Array = []
var _watcher_timer := 8.0
const WATCHER_INTERVAL := 14.0
## This world's kind of Night Stalker -- see NightSpider.make_species.
var stalker_species: Dictionary = {}
var _spiders: Array = []
var _spider_timer := 4.0
const SPIDER_INTERVAL := 18.0


## They come out only once it is properly dark, one every few seconds up to
## this world's cap, somewhere out of arm's reach but close enough to find you.
## Watchers: never where you can see one arrive, never far from cover, and only
## in the dead of night.
func _update_watchers(delta: float, player_pos: Vector3, world: WorldManager) -> void:
	_watchers = _watchers.filter(func(s): return is_instance_valid(s))
	for s in _watchers:
		if world.nearest_player_dist((s as Node3D).global_position) > CREATURE_DESPAWN_RADIUS:
			s.queue_free()
	if watcher_cap <= 0 or night_factor() < 0.55 or not world.spawns_fauna_here():
		return
	_watcher_timer -= delta
	if _watcher_timer > 0.0 or _watchers.size() >= watcher_cap:
		return
	_watcher_timer = WATCHER_INTERVAL * randf_range(0.7, 1.5)
	spawn_watcher_near(player_pos, world, 20.0, 40.0)


func spawn_watcher_near(pos: Vector3, world: WorldManager, near: float, far: float) -> Watcher:
	var g := world.gravity_at(pos)
	if g.length() < 0.01:
		return null
	var up := -g.normalized()
	var t1 := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	var t2 := up.cross(t1).normalized()
	var space := get_world_3d().direct_space_state
	for attempt in 10:
		var ang := randf() * TAU
		var r := randf_range(near, far)
		var p := pos + (t1 * cos(ang) + t2 * sin(ang)) * r
		var q := PhysicsRayQueryParameters3D.create(p + up * 30.0, p - up * 40.0, 1)
		var hit := space.intersect_ray(q)
		if hit.is_empty() or not (hit["collider"] is Chunk):
			continue
		var at: Vector3 = hit["position"]
		if get_id(world_to_voxel(at + up * 0.5)) != Blocks.AIR:
			continue
		if not _chunk_ready_at(at):
			continue
		# Out of sight to arrive -- something in the way between you and it.
		var los := PhysicsRayQueryParameters3D.create(pos + up * 1.5, at + up * 1.6, 1)
		if space.intersect_ray(los).is_empty():
			continue
		# ...and trees to work with once it is here.
		if not _cover_near(at, up):
			continue
		var s := Watcher.new()
		add_child(s)
		s.global_position = at + up * 0.1
		s.setup_watcher(self, world)
		_watchers.append(s)
		_share(s, world)
		return s
	return null


## Is there anything close by to hide behind -- a tree for choice, but a rock
## face or the wall of your own house will do. Swept properly rather than
## sampled at random: twenty-six random points in a cube this size found a
## trunk about one time in fifty, which is why they never turned up.
func _cover_near(at: Vector3, up: Vector3) -> bool:
	var v := world_to_voxel(at + up * 1.0)
	var ux := Vector3i(roundi(up.x), roundi(up.y), roundi(up.z))
	var a1 := Vector3i(ux.y, ux.z, ux.x)
	var a2 := Vector3i(ux.z, ux.x, ux.y)
	var wood := false
	var solid := false
	for du in range(-8, 9, 2):
		for dv in range(-8, 9, 2):
			for dh in range(0, 4):
				var id := Blocks.bottom_of(get_id(v + a1 * du + a2 * dv + ux * dh))
				if id == Blocks.AIR or id == Blocks.WATER:
					continue
				solid = true
				if Blocks.is_wood(id) or Blocks.is_leaf(id):
					wood = true
					break
	return wood or solid


func _update_spiders(delta: float, player_pos: Vector3, world: WorldManager) -> void:
	_spiders = _spiders.filter(func(s): return is_instance_valid(s))
	for s in _spiders:
		if world.nearest_player_dist((s as Node3D).global_position) > CREATURE_DESPAWN_RADIUS:
			s.queue_free()
	if STALKERS_DISABLED or spider_cap <= 0 or night_factor() < 0.6 or not world.spawns_fauna_here():
		return
	_spider_timer -= delta
	if _spider_timer > 0.0 or _spiders.size() >= spider_cap:
		return
	_spider_timer = SPIDER_INTERVAL * randf_range(0.7, 1.4)
	spawn_spider_near(player_pos, world, 22.0, 40.0)


## Put one on the ground somewhere between `near` and `far` blocks from `pos`.
## Returns it, or null if no spot could be found this time.
func spawn_spider_near(pos: Vector3, world: WorldManager, near: float, far: float) -> NightSpider:
	var g := world.gravity_at(pos)
	if g.length() < 0.01:
		return null
	var up := -g.normalized()
	var t1 := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	var t2 := up.cross(t1).normalized()
	var space := get_world_3d().direct_space_state
	for attempt in 8:
		var ang := randf() * TAU
		var r := randf_range(near, far)
		var p := pos + (t1 * cos(ang) + t2 * sin(ang)) * r
		var q := PhysicsRayQueryParameters3D.create(p + up * 30.0, p - up * 40.0, 1)
		var hit := space.intersect_ray(q)
		if hit.is_empty() or not (hit["collider"] is Chunk):
			continue
		var at: Vector3 = hit["position"]
		# Not in water, and not on top of a roof where it could never reach you.
		if get_id(world_to_voxel(at + up * 0.5)) != Blocks.AIR:
			continue
		if not _chunk_ready_at(at):
			continue
		var s := NightSpider.new()
		add_child(s)
		s.setup_spider(self, world, stalker_species)
		s.global_position = at + up * s.sp_ride
		_spiders.append(s)
		_share(s, world)
		return s
	return null


## 0 in broad daylight, 1 in the dead of night. Airless worlds have no dusk to
## speak of, so their transition is much sharper -- the same rule the sky uses.
func night_factor() -> float:
	var height := sun_height()
	var soft: float = 0.22 if has_atmosphere else 0.04
	return 1.0 - clampf(smoothstep(-soft, soft, height), 0.0, 1.0)


## Immediately clears all fauna (called when this planet stops being the active
## one -- wildlife only exists meaningfully near the player).
func clear_fauna() -> void:
	for s in _spiders:
		if is_instance_valid(s):
			s.queue_free()
	_spiders.clear()
	for s in _watchers:
		if is_instance_valid(s):
			s.queue_free()
	_watchers.clear()
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
				# A flock: the same species, circling one centre together, each
				# at its own point round the circle.
				var sp_air: Dictionary = fauna_air[randi() % fauna_air.size()]
				var n := maxi(1, int(sp_air.get("flock", 1)))
				var centre := to_global(local_pos)
				var radius := randf_range(7.0, 16.0)
				var turn := randf_range(0.25, 0.5) * (1.0 if randf() < 0.5 else -1.0)
				for k in n:
					if _creatures.size() >= creature_cap():
						break
					var bird := _spawn_at(centre + Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * 3.0,
						sp_air, world)
					if bird != null and bool(sp_air.get("soar", false)):
						bird.soar_around(centre, radius, turn, TAU * float(k) / float(n))
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
				# Herd animals arrive as a group, scattered around the spot the
				# spawner picked. One animal at a time is what made a planet feel
				# empty even when the spawn rate was fine.
				var sp_land: Dictionary = _pick_land_species()
				var herd := maxi(1, int(sp_land.get("herd", 1)))
				var leader: Creature = null
				for h in herd:
					var jitter := Vector3.ZERO
					if h > 0:
						var ja := randf() * TAU
						var jr := randf_range(1.5, 3.5) * float(h)
						jitter = (t1 * cos(ja) + t2 * sin(ja)) * jr
					var hp := surface_pt + jitter + up * 0.05
					if _creatures.size() >= creature_cap():
						break
					var member := _spawn_at(to_global(hp), sp_land, world)
					# The first to arrive leads; the rest keep with it, which is
					# what makes a herd a herd rather than animals that happened
					# to arrive at the same time and then drifted apart.
					if member != null:
						if leader == null:
							leader = member
						else:
							member.herd_leader = leader
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


## Which land creature to spawn. After dark the roll is weighted hard toward
## whatever is hostile, so night reads as things coming out rather than simply
## more of the same animals wandering about.
func _pick_land_species() -> Dictionary:
	var night := night_factor()
	if night > 0.35 and randf() < night * 0.85:
		var hostiles: Array = []
		for sp in fauna_land:
			if sp.get("temperament", "") == "hostile":
				hostiles.append(sp)
		if not hostiles.is_empty():
			return hostiles[randi() % hostiles.size()]
	return fauna_land[randi() % fauna_land.size()]


func _spawn_at(world_pos: Vector3, sp: Dictionary, world: WorldManager) -> Creature:
	if not _chunk_ready_at(world_pos):
		return null
	var c := Creature.new()
	add_child(c)
	c.global_position = world_pos
	c.configure(sp, self, world)
	_creatures.append(c)
	_share(c, world)
	return c


## A creature this machine spawned, shown to everyone else in a co-op game.
func _share(c: Creature, world: WorldManager) -> void:
	if world != null and world.net != null and world.net.active:
		world.net.fauna.register(c)


# How far from center anything (terrain, trees, buildings, or water) can possibly exist.
func _max_reach() -> float:
	# Mountains count: without them in here, every peak is sliced off flat at
	# whatever height this returns, because generation_sample treats anything
	# past it as air.
	# Biome relief counts for the same reason mountains do: a highland lifted
	# nine blocks and stretched to twice the amplitude would be sliced off flat
	# at whatever this returns.
	var b_amp := 1.0
	var b_lift := 0.0
	for i in _b_amp.size():
		b_amp = maxf(b_amp, _b_amp[i])
		b_lift = maxf(b_lift, _b_lift[i])
	return maxf(radius + terrain_amp * (b_amp + b_lift) + mountain_amp + _relief_up()
		+ maxf(tree_reach, settlement_reach), water_level)


# Each planet gets a random ore mix + abundance from its seed: which ores it holds,
# how common they are, and how deep. So planets are rich in different things.
func _derive_ores() -> void:
	var orng := RandomNumberGenerator.new()
	orng.seed = _seed + 999
	# Half what it was: ore every few blocks made mining a stroll rather than a
	# search, and made a good seam nothing worth finding.
	var richness := orng.randf_range(0.02, 0.055)  # fraction of rock that is ore
	# Calibrated against the noise, not guessed at. The old mapping claimed the
	# same thing and delivered a sixth of it: richness 0.04 set the threshold at
	# 0.592, and only 0.65% of rock is above that -- which is how a home world
	# could end up with no ore anybody would ever walk past. Measured over
	# 200,000 samples of this exact noise: 4% of rock sits above 0.448, 7% above
	# 0.386, 11% above 0.327, near enough a straight line between them.
	ore_threshold = 0.517 - richness * 1.73
	# A world of one of the four families also holds its SIGNATURE ore (see
	# Blocks.FAMILY_SIGNATURE), so it carries one fewer ordinary one.
	var sig: Dictionary = Blocks.FAMILY_SIGNATURE.get(family, {})
	var n := orng.randi_range(1, 2) if not sig.is_empty() else orng.randi_range(2, 3)
	# tiers: guarantee at least one hand-mineable (tier 0/1) so a fresh planet is
	# never a dead end, then spread the rest across all tiers.
	var tiers: Array[int] = [orng.randi_range(0, 1)]
	# The guaranteed hand-mineable ore is also guaranteed SHALLOW -- see _make_ore.
	# One that exists but starts four hundred blocks down is not a starting ore.
	for i in n - 1:
		tiers.append(orng.randi_range(0, 3))
	for i in n:
		var tier: int = tiers[i]
		ore_defs.append(_make_ore(orng, i, tier, i == 0))
	if not sig.is_empty():
		ore_defs.append(_make_signature_ore(orng, n, sig))
	for od in ore_defs:
		_ore_by_block[od["block"]] = od
		_ore_wsum += od["w"]


## The ore only a world of this family holds: one property far beyond anything
## an ordinary ore reaches. Its name comes from the family's own endings, so a
## "-pyre" is always a dust world's fuel wherever you meet one, and the ore's
## identity still follows from its name the way every other ore's does.
func _make_signature_ore(orng: RandomNumberGenerator, slot: int, sig: Dictionary) -> Dictionary:
	var tier := orng.randi_range(1, 2)
	var sufs: Array = sig["suffixes"]
	var name: String = Blocks.ORE_NAME_PRE[orng.randi() % Blocks.ORE_NAME_PRE.size()] \
		+ str(sufs[orng.randi() % sufs.size()])
	var irng := Blocks.identity_rng(name)
	var sc: Color = sig["color"]
	var color := Color.from_hsv(fposmod(sc.h + irng.randf_range(-0.04, 0.04), 1.0),
		clampf(sc.s + irng.randf_range(-0.1, 0.1), 0.2, 1.0),
		clampf(sc.v + irng.randf_range(-0.08, 0.08), 0.15, 0.95))
	var base: Dictionary = Blocks.TIER_PROPS[tier]
	var props := {}
	for k in Blocks.PROP_KEYS:
		props[k] = clampi(int(round(float(base[k]) * irng.randf_range(0.85, 1.15))), 1, 100)
	props["c"] = clampi(int(round(irng.randf_range(4.0, 40.0))), 1, 100)
	for k in Blocks.ORDINARY_PROP_CAP:
		props[k] = mini(int(props[k]), int(Blocks.ORDINARY_PROP_CAP[k]))
	var key: String = sig["prop"]
	props[key] = irng.randi_range(88, 100)
	var hardness: float = Blocks.TIER_HARDNESS[tier] * irng.randf_range(0.9, 1.1)
	return {
		"block": Blocks.ORE_SLOT_IDS[slot], "name": name, "color": color, "tier": tier,
		"props": props, "hardness": hardness, "min_power": Blocks.TIER_MIN_POWER[tier],
		# Scarce and a proper dig down: finding it is the point of the trip.
		"w": orng.randf_range(0.35, 0.6), "mind": orng.randf_range(16.0, 40.0),
		"signature": true,
	}


# Invent one ore: a unique name & color for this planet, with tier-derived stats.
func _make_ore(orng: RandomNumberGenerator, slot: int, tier: int,
		force_shallow: bool = false) -> Dictionary:
	# The planet chooses WHICH ore it has; the ore itself comes from its name.
	# Everything below is drawn from `irng`, seeded by that name, so two worlds
	# landing on Velite describe the same mineral rather than two different ones
	# that happen to share a label. The ending carries the tier, so a name
	# cannot be common here and exotic there.
	#
	# How MUCH of it there is and how deep it sits stay with the PLANET, drawn
	# from orng below: that is how this world holds the ore, not what it is.
	var name: String = Blocks.ore_name(orng, tier)
	var irng := Blocks.identity_rng(name)
	# colour: random hue, saturation/value that read as a mineral; a touch brighter
	# and more saturated at higher tiers so exotic ores catch the eye.
	var hue := irng.randf()
	var sat := 0.45 + 0.12 * tier + irng.randf_range(-0.05, 0.05)
	var val := 0.55 + 0.08 * tier + irng.randf_range(-0.05, 0.05)
	var color := Color.from_hsv(hue, clampf(sat, 0.3, 0.95), clampf(val, 0.4, 0.9))
	# props: tier archetype +/- per-ore variance
	var base: Dictionary = Blocks.TIER_PROPS[tier]
	var props := {}
	for k in Blocks.PROP_KEYS:
		props[k] = clampi(int(round(float(base[k]) * irng.randf_range(0.85, 1.15))), 1, 100)
	# Combustion swings far wider than the other properties, and deliberately
	# ignores tier: roughly a third of ores come out volatile. That means a
	# common surface ore can be the best fuel on the planet, which gives an
	# early world something worth mining and makes "which ore burns best here"
	# a real question rather than "whichever is rarest".
	if irng.randf() < 0.34:
		props["c"] = clampi(int(round(irng.randf_range(62.0, 100.0))), 1, 100)
	else:
		props["c"] = clampi(int(round(irng.randf_range(4.0, 40.0))), 1, 100)
	# Every property a family's signature ore is best at stops short of it on an
	# ordinary ore, so the best fuel really is found on a dust world and the best
	# conductor on a living one -- not on whichever planet rolled well.
	for k in Blocks.ORDINARY_PROP_CAP:
		props[k] = mini(int(props[k]), int(Blocks.ORDINARY_PROP_CAP[k]))
	var hardness: float = Blocks.TIER_HARDNESS[tier] * irng.randf_range(0.9, 1.1)
	var deep := not force_shallow and (tier >= 2 or orng.randf() < 0.4)
	# A depth in BLOCKS, not a fraction of the planet. A quarter of the radius is
	# 375 blocks down on a home world -- deeper than any cave goes, so an ore
	# with that minimum may as well not exist. Deep now means a descent worth
	# making, not one nobody will ever make.
	var mind := orng.randf_range(28.0, 70.0) if deep else 4.0
	return {
		"block": Blocks.ORE_SLOT_IDS[slot], "name": name, "color": color, "tier": tier,
		"props": props, "hardness": hardness, "min_power": Blocks.TIER_MIN_POWER[tier],
		"w": orng.randf_range(0.3, 1.0), "mind": mind,
	}


# --- growing things -----------------------------------------------------------
#
# A planted cell keeps its species and how far along it is in a table beside the
# blocks, the way eighth-blocks and campfires already do. The block id says only
# CROP or YOUNG_TREE; there is no room in a byte for a species, and the mesher
# needs both to draw the thing at the right height.
var _crops: Dictionary = {}    # voxel -> {"key": species, "stage": int, "t": seconds into this stage}


## Put a plant in the ground. Returns false if that cell will not take it.
func plant(v: Vector3i, key: String, tree: bool) -> bool:
	if get_id(v) != Blocks.AIR:
		return false
	_crops[v] = {"key": key, "stage": 0, "t": 0.0, "tree": tree}
	set_block(v, Blocks.YOUNG_TREE if tree else Blocks.CROP)
	return true


func crop_at(v: Vector3i) -> Dictionary:
	return _crops.get(v, {})


## Is this cell a plant that has finished growing?
func crop_ripe(v: Vector3i) -> bool:
	var c: Dictionary = _crops.get(v, {})
	if c.is_empty() or bool(c.get("tree", false)):
		return false
	return int(c["stage"]) >= Blocks.crop_growth(str(c["key"]))["stages"] - 1


## Pull a ripe crop up. Returns what it gave, or {}.
func harvest(v: Vector3i) -> Dictionary:
	if not crop_ripe(v):
		return {}
	var c: Dictionary = _crops[v]
	var g: Dictionary = Blocks.crop_growth(str(c["key"]))
	_crops.erase(v)
	set_block(v, Blocks.AIR)
	return {"key": str(c["key"]), "n": int(g["yield_n"])}


func clear_crop(v: Vector3i) -> void:
	_crops.erase(v)


## Put a crop at a stage somebody else decided. Growth is the host's to run --
## every machine ticking its own clock would have the same field at a different
## height on every screen -- so a client only ever hears the answer.
func set_crop_stage(v: Vector3i, stage: int) -> void:
	if stage < 0:
		_grow_tree_at(v)
		return
	var c: Dictionary = _crops.get(v, {})
	if c.is_empty():
		return
	c["stage"] = stage
	c["t"] = 0.0
	_remesh_at(v)


## One stage of growth, bought rather than waited for. Returns the stage it
## landed on, -1 if it was a sapling and became a tree, or NOTHING if there is
## nothing here to feed or it has already finished growing.
##
## The return value is what makes this safe to replicate: an absolute stage can
## be applied twice without landing twice, where "advance one" cannot.
const FEED_NOTHING := -2

func advance_crop(v: Vector3i) -> int:
	var c: Dictionary = _crops.get(v, {})
	if c.is_empty():
		return FEED_NOTHING
	if bool(c.get("tree", false)):
		_grow_tree_at(v)
		return -1
	var last: int = int(Blocks.crop_growth(str(c["key"]))["stages"]) - 1
	if int(c["stage"]) >= last:
		return FEED_NOTHING   # ripe already: pull it, do not feed it
	c["stage"] = int(c["stage"]) + 1
	c["t"] = 0.0
	_remesh_at(v)
	return int(c["stage"])


## Everything planted here, flat, for saving and for handing to a new arrival.
# --- aurora blooms ---------------------------------------------------------------
#
# Crystal that grows out of open ground while an aurora is overhead, and is
# gone by morning. The only reason this world gives you to be outside at night
# -- so it has to be worth crossing a valley for, and it has to be obvious from
# that valley that it is happening.

## Which cells this world has grown, so dawn knows what to take back. Every one
## of them is AURORA_BLOOM and nothing else ever writes one.
var _blooms := {}
var _bloom_t := 0.0
## How many go up per second of aurora, near the player.
const BLOOM_RATE := 5.0
const BLOOM_REACH := 46.0      # how far from you they will come up
const BLOOM_MAX := 260         # ...and how many at once, per world


## Grow a few. `strength` is the aurora (0 when there is none), `at` is where
## the player is. Returns the cells to write, for the caller to edit in one go.
func grow_blooms(delta: float, strength: float, at: Vector3) -> Dictionary:
	if strength <= 0.01 or not is_night() or _blooms.size() >= BLOOM_MAX:
		return {}
	_bloom_t += delta * BLOOM_RATE * strength
	var n := int(_bloom_t)
	if n <= 0:
		return {}
	_bloom_t -= float(n)
	var out := {}
	var up := _axis_of(to_local(at))
	for i in mini(n, 6):
		# A point on the ground somewhere around you, found by dropping down
		# the world's own up axis from above head height.
		var a := randf() * TAU
		var r: float = sqrt(randf()) * BLOOM_REACH
		var side := up.cross(Vector3(0, 0, 1) if absf(up.z) < 0.9 else Vector3(1, 0, 0)).normalized()
		var side2 := up.cross(side).normalized()
		var probe: Vector3 = at + (side * cos(a) + side2 * sin(a)) * r + up * 8.0
		var v := world_to_voxel(probe)
		# Walk down until there is ground under the cell.
		var found := false
		for step in 22:
			var below := v - Vector3i(roundi(up.x), roundi(up.y), roundi(up.z))
			if get_id(v) == Blocks.AIR and _bloom_soil(get_id(below)):
				found = true
				break
			v = below
		if not found or _blooms.has(v):
			continue
		out[v] = Blocks.AURORA_BLOOM
		_blooms[v] = true
	return out


## What a bloom will root in. Open ground only -- not stone you are standing
## inside, and never on something somebody built.
func _bloom_soil(id: int) -> bool:
	var b := Blocks.base_material_of(Blocks.bottom_of(id))
	return b == Blocks.GRASS or b == Blocks.DIRT or b == Blocks.ROCK \
		or b == Blocks.SNOW or b == Blocks.REGOLITH or b == Blocks.PATH


## Morning. Everything still standing goes, and anything you cut in the night
## is yours to keep -- it is already out of this list.
func clear_blooms() -> Dictionary:
	var out := {}
	for v in _blooms:
		if get_id(v) == Blocks.AURORA_BLOOM:
			out[v] = Blocks.AIR
	_blooms.clear()
	_bloom_t = 0.0
	return out


## A bloom you mined is no longer ours to take back.
func forget_bloom(v: Vector3i) -> void:
	_blooms.erase(v)


func blooms_snapshot() -> Array:
	return _blooms.keys()


func restore_blooms(cells: Array) -> void:
	_blooms.clear()
	for v in cells:
		_blooms[v as Vector3i] = true


func crops_snapshot() -> Array:
	var out: Array = []
	for v in _crops:
		var c: Dictionary = _crops[v]
		out.append([v, str(c["key"]), int(c["stage"]), bool(c.get("tree", false)),
			float(c.get("t", 0.0))])
	return out


func load_crops(rows: Array) -> void:
	_crops.clear()
	for r in rows:
		_crops[r[0]] = {"key": str(r[1]), "stage": int(r[2]), "tree": bool(r[3]),
			"t": float(r[4]) if r.size() > 4 else 0.0}
		_remesh_at(r[0])


## Advance everything planted. Called once a frame by the world.
##
## Walked in full rather than kept in a queue: a planet holds a few dozen
## planted cells at most -- a field is small, and it is the only thing on the
## planet that grows -- so the simple version costs less than the bookkeeping
## that would avoid it.
## Returns what changed: [[voxel, stage], ...] for crops that moved a stage, so
## the caller can put it on the wire. A tree that matured reports stage -1.
func grow_crops(delta: float) -> Array:
	var changed: Array = []
	if _crops.is_empty():
		return changed
	var done: Array = []
	for v in _crops:
		var c: Dictionary = _crops[v]
		if bool(c.get("tree", false)):
			c["t"] = float(c["t"]) + delta
			if float(c["t"]) >= Blocks.SAPLING_TIME:
				done.append(v)
			continue
		var g: Dictionary = Blocks.crop_growth(str(c["key"]))
		var per: float = float(g["time"]) / maxf(float(g["stages"]), 1.0)
		if int(c["stage"]) >= int(g["stages"]) - 1:
			continue        # ripe, and waiting for you
		c["t"] = float(c["t"]) + delta
		if float(c["t"]) >= per:
			c["t"] = 0.0
			c["stage"] = int(c["stage"]) + 1
			changed.append([v, int(c["stage"])])
			_remesh_at(v)
	for v in done:
		_grow_tree_at(v)
		changed.append([v, -1])
	return changed


## A young tree becomes a real one: the trunk and canopy the generator would
## have put here, written in as edits.
func _grow_tree_at(v: Vector3i) -> void:
	# Nothing planted here means this has already happened. Without the guard a
	# second call would clear the trunk block standing where the sapling was and
	# grow another tree through it, which is exactly what an absolute stage of
	# -1 arriving twice would do.
	if not _crops.has(v):
		return
	_crops.erase(v)
	set_block(v, Blocks.AIR)
	var centre := Vector3(v) + Vector3(0.5, 0.5, 0.5)
	var up := _axis_of(centre) if shape_cube else centre.normalized()
	if up == Vector3.ZERO:
		up = Vector3(0, 1, 0)
	# Built by the SAME code that grows the wild ones. A tree definition is a
	# base, an up, a trunk height and a canopy radius -- so a planted tree is one
	# of those, made at the spot you planted it, with the heights this world's
	# trees actually use. Writing a canopy by hand instead produced a diamond of
	# leaves on a planet whose trees are pines: right wood, right leaf colour,
	# wrong tree.
	var cell := Vector3i(floori(centre.x / float(tree_cell)),
		floori(centre.y / float(tree_cell)), floori(centre.z / float(tree_cell)))
	# The kind of tree THIS ground grows, so a sapling planted in a pine wood
	# comes up a pine.
	var vi := 0
	if not _b_amp.is_empty():
		vi = _biome_slot(_biome_pos(centre.normalized()))
	var fv := _flora_of(vi)
	var tmin := int(fv.get("trunk_min", trunk_min))
	var tmax := int(fv.get("trunk_max", trunk_max))
	var cmin := float(fv.get("canopy_min", canopy_min))
	var cmax := float(fv.get("canopy_max", canopy_max))
	var th := tmin + int(_hash01(cell, 1) * float(tmax - tmin + 1))
	var cr := cmin + _hash01(cell, 2) * (cmax - cmin)
	var info: Array = [Vector3(v) + Vector3(0.5, 0.0, 0.5), up, th, cr, cell, vi]
	# Everything the tree can reach. Generous, and clipped by the shape code
	# itself -- a box that is too small crops the canopy, and one that is too
	# big only costs a few thousand cheap misses once.
	var reach := int(ceil(maxf(cr * 1.6, float(fv.get("trunk_rad", trunk_rad)) * 2.0))) + 2
	var high := th + int(ceil(cr * 2.0)) + 2
	for dx in range(-reach, reach + 1):
		for dz in range(-reach, reach + 1):
			for dy in range(-2, high):
				var q := v + Vector3i(dx, dy, dz)
				var got := _tree_block_for(Vector3(q) + Vector3(0.5, 0.5, 0.5), info)
				if got == Blocks.AIR:
					continue
				# Never carve into what is already there: a tree grows around the
				# ground, not through it.
				if get_id(q) != Blocks.AIR:
					continue
				set_block(q, got)

## Nudge the chunk holding `v` to redraw, without changing a block.
func _remesh_at(v: Vector3i) -> void:
	_edit_remesh(chunk_of(v))


# --- eighth-block parts -------------------------------------------------------
#
# A PARTS voxel's eight sub-cells live here rather than in the voxel int: eight
# ids will not fit alongside the orientation bits already packed in there, and
# keeping them out of the hot path leaves get_id a plain lookup.
var _parts_by_chunk := {}      # cc -> {voxel: PackedByteArray(PART_COUNT)}

## The eight sub-cells of `v`, or an empty array when it holds none.
func parts_at(v: Vector3i) -> PackedByteArray:
	var d = _parts_by_chunk.get(chunk_of(v))
	if d == null:
		return PackedByteArray()
	var got = d.get(v)
	return got if got != null else PackedByteArray()


func part_at(v: Vector3i, sub: int) -> int:
	var p := parts_at(v)
	return int(p[sub]) if p.size() == Blocks.PART_COUNT else Blocks.AIR


## Put one eighth into `v`. The voxel itself becomes a PARTS marker so meshing,
## occlusion and re-meshing all behave without knowing about sub-cells.
func set_part(v: Vector3i, sub: int, id: int) -> void:
	Audio.block_placed(id, to_global(Vector3(v) + Vector3(0.5, 0.5, 0.5)))
	var cc := chunk_of(v)
	if not _parts_by_chunk.has(cc):
		_parts_by_chunk[cc] = {}
	var cell: PackedByteArray = parts_at(v)
	if cell.size() != Blocks.PART_COUNT:
		cell = PackedByteArray()
		cell.resize(Blocks.PART_COUNT)
	cell[sub] = id
	_parts_by_chunk[cc][v] = cell
	set_block(v, Blocks.PARTS)


## Take one eighth back out. The last one leaving turns the cell back to air.
func clear_part(v: Vector3i, sub: int) -> void:
	var cell: PackedByteArray = parts_at(v)
	if cell.size() != Blocks.PART_COUNT:
		return
	Audio.block_broken(cell[sub], to_global(Vector3(v) + Vector3(0.5, 0.5, 0.5)))
	cell[sub] = Blocks.AIR
	var any := false
	for i in Blocks.PART_COUNT:
		if cell[i] != Blocks.AIR:
			any = true
			break
	var cc := chunk_of(v)
	if any:
		_parts_by_chunk[cc][v] = cell
		set_block(v, Blocks.PARTS)
	else:
		(_parts_by_chunk[cc] as Dictionary).erase(v)
		set_block(v, Blocks.AIR)


## What occupies one EIGHTH of the world, in global sub-cell coordinates
## (voxel * 2 + sub). A full block reads as eight filled sub-cells, which is what
## lets one pattern language describe both cubes and parts.
func sub_id(sv: Vector3i) -> int:
	var v := Vector3i(floori(sv.x / 2.0), floori(sv.y / 2.0), floori(sv.z / 2.0))
	var raw := get_id(v)
	if raw == Blocks.PARTS:
		var o := sv - v * 2
		return part_at(v, Blocks.part_index(o.x, o.y, o.z))
	if raw == Blocks.AIR or raw == Blocks.WATER or raw == Blocks.DOOR_OPEN:
		return Blocks.AIR
	return Blocks.bottom_of(raw)


## A campfire lights its surroundings the same way a torch does, so the same
## chunks have to re-bake. Mirrors the light fan-out in set_block.
func _relight_around(v: Vector3i) -> void:
	var cc := chunk_of(v)
	_edit_remesh(cc)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				if dx == 0 and dy == 0 and dz == 0:
					continue
				var ncc := cc + Vector3i(dx, dy, dz)
				if loaded_chunks.has(ncc) and _light_reaches(ncc, v, Chunk.FIRE_LIGHT):
					_dirty[ncc] = true


# --- power grid --------------------------------------------------------------
#
# Stations are wired together with Power Conduit. A generator feeds any station
# reachable through a run of conduit, plus anything standing in the same sealed
# room -- so a small base can skip wiring entirely, and a sprawling one runs cable.
const GRID_MAX := 2500        # conduit cells followed before giving up

var _grid_cache := {}         # station id -> Array[Station] of generators feeding it

const ROOM_MAX_CELLS := 900    # bigger than this and you are outdoors, not in a room
const ROOM_RECHECK := 0.35     # seconds between re-floods while walking around
const ROOM_GIVEUP := 2.0       # ...but much slower once we know you are outside
const BASE_NEAR := 26          # only look for a room this close to a real machine

var _room: Dictionary = {}     # cached flood-fill result for the player's room
var _room_at := Vector3i(0, -99999, 0)
var _room_age := 999.0
var _room_ctrls: Array = []    # stations in or against _room, found with it
var _room_scan_at := Vector3i(0, -99999, 0)   # where the last flood was attempted
var _room_temp := 1e9          # the room's own temperature; 1e9 = not established yet

const REGULATED_TEMP := 20.0   # what a powered Heater or Cooler holds a room at

## Does this block hold air in? Leaves and open doorways plainly do not, and
## water is not a wall either.
func _seals(id: int) -> bool:
	if id == Blocks.AIR or id == Blocks.DOOR_OPEN or id == Blocks.WATER:
		return false
	var low := Blocks.bottom_of(id)
	return not (Blocks.is_leaf(low) or Blocks.is_wire(low) or low == Blocks.PARTS)


## Sealing test for one CELL, which is the same thing except for conduit.
##
## A cable is a cable: run across a room floor it must not chop the room in two,
## but threaded through a wall it must not vent the place either. Which one it
## is comes down to what surrounds it -- a wire buried in a wall has solid on
## nearly every side, one lying in a room has solid only underneath. Without
## this, powering a base from an outside generator meant cutting a hole in it.
const WIRE_EMBEDDED := 4       # solid neighbours before a conduit counts as wall

func _cell_seals(v: Vector3i) -> bool:
	var id := get_id(v)
	if not Blocks.is_wire(Blocks.bottom_of(id)):
		return _seals(id)
	var solid := 0
	for n in _NEIGH6:
		if _seals(get_id(v + n)):
			solid += 1
	return solid >= WIRE_EMBEDDED


## Is there any assembled machine close enough for this to be somebody's base?
##
## This gate exists for SPEED, and it is the whole reason walking is smooth: a
## flood fill out in the open runs to the cell cap and costs thousands of
## terrain samples, which is tens of milliseconds every time. A base has
## machines in it by definition -- an empty box is not a base and would not keep
## you alive anyway -- so out in the world, and in caves, the fill never runs.
func _near_base_machine(v: Vector3i) -> bool:
	for pv in _placed_at:
		var d: Vector3i = (pv as Vector3i) - v
		if absi(d.x) <= BASE_NEAR and absi(d.y) <= BASE_NEAR and absi(d.z) <= BASE_NEAR:
			return true
	return false


## Every station standing on this planet (not riding a ship), by each voxel it
## fills. Cheap -- a handful of stations, a few cells each -- and run with each
## base scan rather than kept up to date edit by edit.
func _rebuild_placed() -> void:
	_placed_at.clear()
	_grid_cache.clear()
	if _world_ref == null:
		return
	for st in _world_ref._stations:
		if not is_instance_valid(st) or st.get_parent() is Ship or st.headless:
			continue
		if _world_ref.nearest_planet(st.global_position) != self:
			continue
		for v in station_voxels(st):
			_placed_at[v] = st


## The voxels a station fills, from its footprint and the way it stands. The
## station's origin is the centre of its first cell; a wider footprint runs out
## either side of it the same way its collision box does.
func station_voxels(st: Station) -> Array:
	var fp := StationModels.footprint(st.kind)
	var out: Array = []
	for ix in fp.x:
		for iy in fp.y:
			for iz in fp.z:
				var local := Vector3(float(ix) - float(fp.x - 1) * 0.5, float(iy),
					float(iz) - float(fp.z - 1) * 0.5)
				out.append(world_to_voxel(st.to_global(local)))
	return out


## The generators feeding station `st` through conduit: out along every wire
## touching it, and every generator touching those wires.
func station_grid_generators(st: Station) -> Array:
	var key := st.get_instance_id()
	if _grid_cache.has(key):
		return _grid_cache[key]
	var wires := {}
	var q: Array[Vector3i] = []
	for cell in station_voxels(st):
		for n in _NEIGH6:
			var a: Vector3i = (cell as Vector3i) + n
			if Blocks.bottom_of(get_id(a)) == Blocks.WIRE and not wires.has(a):
				wires[a] = true
				q.append(a)
	var gens := {}
	var head := 0
	while head < q.size():
		var w: Vector3i = q[head]
		head += 1
		for n in _NEIGH6:
			var a: Vector3i = w + n
			var other = _placed_at.get(a)
			if other != null and is_instance_valid(other) and Blocks.makes_power(other.kind):
				gens[other] = true
			if Blocks.bottom_of(get_id(a)) == Blocks.WIRE and not wires.has(a) \
					and wires.size() < GRID_MAX:
				wires[a] = true
				q.append(a)
	var out: Array = gens.keys()
	_grid_cache[key] = out
	return out


## A Campfire station burning in cell `v`: flames drawn and light baked there.
func add_fire(v: Vector3i) -> void:
	if _fire_cells.has(v):
		return
	_fire_cells[v] = true
	_relight_around(v)


func remove_fire(v: Vector3i) -> void:
	if not _fire_cells.has(v):
		return
	_fire_cells.erase(v)
	_relight_around(v)


## Flood-fill the open space containing `start`. Returns the set of cells, or an
## empty dict if the space runs past ROOM_MAX_CELLS (i.e. it is the outdoors).
## Does anything cover this cell? At most CEILING_PROBE lookups straight up,
## against the flood's several thousand, and it settles the commonest case of
## all -- standing outdoors somewhere near your own base -- without running the
## fill at all.
##
## Safe because it can only say "no room" where the flood would have agreed:
## a gap you can see sky through is a gap the fill escapes through. The one
## thing it gives up is a sealed room taller than the probe, which at 900 cells
## of volume is a shape nobody builds.
const CEILING_PROBE := 40

func _has_ceiling(v: Vector3i) -> bool:
	var up := _axis_of(Vector3(v) + Vector3(0.5, 0.5, 0.5))
	var step := Vector3i(roundi(up.x), roundi(up.y), roundi(up.z))
	if step == Vector3i.ZERO:
		step = Vector3i(0, 1, 0)
	var c := v
	for i in CEILING_PROBE:
		c += step
		if _seals(get_id(c)):
			return true
	return false


func _flood_room(start: Vector3i) -> Dictionary:
	if _cell_seals(start):
		return {}
	var seen := {start: true}
	var queue: Array[Vector3i] = [start]
	var head := 0
	# Whether a cell seals, remembered for the length of this fill. A wall cell
	# borders up to six air cells and was asked the same question once for each
	# of them -- and the answer can cost a noise sample, because get_id falls
	# through to generation for anything nobody has edited.
	var seals := {}
	while head < queue.size():
		var c: Vector3i = queue[head]
		head += 1
		for n in _NEIGH6:
			var q: Vector3i = c + n
			if seen.has(q):
				continue
			var blocked = seals.get(q)
			if blocked == null:
				blocked = _cell_seals(q)
				seals[q] = blocked
			if blocked:
				continue
			seen[q] = true
			if seen.size() > ROOM_MAX_CELLS:
				return {}   # escaped: this is open ground, not a room
			queue.append(q)
	return seen


## Advance and report the base the player is standing in. Everything a base does
## is only observable from inside it, so the machines are ticked from here rather
## than each running its own simulation -- that keeps the cost to one room.
func update_base(v: Vector3i, delta: float) -> Dictionary:
	_room_age += delta
	# Throttled hard: re-flood when you have MOVED and the timer is up, or once a
	# second regardless so a wall broken while you stand still is still noticed.
	# Without the timer guard a sprinting player re-floods many times a second.
	# Once we know you are outside, back right off: re-checking every third of a
	# second while you walk around your own base was the stutter.
	var gap: float = ROOM_RECHECK if not _room.is_empty() else ROOM_GIVEUP
	var moved: bool = (v - _room_scan_at).length_squared() >= 9   # ~3 blocks
	if _room_age >= gap and (moved or _room_age >= 3.0):
		_room_at = v
		_room_scan_at = v
		_room_age = 0.0
		var was := _room.size()
		# Both cheap tests first: near a station at all, and standing under
		# something. Out in the open with no station about, the flood never runs.
		var tr := Time.get_ticks_usec()
		_rebuild_placed()
		_room = _flood_room(v) if (_near_base_machine(v) and _has_ceiling(v)) else {}
		WorldManager.perf_mark("room scan", tr)
		if _room.size() != was:
			_room_temp = 1e9   # different room (or none): start from outside again
		# Found once with the room rather than re-walked every tick: this scan is
		# 6 lookups per cell, and the room only changes when the fill does.
		# A station stands IN the room's air (it is a node, not a block, so the
		# flood runs through it) or against its wall; either way it serves it.
		var found := {}
		for c in _room:
			var here = _placed_at.get(c)
			if here != null:
				found[here] = true
			for n in _NEIGH6:
				var m = _placed_at.get((c as Vector3i) + n)
				if m != null:
					found[m] = true
		_room_ctrls = found.keys()
	var out := {"sealed": false, "power": 0.0, "power_max": 0.0,
		"o2": 0.0, "temp": ambient_temp(), "gen": false, "ls": false, "heater": false,
		"cells": _room.size()}
	if _room.is_empty():
		return out
	out["sealed"] = true
	# Which machines does this room touch? A machine counts as part of the base
	# when any of its blocks borders the sealed volume -- you built it into the
	# wall, so it is yours.
	var gens: Array = []
	# Generators built into this base. Anything else built into the same base
	# draws from them with no wiring: sharing a building IS the connection.
	# Conduit is for reaching machines that are not part of it.
	var room_gens: Array = []
	var ls: Station = null
	var heater: Station = null
	var cooler: Station = null
	var gset := {}
	for sv in _room_ctrls:
		var st: Station = sv as Station
		if st == null or not is_instance_valid(st):
			continue
		if Blocks.makes_power(st.kind):
			gset[st] = true
			room_gens.append(st)
		else:
			# A consumer is powered by whatever its CONDUIT reaches, which may be
			# a generator in another room entirely.
			for g in station_grid_generators(st):
				gset[g] = true
			if st.kind == Blocks.OXYGEN_PLANT:
				ls = st
			elif st.kind == Blocks.HEATER:
				heater = st
			elif st.kind == Blocks.COOLER:
				cooler = st
	gens = gset.keys()
	for g in gens:
		out["power"] += (g as Station).power
		out["power_max"] += (g as Station).power_cap()
	out["gen"] = not gens.is_empty()
	out["ls"] = ls != null
	out["heater"] = heater != null
	out["cooler"] = cooler != null
	# Touching the base is a connection; anything further off needs conduit run
	# to it. Base generators are tried first, so a self-contained base never
	# depends on wiring at all.
	var draw := func(consumer: Station, amount: float) -> bool:
		for g in room_gens:
			var st: Station = g
			if st.power >= amount:
				st.power -= amount
				return true
		for g2 in station_grid_generators(consumer):
			var st2: Station = g2
			if st2.power >= amount:
				st2.power -= amount
				return true
		return false
	if ls != null:
		# A bigger room takes proportionally longer to fill, so a cathedral is a
		# real commitment and a cupboard is quick.
		var rate: float = 0.55 * (200.0 / maxf(float(_room.size()), 60.0))
		if draw.call(ls, Station.O2_POWER_RATE * delta):
			ls.o2 = minf(ls.o2 + rate * delta, 1.0)
		else:
			ls.o2 = maxf(ls.o2 - 0.05 * delta, 0.0)
		out["o2"] = ls.o2
	# Four walls are NOT shelter. A sealed room sits at whatever the planet is
	# doing to it; only a powered regulator moves it off ambient. Each pushes one
	# way only, so a Heater is no help on a world that is cooking you -- that
	# needs a Cooler, and vice versa.
	var target := ambient_temp()
	if heater != null and draw.call(heater, Station.HEAT_POWER_RATE * delta):
		target = maxf(target, REGULATED_TEMP)
	if cooler != null and draw.call(cooler, Station.HEAT_POWER_RATE * delta):
		target = minf(target, REGULATED_TEMP)
	if _room_temp > 1e8:
		_room_temp = ambient_temp()
	_room_temp = move_toward(_room_temp, target, 6.0 * delta)
	out["temp"] = _room_temp
	return out


## What it is like outside right now, in degrees C.
func ambient_temp() -> float:
	var base := 15.0
	if hazard == "cold":
		base = -45.0
	elif hazard == "heat":
		base = 62.0
	if has_atmosphere:
		# Night is colder than noon, which is what makes a Heater worth building
		# on an otherwise mild world.
		base += lerpf(-12.0, 6.0, clampf(sun_height() * 0.5 + 0.5, 0.0, 1.0))
	return base


func ore_def(block_id: int) -> Dictionary:
	return _ore_by_block.get(block_id, {})

func ore_color(block_id: int) -> Color:
	var d := ore_def(block_id)
	return d["color"] if d.has("color") else Blocks.color_of(block_id)

## Is this ore one of the good burners? Its stone is drawn black and sooty.
func ore_is_fuel_grade(block_id: int) -> bool:
	var d := ore_def(block_id)
	return d.has("props") and Blocks.is_fuel_grade(d["props"])


## How brightly this ore glows in the dark, 0 to 1.
##
## Reactivity is how well the stuff carries a current, and the ones that carry
## it best hold a charge of their own -- so the richest conductor on a world is
## a faint light in an unlit cave, and a dead one is just rock. It is nothing
## to do with the aurora and nothing to do with night; it simply never stops,
## and you only notice it where there is nothing brighter.
func ore_glow(ore_id: int) -> float:
	var d := ore_def(ore_id)
	if not d.has("props"):
		return 0.0
	var props: Dictionary = d["props"]
	# Nothing at all below the halfway mark, then climbing to the top of the
	# range, so a glowing seam means something rather than every wall shining.
	return clampf((float(props.get("r", 0)) - 52.0) / 48.0, 0.0, 1.0)


## The stone a fuel ore sits in: the planet's own rock, gone most of the way to
## soot. Kept a touch of the rock's tint so it still belongs to this world.
const SOOT := Color(0.065, 0.058, 0.052)


func sooty_rock_color() -> Color:
	return color_of(pal_rock).lerp(SOOT, 0.74)


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

	# How this world's caves are SHAPED, independently of how many it has. Most
	# planets get a warren -- corridors you walk down with the odd room off them.
	# A minority keep the enormous voids, which are worth seeing but make a poor
	# default: a chamber wider than the streaming radius shows you its own
	# unloaded far wall, and its ceiling sits shallow enough to catch daylight.
	var srng := RandomNumberGenerator.new()
	srng.seed = _seed + 9191
	cave_style = "cavern" if srng.randf() < 0.22 else "warren"

	# Cave size is measured in BLOCKS. It used to be divided by the planet
	# radius, so a bigger world got proportionally bigger caves: on a 1300-block
	# planet the main network had a ~900-block wavelength and even the "fine
	# veins" ran ~200. That is how a cave system became a shaft you fall down for
	# a mile. A cave is something you walk through, so its scale belongs in paces
	# rather than in planet radii.
	# Tunnel size is set by how it feels to WALK down one. Widening the scale
	# widens the passage without hollowing out more rock (open volume holds at
	# ~6% across the whole range), so it is the lever to reach for: at a 22-block
	# scale only 62% of floor spots had standing headroom and the average passage
	# was 3.0 wide, which is a crawl. At 40 it is 80% and 4.4 wide.
	var room_size := lerpf(105.0, 72.0, a)
	var tunnel_size := lerpf(60.0, 44.0, a)
	if cave_style == "cavern":
		room_size = lerpf(190.0, 130.0, a)
		tunnel_size = lerpf(68.0, 52.0, a)

	# BIG network: sparse, wide -> the rooms. More amount -> lower threshold
	# (denser) and lower frequency (bigger rooms).
	# Thresholds are calibrated against the fraction of rock they actually open
	# (measured, not guessed): these give roughly 0.5%-3% for the rooms and
	# 1.5%-7% for the tunnels, so a warren world lands near 2%-10% open. The old
	# values opened 32% of every planet's rock, which is what made caves read as
	# endless connected voids rather than as passages through stone.
	cave_threshold = lerpf(0.80, 0.70, a)
	if cave_style == "cavern":
		cave_threshold = lerpf(0.76, 0.64, a)
	# A smaller margin over the base threshold means more of the network is
	# allowed to break the surface, so cave mouths you can walk into are something
	# you actually come across rather than a rarity.
	cave_breach_threshold = minf(cave_threshold + 0.05, 0.985)
	var freq := 1.0 / room_size
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
	cave_threshold_fine = lerpf(0.74, 0.63, a)
	# breach uses a near-absolute bar (NOT a small margin over the base threshold,
	# which is tuned low for deep diggability and would make breaches everywhere)
	# so surface entrances from the fine network stay rare regardless of density
	cave_breach_threshold_fine = lerpf(0.935, 0.90, a)
	var freq_fine := 1.0 / tunnel_size
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
## Recolour this world. Hues are chosen as a FAMILY rather than independently:
## foliage picks a hue, ground sits near it, stone and water take their own but
## related hues. Rolling six unrelated colours produces noise, not a planet.
func _derive_palette() -> void:
	tint.clear()
	if not alien_palette:
		return
	var r := RandomNumberGenerator.new()
	r.seed = _seed + 9001
	# How far from Earth this world sits. A third of habitable worlds stay
	# recognisable -- green, brown, blue -- because "alien" only lands if there
	# is something ordinary to measure it against. The rest are allowed to be
	# properly strange, and the strangeness carries through hue, saturation,
	# the sky and the shape of the trees.
	strangeness = r.randf()
	if strange_min > 0.0:
		strangeness = strange_min + strangeness * (1.0 - strange_min)
	var homely := strangeness < 0.35
	var life_h: float
	var life_s: float
	if homely:
		life_h = r.randf_range(0.22, 0.42)          # greens
		life_s = r.randf_range(0.30, 0.60)
	else:
		# Everything BUT green, so an alien world can never be mistaken for a
		# slightly-off Earth.
		var bands := [Vector2(0.80, 1.05), Vector2(0.02, 0.13),
			Vector2(0.46, 0.56), Vector2(0.60, 0.75)]
		var band: Vector2 = bands[r.randi() % bands.size()]
		life_h = fposmod(r.randf_range(band.x, band.y), 1.0)
		life_s = r.randf_range(0.55, 0.95)
	var ground_h := fposmod(life_h + r.randf_range(-0.06, 0.06), 1.0)
	tint[Blocks.GRASS] = Color.from_hsv(ground_h, life_s * 0.9, r.randf_range(0.45, 0.75))
	tint[Blocks.DIRT] = Color.from_hsv(fposmod(ground_h + r.randf_range(-0.10, 0.10), 1.0),
		life_s * 0.55, r.randf_range(0.28, 0.48))
	# Minerals are their own story: drab on a homely world, occasionally
	# striking on a strange one.
	var rock_h := r.randf()
	var rock_s := r.randf_range(0.03, 0.16)
	if not homely and r.randf() < 0.5:
		rock_s = r.randf_range(0.35, 0.7)
	tint[Blocks.ROCK] = Color.from_hsv(rock_h, rock_s, r.randf_range(0.30, 0.62))
	# Timber is warm brown at home, and can echo the foliage further out.
	var wood_h := r.randf_range(0.03, 0.11)
	if not homely and r.randf() < 0.6:
		wood_h = fposmod(life_h + 0.5, 1.0)
	for w in Blocks.WOOD_IDS:
		tint[w] = Color.from_hsv(wood_h, r.randf_range(0.25, 0.6), r.randf_range(0.22, 0.46))
	for i in Blocks.PLANK_IDS.size():
		tint[Blocks.PLANK_IDS[i]] = (tint[Blocks.WOOD_IDS[i]] as Color).lightened(0.25)
	# Leaves spread around the biosphere hue so one canopy has variety in it --
	# and WIDER on a world with regions, because each region takes its foliage
	# from its own stretch of this ramp. At the one-canopy width the stretches
	# are a hundredth of a hue apart, which is the same green twice.
	var spread: float = 0.10 if homely else 0.26
	if has_biomes():
		spread *= 2.2
	for li in Blocks.LEAF_IDS.size():
		var h := fposmod(life_h + (float(li) / float(Blocks.LEAF_IDS.size()) - 0.5) * spread, 1.0)
		tint[Blocks.LEAF_IDS[li]] = Color.from_hsv(h, life_s, r.randf_range(0.45, 0.85))
	# Seas: blue at home, anything at all further out.
	var water_h := r.randf_range(0.52, 0.62) if homely else r.randf()
	tint[Blocks.WATER] = Color.from_hsv(water_h,
		r.randf_range(0.25, 0.55) if homely else r.randf_range(0.4, 0.85),
		r.randf_range(0.35, 0.75), Blocks.color_of(Blocks.WATER).a)
	# The sky is half of how a place feels, so it moves with the rest.
	if not homely:
		atmo_color = Color.from_hsv(fposmod(life_h + r.randf_range(0.3, 0.7), 1.0),
			r.randf_range(0.35, 0.8), r.randf_range(0.55, 0.95))
	leaf_holes = r.randf_range(0.0, 2.2)
	leaf_grain = r.randf_range(0.6, 1.9)
	# SURFACE STYLE, not just surface colour. The texel pattern was seeded per
	# planet but always used the same cell size, step count and contrast, so
	# every world's ground was the same material in a different colour. These
	# make one planet's soil a fine even wash and another's a coarse mottle.
	var tame: float = 1.0 if strangeness < 0.35 else 0.0
	ground_grain = lerpf(r.randf_range(0.45, 2.2), r.randf_range(0.85, 1.3), tame)
	ground_levels = lerpf(r.randf_range(2.0, 7.0), r.randf_range(3.0, 5.0), tame)
	ground_contrast = lerpf(r.randf_range(0.35, 2.6), r.randf_range(0.7, 1.3), tame)
	rock_grain = lerpf(r.randf_range(0.4, 2.6), r.randf_range(0.8, 1.4), tame)
	rock_contrast = lerpf(r.randf_range(0.5, 6.0), r.randf_range(0.8, 1.6), tame)


## What this world calls a block. A retinted leaf must not still be called
## "Violet Leaves" while being mint green -- the name is derived from the colour
## it actually is here.
func name_of(id: int) -> String:
	if Blocks.is_leaf(Blocks.bottom_of(id)) and tint.has(Blocks.bottom_of(id)):
		return "%s Leaves" % Blocks.hue_name(tint[Blocks.bottom_of(id)])
	return Blocks.name_of(id)


## This world's colour for a block, falling back to the global registry.
func color_of(id: int) -> Color:
	var c = tint.get(id)
	if c != null:
		return c
	# Through the shape: this world's timber is its own colour, and a slab cut
	# from it is the same timber. Only the plain materials are tinted, so a
	# shaped block has to ask on behalf of what it was cut from.
	var mat := Blocks.base_material_of(Blocks.bottom_of(id))
	if mat != id:
		c = tint.get(mat)
		if c != null:
			return c
	return Blocks.color_of(id)


## Which regions this world is made of, and how big they are.
##
## A CONTIGUOUS run of the table rather than a scattered pick, because the table
## is an axis: a world that had a basin and barrens and nothing in between would
## put a cliff of dead rock straight against a lake. Where the run starts and how
## long it is are the roll, so one world is basins-through-scrub and the next is
## forest-through-barrens.
func _derive_biomes() -> void:
	biome_names.clear()
	_b_top.clear()
	_b_trees.clear()
	_b_grass.clear()
	_b_amp.clear()
	_b_lift.clear()
	_b_hue.clear()
	_b_sat.clear()
	_b_val.clear()
	if radius < BIOME_MIN_RADIUS:
		return
	var r := RandomNumberGenerator.new()
	r.seed = _seed + 1717
	var n := r.randi_range(4, 6)
	var start := r.randi_range(0, BIOME_KINDS.size() - n)
	for i in n:
		var b: Dictionary = BIOME_KINDS[start + i]
		biome_names.append(str(b["name"]))
		_b_top.append(int(b["top"]))
		# Jittered per world, so two planets that happen to draw the same run are
		# still not the same planet.
		_b_trees.append(float(b["trees"]) * r.randf_range(0.75, 1.3))
		_b_grass.append(float(b["grass"]) * r.randf_range(0.75, 1.3))
		_b_amp.append(float(b["amp"]) * r.randf_range(0.85, 1.15))
		_b_lift.append(float(b["lift"]) * r.randf_range(0.8, 1.2))
		# Spread ACROSS the run rather than rolled independently, so neighbouring
		# regions are neighbouring shades and the two ends of a world are the
		# two ends of its palette. Rolling each one loose puts the greenest
		# meadow next to the greyest moor as often as not.
		var t := 0.0 if n <= 1 else float(i) / float(n - 1)
		# A wide turn of hue, not a nudge. At a twentieth of the wheel the
		# regions were three greens you had to be told apart; at a seventh they
		# are a yellow-green, a green and a blue-green, which is the difference
		# between a meadow and a moor as anybody would actually describe it.
		_b_hue.append(lerpf(-0.14, 0.14, t) * r.randf_range(0.75, 1.25))
		_b_sat.append(lerpf(1.40, 0.48, t) * r.randf_range(0.9, 1.1))
		_b_val.append(lerpf(0.86, 1.20, t) * r.randf_range(0.95, 1.05))
	biome_noise.seed = _seed + 1718
	biome_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	biome_noise.frequency = BIOME_SCALE / maxf(radius, 1.0)
	# Two octaves, so a region has a ragged coast rather than the outline of a
	# single noise blob.
	biome_noise.fractal_octaves = 2


func has_biomes() -> bool:
	return not _b_amp.is_empty()


## Where a point on the surface sits along this world's biome axis, 0 to 1.
## Continuous on purpose: the relief either side of a border is blended across
## it, and only the ground material and the vegetation snap.
func _biome_pos(dir: Vector3) -> float:
	var v := biome_noise.get_noise_3d(dir.x * radius, dir.y * radius, dir.z * radius)
	return clampf(v * 0.85 + 0.5, 0.0, 1.0)


## Which region a point actually belongs to, for the things that cannot be half
## one and half the other: what the ground is made of, and what grows on it.
##
## EQUAL shares of the axis. Handing each region the span nearest its own index
## instead gives the two ends half a share each, which with three regions put
## two thirds of the world in the middle one -- a planet of plains with a rumour
## of forest at either end.
func _biome_slot(pos: float) -> int:
	return clampi(int(pos * float(_b_amp.size())), 0, _b_amp.size() - 1)


## Relief at a point: the amplitude multiplier and the height offset, blended
## across the border between two regions.
##
## Measured between the CENTRES of neighbouring shares, so the blend is at its
## purest in the middle of a region and half-and-half exactly where the ground
## material changes -- and flat past the outermost centres, or the far end of a
## world would keep sinking after it had run out of basin.
func _biome_relief(pos: float) -> Vector2:
	var n := _b_amp.size()
	var at := pos * float(n) - 0.5
	var i := clampi(int(floorf(at)), 0, n - 1)
	var j := clampi(i + 1, 0, n - 1)
	var f := clampf(at - float(i), 0.0, 1.0)
	return Vector2(lerpf(_b_amp[i], _b_amp[j], f), lerpf(_b_lift[i], _b_lift[j], f))


## How many steps the ground colour is allowed to take across a world.
##
## The colour GRADES between regions rather than snapping at the border the way
## the material and the trees do -- soil does not change in a line, and a hard
## edge across open ground reads as a seam in the world rather than as a change
## of country. But a continuous colour cannot be merged into big quads, so it is
## quantised: enough steps to read as a gradient, few enough that a step lasts
## tens of blocks and the mesher still has runs to merge.
const GROUND_STEPS := 24


## Where a voxel sits on the ground-colour ramp, as a mesher-friendly 1-based
## number. 0 means "this world has no regions", so a caller keeps one code path.
func biome_slot_at(v: Vector3i) -> int:
	if _b_amp.is_empty():
		return 0
	var p := Vector3(v) + Vector3(0.5, 0.5, 0.5)
	var l := p.length()
	if l < 0.0001:
		return 0
	return 1 + clampi(int(_biome_pos(p / l) * float(GROUND_STEPS - 1) + 0.5),
		0, GROUND_STEPS - 1)


## Is this a block the regions colour? The ground they carpet, and only that --
## rock is rock everywhere, and a wall somebody built out of it should not change
## shade because of where they built it.
func biome_tints(id: int) -> bool:
	return not _b_amp.is_empty() and (id == pal_top or id == pal_sub)


## This world's colour for a block, at that point on the ground ramp. `slot` is
## 1-based, the way biome_slot_at hands it out; 0 leaves the colour alone.
##
## Blended between neighbouring regions in exactly the way the relief is, and
## between their CENTRES, so a colour is at its purest in the middle of a region
## and half-and-half where the ground material changes.
func ground_color(id: int, slot: int) -> Color:
	var c := color_of(id)
	if slot <= 0 or _b_hue.is_empty() or not biome_tints(id):
		return c
	var t := float(slot - 1) / float(GROUND_STEPS - 1)
	var n := _b_hue.size()
	var at := t * float(n) - 0.5
	var i := clampi(int(floorf(at)), 0, n - 1)
	var j := clampi(i + 1, 0, n - 1)
	var f := clampf(at - float(i), 0.0, 1.0)
	var dh := lerpf(_b_hue[i], _b_hue[j], f)
	var ds := lerpf(_b_sat[i], _b_sat[j], f)
	var dv := lerpf(_b_val[i], _b_val[j], f)
	return Color.from_hsv(fposmod(c.h + dh, 1.0),
		clampf(c.s * ds, 0.0, 1.0),
		clampf(c.v * dv, 0.0, 1.0), c.a)


## Everything the simulation thinks about one cell, in words. For the /water
## command: when water is not doing what somebody expects, the useful thing is
## not another guess about the code, it is what this particular cell actually
## is.
func water_debug(v: Vector3i) -> Array:
	var out: Array = []
	out.append("cell %s  id %s  style %d  simulated %s" % [
		str(v), Blocks.name_of(get_id(v)), water_style, str(water_simulated)])
	out.append("  level %d  source %s  native %s  fill %.2f" % [
		int(_wlev.get(v, 0)), str(_ocean_source(v)), str(water_is_native(v)),
		water_fill(v)])
	var down := _wdown(v)
	out.append("  down %s  target if evaluated: %d" % [str(down), _water_target(v)])
	for n in _NEIGH6:
		var q: Vector3i = v + (n as Vector3i)
		out.append("  %-14s %-12s lvl %d  source %s  solid %s" % [
			str(n), Blocks.name_of(get_id(q)), _wlevel(q),
			str(_ocean_source(q)), str(_is_solid_block(q))])
	out.append("  queues: yours %d, sea %d, redraws %d, stalled %d, wet %d" % [
		_water_active.size(), _water_bg.size(), _water_dirty.size(),
		_water_stalled.size(), _wlev.size()])
	out.append("  chunk loaded %s  accum %.3f" % [
		str(loaded_chunks.has(chunk_of(v))), _flow_accum])
	return out


## What this world calls the place you are standing.
func biome_at(world_pos: Vector3) -> String:
	if not has_biomes():
		return ""
	var d := (world_pos - global_position)
	if d.length_squared() < 0.0001:
		return ""
	return str(biome_names[_biome_slot(_biome_pos(d.normalized()))])


func _derive_flora(density: float) -> void:
	tree_density = density
	flora_variants.clear()
	if tree_density <= 0.0:
		return
	var fr := RandomNumberGenerator.new()
	fr.seed = _seed + 555
	# The world's own trees first, rolled exactly as they always were -- so a
	# moon, or a world with one region, grows precisely what it used to.
	var kinds := maxi(_b_amp.size(), 1)
	var base_v := _roll_flora(fr, -1, 0, kinds)
	flora_variants.append(base_v)
	# Then one kind per region, in the same shape family. Rolled from the same
	# generator, in order, so adding regions cannot change the first roll.
	for i in range(1, kinds):
		flora_variants.append(_roll_flora(fr, int(base_v["shape"]), i, kinds))
	# The planet's own fields stay the FIRST variant's, because a sapling
	# planted before any of this existed is that tree, and because everything
	# that asks the planet what its trees are like means the ordinary ones.
	flora_leaves = base_v["leaves"]
	flora_wood = int(base_v["wood"])
	flora_shape = int(base_v["shape"])
	trunk_min = int(base_v["trunk_min"])
	trunk_max = int(base_v["trunk_max"])
	trunk_rad = float(base_v["trunk_rad"])
	canopy_min = float(base_v["canopy_min"])
	canopy_max = float(base_v["canopy_max"])
	tree_cell = int(base_v["cell"])
	# Bounds are the WORST case across every kind the world grows. These decide
	# how far above the ground terrain generation bothers to look and how many
	# neighbouring cells a voxel consults -- so a bound taken from the average
	# would slice the canopy off whichever region grows the biggest tree.
	var reach_max := 0.0
	var scan_max := 1
	for v in flora_variants:
		var vd: Dictionary = v
		reach_max = maxf(reach_max,
			float(int(vd["trunk_max"])) + float(vd["canopy_max"]) * 2.0 + 2.0)
		scan_max = maxi(scan_max,
			int(ceil(float(vd["canopy_max"]) * 1.15 / float(int(vd["cell"])))))
	tree_reach = reach_max
	_tree_scan = scan_max


## One kind of tree. `force_shape` of -1 rolls the shape freely; anything else
## keeps to that family, which is what stops one region's giants setting the
## spacing for a neighbour's ordinary wood.
func _roll_flora(fr: RandomNumberGenerator, force_shape: int,
		slot := 0, slots := 1) -> Dictionary:
	# Each region draws its foliage from ITS OWN stretch of the world's leaf
	# ramp, which is a spread of hues around the biosphere's own colour -- so
	# walking out of one wood and into the next is a change of shade rather than
	# the same green a second time. With one region there is one stretch and it
	# is the whole ramp, which is what a moon and every old world gets.
	var ramp: Array = Blocks.LEAF_IDS
	var span := maxi(3, int(ceil(float(ramp.size()) / float(maxi(slots, 1)))))
	var start := 0
	if slots > 1:
		start = clampi(int(round(float(slot) * float(ramp.size() - span)
			/ float(slots - 1))), 0, ramp.size() - span)
	var pool: Array = ramp.slice(start, start + span)
	var leaves: Array = []
	var n := fr.randi_range(1, 3)
	for i in n:
		leaves.append(pool.pop_at(fr.randi() % pool.size()))
	var wood: int = Blocks.WOOD_IDS[fr.randi() % Blocks.WOOD_IDS.size()]
	# Shape follows the palette: a homely world grows recognisable trees, a
	# strange one is where the giants and the coral live. Colour alone was not
	# enough -- normal tree silhouettes read as Earth whatever their hue.
	var shape := 0
	if strangeness < 0.35:
		shape = fr.randi() % 3
	elif strangeness < 0.65:
		shape = [0, 2, 3, 4][fr.randi() % 4]
	else:
		shape = [3, 4, 4, 2][fr.randi() % 4]
	if not flora_pool.is_empty():
		# A world with its own pool: each region picks any shape in it, so a
		# reef world can be staghorn here, tube sponges there.
		shape = int(flora_pool[fr.randi() % flora_pool.size()])
	elif force_shape >= 0:
		# Same family as the world's own trees. Giants stay giants and coral
		# stays coral; everything else is free to be round, pine or wide, which
		# is the difference you actually read walking from one wood into another.
		shape = force_shape if force_shape >= 3 else (fr.randi() % 3)
	var tmin := fr.randi_range(3, 4)
	var tmax := tmin + fr.randi_range(2, 4)
	var cmin := fr.randf_range(2.5, 3.5)
	var cmax := cmin + fr.randf_range(1.5, 3.0)
	var trad := 0.7
	var cell := TREE_CELL
	if shape == 3:
		# GIANT: a pillar of a tree with a canopy you can build a house under.
		tmin = fr.randi_range(26, 34)
		tmax = tmin + fr.randi_range(6, 14)
		trad = fr.randf_range(2.2, 3.4)
		# A crown in proportion to the trunk. Affordable because giants stand
		# far apart -- the canopy still fits inside a single (much larger) cell.
		cell = 22
		cmin = fr.randf_range(11.0, 13.5)
		cmax = cmin + fr.randf_range(2.0, 4.0)
	elif shape == 4:
		# CORAL: no single canopy -- a cluster of lobes budding off a short,
		# fat stem, which reads as something that grew underwater.
		tmin = fr.randi_range(2, 4)
		tmax = tmin + fr.randi_range(1, 3)
		trad = fr.randf_range(1.0, 1.8)
		cell = 10
		cmin = fr.randf_range(2.4, 3.4)
		cmax = cmin + fr.randf_range(1.2, 2.6)
	elif shape == FLORA_MUSHROOM:
		tmin = fr.randi_range(9, 14)
		tmax = tmin + fr.randi_range(4, 9)
		trad = fr.randf_range(0.8, 1.3)
		cmin = fr.randf_range(5.0, 6.5)
		cmax = cmin + fr.randf_range(1.0, 2.5)
	elif shape == FLORA_DOME:
		tmin = 1
		tmax = 2
		trad = 0.5
		cmin = fr.randf_range(3.5, 4.5)
		cmax = cmin + fr.randf_range(1.0, 2.5)
	elif shape == FLORA_BRANCH:
		tmin = 1
		tmax = 2
		trad = fr.randf_range(0.6, 0.9)
		cmin = fr.randf_range(3.5, 4.5)
		cmax = cmin + fr.randf_range(1.0, 2.5)
	elif shape == FLORA_TUBE:
		tmin = fr.randi_range(4, 7)
		tmax = tmin + fr.randi_range(3, 7)
		trad = fr.randf_range(0.9, 1.4)
		cmin = fr.randf_range(3.0, 3.6)
		cmax = cmin + fr.randf_range(0.4, 1.0)
	elif shape == FLORA_SPIRE:
		tmin = fr.randi_range(7, 12)
		tmax = tmin + fr.randi_range(4, 12)
		trad = fr.randf_range(1.1, 2.0)
		cmin = fr.randf_range(4.0, 4.8)
		cmax = cmin + fr.randf_range(0.4, 1.2)
	if not flora_pool.is_empty():
		for sh in flora_pool:
			cell = maxi(cell, int(FLORA_CELL.get(int(sh), TREE_CELL)))
	elif FLORA_CELL.has(shape) and shape >= FLORA_MUSHROOM:
		cell = int(FLORA_CELL[shape])
	return {"leaves": leaves, "wood": wood, "shape": shape,
		"trunk_min": tmin, "trunk_max": tmax, "trunk_rad": trad,
		"canopy_min": cmin, "canopy_max": cmax, "cell": cell}


## The kind of tree a given region grows.
func _flora_of(vi: int) -> Dictionary:
	if flora_variants.is_empty():
		return {}
	return flora_variants[clampi(vi, 0, flora_variants.size() - 1)]


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

## The terrain surface radius along `dir`. Exposed so the mesher can work out
## how deep a face is buried, and therefore how much daylight reaches it.
func surface_radius(dir: Vector3) -> float:
	return _surf(dir)


## `bpos` is this column's place on the biome axis, passed in by callers that
## have already worked it out. It is one noise lookup, and generation asks for
## the surface height several times per voxel.
func _surf(dir: Vector3, bpos := -1.0) -> float:
	var h := _surf_base(dir, bpos)
	if relief_style == "":
		return h
	return _apply_relief(dir, h)


# --- relief: the shape of the land itself -------------------------------------
#
# What makes a world's ground unlike any on Earth. On top of the rolling hills
# every world has, a world may carry one of these:
#   terraces -- the land in flat steps with sheer risers between: mesas, shelves
#   spires   -- needles of rock standing up out of the plain, some of them huge
#   bubbles  -- the ground swelling into round domes, shoulder to shoulder
#   dunes    -- long curving ridges of drift
#   craters  -- bowls with raised rims, as if the sky had been falling for ages
# Spires, bubbles and craters are laid out on a cellular grid: each cell holds
# at most one, sized by that cell's own random value.

var relief_style := ""
var relief_amp := 0.0
var relief_size := 30.0        # blocks between features
var relief_step := 4.0         # terrace height
var _relief_noise := FastNoiseLite.new()   # distance to the nearest feature
var _relief_value := FastNoiseLite.new()   # that feature's own random value, -1..1


func _derive_relief(cfg: Dictionary) -> void:
	relief_style = str(cfg.get("relief", ""))
	if relief_style == "":
		return
	var r := RandomNumberGenerator.new()
	r.seed = _seed + 6161
	match relief_style:
		"terraces":
			relief_step = float(r.randi_range(3, 6))
		"spires":
			relief_size = r.randf_range(22.0, 38.0)
			relief_amp = r.randf_range(18.0, 34.0)
		"bubbles":
			relief_size = r.randf_range(12.0, 24.0)
			relief_amp = relief_size * r.randf_range(0.28, 0.45)
		"dunes":
			relief_size = r.randf_range(20.0, 34.0)
			relief_amp = r.randf_range(6.0, 10.0)
		"craters":
			relief_size = r.randf_range(26.0, 46.0)
			relief_amp = relief_size * r.randf_range(0.18, 0.28)
	for nz in [_relief_noise, _relief_value]:
		nz.seed = _seed + 6162
		nz.noise_type = FastNoiseLite.TYPE_CELLULAR
		nz.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
		nz.cellular_jitter = 0.85
		nz.fractal_type = FastNoiseLite.FRACTAL_NONE
		nz.frequency = 1.0 / relief_size
	_relief_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	_relief_value.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	if relief_style == "dunes":
		# Dunes are waves, not cells: a warped stripe pattern.
		_relief_value.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_relief_value.frequency = 1.0 / (relief_size * 6.0)


## How far above the ordinary surface relief can reach, and how far below.
func _relief_up() -> float:
	match relief_style:
		"spires", "bubbles", "dunes":
			return relief_amp
		"craters":
			return relief_amp * 0.35
		"terraces":
			return relief_step
	return 0.0


func _relief_down() -> float:
	return relief_amp if relief_style == "craters" else 0.0


func _apply_relief(dir: Vector3, h: float) -> float:
	var x := dir.x * radius
	var y := dir.y * radius
	var z := dir.z * radius
	match relief_style:
		"terraces":
			var f := h / relief_step
			var fl := floorf(f)
			return (fl + smoothstep(0.72, 1.0, f - fl)) * relief_step
		"dunes":
			var warp := _relief_value.get_noise_3d(x, y, z)
			var ph := (x * 0.8 + y * 0.35 + z * 0.55) / relief_size + warp * 3.0
			var w := 0.5 + 0.5 * sin(ph * TAU)
			# Steep lee side, long windward slope.
			return h + relief_amp * w * w * (0.6 + 0.4 * warp)
	var d := (_relief_noise.get_noise_3d(x, y, z) + 1.0) * relief_size
	var cv := _relief_value.get_noise_3d(x, y, z)   # -1..1, one per feature
	match relief_style:
		"spires":
			if cv < -0.2:
				return h                   # most cells stand empty
			var rad := relief_size * (0.1 + 0.08 * (cv + 1.0))
			if d >= rad:
				return h
			var k := 1.0 - d / rad
			var tall := relief_amp * (0.35 + 0.65 * (cv + 0.2) / 1.2)
			return h + tall * pow(k, 0.55)
		"bubbles":
			var rad2 := relief_size * (0.32 + 0.12 * cv)
			if d >= rad2:
				return h
			var t := d / rad2
			return h + relief_amp * (0.55 + 0.45 * cv) * sqrt(1.0 - t * t)
		"craters":
			if cv < 0.0:
				return h
			var rad3 := relief_size * (0.2 + 0.18 * cv)
			var t3 := d / rad3
			if t3 >= 1.6:
				return h
			var depth := relief_amp * (0.4 + 0.6 * cv)
			var bowl := (1.0 - t3 * t3) * depth if t3 < 1.0 else 0.0
			var rim := depth * 0.35 * exp(-pow((t3 - 1.0) / 0.22, 2.0))
			return h - bowl + rim
	return h


func _surf_base(dir: Vector3, bpos := -1.0) -> float:
	var x := dir.x * radius
	var y := dir.y * radius
	var z := dir.z * radius
	var n := surface_noise.get_noise_3d(x, y, z)
	var amp := terrain_amp
	var lift := 0.0
	if not _b_amp.is_empty():
		var relief := _biome_relief(bpos if bpos >= 0.0 else _biome_pos(dir))
		amp = terrain_amp * relief.x
		lift = relief.y
	var h := radius + n * amp + lift * terrain_amp
	if mountain_amp <= 0.0:
		return h
	# Ranges only rise where the land is ALREADY high. Ridged noise on its own
	# webs the entire planet with ridges, which makes a mountain world rather
	# than a world with mountains in it; gating on the rolling-hills height that
	# has just been computed gathers them into the high country and leaves the
	# basins rolling. It costs nothing -- the number is already here.
	#
	# Read off the raw noise rather than off the finished height, which is the
	# same number on a world without regions and the RIGHT one on a world with
	# them: a basin is lower because it is a basin, not because the land there
	# is low, and gating on the finished height would refuse it mountains on
	# principle while giving every highland a range whether the land called for
	# one or not.
	var where := smoothstep(0.0, 0.65, n)
	if where <= 0.0:
		return h
	var m := mountain_noise.get_noise_3d(x, y, z)
	if m <= MOUNTAIN_CUTOFF:
		return h
	# Squared, so a range rises out of foothills instead of out of a kerb.
	var t := (m - MOUNTAIN_CUTOFF) / (1.0 - MOUNTAIN_CUTOFF)
	var mh := t * t * mountain_amp * where
	return h + lerpf(mh, floorf(mh / TERRACE_STEP) * TERRACE_STEP, TERRACE_MIX)


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
## `tcache` is a per-build memo of which cells hold trees. It is passed in
## rather than kept on the planet because the mesher runs on worker threads: a
## dictionary shared between them would be a data race, while one created per
## chunk build is private to that task. Callers outside the mesher pass nothing
## and simply pay full price, which is fine for the handful of samples a
## raycast or a spawn check makes.
func generation_sample(gx: int, gy: int, gz: int, tcache = null) -> int:
	var p := Vector3(gx, gy, gz)
	var d := _norm(p)
	if d > _max_reach() + 2.0:
		return Blocks.AIR
	# Wrecks, outposts, ruins and vaults come first: a site's walls stand
	# through a cave, and its rooms are carved out of whatever rock is there.
	if not site_density.is_empty():
		var sb := _site_block(Vector3i(gx, gy, gz), tcache)
		if sb >= 0:
			return sb
	var l2 := p.length()
	var dir := p / maxf(l2, 0.0001)
	# One lookup, shared by the height below, the ground material and the
	# vegetation -- all three are properties of this column, not of this voxel.
	var bpos := _biome_pos(dir) if not _b_amp.is_empty() else -1.0
	var surf := _surf(dir, bpos)
	var top := pal_top
	var sub := pal_sub
	var grass_here := grass_density
	if bpos >= 0.0:
		var slot := _biome_slot(bpos)
		match _b_top[slot]:
			1: top = pal_sub
			2: top = pal_rock
		sub = pal_sub if _b_top[slot] < 2 else pal_rock
		grass_here = grass_density * _b_grass[slot]

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
			var t := _tree_at(p, dir, surf, tcache)
			if t != Blocks.AIR:
				return t
		# Ground cover, in the ONE cell above the surface and only over soil.
		if grass_here > 0.0 and d - surf <= 1.0 and top == Blocks.GRASS \
				and (water_style == WATER_NONE or surf > water_level + 0.5) \
				and _hash01(Vector3i(gx, gy, gz), 91) < grass_here:
			# And only where there is actually SOIL under it. "One cell above the
			# surface" is a nominal height, not a promise that anything is there --
			# where a cave breaks through the ground has been carved away, and the
			# grass was left standing in mid-air over the hole.
			var gup := _axis_of(dir) if shape_cube else dir
			var under := generation_sample(gx - roundi(gup.x), gy - roundi(gup.y),
					gz - roundi(gup.z), tcache)
			if under != Blocks.AIR and under != Blocks.WATER:
				return Blocks.TALL_GRASS
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
		return top
	if depth < 4.0:
		return sub
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
## Shortest distance from a point to a line segment. Used to grow branches
## between a coral tree's stem and its lobes.
func _dist_to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var d := ab.length_squared()
	if d < 0.0001:
		return (p - a).length()
	var t := clampf((p - a).dot(ab) / d, 0.0, 1.0)
	return (p - (a + ab * t)).length()


## The tree, if any, rooted in one cell. Empty array means none. Split out of
## _tree_at so it can be memoised per chunk build (see the tcache argument).
func _tree_in_cell(cc: Vector3i, c: float) -> Array:
	var cdir := (Vector3(cc) * c + Vector3(c * 0.5, c * 0.5, c * 0.5)).normalized()
	# The region the tree is ROOTED in decides whether it is there at all, which
	# is what makes a forest a forest and the plain beside it a plain. Tested
	# here rather than per voxel: a tree that half exists because its canopy
	# crosses a border is a tree with half a canopy.
	var density := tree_density
	var vi := 0
	if not _b_amp.is_empty():
		vi = _biome_slot(_biome_pos(cdir))
		density *= _b_trees[vi]
	if _hash01(cc, 0) >= density:
		return []
	var base := _surface_point(cdir)
	# one tree per cell: only if its base actually sits in this cell
	if Vector3i(floori(base.x / c), floori(base.y / c), floori(base.z / c)) != cc:
		return []
	# no trees standing in water -- skip if the base is at/below sea level
	if water_style != WATER_NONE and _norm(base) <= water_level:
		return []
	# no trees rooted inside a settlement -- rejecting at the ROOT (not per-voxel)
	# means a canopy can never end up sliced in half by a wall; the land people
	# build on reads as actually cleared
	if not settlements.is_empty() and _tree_blocked_by_settlement(base):
		return []
	# On a cube, trees grow straight out of the flat face (axis-aligned), not
	# toward the center -- otherwise they lean on diagonal faces.
	var up := _axis_of(cdir) if shape_cube else cdir
	var fv := _flora_of(vi)
	var tmin := int(fv.get("trunk_min", trunk_min))
	var tmax := int(fv.get("trunk_max", trunk_max))
	var cmin := float(fv.get("canopy_min", canopy_min))
	var cmax := float(fv.get("canopy_max", canopy_max))
	var th := tmin + int(_hash01(cc, 1) * float(tmax - tmin + 1))
	var cr := cmin + _hash01(cc, 2) * (cmax - cmin)
	# The cell itself rides along: every hash that decides this tree's look --
	# lobe angles, which leaf colour, canopy wobble -- is seeded from it. So
	# does the KIND, so a canopy is built from the same tree its trunk is.
	return [base, up, th, cr, cc, vi]


func _tree_at(p: Vector3, dir: Vector3, _surf_unused: float, tcache = null) -> int:
	var c := float(tree_cell)
	# The surface point BENEATH p, in the same frame the trees are built in.
	#
	# This used to project p RADIALLY (_surface_point(p.normalized())), but on a
	# cube planet a tree grows along its face NORMAL, not toward the core. The
	# two disagree by the voxel's height times its distance from the face centre,
	# over the radius -- 30 blocks at 40 up and 1000 off centre, which is more
	# than a whole tree cell. The canopy of a tall tree therefore looked itself up
	# in the WRONG cell: its own cell fell outside the scan, so no leaves were
	# generated above the trunk, while the cell it drifted into supplied leaves
	# off to one side. That is the trees whose foliage sits beside them instead of
	# on top, and why it only afflicts tall trees far from a face centre.
	var sp := _surface_point(dir)
	if shape_cube:
		# Keep the HEIGHT that radial projection found, but put it back at p's own
		# tangential position. That costs a handful of vector ops and no extra
		# noise lookup, and the leftover error -- sampling the height a little way
		# off, where the terrain is a few blocks different -- can only ever shift
		# the cell along the up axis, which the neighbour scan already covers.
		var up_a := _axis_of(dir)
		sp = (p - up_a * p.dot(up_a)) + up_a * sp.dot(up_a)
	var scell := Vector3i(floori(sp.x / c), floori(sp.y / c), floori(sp.z / c))
	# How many neighbouring cells can reach this voxel. Only the giants need a
	# wider sweep, and paying for it everywhere would slow generation on every
	# world to fix a problem two of them have.
	var sr := _tree_scan
	# Which trees can reach ANY voxel in this column is a property of the column,
	# not of the voxel -- so the whole neighbourhood scan is memoised per surface
	# cell. A chunk is thousands of voxels over a handful of columns, and this
	# turns a 27-cell sweep per voxel into one dictionary lookup plus a walk over
	# the nought-to-three trees that are actually nearby.
	var cells = null
	var lists = null
	if tcache != null:
		cells = tcache.get("c")
		if cells == null:
			cells = {}
			tcache["c"] = cells
		lists = tcache.get("l")
		if lists == null:
			lists = {}
			tcache["l"] = lists
	var near = lists.get(scell) if lists != null else null
	if near == null:
		near = []
		for dx in range(-sr, sr + 1):
			for dy in range(-sr, sr + 1):
				for dz in range(-sr, sr + 1):
					var ncell := scell + Vector3i(dx, dy, dz)
					var got = cells.get(ncell) if cells != null else null
					if got == null:
						got = _tree_in_cell(ncell, c)
						if cells != null:
							cells[ncell] = got
					if not (got as Array).is_empty():
						near.append(got)
		if lists != null:
			lists[scell] = near
	for info in near:
		var got := _tree_block_for(p, info)
		if got != Blocks.AIR:
			return got
	return Blocks.AIR


## What one tree puts at `p`, given that tree's own definition.
##
## Split out of _tree_at so a tree GROWN from a sapling can be the same tree as
## one the world put there. A second description of a canopy is a second
## canopy: the one written by hand for saplings was a diamond of leaves, on
## planets whose trees are pines.
func _tree_block_for(p: Vector3, info: Array) -> int:
	var base: Vector3 = info[0]
	var up: Vector3 = info[1]
	var th: int = info[2]
	var cr: float = info[3]
	var cc: Vector3i = info[4]
	# Which kind of tree this one is. Older callers pass five elements and mean
	# the world's ordinary trees.
	var fv := _flora_of(int(info[5]) if info.size() > 5 else 0)
	var f_leaves: Array = fv.get("leaves", flora_leaves)
	var f_wood: int = int(fv.get("wood", flora_wood))
	var f_shape: int = int(fv.get("shape", flora_shape))
	var f_rad: float = float(fv.get("trunk_rad", trunk_rad))
	if f_shape >= FLORA_MUSHROOM:
		return _alien_growth_block(p, base, up, th, cr, cc, f_shape, f_leaves, f_wood, f_rad)
	var rel := p - base
	var along := rel.dot(up)
	var horiz := (rel - up * along).length()
	# Trunk. It starts BELOW the surface point, because a thick trunk
	# spans several ground columns and on any slope some of them sit
	# lower -- without this the uphill side floats and the tree stops
	# reading as rooted in anything.
	var sink := 1.0 + f_rad * 2.0
	if along >= -sink and along <= float(th) and horiz < f_rad:
		return f_wood
	# Nothing else in this tree can reach p, so skip the canopy and
	# coral-lobe work outright. That work is the expensive half of
	# terrain generation -- a coral tree walks every lobe with trig
	# and hashing, once per candidate cell -- and most candidate
	# cells are nowhere near the voxel being asked about. The bounds
	# are deliberately loose; they are verified to reproduce the
	# previous terrain voxel-for-voxel.
	if horiz > cr * 1.3 + f_rad + 1.0 						or along > float(th) * 1.15 + cr * 1.6 + 1.0 						or along < minf(-sink - 1.0, float(th) - cr * 2.2 - 1.0):
		return Blocks.AIR
	if f_shape == 4:
		# CORAL: lobes budding off the stem at different heights and
		# bearings. Each is joined to the stem by a real BRANCH --
		# without one the lobes hang in mid-air well clear of the
		# trunk, which is what made the leaves look unattached.
		var ax := up.cross(Vector3(1, 0, 0))
		if ax.length_squared() < 0.01:
			ax = up.cross(Vector3(0, 0, 1))
		ax = ax.normalized()
		var bx := up.cross(ax).normalized()
		# One lobe sits ON the stem rather than beside it. Every other
		# lobe is thrown clear of the axis by 0.3 to 0.7 of the canopy
		# radius while being only 0.3 to 0.45 wide, so the top of the
		# stem itself was usually left uncovered: measured, 71% of
		# coral stems had nothing at all directly overhead. From the
		# ground that reads as a bare post with foliage floating
		# around it, which is what "trees with no leaves" turns out
		# to be on these worlds.
		if (p - (base + up * (float(th) + cr * 0.15))).length() 							< cr * (0.45 + _hash01(cc, 70) * 0.20):
			return f_leaves[int(_hash01(cc, 71)
				* f_leaves.size()) % f_leaves.size()]
		var lobes := 3 + int(_hash01(cc, 8) * 3.0)
		var arms: Array = []
		for lb in lobes:
			var a := _hash01(cc, 20 + lb) * TAU
			var hgt := float(th) * (0.5 + _hash01(cc, 30 + lb) * 0.6)
			# Lobe centre and radius are kept so that centre+radius
			# stays inside the reach the neighbour scan actually
			# covers (1.15x the canopy). They used to sum to 2.2x, so
			# the outer half of every lobe fell in cells no voxel ever
			# consulted and was simply missing.
			var reach := cr * (0.30 + _hash01(cc, 40 + lb) * 0.40)
			var lc := base + up * hgt + (ax * cos(a) + bx * sin(a)) * reach
			var lr := cr * (0.30 + _hash01(cc, 50 + lb) * 0.15)
			if (p - lc).length() < lr:
				return f_leaves[int(_hash01(cc, 60 + lb)
					* f_leaves.size()) % f_leaves.size()]
			arms.append([base + up * (hgt * 0.55), lc])
		for arm in arms:
			if _dist_to_segment(p, arm[0], arm[1]) < maxf(f_rad * 0.55, 0.75):
				return f_wood
		return Blocks.AIR
	# canopy (ellipsoid, shape-dependent, with lumpy edge)
	var vscale := 1.5 if f_shape == 1 else (0.7 if f_shape == 2 else 1.0)
	if f_shape == 3:
		vscale = 0.55     # a giant spreads far wider than it is deep
	var ch := cr * vscale
	# Overlap the crown with the top of the trunk rather than
	# balancing it above: a gap there is what makes leaves and log
	# look like separate objects.
	var center := base + up * (float(th) - ch * 0.25)
	var rc := p - center
	var cvert := rc.dot(up)
	var choriz := (rc - up * cvert).length()
	var rad := cr
	if f_shape == 1:  # pine: taper toward the top
		var t := clampf((cvert + ch) / (2.0 * ch), 0.0, 1.0)
		rad = cr * (1.0 - t * 0.8)
	var e := (choriz * choriz) / maxf(rad * rad, 0.01) + (cvert * cvert) / maxf(ch * ch, 0.01)
	# Lumpy canopy edge, but COARSE: a per-voxel roll speckles single
	# leaves off the rim, and a leaf one voxel clear of the canopy
	# reads as not belonging to the tree. Sampling at half
	# resolution makes the wobble happen in clumps that stay
	# attached, and the range is tighter for the same reason.
	# ADDITIVE only. A lump that can also bite INTO the canopy carves
	# notches in its surface, and a notch deep enough to cut a rim
	# voxel loose leaves foliage floating clear of the tree. Adding
	# outward can only ever hang a clump off a face it touches.
	var lump := maxf(0.0, _hash01(Vector3i(floori(p.x * 0.5),
		floori(p.y * 0.5), floori(p.z * 0.5)), 7) * 0.26 - 0.09)
	if e < 1.0 + lump:
		var li: int = f_leaves[int(_hash01(cc, 3) * f_leaves.size()) % f_leaves.size()]
		return li
	return Blocks.AIR
	return Blocks.AIR


## The alien growths (FLORA_MUSHROOM and up): what one of them puts at `p`.
##
## Every one stays inside the bounds the neighbour scan and tree_reach promise:
## no further out than 1.15 x its canopy radius, no higher than its height plus
## twice that radius.
func _alien_growth_block(p: Vector3, base: Vector3, up: Vector3, th: int, cr: float,
		cc: Vector3i, shape: int, leaves: Array, wood: int, rad: float) -> int:
	var rel := p - base
	var along := rel.dot(up)
	var flat := rel - up * along
	var horiz := flat.length()
	if horiz > cr * 1.15 + 2.0 or along < -2.5 or along > float(th) + cr * 2.0 + 1.0:
		return Blocks.AIR
	var ax := up.cross(Vector3(1, 0, 0))
	if ax.length_squared() < 0.01:
		ax = up.cross(Vector3(0, 0, 1))
	ax = ax.normalized()
	var bx := up.cross(ax).normalized()
	var main_leaf: int = leaves[int(_hash01(cc, 3) * leaves.size()) % leaves.size()]
	var other_leaf: int = leaves[(leaves.find(main_leaf) + 1) % leaves.size()]
	if other_leaf == main_leaf:
		# One-colour world: the accent is the next shade along the ramp.
		var li := Blocks.LEAF_IDS.find(main_leaf)
		other_leaf = Blocks.LEAF_IDS[(li + 3) % Blocks.LEAF_IDS.size()]
	match shape:
		FLORA_MUSHROOM:
			# The stem leans a little as it rises, and the cap goes with it.
			var lean_a := _hash01(cc, 80) * TAU
			var lean := _hash01(cc, 81) * minf(1.6, cr * 0.25)
			var ldir := ax * cos(lean_a) + bx * sin(lean_a)
			var k := clampf(along / float(th), 0.0, 1.0)
			var off := ldir * lean * k * k
			var sh := (flat - off).length()
			var sink := 1.0 + rad * 2.0
			if along >= -sink and along <= float(th) and sh < rad * (1.15 - 0.25 * k):
				return wood
			# The cap: an umbrella. A flattened dome on top, a flat underside
			# of gills in the accent colour, and a rim that hangs down past it
			# -- the shape that says "mushroom" from any distance.
			var ch := cr * 0.55
			var cvert := along - float(th)
			var ch_h := (flat - ldir * lean).length()
			if cvert < -1.6 or cvert > ch or ch_h > cr:
				return Blocks.AIR
			if cvert >= 0.0:
				var e := (ch_h * ch_h) / (cr * cr) + (cvert * cvert) / (ch * ch)
				if e >= 1.0:
					return Blocks.AIR
				if cvert < 1.0 and ch_h < cr * 0.88:
					return other_leaf   # the gills, seen from beneath
				# Spots, in clumps two voxels across so they read as spots.
				var spot := _hash01(Vector3i(floori(p.x * 0.5), floori(p.y * 0.5),
					floori(p.z * 0.5)), 82)
				return other_leaf if spot < 0.14 else main_leaf
			# The rim, hanging down round the edge.
			if ch_h > cr * 0.84:
				return main_leaf
			return Blocks.AIR
		FLORA_DOME:
			# A hollow blister half-sunk in the ground, and up to two smaller
			# ones budding off its side.
			var domes := [[base - up * cr * 0.15, cr]]
			var buds := int(_hash01(cc, 83) * 3.0)
			for b in buds:
				var a := _hash01(cc, 84 + b) * TAU
				var br := cr * (0.35 + _hash01(cc, 86 + b) * 0.15)
				domes.append([base + (ax * cos(a) + bx * sin(a)) * cr * 0.62 - up * br * 0.3, br])
			for i in domes.size():
				var dc: Vector3 = domes[i][0]
				var dr: float = domes[i][1]
				var dist := (p - dc).length()
				if dist < dr and dist > dr - 1.3:
					# A ring of the accent colour round each crown.
					var hgt := (p - dc).dot(up) / dr
					if hgt > 0.78:
						return other_leaf
					return main_leaf
			return Blocks.AIR
		FLORA_BRANCH:
			# Staghorn: arms reaching up and out from the base, each forking
			# once, the ends swelling into bright tips.
			var arms := 3 + int(_hash01(cc, 90) * 3.0)
			var length := cr * 0.85
			var thick := maxf(rad, 0.6)
			for i in arms:
				var a := _hash01(cc, 91 + i) * TAU
				var tilt := deg_to_rad(22.0 + _hash01(cc, 101 + i) * 26.0)
				var out := ax * cos(a) + bx * sin(a)
				var p0 := base + up * 0.4
				var p1 := p0 + (up * cos(tilt) + out * sin(tilt)) * length
				if _dist_to_segment(p, p0, p1) < thick:
					return main_leaf
				for f in 2:
					var fa := a + (0.55 if f == 0 else -0.55)
					var fout := ax * cos(fa) + bx * sin(fa)
					var ftilt := tilt * 0.5
					var p2 := p1 + (up * cos(ftilt) + fout * sin(ftilt)) * length * 0.5
					if _dist_to_segment(p, p1, p2) < thick * 0.8:
						return main_leaf
					if (p - p2).length() < thick * 1.35:
						return other_leaf
			return Blocks.AIR
		FLORA_TUBE:
			# Pipes of different heights, open at the top, hollow all the way down.
			var tubes := 3 + int(_hash01(cc, 110) * 4.0)
			for i in tubes:
				var a := _hash01(cc, 111 + i) * TAU
				var off := (ax * cos(a) + bx * sin(a)) * cr * 0.6 * _hash01(cc, 121 + i)
				var tr := rad * (0.8 + _hash01(cc, 131 + i) * 0.5)
				var h := float(th) * (0.45 + _hash01(cc, 141 + i) * 0.55)
				if along > h or along < -2.0:
					continue
				var dh := (flat - off).length()
				if dh < tr and dh > tr - 0.8:
					return other_leaf if along > h - 1.0 else main_leaf
			return Blocks.AIR
		FLORA_SPIRE:
			# A needle, leaning, banded in two colours; sometimes a smaller twin.
			var spires := 1 + (1 if _hash01(cc, 150) < 0.4 else 0)
			for i in spires:
				var a := _hash01(cc, 151 + i) * TAU
				var out := ax * cos(a) + bx * sin(a)
				var hgt := float(th) * (1.0 if i == 0 else 0.55)
				var r0 := rad * (1.0 if i == 0 else 0.65)
				var foot := base + (out * cr * 0.45 if i == 1 else Vector3.ZERO) - up * 1.5
				var lean := minf(cr * 0.35, hgt * 0.2) * _hash01(cc, 153 + i)
				var tip := foot + up * (hgt + 1.5) + out * lean
				var axis := tip - foot
				var t := clampf((p - foot).dot(axis) / axis.length_squared(), 0.0, 1.0)
				var dist := (p - (foot + axis * t)).length()
				if dist < r0 * pow(1.0 - t, 0.9) + 0.35:
					return other_leaf if int(floor(t * hgt / 2.5)) % 2 == 1 else main_leaf
			return Blocks.AIR
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
	var cc := chunk_of(v)
	var d = _edits_by_chunk.get(cc)
	if d != null and d.has(v):
		return d[v]
	# The chunk's generated terrain, if it has been built -- the same answer the
	# generator would give, without the noise. Everything that asks the world
	# about one cell at a time goes through here: mining, water, a falling tree
	# looking for what it stands on.
	var g = _gen_cache.get(cc)
	if g != null:
		var a: PackedInt32Array = g
		if a.size() == 1:
			return a[0]
		var l := v - cc * CS
		return a[l.x + l.y * CS + l.z * CS * CS]
	return generation_sample(v.x, v.y, v.z)


func is_solid(v: Vector3i) -> bool:
	return get_id(v) != Blocks.AIR


# --- gravity ------------------------------------------------------------------

## Gravity acceleration vector (world space) this planet exerts at a world point.
func gravity_at(world_pos: Vector3) -> Vector3:
	var to_center := global_position - world_pos
	if to_center.length_squared() < 0.000001:
		return Vector3.ZERO
	# A CUBE pulls toward the face you are over, not toward its middle. Pulling
	# radially is what a sphere does, and on a cube it means that everywhere
	# except the centre of a face the ground is not level: it tilts more the
	# further out you walk, and at an edge it is pulling you sideways as much as
	# down. Everything downstream was quietly correcting for that by snapping
	# the direction to an axis itself, which is the same answer arrived at six
	# times over -- and creatures and dropped things were not doing it at all.
	var dir := -_axis_of(-to_center) if shape_cube else to_center.normalized()
	# Distance measured the same way the planet is SHAPED, or the corners read as
	# far away and their gravity fades for no reason a player could see.
	var d := _norm(-to_center)
	var g: float
	if d >= radius:
		g = surface_gravity * (radius * radius) / (d * d)  # inverse-square falloff outside
	else:
		g = surface_gravity * (d / radius)                 # falls linearly to 0 at the core
	return dir * g


# --- coordinate helpers -------------------------------------------------------

## What each placed block was made from: voxel -> tag (see Blocks.make_tag).
## Cleared whenever the block there changes, saved with the world, sent to
## every player with the edit, handed back when it is mined and carried aboard
## a ship with it.
var block_tags := {}


## Put a block down along with what it was made from.
func set_block_tagged(v: Vector3i, id: int, tag: Dictionary, quiet := false) -> void:
	set_block(v, id, quiet)
	if tag != null and not tag.is_empty() and id != Blocks.AIR:
		block_tags[v] = tag.duplicate(true)


## Was this cell put there by someone, rather than generated?
func is_placed(v: Vector3i) -> bool:
	var e = _edits_by_chunk.get(chunk_of(v))
	return e != null and (e as Dictionary).has(v) and int(e[v]) != Blocks.AIR


func world_to_voxel(world_pos: Vector3) -> Vector3i:
	var local := to_local(world_pos)
	return Vector3i(floori(local.x), floori(local.y), floori(local.z))

func chunk_of(v: Vector3i) -> Vector3i:
	return Vector3i(floori(float(v.x) / CS), floori(float(v.y) / CS), floori(float(v.z) / CS))


# --- streaming ----------------------------------------------------------------

## What the last FULL scan decided it wanted. Kept so the periodic retry below
## does not have to work it out again -- which is the whole fix: re-deciding
## which chunks exist is thousands of cells of geometry, and re-checking whether
## the ones we already chose have arrived is a dictionary lookup each.
var _wanted := {}
var _gen_cache := {}      # chunk -> its generated terrain; see Chunk.GEN_KEY
var _bslot_cache := {}    # chunk -> its region slots
var _depth_cache := {}    # chunk -> its skylight columns' depths; see Chunk.DEPTH_KEY
var _ground_memo := {}    # chunk -> terrain height over it; see _chunk_ground
var _unload_later := {}   # left range while still building; see _unload_stragglers
var _stream_last_cc0 := Vector3i(0x7fffffff, 0, 0)  # sentinel: never a real chunk coord
var _stream_last_rd := -1
var _stream_last_ms := 0

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
	# Re-scan periodically even when standing still. The early-out below only
	# fires when you cross a chunk boundary, so a chunk that failed to load --
	# dropped from the queue, or whose build was discarded -- was never asked
	# for again and simply stayed missing until you happened to walk far enough
	# away and back. That is the terrain that "never loads".
	var now := Time.get_ticks_msec()
	var moved := cc0 != _stream_last_cc0 or rd != _stream_last_rd
	if not moved and now - _stream_last_ms < 400:
		return
	_stream_last_ms = now
	if not moved:
		# Standing still. The set of chunks we want has not changed, so nothing
		# here needs recomputing -- only asking again for the ones that never
		# turned up. This used to run the entire scan below, every 400ms, for
		# as long as the game was open: measured at 49ms a time and 12% of the
		# frame budget, with 73ms spikes.
		_requeue_missing(cc0)
		_unload_stragglers()
		return
	var prev := _stream_last_cc0
	var prev_rd := _stream_last_rd
	_stream_last_cc0 = cc0
	_stream_last_rd = rd
	var step := cc0 - prev
	if prev_rd == rd and not _wanted.is_empty() 			and absi(step.x) <= 1 and absi(step.y) <= 1 and absi(step.z) <= 1:
		_stream_step(prev, cc0, rd)
		return
	_stream_full(cc0, rd)


## The whole neighbourhood from scratch. Only when there is nothing to step
## from: the first scan, a change of render distance, or a jump of more than a
## chunk (a respawn, a landing).
func _stream_full(cc0: Vector3i, rd: int) -> void:
	var wanted := {}
	for dx in range(-rd, rd + 1):
		for dy in range(-rd, rd + 1):
			for dz in range(-rd, rd + 1):
				var cc := cc0 + Vector3i(dx, dy, dz)
				if _want_chunk(cc, cc0):
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
			# Nothing needs stand-in collision in a chunk that is gone.
			_clear_temp_colliders(cc, true)
			_gen_cache.erase(cc)
			_bslot_cache.erase(cc)
			_depth_cache.erase(cc)
	_wanted = wanted
	_drop_unwanted_queued()
	_sort_load_queue(cc0)


## One chunk's worth of walking: only the slab coming into range and the slab
## going out of it are looked at.
##
## The full scan asks about every chunk in the cube -- 9261 of them at render
## distance 10 -- and then sorted the whole load queue with a script-side
## comparison. Together that was 40-75ms, once per chunk boundary crossed:
## a hitch every couple of seconds of walking. A step changes a few hundred
## chunks at most, and whether a chunk could hold ground is a fixed fact about
## it, so the rest of the cube's answers are still right from last time.
func _stream_step(prev: Vector3i, cc0: Vector3i, rd: int) -> void:
	# Coming into range: in the new cube, not in the old one.
	for dx in range(-rd, rd + 1):
		for dy in range(-rd, rd + 1):
			for dz in range(-rd, rd + 1):
				var cc := cc0 + Vector3i(dx, dy, dz)
				var o := cc - prev
				if absi(o.x) <= rd and absi(o.y) <= rd and absi(o.z) <= rd:
					continue
				if _want_chunk(cc, cc0):
					_want_add(cc)
	# Going out of range: in the old cube, not in the new one.
	var dropped := false
	for dx in range(-rd, rd + 1):
		for dy in range(-rd, rd + 1):
			for dz in range(-rd, rd + 1):
				var cc := prev + Vector3i(dx, dy, dz)
				var o := cc - cc0
				if absi(o.x) <= rd and absi(o.y) <= rd and absi(o.z) <= rd:
					continue
				if _want_drop(cc):
					dropped = true
	# The deep chunks kept loaded around the player moved with them: whatever
	# is in the old or the new near cube, and still in range, is decided again.
	for dx in range(-NEAR_CHUNKS, NEAR_CHUNKS + 1):
		for dy in range(-NEAR_CHUNKS, NEAR_CHUNKS + 1):
			for dz in range(-NEAR_CHUNKS, NEAR_CHUNKS + 1):
				for c0 in [prev, cc0]:
					var cc: Vector3i = c0 + Vector3i(dx, dy, dz)
					var o := cc - cc0
					if absi(o.x) > rd or absi(o.y) > rd or absi(o.z) > rd:
						continue
					if _want_chunk(cc, cc0):
						_want_add(cc)
					elif _wanted.has(cc) and _want_drop(cc):
						dropped = true
	_unload_stragglers()
	if dropped:
		_drop_unwanted_queued()
	_sort_load_queue(cc0)


## How far below the lowest ground anywhere on this world a chunk is still
## loaded for its own sake. Deeper than that, it is only loaded when the player
## is within NEAR_CHUNKS of it.
##
## The streamed cube is 21 chunks tall at render distance 10 -- 336 blocks -- and
## on a big world every one of those chunks is inside the planet, so all of them
## qualified. Chunk builds used to be slow enough that the world never got
## round to the buried ones; once a build took a fifth of the time, it did, and
## the loaded count climbed by about forty a second without stopping, dragging
## draw calls and physics with it, for rock nobody could see. A cave deep
## enough to fall outside this band is dark and closed anyway, and loads around
## you the moment you are in it.
const DEEP_BAND := 48.0
const NEAR_CHUNKS := 3


## Is this chunk worth loading with the player's chunk at `cc0`?
func _want_chunk(cc: Vector3i, cc0: Vector3i) -> bool:
	if not _chunk_possibly_solid(cc):
		return false
	var o := cc - cc0
	if absi(o.x) <= NEAR_CHUNKS and absi(o.y) <= NEAR_CHUNKS and absi(o.z) <= NEAR_CHUNKS:
		return true
	# The farthest corner from the centre is the shallowest the chunk gets.
	var lo := Vector3(cc * CS)
	var far := 0.0
	for i in 8:
		var corner := lo + Vector3(CS if (i & 1) else 0, CS if (i & 2) else 0, CS if (i & 4) else 0)
		far = maxf(far, _norm(corner))
	# Deeper than the band below the lowest ground ANYWHERE: settled without
	# asking the terrain. Otherwise it is measured against the ground right
	# above it -- the world's lowest basin is far below the hill you are
	# standing on, and measuring from there kept nearly everything.
	if far < _min_surface() - DEEP_BAND:
		return false
	var ground := _chunk_ground(cc)
	if far < ground - DEEP_BAND:
		return false
	# And the other way: open sky well above the ground, the tallest tree or
	# building and the sea, holding nothing anybody has built. Those chunks are
	# empty -- but there were thousands of them, each a node and a build.
	var hi := lo + Vector3(CS, CS, CS)
	var near := _norm(Vector3(clampf(0.0, lo.x, hi.x), clampf(0.0, lo.y, hi.y), clampf(0.0, lo.z, hi.z)))
	if near > maxf(ground + maxf(tree_reach, settlement_reach) + 2.0, water_level + 1.0) 			and not _edits_by_chunk.has(cc) and not _parts_by_chunk.has(cc):
		return false
	return true


## The terrain height over a chunk, asked once per chunk and remembered: a step
## across a chunk boundary re-decides several hundred chunks, and the height
## noise is the expensive part of deciding. Keyed by chunk and never stale --
## terrain is a function of the seed.
func _chunk_ground(cc: Vector3i) -> float:
	var g = _ground_memo.get(cc)
	if g != null:
		return g
	var mid := Vector3(cc * CS) + Vector3(CS, CS, CS) * 0.5
	var h := _surf(mid / maxf(mid.length(), 0.0001))
	_ground_memo[cc] = h
	return h


## The lowest the ground gets anywhere on this world, allowing for the deepest
## basin a region can sink to. Conservative: a little lower than the real floor
## costs a few extra chunks, a little higher would leave holes in valleys.
func _min_surface() -> float:
	var b_amp := 1.0
	var b_sink := 0.0
	for i in _b_amp.size():
		b_amp = maxf(b_amp, _b_amp[i])
		b_sink = maxf(b_sink, absf(_b_lift[i]))
	return radius - terrain_amp * (b_amp + b_sink) - _relief_down() - 2.0


func _want_add(cc: Vector3i) -> void:
	_wanted[cc] = true
	_unload_later.erase(cc)
	if not loaded_chunks.has(cc) and not _load_queue_set.has(cc):
		_load_queue.append(cc)
		_load_queue_set[cc] = true


## Returns whether it was waiting in the load queue, which then needs pruning.
func _want_drop(cc: Vector3i) -> bool:
	_wanted.erase(cc)
	if loaded_chunks.has(cc):
		_unload_later[cc] = true
	return _load_queue_set.has(cc)


## Unload whatever has left range, except chunks still being built -- those are
## tried again on the next scan, standing still or not. The full scan used to
## pick these up the next time it ran; a step never revisits them, so they are
## remembered here instead of being left loaded for ever.
func _unload_stragglers() -> void:
	if _unload_later.is_empty():
		return
	for cc in _unload_later.keys():
		if _wanted.has(cc):
			_unload_later.erase(cc)      # walked back into range before it went
			continue
		if _inflight.has(cc):
			continue
		_unload_later.erase(cc)
		var node = loaded_chunks.get(cc)
		if node != null:
			loaded_chunks.erase(cc)
			(node as Node).queue_free()
			_clear_temp_colliders(cc, true)
			_gen_cache.erase(cc)
			_bslot_cache.erase(cc)
			_depth_cache.erase(cc)


func _drop_unwanted_queued() -> void:
	var kept: Array[Vector3i] = []
	for cc in _load_queue:
		if _wanted.has(cc):
			kept.append(cc)
	_load_queue = kept
	_load_queue_set.clear()
	for cc in _load_queue:
		_load_queue_set[cc] = true


## Nearest first, so the world fills in outward from the player.
##
## Sorted as packed integers -- distance in the high bits, position in the queue
## in the low ones -- so the comparison happens in the engine rather than in a
## script callback. For a few thousand chunks that is the difference between
## tens of milliseconds and well under one.
func _sort_load_queue(cc0: Vector3i) -> void:
	var n := _load_queue.size()
	if n < 2:
		return
	var keys := PackedInt64Array()
	keys.resize(n)
	for i in n:
		var d: Vector3i = _load_queue[i] - cc0
		keys[i] = (d.x * d.x + d.y * d.y + d.z * d.z) * 1048576 + i
	keys.sort()
	var out: Array[Vector3i] = []
	out.resize(n)
	for i in n:
		out[i] = _load_queue[keys[i] & 0xFFFFF]
	_load_queue = out


## Ask again for anything the last scan wanted that still is not here.
##
## This is why the periodic re-scan existed at all: a chunk whose build was
## dropped is never re-requested by the full scan, because that only runs when
## you cross a chunk boundary -- so it stayed missing until you walked far
## enough away and back. That is the terrain that "never loads".
##
## Doing it this way keeps the cure and drops the cost: dictionary lookups over
## a set that is already decided, no geometry, no unload pass, and no re-sort
## unless something was actually added.
func _requeue_missing(cc0: Vector3i) -> void:
	# The ordinary case, answered without looking: everything wanted is already
	# here. The unload pass in the full scan drops anything not wanted, so what
	# is loaded is a subset of what is wanted -- which makes the sizes matching
	# the same statement as the sets matching. Being wrong here costs one more
	# 400ms tick before a genuinely missing chunk is asked for again.
	if loaded_chunks.size() >= _wanted.size():
		return
	var added := false
	for cc in _wanted:
		if not loaded_chunks.has(cc) and not _load_queue_set.has(cc) and not _inflight.has(cc):
			_load_queue.append(cc)
			_load_queue_set[cc] = true
			added = true
	if added:
		_sort_load_queue(cc0)


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
	# Applying a finished chunk is main-thread work -- an ArrayMesh and, worse, a
	# cooked ConcavePolygonShape3D -- and how long it takes depends entirely on
	# how much geometry came back. A fixed count per frame therefore costs
	# whatever it costs: four dense chunks in one frame is a visible hitch, four
	# empty ones is nothing. A time budget spends the same total effort while
	# refusing to spend it all at once.
	var budget_start := Time.get_ticks_usec()
	var applied := 0
	for cc in ready_ccs:
		# Always let ONE through, or a frame that is already slow could starve
		# streaming entirely and never catch up.
		if applied >= APPLY_PER_FRAME or (applied > 0
				and APPLY_PER_FRAME != APPLY_PER_FRAME_FAST_LOAD
				and Time.get_ticks_usec() - budget_start > APPLY_BUDGET_US):
			break
		_ready_mutex.lock()
		var data: Dictionary = _ready_data.get(cc, {})
		_ready_data.erase(cc)
		_ready_mutex.unlock()
		if _inflight.has(cc):
			WorkerThreadPool.wait_for_task_completion(_inflight[cc])
			_inflight.erase(cc)
		_keep_generated(cc, data)
		if _is_stale(cc, data):
			continue
		var node = loaded_chunks.get(cc)
		if node != null and is_instance_valid(node):
			node.apply_mesh_data(data)
			wake_water_boundary(data.get("wetfall", PackedVector3Array()))
			_clear_temp_colliders(cc)
		_edit_priority.erase(cc)
		applied += 1

	# 2) re-mesh dirty (edited / flowed) chunks FIRST -- player edits and flowing
	# water must update promptly, not wait behind chunk streaming
	var dirty_ccs: Array = _dirty.keys()
	if not _edit_priority.is_empty():
		# Edits before flowing water: a dict's key order is arbitrary, so without
		# this a click can wait behind a lake that is still settling.
		var ef: Array = []
		var er: Array = []
		for cc in dirty_ccs:
			if _edit_priority.has(cc):
				ef.append(cc)
			else:
				er.append(cc)
		dirty_ccs = ef + er
	for cc in dirty_ccs:
		if _inflight.size() >= MAX_INFLIGHT and not _edit_priority.has(cc):
			break
		if _inflight.has(cc):
			continue  # already meshing; stays dirty and re-dispatches next frame
		_dirty.erase(cc)
		if not loaded_chunks.has(cc):
			continue
		var s := _edits_snapshot(cc)
		var t := WorkerThreadPool.add_task(Callable(self, "_build_task").bind(cc, s, _wlev_snapshot(s), _ver_of(cc)))
		_inflight[cc] = t

	# 3) dispatch new chunk loads with whatever capacity remains
	while _inflight.size() < MAX_INFLIGHT and not _load_queue.is_empty():
		var cc: Vector3i = _load_queue.pop_front()
		_load_queue_set.erase(cc)
		if loaded_chunks.has(cc):
			continue
		_spawn_chunk_node(cc)
		var snap := _edits_snapshot(cc)
		var tid := WorkerThreadPool.add_task(Callable(self, "_build_task").bind(cc, snap, _wlev_snapshot(snap), _ver_of(cc)))
		_inflight[cc] = tid
	return applied


func _spawn_chunk_node(cc: Vector3i) -> Chunk:
	var chunk := Chunk.new()
	chunk.planet = self
	chunk.cc = cc
	chunk.position = Vector3(cc * CS)
	add_child(chunk)
	loaded_chunks[cc] = chunk
	if water_style == WATER_LIQUID and not _water_stalled.is_empty():
		_resume_water(cc)
	return chunk


# Make sure no worker thread is still meshing against us when we get freed
# (otherwise it reads a half-destroyed planet and the app hangs on shutdown).
func _exit_tree() -> void:
	for tid in _inflight.values():
		WorkerThreadPool.wait_for_task_completion(tid)
	_inflight.clear()


# Runs on a worker thread: pure computation, results deposited under a mutex.
## Keep what a build learned about a chunk's terrain, for as long as the chunk
## is loaded. Only while it is loaded: a chunk that is kept rebuilding is one
## near the player, and holding the whole streamed world's terrain would cost
## memory for chunks nobody will touch.
func _keep_generated(cc: Vector3i, data: Dictionary) -> void:
	if not loaded_chunks.has(cc):
		return
	if data.has(Chunk.GEN_OUT):
		_gen_cache[cc] = data[Chunk.GEN_OUT]
	if data.has(Chunk.BSL_OUT):
		_bslot_cache[cc] = data[Chunk.BSL_OUT]
	if data.has(Chunk.DEPTH_OUT):
		_depth_cache[cc] = data[Chunk.DEPTH_OUT]


func _build_task(cc: Vector3i, snap: Dictionary, wsnap: Dictionary, ver: int = 0) -> void:
	var data := Chunk.build_mesh_data(self, cc, snap, wsnap)
	data["_ver"] = ver
	# Carried back to the main thread with the mesh, and stored there -- the
	# caches are read while taking snapshots, which happens on the main thread.
	if snap.has(Chunk.GEN_OUT):
		data[Chunk.GEN_OUT] = snap[Chunk.GEN_OUT]
	if snap.has(Chunk.BSL_OUT):
		data[Chunk.BSL_OUT] = snap[Chunk.BSL_OUT]
	if snap.has(Chunk.DEPTH_OUT):
		data[Chunk.DEPTH_OUT] = snap[Chunk.DEPTH_OUT]
	_ready_mutex.lock()
	_ready_data[cc] = data
	_ready_mutex.unlock()


# Copy edits for a chunk and its 6 face-neighbors into a plain dict for a worker.
func _edits_snapshot(cc: Vector3i) -> Dictionary:
	var snap := {}
	# The FULL 3x3x3 neighbourhood, not just the 6 face-adjacent chunks. A torch
	# lights up to 14 blocks (see Blocks.light_level), which reaches diagonally
	# into the corner chunks as easily as straight into the face ones -- and a
	# light the mesher cannot see in the snapshot is a light it cannot bake.
	const OFFS := [Vector3i(0, 0, 0),
		Vector3i(-1, -1, -1), Vector3i(-1, -1, 0), Vector3i(-1, -1, 1),
		Vector3i(-1, 0, -1), Vector3i(-1, 0, 0), Vector3i(-1, 0, 1),
		Vector3i(-1, 1, -1), Vector3i(-1, 1, 0), Vector3i(-1, 1, 1),
		Vector3i(0, -1, -1), Vector3i(0, -1, 0), Vector3i(0, -1, 1),
		Vector3i(0, 0, -1), Vector3i(0, 0, 1),
		Vector3i(0, 1, -1), Vector3i(0, 1, 0), Vector3i(0, 1, 1),
		Vector3i(1, -1, -1), Vector3i(1, -1, 0), Vector3i(1, -1, 1),
		Vector3i(1, 0, -1), Vector3i(1, 0, 0), Vector3i(1, 0, 1),
		Vector3i(1, 1, -1), Vector3i(1, 1, 0), Vector3i(1, 1, 1)]
	var parts := {}
	# The generated terrain of every neighbour that has been built, so neither
	# this chunk nor the lighting and culling that look past its edges have to
	# ask the generator again. Packed arrays are copy-on-write: handing them to
	# a worker shares them without copying and without a race.
	var gen := {}
	for off in OFFS:
		var g = _gen_cache.get(cc + off)
		if g != null:
			gen[cc + off] = g
	snap[Chunk.GEN_KEY] = gen
	var bs = _bslot_cache.get(cc)
	if bs != null:
		snap[Chunk.BSL_KEY] = bs
	var dp = _depth_cache.get(cc)
	if dp != null:
		snap[Chunk.DEPTH_KEY] = dp
	for off in OFFS:
		var d = _edits_by_chunk.get(cc + off)
		if d != null:
			for k in d:
				snap[k] = d[k]
		var pd = _parts_by_chunk.get(cc + off)
		if pd != null:
			for k in pd:
				parts[k] = (pd[k] as PackedByteArray).duplicate()
	# Copied, not referenced: the mesher runs on a worker thread and must not
	# read a cell the main thread is part-way through editing.
	# Fires near this chunk, so the worker can draw their flames and bake their
	# light without touching planet state from another thread.
	var fires: Array = []
	if not _fire_cells.is_empty():
		var lo := (cc - Vector3i.ONE) * CS
		var hi := (cc + Vector3i.ONE * 2) * CS
		for fv in _fire_cells:
			var f: Vector3i = fv
			if f.x >= lo.x and f.y >= lo.y and f.z >= lo.z 					and f.x < hi.x and f.y < hi.y and f.z < hi.z:
				fires.append(f)
	# Planted cells near this chunk: the mesher needs the species and stage to
	# draw a crop at the right height, and neither is in the block id.
	var crops := {}
	if not _crops.is_empty():
		var clo := (cc - Vector3i.ONE) * CS
		var chi := (cc + Vector3i.ONE * 2) * CS
		for cv in _crops:
			var q: Vector3i = cv
			if q.x >= clo.x and q.y >= clo.y and q.z >= clo.z 					and q.x < chi.x and q.y < chi.y and q.z < chi.z:
				crops[q] = (_crops[q] as Dictionary).duplicate()
	snap[Chunk.CROP_KEY] = crops
	snap[Chunk.FIRE_KEY] = fires
	snap[Chunk.PARTS_KEY] = parts
	return snap


# Water levels for the WATER cells in an edits snapshot (thread-safe copy so the
# mesher can render partial-height water). Ocean cells default to full in the mesher.
func _wlev_snapshot(snap: Dictionary) -> Dictionary:
	var w := {}
	for v in snap:
		# The snapshot carries non-voxel keys too (the parts table, the baked
		# light map), so anything that walks it must check what it is holding.
		if not (v is Vector3i):
			continue
		if snap[v] == Blocks.WATER:
			w[v] = _wlev.get(v, W_FULL)
	return w


## Water a freshly-built chunk says has somewhere to go.
##
## The sea does not decide to move on its own -- the simulation only runs where
## something wakes it. Waking it as the ground under it arrives is what makes a
## generated cave mouth pour rather than hold an ocean up, and it is the same
## fall you already get by breaking a block beside one: down the hole, out
## across the floor, and stop.
func wake_water_boundary(cells: PackedVector3Array) -> void:
	if cells.is_empty() or water_style != WATER_LIQUID or not water_simulated:
		return
	for c in cells:
		_wake_bg(Vector3i(c))


## Build one chunk synchronously on the main thread (used at spawn so there's
## ground under the player immediately).
## Rebuild a chunk that is ALREADY standing, right now, on this thread.
##
## The ordinary path marks a chunk dirty and a worker gets to it a frame or two
## later, which is right for anything the player is watching. It is wrong for
## edits made behind a loading screen: the data changed before the world was
## visible, but the mesh landed after, so you watched the blocks inside the
## wreck wink out a second into the game.
func rebuild_chunk_sync(cc: Vector3i) -> void:
	if not loaded_chunks.has(cc):
		build_chunk_sync(cc)
		return
	var node = loaded_chunks[cc]
	if node == null or not is_instance_valid(node):
		return
	var snap := _edits_snapshot(cc)
	node.apply_mesh_data(Chunk.build_mesh_data(self, cc, snap, _wlev_snapshot(snap)))
	_dirty.erase(cc)


func build_chunk_sync(cc: Vector3i) -> void:
	if loaded_chunks.has(cc):
		return
	if not _chunk_possibly_solid(cc):
		return
	var node := _spawn_chunk_node(cc)
	var snap := _edits_snapshot(cc)
	var data := Chunk.build_mesh_data(self, cc, snap, _wlev_snapshot(snap))
	node.apply_mesh_data(data)
	wake_water_boundary(data.get("wetfall", PackedVector3Array()))


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
		_chunk_ver[cc] = _ver_of(cc) + 1
		_dirty[cc] = true


## A player edit must show up NOW, so it does not go through the normal
## dirty-then-dispatch-next-tick path. Three frames of lag between the click and
## the block appearing is small on paper and very obvious in the hand.
##
## Dispatched straight away (ignoring MAX_INFLIGHT -- an edit touches at most 7
## chunks, and making it queue behind terrain streaming is exactly the delay
## being removed), then collected in _process the moment the worker is done.
## Can a light of level `lvl` at voxel `v` put any light into chunk `cc`?
##
## Light spreads one cell at a time through the 6 face neighbours, losing a level
## per step, so the distance that matters is MANHATTAN, not straight-line. A
## torch in the middle of a chunk reaches its face neighbours and no further --
## the corner chunks are three times as far by this measure, which is why
## rebuilding all 26 of them was almost entirely wasted work.
func _light_reaches(cc: Vector3i, v: Vector3i, lvl: int) -> bool:
	var lo := cc * CS
	var hi := lo + Vector3i(CS - 1, CS - 1, CS - 1)
	var d := 0
	d += maxi(0, maxi(lo.x - v.x, v.x - hi.x))
	d += maxi(0, maxi(lo.y - v.y, v.y - hi.y))
	d += maxi(0, maxi(lo.z - v.z, v.z - hi.z))
	return d <= lvl - 1


func _ver_of(cc: Vector3i) -> int:
	return int(_chunk_ver.get(cc, 0))


## Was this finished mesh built from data older than the chunk holds now? If
## so it is not shown, and the chunk is queued to mesh again.
func _is_stale(cc: Vector3i, data: Dictionary) -> bool:
	if int(data.get("_ver", 0)) >= _ver_of(cc):
		return false
	_dirty[cc] = true
	return true


func _edit_remesh(cc: Vector3i) -> void:
	# Counted whether or not it is loaded: a chunk whose build is already out
	# on a worker is loaded, and must not have that build shown.
	_chunk_ver[cc] = _ver_of(cc) + 1
	if not loaded_chunks.has(cc):
		return
	_edit_priority[cc] = true
	# Inside a batch, remember it and rebuild once at the end. Some edits are
	# one THING made of several blocks -- both halves of a door -- and meshing
	# after the first of them shows the world a half-finished object. See
	# begin_batch.
	if _batching:
		_batch_remesh[cc] = true
		return
	if _inflight.has(cc):
		# Already meshing against older data -- can't start a second task for the
		# same chunk (they'd race to write _ready_data), so fall back to dirty.
		_dirty[cc] = true
		return
	_dirty.erase(cc)
	var snap := _edits_snapshot(cc)
	# HIGH PRIORITY: during exploration the pool is full of streaming builds, and
	# a normal-priority edit task queues behind them -- which is what made
	# building while walking feel so much worse than building standing still.
	_inflight[cc] = WorkerThreadPool.add_task(
		Callable(self, "_build_task").bind(cc, snap, _wlev_snapshot(snap), _ver_of(cc)), true)


## Turn finished EDIT meshes into geometry as soon as they are ready, rather than
## waiting for the next physics tick's process_load_queue.
func _apply_ready_edits() -> void:
	if _edit_priority.is_empty():
		return
	for cc in _edit_priority.keys():
		_ready_mutex.lock()
		var has := _ready_data.has(cc)
		var data: Dictionary = _ready_data.get(cc, {})
		if has:
			_ready_data.erase(cc)
		_ready_mutex.unlock()
		if not has:
			continue
		if _inflight.has(cc):
			WorkerThreadPool.wait_for_task_completion(_inflight[cc])
			_inflight.erase(cc)
		_keep_generated(cc, data)
		if _is_stale(cc, data):
			_edit_remesh(cc)
			continue
		var node = loaded_chunks.get(cc)
		if node != null and is_instance_valid(node):
			node.apply_mesh_data(data)
			wake_water_boundary(data.get("wetfall", PackedVector3Array()))
			_clear_temp_colliders(cc)
		_edit_priority.erase(cc)
		# A chunk re-dirtied while it was meshing (a fast second click) gets its
		# follow-up task started immediately instead of next tick.
		if _dirty.has(cc):
			_dirty.erase(cc)
			_edit_remesh(cc)


# A block you just placed has no collision until its chunk finishes re-meshing
# on a worker thread. That is only a frame or two, but it is exactly the frame
# you need it: pillaring up means placing a block under yourself mid-jump and
# landing on it, and without collision you fall straight through into the column
# below. So a placed block gets a temporary box collider immediately, thrown
# away as soon as the real chunk mesh arrives.
var _temp_solid := {}          # voxel -> StaticBody3D


func _add_temp_collider(v: Vector3i) -> void:
	if _temp_solid.has(v):
		return
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE
	col.shape = box
	body.add_child(col)
	body.position = Vector3(v) + Vector3(0.5, 0.5, 0.5)
	add_child(body)
	_temp_solid[v] = body


## Drop the stand-ins for a chunk once its real collision exists.
##
## `force` is for a chunk being UNLOADED. The stand-ins are children of the
## planet rather than of the chunk, so freeing the chunk does not take them, and
## the guard below would otherwise refuse to clear a chunk that still owed a
## rebuild it is never now going to get. That left a physics body per placed
## block behind for the rest of the session, every time you built something and
## walked away -- which builds up exactly as slowly and as invisibly as it
## sounds.
func _clear_temp_colliders(cc: Vector3i, force: bool = false) -> void:
	if _temp_solid.is_empty():
		return
	# Not while this chunk is still owed a rebuild.
	#
	# A build already in flight when you placed the block does not contain it --
	# its snapshot was taken before the click. Dropping the stand-in the moment
	# THAT build lands leaves the block with no collision at all until the real
	# rebuild arrives, which is how you fall through the pillar you are standing
	# on. It only happens when a chunk was busy for some other reason at the
	# instant you placed, which is why it is intermittent.
	if _dirty.has(cc) and not force:
		return
	for v in _temp_solid.keys():
		if chunk_of(v) != cc:
			continue
		var b: Node = _temp_solid[v]
		if b != null and is_instance_valid(b):
			b.queue_free()
		_temp_solid.erase(v)


## Break, place, or neither.
##
## This lives in set_block rather than at the call sites because set_block is
## the ONLY way a block ever changes after generation -- local edits, the host
## applying a client's edit, and a client applying the host's all funnel through
## here. One hook covers single player and co-op without either knowing about
## the other.
func _edit_sound(v: Vector3i, was: int, id: int) -> void:
	var pos := to_global(Vector3(v) + Vector3(0.5, 0.5, 0.5))
	if id == Blocks.AIR:
		if was != Blocks.AIR:
			Audio.block_broken(was, pos)
	elif id != was:
		Audio.block_placed(id, pos)


## `quiet` is for edits that are being replayed rather than happening: a client
## catching up on a hundred blocks it missed should arrive at the right world in
## silence, not to a hundred simultaneous bangs.
## Many cells at once, as one change: a felled tree coming out of the world,
## and going back into it where it lands.
##
## set_block does a great deal for ONE block -- a sound, the water around it
## settled on the spot, stand-in collision, a remesh of its chunk and any
## neighbour it borders -- and a tree is up to a thousand blocks. Through
## set_block that was a visible freeze before the tree began to fall. Here the
## cells are written, each chunk is remeshed once, and water is only woken
## where some is actually next to a cell that changed.
func set_blocks(cells: Dictionary) -> void:
	begin_batch()
	var near_water: Array[Vector3i] = []
	for key in cells:
		var v: Vector3i = key
		var id: int = cells[key]
		block_tags.erase(v)
		var cc := chunk_of(v)
		if not _edits_by_chunk.has(cc):
			_edits_by_chunk[cc] = {}
		_edits_by_chunk[cc][v] = id
		if _temp_solid.has(v):
			var gone: Node = _temp_solid[v]
			if gone != null and is_instance_valid(gone):
				gone.queue_free()
			_temp_solid.erase(v)
		_edit_remesh(cc)
		var local := v - cc * CS
		if local.x == 0: _edit_remesh(cc + Vector3i(-1, 0, 0))
		if local.x == CS - 1: _edit_remesh(cc + Vector3i(1, 0, 0))
		if local.y == 0: _edit_remesh(cc + Vector3i(0, -1, 0))
		if local.y == CS - 1: _edit_remesh(cc + Vector3i(0, 1, 0))
		if local.z == 0: _edit_remesh(cc + Vector3i(0, 0, -1))
		if local.z == CS - 1: _edit_remesh(cc + Vector3i(0, 0, 1))
		if water_style == WATER_LIQUID and not _wlev.is_empty():
			for n in _NEIGH6:
				if _wlev.has(v + n):
					near_water.append(v)
					break
	end_batch()
	for v in near_water:
		_wake(v)


func set_block(v: Vector3i, id: int, quiet := false) -> void:
	var was := get_id(v)
	if Blocks.bottom_of(was) != Blocks.bottom_of(id):
		block_tags.erase(v)
	if not quiet:
		_edit_sound(v, was, id)
	var cc := chunk_of(v)
	if not _edits_by_chunk.has(cc):
		_edits_by_chunk[cc] = {}
	_edits_by_chunk[cc][v] = id
	# Stand-in collision so the block is solid THIS frame, not in two.
	if id != Blocks.AIR and id != Blocks.WATER and not Blocks.is_leaf(Blocks.bottom_of(id)) 			and Blocks.bottom_of(id) != Blocks.WIRE and Blocks.bottom_of(id) != Blocks.PARTS:
		_add_temp_collider(v)
	elif _temp_solid.has(v):
		var gone: Node = _temp_solid[v]
		if gone != null and is_instance_valid(gone):
			gone.queue_free()
		_temp_solid.erase(v)
	if Blocks.bottom_of(id) == Blocks.WIRE or Blocks.bottom_of(was) == Blocks.WIRE:
		_grid_cache.clear()   # the conduit network just changed shape
	# Every hole in the ground is a hole water can find. Asked HERE rather than
	# at the one place a player swings a pick, so that a block broken by anyone
	# -- another player, a machine, anything added later -- gets the same answer.
	# `quiet` edits are a world being replayed rather than changed, and waking
	# the whole of a loaded save at once is not a thing worth doing.
	# A water block written through HERE is one somebody poured, because the
	# simulation writes its own cells straight into the edit table rather than
	# through this function. So it becomes a spring, and emptying the cell again
	# -- with a bucket, or by building in it -- takes the spring with it. Done
	# for replayed edits too: this is state, not an event, and a client applying
	# the host's edits has to arrive at the same water the host has.
	if id == Blocks.WATER:
		_wlev[v] = W_SOURCE
		# Water poured straight onto a crop washes it away like any other, and
		# the growth table has to hear about it: a row left behind goes on
		# ripening under the water and hands back a harvest from a plant that is
		# not there. _set_water does the same for water that FLOWS onto one.
		if not _crops.is_empty():
			_crops.erase(v)
	elif was == Blocks.WATER:
		_wlev.erase(v)
	if not quiet and water_style == WATER_LIQUID:
		flow_water(v)
	_edit_remesh(cc)
	# a change on a chunk border also changes the neighbor's visible faces
	var local := v - cc * CS
	if local.x == 0: _edit_remesh(cc + Vector3i(-1, 0, 0))
	if local.x == CS - 1: _edit_remesh(cc + Vector3i(1, 0, 0))
	if local.y == 0: _edit_remesh(cc + Vector3i(0, -1, 0))
	if local.y == CS - 1: _edit_remesh(cc + Vector3i(0, 1, 0))
	if local.z == 0: _edit_remesh(cc + Vector3i(0, 0, -1))
	if local.z == CS - 1: _edit_remesh(cc + Vector3i(0, 0, 1))
	# A light source reaches far past its own chunk, and every chunk it touches
	# has that light BAKED into its mesh (see Chunk._compute_block_light). Only
	# re-meshing this one left the neighbours holding their old, unlit mesh, so a
	# torch's pool of light stopped dead against a straight line on the chunk
	# boundary. Light never travels further than one chunk (max level 14 < CS),
	# so the 3x3x3 around it is exactly enough.
	# Only the chunks it ACTUALLY reaches, and only at normal priority. Rebuilding
	# the whole 3x3x3 on the high-priority edit path meant 27 full chunk re-meshes
	# for one torch, all landing on the main thread together -- a second-long
	# freeze. Light spilling into a neighbour is a cosmetic update: it can arrive
	# a few frames later through the ordinary streaming queue. The chunk the light
	# is IN was already queued at high priority above, so the block itself still
	# appears instantly.
	var lvl := maxi(Blocks.light_level(id), Blocks.light_level(was))
	if lvl > 0:
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					if dx == 0 and dy == 0 and dz == 0:
						continue
					var ncc := cc + Vector3i(dx, dy, dz)
					if loaded_chunks.has(ncc) and _light_reaches(ncc, v, lvl):
						_dirty[ncc] = true


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
	# One object, one redraw: see begin_batch.
	begin_batch()
	set_block(v, Blocks.door_toggle_of(id))
	for n: Vector3i in _DOOR_NEIGH6:
		var nb: Vector3i = v + n
		var nid := get_id(nb)
		# Each half swung by ITS OWN state, not handed the other half's. They
		# differ in which one is the top, and copying one onto the other put two
		# bottom halves in a doorway -- or two tops.
		if Blocks.is_door(nid):
			set_block(nb, Blocks.door_toggle_of(nid))
	end_batch()
	return true


# Queue a loaded chunk to be re-meshed on a worker thread (never blocks the main
# thread). Applied a frame or two later via process_load_queue.
func _rebuild_if_loaded(cc: Vector3i, urgent := true) -> void:
	if loaded_chunks.has(cc):
		_dirty[cc] = true
		# Remember that this one came from an EDIT, so its finished mesh jumps
		# the queue below. Without it a broken block could sit visible for a
		# second or more behind whatever terrain happened to be streaming.
		#
		# NOT everything that moves water is urgent, and this is where saying so
		# matters. The sea finding the caves under a coast redraws hundreds of
		# chunks a second; marking every one of them urgent puts hundreds of
		# things in the queue that exists to hold the ONE thing you just did, and
		# your own block then waits behind all of them. That is water taking two
		# minutes to visibly move while the simulation had already finished
		# moving it.
		if urgent:
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
## A cell that is a SPRING rather than a puddle: it holds itself full and feeds
## its neighbours, and nothing drains it. Generated ocean behaves this way
## because it is a function of the seed; this is how a bucket of water poured on
## dry ground does the same. Stored as a level above full so it rides along in
## the level table, the save file and the network message that already exist --
## a second table of which cells are special is a second table to keep in step.
const W_SOURCE := 9
const FLOW_DT := 0.10          # simulation tick interval (seconds)
const FLOW_BUDGET := 4096      # hard ceiling on cells per tick
## How long a step may spend, in microseconds.
##
## A CELL count was the wrong knob. What a cell costs depends on where it is --
## one in open water asks the terrain function about its neighbours, one buried
## in rock is dismissed in two comparisons -- so a fixed 256 of them was half a
## millisecond in a trench and eight milliseconds along a coast, which is a
## stutter ten times a second rather than a stream running. A time budget is the
## thing that was actually meant: the sea takes longer to arrive where there is
## more of it to work out, and the frame never notices either way.
const FLOW_SLICE_USEC := 2500
## What an EDIT may spend settling its own water, then and there.
##
## Water set off by a block you broke is worked out before that block is handed
## to the mesher, so it arrives in the SAME redraw as the hole rather than in
## another one a step later. A chunk redraw is most of a second on this project;
## needing two of them is the difference between water that answers you and
## water you never catch moving.
##
## Small, and only ever spent near water: an edit nowhere near any wakes seven
## cells that all decide there is nothing to do, in microseconds.
const EDIT_SLICE_USEC := 1500
## Safety cap on how much water the simulation may be holding at once. Generous
## because a real coast pours into every cave mouth along it -- eight thousand
## cells for a hundred and twenty-five chunks of seabed -- and this is a guard
## against something running away, not a water allowance.
const MAX_WATER := 400000
## A chunk is rebuilt at most this often WHILE water is moving through it. The
## simulation steps ten times a second and a spreading flood touches a dozen
## chunks; rebuilding every one of them on every step is far more work than
## anybody can see, and it is what would make a burst dam cost frames rather
## than merely look like it should.
const FLOW_REMESH_DT := 0.25
## Cells waiting on terrain nobody has generated. Bounded, because a channel cut
## toward the horizon would otherwise keep a list of every place the water would
## eventually have got to.
const MAX_STALLED := 8000
var _wlev := {}                # Vector3i -> level 1..W_FULL
## Two queues, not one.
##
## Loading the ground around you wakes every cell of sea that has somewhere to
## go -- nineteen thousand of them along a coast -- and that is BACKGROUND work:
## the sea quietly finding the caves under it, which nobody is watching and
## which can take a minute. Breaking a block is not: it is a thing you just did
## and are standing over waiting for.
##
## With one queue the second waits behind the first, and a bucket emptied into a
## hole you dug looks like it is not working at all -- which is precisely how it
## looked. So an edit and everything that cascades from it go in front of all of
## the ambient work, however much of it there is.
var _water_active := {}        # cells to (re)evaluate next tick -- yours
var _water_bg := {}            # ...and the sea's own business
## Which queue a cell woken RIGHT NOW belongs in. Set around the loop rather
## than passed down, because waking happens six calls deep and the answer is a
## property of the whole pass, not of any one cell.
var _waking_bg := false
## Inside a step already; see flow_water.
var _settling := false
var _batching := false         # see begin_batch
var _batch_remesh := {}        # chunks a batch has dirtied
var _water_stalled := {}       # chunk -> {cell: true}, woken when that chunk loads
var _water_dirty := {}         # chunks whose water moved, waiting on a re-mesh
var _water_remesh_at := {}     # chunk -> earliest next re-mesh, in msec
var _flow_accum := 0.0
## Answers to "is this cell open sea", for the length of ONE simulation step.
## The same cells are asked about again and again within a step -- each cell
## asks about six neighbours, and those neighbours are each other -- and the
## answer cannot change while a step is running. Cleared every step, so it stays
## the size of the work in front of it rather than growing with the world.
var _src_memo := {}
## False on a network client: water is decided by the host and sent, the same way
## crops are. Two machines running the same automaton on slightly different
## timing do not stay in step, and water that disagrees about where it is is
## water you drown in on one screen and walk through on the other.
var water_simulated := true


## Something opened a hole at `v`. Let whatever is next to it come and find out.
func flow_water(v: Vector3i) -> void:
	if water_style != WATER_LIQUID or not water_simulated:
		return
	_wake(v)
	# ...and settle it now rather than on the next step. See EDIT_SLICE_USEC.
	# Guarded because this runs from inside set_block, and a step that somehow
	# reached set_block again would be re-entering its own queue.
	if _settling:
		return
	_settling = true
	_sim_water(_water_active, false, Time.get_ticks_usec() + EDIT_SLICE_USEC)
	_settling = false


func _wake(c: Vector3i) -> void:
	_wake_one(c)
	for n in _NEIGH6:
		_wake_one(c + n)


## The sea's own business: slower, and always behind anything you did.
func _wake_bg(c: Vector3i) -> void:
	var was := _waking_bg
	_waking_bg = true
	_wake_one(c)
	_waking_bg = was


## A cell can only be simulated where there is a chunk to show the result in.
##
## Water reaching the edge of what is loaded WAITS there rather than crawling on
## out of sight: it would spread through terrain nobody has generated, into a
## level table that never stops growing, and then be finished by the time you
## walked out to look at it. Stalled cells are picked up again when their chunk
## loads, so following the water means arriving with it.
func _wake_one(c: Vector3i) -> void:
	var cc := chunk_of(c)
	if loaded_chunks.has(cc):
		if _waking_bg:
			# Never demote: a cell already in the fast lane stays there even if
			# the background pass reaches it too.
			if not _water_active.has(c):
				_water_bg[c] = true
		else:
			_water_active[c] = true
			_water_bg.erase(c)
		return
	if _water_stalled.size() > MAX_STALLED:
		return
	if not _water_stalled.has(cc):
		_water_stalled[cc] = {}
	_water_stalled[cc][c] = true


## Treat the next few edits as ONE change.
##
## A door is two blocks. Editing them one at a time dispatches a mesh for the
## first before the second has happened, so the chunk is drawn with the top half
## swung and the bottom half still shut -- which is exactly what it looked like:
## a door whose halves open at different moments instead of one object moving.
func begin_batch() -> void:
	_batching = true


func end_batch() -> void:
	if not _batching:
		return
	_batching = false
	var ccs: Array = _batch_remesh.keys()
	_batch_remesh.clear()
	for cc in ccs:
		_edit_remesh(cc)


## A chunk just came in; anything that was waiting on it can carry on.
func _resume_water(cc: Vector3i) -> void:
	var held = _water_stalled.get(cc)
	if held == null:
		return
	_water_stalled.erase(cc)
	for c in held:
		# Water that was waiting on ground to arrive is the sea's own business,
		# not something anybody is standing over.
		if not _water_active.has(c):
			_water_bg[c] = true


func _wdown(c: Vector3i) -> Vector3i:
	var ax := _axis_of(Vector3(c) + Vector3(0.5, 0.5, 0.5))  # outward face axis
	return Vector3i(int(-ax.x), int(-ax.y), int(-ax.z))       # toward center = down


func _is_solid_block(c: Vector3i) -> bool:
	var id := get_id(c)
	# Tall grass does not dam a stream. Water flows into its cell and takes it
	# with it, rather than parting around a blade of grass and leaving it
	# standing in the middle of the water.
	return id != Blocks.AIR and id != Blocks.WATER and not Blocks.is_washable(id)


# Undug, generated ocean = an infinite full source.
func _ocean_source(c: Vector3i) -> bool:
	if int(_wlev.get(c, 0)) == W_SOURCE:
		return true      # poured from a bucket, and it stays
	var d = _edits_by_chunk.get(chunk_of(c))
	if d != null and d.has(c):
		return false
	if _wlev.has(c):
		return false
	if water_style != WATER_LIQUID:
		return false
	var was = _src_memo.get(c)
	if was != null:
		return bool(was)
	# A cheap REJECT before the real answer, never instead of it.
	#
	# The generator's rule for open sea is "above the ground and below the
	# waterline", so anything failing that cannot be sea and is dismissed in two
	# noise fields rather than in the whole terrain function with its caves, ore
	# veins and tree cells. Inside a cave -- where this runs most -- every
	# neighbour fails on the first test. It matters because this is the
	# simulation's hottest line: every cell it looks at asks about six
	# neighbours, and going the long way round put a step of water at fifteen
	# milliseconds, a stutter ten times a second rather than a stream running.
	#
	# The MARGIN is the whole thing. This has to use the same corner of the cell
	# generation_sample does and, where it cannot be sure, say "ask properly"
	# rather than "no". Testing the cell's CENTRE instead put it half a block out
	# -- which is nothing except exactly at the waterline, where it rejected the
	# top layer of the sea. That is the only layer with air against it, so it is
	# the only layer that ever flows: the whole ocean quietly stopped being a
	# source and no water moved anywhere, while the simulation ran on happily
	# finding nothing to do.
	var pf := Vector3(c)
	var margin := 1.0
	var dist := _norm(pf)
	var ans := false
	if dist <= water_level + margin:
		var l2 := pf.length()
		if l2 > 0.0001 and dist > _surf(pf / l2) - margin:
			ans = generation_sample(c.x, c.y, c.z) == Blocks.WATER
	_src_memo[c] = ans
	return ans


func _wlevel(c: Vector3i) -> int:
	if _ocean_source(c):
		return W_FULL
	return mini(int(_wlev.get(c, 0)), W_FULL)


func _water_target(c: Vector3i) -> int:
	var down := _wdown(c)
	var above := c - down
	if not _is_solid_block(above) and _wlevel(above) > 0:
		return W_FULL  # water falling straight down fills the cell
	var best := 0
	for n in _NEIGH6:
		if n == down or n == -down:
			continue  # horizontal neighbors only spread sideways
		var q: Vector3i = c + n
		var lv := _wlevel(q)
		if lv <= 0:
			continue
		# Water with somewhere to FALL does not also run sideways. It is the
		# rule that makes a stream behave like a stream: reach the lip of a pit
		# and the whole flow turns down it, instead of the pit filling from a
		# sheet that carried on spreading seven blocks past the edge as though
		# the hole were not there.
		#
		# The open sea is exempt. It is infinite and its surface is level by
		# definition -- a hole in the seabed does not stop the sea beside it
		# being sea, and making it stop would tear a dry ring around every
		# breach.
		if not _ocean_source(q) and _falls_from(q, down):
			continue
		best = maxi(best, lv - 1)
	return best


## Has this cell somewhere to drop into? Anything but solid ground under it, not
## already brim full.
func _falls_from(q: Vector3i, down: Vector3i) -> bool:
	var b := q + down
	return not _is_solid_block(b) and _wlevel(b) < W_FULL


func _process(_delta: float) -> void:
	var t := Time.get_ticks_usec()
	_apply_ready_edits()
	WorldManager.perf_mark("apply edits", t)


## One step of the water, if one is due. Returns the cells that changed as
## [Vector3i, level] rows -- level 0 meaning it drained -- so a host can tell
## everyone else what the water did, exactly the way crops are reported.
##
## Driven from WorldManager rather than from _process, because whether this
## planet simulates at all is a question about the SESSION, not about the planet.
func flow_tick(delta: float) -> Array:
	if water_style != WATER_LIQUID:
		return []
	_flow_accum += delta
	if _flow_accum < FLOW_DT:
		return []
	_flow_accum = 0.0
	# Flushed BEFORE the early exit, or the last step of a flood is the one that
	# never gets drawn: the water stops moving and the chunk keeps its old shape.
	_flush_water_meshes()
	if _water_active.is_empty() and _water_bg.is_empty():
		return []
	var tw := Time.get_ticks_usec()
	var until := Time.get_ticks_usec() + FLOW_SLICE_USEC
	var changed := _sim_water(_water_active, false, until)
	# The sea gets whatever is left of the slice. Usually almost all of it,
	# because what you just did is a few hundred cells and is finished inside
	# one step.
	if Time.get_ticks_usec() < until:
		changed.append_array(_sim_water(_water_bg, true, until))
	WorldManager.perf_mark("water", tw)
	return changed


func _sim_water(queue: Dictionary, background: bool, until: int) -> Array:
	_src_memo.clear()
	_waking_bg = background
	# A SNAPSHOT to walk, with the live set left in place and each cell taken out
	# of it as it is dealt with. Emptying the set and putting the leftovers back
	# one at a time cost a dictionary insert per waiting cell per step, and along
	# a coast there are twenty thousand of them waiting -- so most of a step went
	# on rewriting the list of work rather than on doing any.
	var todo: Array = queue.keys()
	var changed: Array = []
	var count := 0
	for c in todo:
		count += 1
		# Checked EVERY cell. It used to be every sixteenth, on the reasoning
		# that asking the clock costs more than some cells do -- which is true of
		# the cheap ones, but a cell next to the sea asks the terrain generator
		# about itself and its neighbours and can cost most of a millisecond.
		# Sixteen of those overran a 2.5ms slice to 14ms, and on a busy coast to
		# 64ms: a visible hitch every tenth of a second, standing still.
		if count >= FLOW_BUDGET or Time.get_ticks_usec() > until:
			break                    # the rest keep their place for the next step
		queue.erase(c)
		if _ocean_source(c):
			for n in _NEIGH6:
				var q: Vector3i = c + n
				# ONLY cells that could actually change. Waking neighbouring
				# ocean -- which is nearly all of a sea's neighbours -- makes
				# every tick wake six more sources, and the wave walks out
				# through the whole ocean and never arrives anywhere. That is a
				# simulation that never stops running and an active list that
				# never stops growing, which is what had this switched off.
				if _ocean_source(q) or _is_solid_block(q):
					continue
				_wake_one(q)
			continue
		if _is_solid_block(c):
			if _wlev.has(c):
				_clear_water(c, _water_dirty)
				changed.append([c, 0])
			continue
		var cur: int = _wlev.get(c, 0)
		var t := _water_target(c)
		if t <= 0:
			if cur > 0:
				_clear_water(c, _water_dirty)
				changed.append([c, 0])
				_wake(c)
		elif t != cur and (_wlev.size() < MAX_WATER or _wlev.has(c)):
			_set_water(c, t, _water_dirty)
			changed.append([c, t])
			_wake(c)
	_waking_bg = false
	_flush_water_meshes()
	return changed


## Rebuild the chunks the water has moved through, no more often than any one of
## them is worth rebuilding. A chunk that is not due yet keeps its place in the
## list and goes on the next pass, so nothing is left showing water that has
## already gone somewhere else.
func _flush_water_meshes() -> void:
	if _water_dirty.is_empty():
		return
	var now := Time.get_ticks_msec()
	for cc in _water_dirty.keys():
		# The throttle is there to stop the sea redrawing a chunk ten times a
		# second while it settles. It has no business holding up the splash you
		# are standing in front of.
		if not bool(_water_dirty[cc]) and now < int(_water_remesh_at.get(cc, 0)):
			continue
		_water_remesh_at[cc] = now + int(FLOW_REMESH_DT * 1000.0)
		var urgent := bool(_water_dirty[cc])
		_water_dirty.erase(cc)
		_rebuild_if_loaded(cc, urgent)   # async; never blocks the main thread


## What the host says the water is doing. Applied wholesale rather than worked
## out again locally -- see water_simulated.
func apply_water(rows: Array) -> void:
	for r in rows:
		var c: Vector3i = r[0]
		var lv := int(r[1])
		if lv <= 0:
			_clear_water(c, _water_dirty)
		else:
			_set_water(c, lv, _water_dirty)
	_flush_water_meshes()


## Is this cell simply the sea the world generated, rather than water somebody
## put there? An untouched sea is a function of the seed and infinite by
## construction, so a bucket does not dent it -- writing a hole into the surface
## would leave a permanent dip wherever anyone had ever filled one. Anything the
## simulation is actually tracking can be taken away.
func water_is_native(v: Vector3i) -> bool:
	return not _wlev.has(v) and _ocean_source(v)


## The edits worth writing down.
##
## Water the simulation put somewhere is DERIVED -- from the springs, the
## terrain, and the holes people have dug -- and it is worked out again as the
## world loads, because loading a chunk wakes the water on its boundary. Writing
## it into the save is storing an answer that is recomputed anyway, and on a
## coast that answer runs to thousands of cells per hundred chunks. A spring
## somebody poured is NOT derived and stays.
func saveable_edits() -> Dictionary:
	if _wlev.is_empty():
		return _edits_by_chunk
	var out := {}
	for cc in _edits_by_chunk:
		var src: Dictionary = _edits_by_chunk[cc]
		var keep := {}
		for v in src:
			if int(src[v]) == Blocks.WATER and int(_wlev.get(v, 0)) != W_SOURCE:
				continue
			keep[v] = src[v]
		if not keep.is_empty():
			out[cc] = keep
	return out


## Every dynamic water cell and how deep it is, for the save file and for a
## joining client. Generated ocean is not in here: it is a function of the seed,
## and the far side of a world nobody has touched should cost the save nothing.
func water_rows(sources_only := false) -> Array:
	var out: Array = []
	for c in _wlev:
		var lv := int(_wlev[c])
		if sources_only and lv != W_SOURCE:
			continue
		out.append([c, lv])
	return out


## Put the water back where it was, on load or on joining.
func load_water(rows: Array) -> void:
	for r in rows:
		_wlev[r[0]] = int(r[1])


## How full a cell is, 0.0 to 1.0. Generated ocean is full; anything the
## simulation put there is as deep as the simulation left it.
func water_fill(v: Vector3i) -> float:
	if get_id(v) != Blocks.WATER:
		return 0.0
	# Deliberately NOT _wlevel: that asks generation_sample whether the cell is
	# ocean, and this is on the movement path, several times a frame. Anything
	# the simulation is holding a depth for is that deep; anything else is a
	# cell the world generated, which is full.
	if not _wlev.has(v):
		return 1.0
	return clampf(float(_wlev[v]) / float(W_FULL), 0.0, 1.0)   # a spring reads as full


func _set_water(c: Vector3i, level: int, dirty: Dictionary) -> void:
	if _is_solid_block(c):
		return   # something is standing here; water does not write over it
	# A crop washed away has to stop being a crop as well as stop being a block.
	# The growth table is keyed by cell and ticked on its own, so a row left in
	# it would go on ripening under the water and hand back a harvest from a
	# plant that is no longer there.
	if not _crops.is_empty() and _crops.has(c):
		_crops.erase(c)
	_wlev[c] = level
	var cc := chunk_of(c)
	if not _edits_by_chunk.has(cc):
		_edits_by_chunk[cc] = {}
	_edits_by_chunk[cc][c] = Blocks.WATER
	_mark_borders(c, dirty)


func _clear_water(c: Vector3i, dirty: Dictionary) -> void:
	_wlev.erase(c)
	var d = _edits_by_chunk.get(chunk_of(c))
	# ONLY if the edit here is still water. Something else may have been put in
	# this cell since -- placing a block underwater is exactly that -- and
	# erasing the edit reverts the cell to generation, which takes the block
	# with it. That is a block that appears, is spent from the inventory, and
	# then vanishes a moment later, in the places water had flowed and nowhere
	# else.
	if d != null and int(d.get(c, Blocks.AIR)) == Blocks.WATER:
		# Reverting to generation is only right where generation is NOTHING. A
		# cell the world grows a stalk of grass in would grow it back the moment
		# the water left -- including grass that had been cut long before the
		# water ever got there, which is where this was first noticed: break the
		# grass, flood the cell, take the water away, and the grass is back.
		var g := generation_sample(c.x, c.y, c.z)
		if g == Blocks.AIR or g == Blocks.WATER:
			d.erase(c)   # air on land, ocean below sea level: generation is right
		else:
			d[c] = Blocks.AIR
	_mark_borders(c, dirty)


## Chunks needing a redraw because water moved in them. The VALUE says whether
## anybody is standing over it: water you set off yourself is urgent, the sea's
## own business is not, and that is what decides where its redraw sits in the
## queue.
func _mark_borders(c: Vector3i, dirty: Dictionary) -> void:
	var urgent := not _waking_bg
	var cc := chunk_of(c)
	dirty[cc] = urgent or bool(dirty.get(cc, false))
	var local := c - cc * CS
	if local.x == 0: _mark_one(dirty, cc + Vector3i(-1, 0, 0), urgent)
	if local.x == CS - 1: _mark_one(dirty, cc + Vector3i(1, 0, 0), urgent)
	if local.y == 0: _mark_one(dirty, cc + Vector3i(0, -1, 0), urgent)
	if local.y == CS - 1: _mark_one(dirty, cc + Vector3i(0, 1, 0), urgent)
	if local.z == 0: _mark_one(dirty, cc + Vector3i(0, 0, -1), urgent)
	if local.z == CS - 1: _mark_one(dirty, cc + Vector3i(0, 0, 1), urgent)


## Never downgrade: a chunk somebody is waiting on stays waited on, even if the
## sea touches it again in the same step.
func _mark_one(dirty: Dictionary, cc: Vector3i, urgent: bool) -> void:
	dirty[cc] = urgent or bool(dirty.get(cc, false))
