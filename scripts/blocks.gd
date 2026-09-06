class_name Blocks
extends RefCounted

## Central registry of block types. Blocks are identified by a small integer id
## that gets stored in chunks / edit dictionaries. Rendering uses per-vertex
## colors (no textures needed), so each block just needs a color and a name.

const CHUNK_SIZE := 16  # voxels per chunk edge (shared constant, lives here to avoid cycles)

const AIR := 0
const ROCK := 1
const DIRT := 2
const GRASS := 3
const REGOLITH := 4  # dusty surface (moon/desert planets)
const ICE := 5
const IRON_ORE := 6
const CRYSTAL := 7
const CORE := 8      # hot planet core
const SNOW := 9
const METAL := 10    # player-placeable hull block
const COCKPIT := 11  # ship control seat (a ship needs exactly one)
const THRUSTER := 12 # ship engine (a ship needs at least one to fly)

# --- flora ---
const WOOD := 13
const WOOD_PALE := 14
const WOOD_DARK := 15
# a spectrum of leaf colors (planets pick a palette from these)
const LEAF_0 := 16   # forest green
const LEAF_1 := 17   # lime
const LEAF_2 := 18   # deep green
const LEAF_3 := 19   # olive
const LEAF_4 := 20   # autumn orange
const LEAF_5 := 21   # rust red
const LEAF_6 := 22   # golden yellow
const LEAF_7 := 23   # teal
const LEAF_8 := 24   # violet
const LEAF_9 := 25   # sky blue
const LEAF_10 := 26  # pink
const LEAF_11 := 27  # mint

const LEAF_IDS := [16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27]
const WOOD_IDS := [13, 14, 15]

# STONE: the hard stuff under a planet's soil, and what ore is embedded in.
# Every planet archetype currently uses ROCK for that layer -- if a world ever
# gets its own stone (basalt, chalk), add it here and every recipe that asks for
# stone accepts it with no other change. Deliberately NOT dirt, regolith, ice or
# crystal: those are soils and surfaces, not something you would build a furnace
# out of.
const STONE_IDS := [ROCK]

# --- legacy fixed ore ids (kept so old planet configs don't break; no longer
#     generated -- ores are now procedural per planet, see ORE slots below) ---
const COPPER_ORE := 28
const GOLD_ORE := 29
const TITANIUM_ORE := 30
const SILICON_ORE := 31
const URANIUM_ORE := 32
const WATER := 33  # liquid: transparent, non-collidable (rendered as a second surface)

# --- placed machines/containers (not voxel blocks) ---
const SMELTER := 34
const FABRICATOR := 35
const SHIPWORKS := 36
const CHEST := 52     # pure storage (bigger than a machine)
const CARPENTER := 62 # base-building bench: structural blocks from plain resources
const FORGE := 63     # multiblock-built smelter upgrade: bigger + faster
const CLIMATE_UNIT := 64  # planet base shelter: negates hazard damage nearby
const STATION_IDS := [SMELTER, FABRICATOR, SHIPWORKS, CHEST, CARPENTER, FORGE, CLIMATE_UNIT, SHAPER, GENERATOR, OXYGEN_PLANT, HEATER, COOLER, POWER_BAY, CAMPFIRE]

# --- procedural ore slots ---------------------------------------------------
# Each planet invents its own ores (unique name + color) and assigns each to a
# generic slot id below and a universal TIER. The slot id is what gets stored in
# the voxel/edit data; the real identity (name, color, tier, props) lives in the
# planet's ore definition and travels with mined items as metadata. So Verdis and
# Frost can both have a "tier-2" ore that looks and is named completely differently.
const ORE_0 := 43
const ORE_1 := 44
const ORE_2 := 45
const ORE_3 := 46
const ORE_SLOT_IDS := [ORE_0, ORE_1, ORE_2, ORE_3]
# refined counterparts (inventory-only items the Smelter produces)
const REFINED_0 := 47
const REFINED_1 := 48
const REFINED_2 := 49
const REFINED_3 := 50
const REFINED_SLOT_IDS := [REFINED_0, REFINED_1, REFINED_2, REFINED_3]

# Universal ore tiers (0=most common/soft .. 3=exotic). A planet's ore maps to one.
const TIER_NAMES := ["Common", "Uncommon", "Rare", "Exotic"]
# base material properties per tier (h/d/e/r, 0..100); planet adds per-ore variance
const TIER_PROPS := [
	{"h": 40, "d": 40, "e": 30, "r": 15, "c": 30},
	{"h": 55, "d": 50, "e": 50, "r": 30, "c": 35},
	{"h": 72, "d": 62, "e": 68, "r": 55, "c": 40},
	{"h": 88, "d": 82, "e": 85, "r": 85, "c": 45},
]
const TIER_HARDNESS := [1.0, 1.4, 2.0, 2.8]   # base mining seconds (before hand penalty / tool)
const TIER_MIN_POWER := [1.0, 1.0, 1.6, 2.4]  # mine_power needed to break at all (hands=1.0)

# Syllables for inventing ore names (planet combines a prefix + suffix from its seed).
const ORE_NAME_PRE := ["Vel", "Cryo", "Pyr", "Aur", "Fer", "Lum", "Xen", "Tor",
	"Zin", "Mag", "Cor", "Nyx", "Hal", "Ryn", "Quar", "Bas", "Dra", "Eos"]
const ORE_NAME_SUF := ["ite", "ium", "ex", "ora", "yte", "ine", "ar", "onite", "ax", "yr"]

# Syllables for inventing creature/fish species names (per-planet, like ores).
const FAUNA_NAME_PRE := ["Grum", "Ska", "Bri", "Lox", "Fen", "Wob", "Thal", "Kree",
	"Mun", "Snap", "Grov", "Piv", "Ux", "Yar", "Zeph", "Bok", "Crin", "Dus"]
const FAUNA_NAME_SUF := ["ling", "back", "hide", "fang", "snout", "wing", "tail",
	"claw", "hopper", "crawler", "gill", "fin", "runt", "beast"]

const PROP_KEYS := ["h", "d", "e", "r", "c"]
const PROP_LABELS := {"h": "Hardness", "d": "Density", "e": "Energy",
	"r": "Reactivity", "c": "Combustion"}

## Combustion turns an ore into fuel. It drives how far and how bright a torch
## made from it burns, and is the same figure that will decide how far a unit of
## warp fuel gets you -- so a volatile ore is worth hauling home whatever its
## tier. Unlike the other properties it is NOT tied to tier: a common surface
## ore can burn ferociously while a deep exotic one barely smoulders, which
## gives low-tier worlds something worth mining.
const TORCH_TIERS := 4


static func combustion_of(props: Dictionary) -> int:
	return int(props.get("c", 0))


## 0..3, the brightness step a torch made from this material burns at.
## How long a unit of ore burns, and how much power it yields -- both scaled by
## that ore's Combustion. This is what makes a volatile ore worth hauling home
## rather than being just another rock.
static func fuel_burn_time(props: Dictionary) -> float:
	return 2.0 + float(combustion_of(props)) * 0.10      # ~2 .. 12 seconds


static func fuel_power_rate(props: Dictionary) -> float:
	return 1.0 + float(combustion_of(props)) * 0.05      # ~1 .. 6 power/sec


static func is_fuel(id: int, props: Dictionary) -> bool:
	return is_ore(id) and combustion_of(props) > 0


static func torch_tier_for(props: Dictionary) -> int:
	return clampi(int(floor(float(combustion_of(props)) / 26.0)), 0, TORCH_TIERS - 1)

# --- crafted gear (inventory-only tools produced at stations) ---
const DRILL := 51            # mining tool; its power (from its material) sets mine speed & max tier
# 55 was the O2 Tank (extra suit oxygen). Removed -- personal air is being
# reworked around refillable base/ship tanks instead. The id stays reserved so
# an old save's leftover item still resolves to a name instead of garbage.
const O2_TANK := 55
const SUIT := 56             # worn gear: reduces hazard damage (insulation from Density)
const WEAPON := 59           # melee weapon: its damage (from its material) beats bare hands
const TOOL_IDS := [DRILL, SUIT, WEAPON, PULSE_PISTOL, WRENCH]

const LIFE_SUPPORT := 53     # ship block: with a sealed interior it makes the ship habitable
const GLASS := 54            # transparent, solid hull -- windows that still seal a cabin
const DOOR := 57             # closed door: solid, seals, collides
const DOOR_OPEN := 58        # open door: passable, does NOT seal (air escapes)

# --- intermediate materials (Smelter combines refined + a base resource into
#     these; specific stations build FROM them instead of raw refined material,
#     so not everything is gated behind "refine ore and you're done") ---
const ALLOY := 60      # refined + Metal -> structural stock (Shipworks: Thruster, Life Support)
const CIRCUIT := 61    # refined + Metal -> functional stock (Fabricator: Drill, Suit, Weapon)
const INTERMEDIATE_IDS := [ALLOY, CIRCUIT]

const INTERFACE := 65  # placeable trigger block: surround it with a recognized shell
                        # pattern (see MULTIBLOCK_RECIPES) to build a bigger structure
const ROOF_SLAB := 66   # half-height roof block (real partial-height geometry, like water)
const PATH := 67         # worn dirt/gravel walkway generated between settlement buildings
const WARP_DRIVE := 68   # ship block: with the ship in space, unlocks the star map for warp travel
const PULSE_PISTOL := 69 # ranged weapon: fires a traveling energy bolt, damage from its material

# --- block shaping -----------------------------------------------------------
# SHAPER is a bench that reshapes a plain block into other FORMS of the same
# material. It deliberately has no fixed recipe list: you load a block and it
# offers whatever shapes that material supports, so adding a new shape later
# (stairs, pillars) costs one entry here and works for every material at once,
# instead of one recipe per material per shape.
const SHAPER := 70       # "Block Shaper" bench: reshape a block into slabs etc.

## The only blocks that emit light. Nights are genuinely dark and caves are
## carved deep, so a light source is what makes either of them explorable
## rather than a wall of black.
const TORCH := 91        # small standing flame: cheap, bright, warm
const GLOW_LAMP := 92     # full block of steady light, for finished builds
const EMBER_TORCH := 93   # torch burning a combustible ore -- brightness from its Combustion
const LIGHT_IDS := [TORCH, GLOW_LAMP, EMBER_TORCH]

## Brightness step baked into a placed ember torch. Packed above the id (the
## bits stairs use for facing -- a block is one or the other, never both)
## because a placed voxel is a bare int and cannot carry the item's properties.
const TORCH_TIER_SHIFT := 16
const TORCH_TIER_MASK := 0x3


static func make_torch(id: int, tier: int) -> int:
	return (id & ID_MASK) | ((tier & TORCH_TIER_MASK) << TORCH_TIER_SHIFT)


static func torch_tier_of(v: int) -> int:
	return (v >> TORCH_TIER_SHIFT) & TORCH_TIER_MASK


static func is_light(id: int) -> bool:
	return id in LIGHT_IDS


## Light radius and colour per light block.
## Emission level 0..15 for a light block, Minecraft-style: this is how many
## blocks its light carries before it dies out.
static func light_level(raw: int) -> int:
	var id := bottom_of(raw)
	if id == EMBER_TORCH:
		return 11 + torch_tier_of(raw)     # 11..14, brighter ore burns further
	if id == TORCH:
		return 11
	if id == GLOW_LAMP:
		return 14
	return 0


static func light_def(raw: int) -> Dictionary:
	var id := bottom_of(raw)
	if id == EMBER_TORCH:
		# The whole point of a combustible ore: a fiercely burning one throws
		# light most of the way across a cavern, a dull one barely beats a
		# plain torch.
		var t := float(torch_tier_of(raw))
		return {"range": 13.0 + t * 4.5, "energy": 1.6 + t * 0.45,
			"color": Color(1.0, 0.66, 0.30).lerp(Color(1.0, 0.93, 0.72), t / 3.0)}
	if id == TORCH:
		return {"range": 11.0, "energy": 1.5, "color": Color(1.0, 0.72, 0.38)}
	return {"range": 15.0, "energy": 1.8, "color": Color(0.92, 0.95, 1.0)}

# Half-height version of each shapeable material. One id per material is still
# needed because slabs are real inventory items you carry and place; the SHAPE
# side of the matrix is what stays open-ended.
const ROCK_SLAB := 71
const DIRT_SLAB := 72
const GRASS_SLAB := 73
const REGOLITH_SLAB := 74
const ICE_SLAB := 75
const SNOW_SLAB := 76
const CRYSTAL_SLAB := 77
const METAL_SLAB := 78
const WOOD_SLAB := 79
const GLASS_SLAB := 80

## material -> its slab. Drives both the Shaper's offered shapes and meshing.
const SLAB_OF := {
	ROCK: ROCK_SLAB, DIRT: DIRT_SLAB, GRASS: GRASS_SLAB, REGOLITH: REGOLITH_SLAB,
	ICE: ICE_SLAB, SNOW: SNOW_SLAB, CRYSTAL: CRYSTAL_SLAB, METAL: METAL_SLAB,
	WOOD: WOOD_SLAB, WOOD_PALE: WOOD_SLAB, WOOD_DARK: WOOD_SLAB, GLASS: GLASS_SLAB,
}
## slab -> the material it is made of. Colour, name and surface texturing all
## come from the material, so a slab never needs its own palette entry.
# Stairs, one id per material like slabs. FACING and the corner flag are packed
# into the placed voxel (see make_stair), not baked into the id -- otherwise
# every material would need eight ids instead of one.
const ROCK_STAIR := 81
const DIRT_STAIR := 82
const GRASS_STAIR := 83
const REGOLITH_STAIR := 84
const ICE_STAIR := 85
const SNOW_STAIR := 86
const CRYSTAL_STAIR := 87
const METAL_STAIR := 88
const WOOD_STAIR := 89
const GLASS_STAIR := 90

const STAIR_OF := {
	ROCK: ROCK_STAIR, DIRT: DIRT_STAIR, GRASS: GRASS_STAIR, REGOLITH: REGOLITH_STAIR,
	ICE: ICE_STAIR, SNOW: SNOW_STAIR, CRYSTAL: CRYSTAL_STAIR, METAL: METAL_STAIR,
	WOOD: WOOD_STAIR, WOOD_PALE: WOOD_STAIR, WOOD_DARK: WOOD_STAIR, GLASS: GLASS_STAIR,
}
const STAIR_MATERIAL := {
	ROCK_STAIR: ROCK, DIRT_STAIR: DIRT, GRASS_STAIR: GRASS, REGOLITH_STAIR: REGOLITH,
	ICE_STAIR: ICE, SNOW_STAIR: SNOW, CRYSTAL_STAIR: CRYSTAL, METAL_STAIR: METAL,
	WOOD_STAIR: WOOD, GLASS_STAIR: GLASS,
}

const SLAB_MATERIAL := {
	ROCK_SLAB: ROCK, DIRT_SLAB: DIRT, GRASS_SLAB: GRASS, REGOLITH_SLAB: REGOLITH,
	ICE_SLAB: ICE, SNOW_SLAB: SNOW, CRYSTAL_SLAB: CRYSTAL, METAL_SLAB: METAL,
	WOOD_SLAB: WOOD, GLASS_SLAB: GLASS,
}


static func is_slab(id: int) -> bool:
	return SLAB_MATERIAL.has(id)


static func is_stair(id: int) -> bool:
	return STAIR_MATERIAL.has(id)


# --- placed-stair orientation ------------------------------------------------
# A stair's FACING (which way you climb) and whether it is a corner are packed
# into the stored voxel above the id, so one stair id per material covers all
# eight placements instead of needing an id each.
const FACING_SHIFT := 16
const FACING_MASK := 0x3
const VARIANT_SHIFT := 18
const VARIANT_MASK := 0x3

## Stair shapes, cycled with R before placing. Stored as an index rather than a
## flag so more can be added without changing the packing or the key handling.
## Only two SHAPES exist: a straight run and a corner. A second corner variant
## would be redundant -- rotating the corner through its four facings already
## reaches all four corner quarters.
const STAIR_VARIANTS := ["Straight", "Corner"]
const STAIR_STRAIGHT := 0
const STAIR_CORNER := 1

## Every placeable stair state, cycled in order by R: the straight run turned
## through all four quarters, then the corner through all four. Facing is part
## of the cycle rather than taken from the camera, so what you see previewed is
## exactly what you get.
const STAIR_STATES := 8


static func stair_state_facing(state: int) -> int:
	return state % 4


static func stair_state_variant(state: int) -> int:
	return STAIR_STRAIGHT if state < 4 else STAIR_CORNER


static func stair_state_name(state: int) -> String:
	return "%s  %d°" % [STAIR_VARIANTS[stair_state_variant(state)],
		stair_state_facing(state) * 90]


static func make_stair(stair_id: int, facing: int, variant: int) -> int:
	return (stair_id & ID_MASK) 		| ((facing & FACING_MASK) << FACING_SHIFT) 		| ((variant & VARIANT_MASK) << VARIANT_SHIFT)


static func stair_facing_of(v: int) -> int:
	return (v >> FACING_SHIFT) & FACING_MASK


static func stair_variant_of(v: int) -> int:
	return (v >> VARIANT_SHIFT) & VARIANT_MASK


static func stair_variant_name(variant: int) -> String:
	return STAIR_VARIANTS[variant % STAIR_VARIANTS.size()]


# --- log orientation ---------------------------------------------------------
# A log records which way its trunk runs, so the cut ends land on the right two
# faces. Without it, "which face is the cut end" has to be guessed from the
# planet's up, which is only right for an upright trunk. Packed in the same
# bits stairs use for facing -- a block is one or the other, never both.
# Surface-mounted conduit: which of its cell's six faces the wire clings to,
# stored +1 so 0 means "not placed against anything" (world-gen / hand-given).
# Kept clear of the log-axis and stair bits below.
# A BITMASK of the faces a wire clings to, not a single face: one cell can carry
# a run along its floor and another up its wall, so a cable turns a corner inside
# one block instead of needing two. 0 means "not placed against anything".
const WIRE_FACE_SHIFT := 24
const WIRE_FACE_MASK := 0x3F

static func is_wire(id: int) -> bool:
	return id == WIRE

## Bitmask over Chunk._WFACE indices; 0 when unset.
static func wire_faces_of(v: int) -> int:
	return int((v >> WIRE_FACE_SHIFT) & WIRE_FACE_MASK)

static func wire_with_faces(mask: int) -> int:
	return WIRE | ((mask & WIRE_FACE_MASK) << WIRE_FACE_SHIFT)

## Add one face to whatever this cell already carries.
static func wire_add_face(v: int, face: int) -> int:
	return wire_with_faces(wire_faces_of(v) | (1 << face))


const LOG_AXIS_SHIFT := 16
const LOG_AXIS_MASK := 0x3
const AXIS_X := 0
const AXIS_Y := 1
const AXIS_Z := 2


## Stored as axis+1 so that 0 means "no axis recorded". A plain WOOD id from
## world generation has all-zero high bits, and reading that as axis 0 made
## every naturally grown trunk render as though it were lying along X.
static func make_log(wood_id: int, axis: int) -> int:
	return (wood_id & ID_MASK) | (((axis + 1) & LOG_AXIS_MASK) << LOG_AXIS_SHIFT)


## The trunk axis, or -1 when the log doesn't record one (grown, not placed).
static func log_axis_of(v: int) -> int:
	return (((v >> LOG_AXIS_SHIFT) & LOG_AXIS_MASK)) - 1


# --- stacked slabs -----------------------------------------------------------
# Two DIFFERENT slabs can share one voxel (a rock slab with a wood slab on top).
# Rather than inventing an id for every pair -- 10 materials would need 45 --
# the second slab is packed into the high bits of the stored voxel value.
# Two slabs of the SAME material never take this path: they merge into the plain
# full block instead, which is both simpler and what you'd expect.
const TOP_SHIFT := 8
const ID_MASK := 0xFF


static func make_stacked(bottom: int, top: int) -> int:
	return (bottom & ID_MASK) | ((top & ID_MASK) << TOP_SHIFT)


## The slab sitting in the upper half of a voxel, or AIR if there isn't one.
static func top_slab_of(v: int) -> int:
	return (v >> TOP_SHIFT) & ID_MASK


## The block occupying the lower half (or the whole) of a voxel.
static func bottom_of(v: int) -> int:
	return v & ID_MASK


static func is_stacked_slab(v: int) -> bool:
	return top_slab_of(v) != AIR


## What a voxel becomes when `placing` is put on top of the slab already in it.
## Returns AIR when the two don't combine, so the caller falls back to normal
## placement in the next voxel up.
##   same material      -> the plain full block (two halves make a whole)
##   different material -> both slabs packed into the one voxel
static func stack_result(existing: int, placing: int) -> int:
	if not is_slab(existing) or not is_slab(placing):
		return AIR
	if existing == placing:
		return base_material_of(placing)
	return make_stacked(existing, placing)


## The material a shaped block is made of -- itself, if it isn't shaped.
static func base_material_of(id: int) -> int:
	if STAIR_MATERIAL.has(id):
		return int(STAIR_MATERIAL[id])
	return SLAB_MATERIAL.get(id, id)


## Every shape `mat` can be turned into at a Shaper, as
## {"label", "out", "n", "cost_n"}. One entry per SHAPE, not per material.
static func shapes_for(mat: int) -> Array:
	var out: Array = []
	# Sawing a log is the one shape that MULTIPLIES: one log gives four boards,
	# and they keep the timber they came from.
	if PLANK_OF.has(mat):
		out.append({"shape": "Planks", "out": int(PLANK_OF[mat]), "n": 4, "cost_n": 1})
	if SLAB_OF.has(mat):
		out.append({"shape": "Slab", "out": int(SLAB_OF[mat]), "n": 2, "cost_n": 1})
	if STAIR_OF.has(mat):
		out.append({"shape": "Stairs", "out": int(STAIR_OF[mat]), "n": 1, "cost_n": 1})
	return out

# A 3x3x3 shell of `shell` around a placed INTERFACE block collapses into a
# `result` station -- the multiblock alternative to just crafting a plain item.
## The block you interact with to assemble and operate a built machine. Placing
## one is how you declare "a machine goes here"; it is worthless on its own.
const MACHINE_CORE := 94
## Burns combustible ore for power. Deliberately has no single-block version:
## a generator is the kind of thing whose whole point is that it's big.
const GENERATOR := 95
const OXYGEN_PLANT := 96  # multiblock: floods a SEALED room with breathable air
const HEATER := 97        # multiblock: warms a sealed room on a cold world
const COOLER := 98        # multiblock: the opposite -- sheds heat on a scorching one
const WIRE := 99          # planet-side conduit: carries power between machines
const BATTERY := 100      # carried charge: fill it at a base, empty it into a ship
const POWER_BAY := 101    # ship station: batteries in, ship tanks filled

# --- eighth-block PARTS -------------------------------------------------------
# A voxel holding PARTS is a marker: its real contents are eight sub-cells kept
# in the planet's parts table, addressed as sx + sy*2 + sz*4. Machines are meant
# to be BUILT rather than conjured from a menu, and a full cube is too coarse a
# brush for a workbench leg or a control panel.
const PARTS := 102
const WRENCH := 103       # right-click a build with this to turn it into a station

# Sawn boards, one per timber. A log keeps its species through the saw, so a
# pale forest builds a pale house -- the material is the player's signature and
# turning every wood into one generic plank would throw that away.
const PLANK := 104
const PLANK_PALE := 105
const PLANK_DARK := 106

# --- food and animal products ---------------------------------------------
# Dropped by wildlife, not mined. Meat is the whole point of hunting: raw keeps
# you alive in a pinch, cooked is what actually feeds you (see FOOD_VALUE).
const RAW_MEAT := 107
const COOKED_MEAT := 108
const HIDE := 109
const BONE := 110
## A fire you can cook on, built from a single 2x2 layer of wood eighths --
## the cheapest structure in the game, because going hungry should not be
## gated behind a workshop.
const CAMPFIRE := 111
## Ground cover: thin blades standing on soil. Not something you stand on -- it
## has no collision and you walk straight through it.
const TALL_GRASS := 112
const PLANK_IDS := [PLANK, PLANK_PALE, PLANK_DARK]
const PLANK_OF := {WOOD: PLANK, WOOD_PALE: PLANK_PALE, WOOD_DARK: PLANK_DARK}
const PART_DIM := 2                    # sub-cells per axis
const PART_COUNT := PART_DIM * PART_DIM * PART_DIM

static func part_index(sx: int, sy: int, sz: int) -> int:
	return sx + sy * PART_DIM + sz * PART_DIM * PART_DIM

## Can this item be placed as an eighth rather than a full cube? Building
## materials can, so a leg can be wood and a panel metal; loose gear cannot.
static func is_partable(id: int) -> bool:
	return id == ALLOY or id == CIRCUIT or (id in PLACEABLE and not is_station(id))

## Machines that can ONLY exist as a structure you physically build -- there is
## deliberately no single-block version that does the same job worse. The small
## benches stay craftable items; these are the things whose whole point is that
## they are big.
##
## `layers` reads bottom-to-top; within a layer each string is a row along the
## structure's local +Z, and each character a cell along local +X. The legend
## maps characters to the block that must be there. Exactly one cell is the
## controller, and the pattern is matched in all four rotations about local up,
## so orientation never has to be guessed.
const STRUCTURES := [
	{
		"name": "Generator",
		"result": GENERATOR,
		"size": Vector3i(3, 3, 3),
		"legend": {"#": METAL, "R": ROCK, "C": MACHINE_CORE, ".": AIR},
		# A stone firebox in a metal frame: rock floor and walls around the
		# burn chamber, metal above, and the core on the front face where you
		# feed it.
		"layers": [
			["RRR", "RRR", "RRR"],
			["#C#", "R.R", "RRR"],
			["###", "###", "###"],
		],
	},
	{
		"name": "Oxygen Plant",
		"result": OXYGEN_PLANT,
		"size": Vector3i(3, 3, 3),
		"legend": {"#": METAL, "G": GLASS, "C": MACHINE_CORE, ".": AIR},
		# A glass scrubber column in a metal frame -- the glass is what makes it
		# readable as an AIR machine from across the room.
		"layers": [
			["###", "###", "###"],
			["#C#", "G.G", "#G#"],
			["###", "###", "###"],
		],
	},
	{
		"name": "Heater",
		"result": HEATER,
		"size": Vector3i(3, 3, 3),
		"legend": {"#": METAL, "R": ROCK, "C": MACHINE_CORE, ".": AIR},
		# A stone mass that holds heat, banded with metal.
		"layers": [
			["RRR", "RRR", "RRR"],
			["#C#", "R.R", "R#R"],
			["RRR", "R#R", "RRR"],
		],
	},
	{
		"name": "Cooler",
		"result": COOLER,
		"size": Vector3i(3, 3, 3),
		"legend": {"#": METAL, "G": GLASS, "C": MACHINE_CORE, ".": AIR},
		# Radiator fins in glass: the mirror of the Heater, for worlds that are
		# trying to cook you rather than freeze you.
		"layers": [
			["###", "###", "###"],
			["#C#", "G.G", "###"],
			["#G#", "###", "###"],
		],
	},
	{
		"name": "Forge",
		"result": FORGE,
		"size": Vector3i(3, 3, 3),
		"legend": {"#": METAL, "C": MACHINE_CORE, ".": AIR},
		"layers": [
			["###", "###", "###"],
			["#C#", "#.#", "###"],
			["###", "###", "###"],
		],
	},
]


# --- buildable stations -------------------------------------------------------
#
# Patterns are written in EIGHTH-blocks, so a full cube is simply eight filled
# sub-cells and legs, worktops and panels can all be described in one grid.
# Layers run bottom to top; each row runs along local +Z, each character along
# local +X. Matched in four rotations about local up.
#
# A legend character names a CLASS, not one block, so the same bench can be oak
# or pine and still be a bench. That is deliberate: the shape is the recipe, the
# material is yours.
## How much hunger each food restores. Raw meat is deliberately poor value: it
## keeps you going, but cooking it is worth roughly four times as much, which is
## what makes a campfire worth building the moment you start hunting.
const FOOD_VALUE := {
	RAW_MEAT: 9.0,
	COOKED_MEAT: 38.0,
}

static func is_food(raw: int) -> bool:
	return FOOD_VALUE.has(bottom_of(raw))


static func food_value(raw: int) -> float:
	return float(FOOD_VALUE.get(bottom_of(raw), 0.0))


const PART_CLASSES := {
	"W": WOOD_IDS,                       # any wood
	"S": STONE_IDS,                      # stone only -- not soil, not ice
	"M": [METAL],
	"A": [ALLOY],
	"C": [CIRCUIT],
	"G": [GLASS],
}

const PART_STRUCTURES := [
	{
		"name": "Carpenter's Bench",
		"result": CARPENTER,
		"size": Vector3i(4, 2, 2),       # two blocks wide, one deep, one tall
		"layers": [
			["W..W", "W..W"],            # a leg at each end
			["WWWW", "WWWW"],            # worktop across the top
		],
	},
	{
		# A forge hearth built from EIGHTHS: a stone shell two blocks wide and
		# two tall, one block deep, with a mouth cut into its face. At this
		# resolution it reads as a fireplace rather than a stack of cubes, which
		# is the whole reason parts exist.
		"name": "Smelter",
		"result": SMELTER,
		"size": Vector3i(4, 4, 2),        # 2 x 2 blocks, one deep, in eighths
		"layers": [
			["SSSS", "SSSS"],             # hearth floor
			["S..S", "SSSS"],             # fire chamber, open at the front
			["S..S", "SSSS"],
			["SSSS", "SSSS"],             # lintel across the top
		],
	},
	{
		# The cheapest structure there is: one 2x2 layer of wood eighths, laid
		# flat on the ground. Deliberately trivial -- food should not wait on a
		# workshop -- and it doubles as a light source once lit.
		"name": "Campfire",
		"result": CAMPFIRE,
		"size": Vector3i(2, 1, 2),        # a single block, one eighth-layer tall
		"layers": [
			["WW", "WW"],
		],
	},
	{
		# A metal box with its control panel built from real parts: circuit board
		# below, alloy casing above, in the one block at the front left.
		"name": "Fabricator",
		"result": FABRICATOR,
		"size": Vector3i(4, 4, 4),
		"layers": [
			["MMMM", "MMMM", "MMMM", "MMMM"],     # metal base
			["MMMM", "MMMM", "MMMM", "MMMM"],
			["CCMM", "CCMM", "MMMM", "MMMM"],     # circuit boards
			["AAMM", "AAMM", "MMMM", "MMMM"],     # alloy facing over them
		],
	},
]


# Class membership as SETS. The matcher asks "is this id in this class" tens of
# thousands of times per wrench click, and a linear scan of an Array there is
# most of the cost.
static var _CLASS_SETS: Dictionary = {}
# Per pattern and rotation, the cells flattened once into [offset, class_char].
# Rebuilding these inside the search meant re-reading strings and re-running the
# rotation maths for every candidate placement -- that was the wrench's lag.
static var _PART_CELLS: Dictionary = {}


static func class_set(ch: String) -> Dictionary:
	if _CLASS_SETS.is_empty():
		for k in PART_CLASSES:
			var d := {}
			for id in PART_CLASSES[k]:
				d[id] = true
			_CLASS_SETS[k] = d
	return _CLASS_SETS.get(ch, {})


## Flattened, rotated cells of a pattern: [[Vector3i offset, String ch], ...].
static func part_cells(di: int, rot: int) -> Array:
	var key := di * 4 + rot
	var got = _PART_CELLS.get(key)
	if got != null:
		return got
	var def: Dictionary = PART_STRUCTURES[di]
	var size: Vector3i = def["size"]
	var layers: Array = def["layers"]
	var out: Array = []
	for y in layers.size():
		var rows: Array = layers[y]
		for z in rows.size():
			var row: String = rows[z]
			for x in row.length():
				out.append([_rotate_offset(Vector3i(x, y, z), size, rot), row[x]])
	_PART_CELLS[key] = out
	return out


static var _PART_PROBES: Dictionary = {}

## Three filled cells spread across a pattern, used to reject a candidate
## placement in three checks instead of ninety-six. Without this the search has
## to score every placement equally, runs out of its work budget, and reports
## whichever wrong answer it happened to reach first.
static func part_probes(di: int, rot: int) -> Array:
	var key := di * 4 + rot
	var got = _PART_PROBES.get(key)
	if got != null:
		return got
	var filled: Array = []
	for c in part_cells(di, rot):
		if c[1] != ".":
			filled.append(c)
	var out: Array = []
	if not filled.is_empty():
		out.append(filled[0])
		out.append(filled[filled.size() / 2])
		out.append(filled[filled.size() - 1])
	_PART_PROBES[key] = out
	return out


static var _PART_IDS: Dictionary = {}

## Every block id that appears anywhere in a pattern, as a set. Used to skip
## patterns the block you clicked could not possibly belong to.
static func part_pattern_ids(di: int) -> Dictionary:
	var got = _PART_IDS.get(di)
	if got != null:
		return got
	var d := {}
	for lay in (PART_STRUCTURES[di] as Dictionary)["layers"]:
		for row in lay:
			for ch in str(row):
				if ch == ".":
					continue
				for id in PART_CLASSES.get(ch, []):
					d[id] = true
	_PART_IDS[di] = d
	return d


## Is every sub-cell in this pattern doubled up on all three axes? If so it can
## be built out of whole cubes, and the Recipe Book can say so at block scale
## instead of making you read an eighth-by-eighth grid.
static func part_pattern_is_blocky(def: Dictionary) -> bool:
	var size: Vector3i = def["size"]
	if size.x % 2 != 0 or size.y % 2 != 0 or size.z % 2 != 0:
		return false
	var layers: Array = def["layers"]
	for y in layers.size():
		var rows: Array = layers[y]
		# paired with the layer it shares a block with
		var orows: Array = layers[y ^ 1]
		for z in rows.size():
			var row: String = rows[z]
			if row != String(orows[z]) or row != String(rows[z ^ 1]):
				return false
			for x in row.length():
				if row[x] != row[x ^ 1]:
					return false
	return true


## A build guide for a sub-cell station.
static func part_structure_diagram(def: Dictionary, with_name := true) -> String:
	var size: Vector3i = def["size"]
	var layers: Array = def["layers"]
	var blocky := part_pattern_is_blocky(def)
	var step := 2 if blocky else 1
	var out := "%s  (%d wide x %d tall x %d deep %s)" % [
		def["name"] if with_name else "Pattern",
		size.x / step, size.y / step, size.z / step,
		"blocks" if blocky else "eighths"]
	var names := ["bottom", "middle", "top"]
	var count := layers.size() / step
	var y := 0
	while y < layers.size():
		var li := y / step
		var tag := ""
		if count == 2:
			tag = "  (%s)" % ["bottom", "top"][li]
		elif count == 3:
			tag = "  (%s)" % names[li]
		out += "
  layer %d%s" % [li + 1, tag]
		# Rows STACKED, one per line, so a layer reads as the footprint you
		# actually lay down rather than a run of groups on one line.
		var rows: Array = layers[y]
		var z := 0
		while z < rows.size():
			var row: String = rows[z]
			var cut := ""
			var x := 0
			while x < row.length():
				cut += row[x]
				x += step
			out += "
      " + cut
			z += step
		y += step
	out += "
  rows run front to back, seen from above"
	# Say the quiet part: nothing here becomes a station until you tell it to.
	out += "
  build it, then right-click with a Wrench"
	var key := PackedStringArray()
	var seen := {}
	for lay in layers:
		for row in lay:
			for ch in str(row):
				if seen.has(ch):
					continue
				seen[ch] = true
				if ch == ".":
					key.append(". = empty")
				else:
					key.append("%s = %s" % [ch, class_label(ch)])
	out += "
  " + "   ".join(key)
	if not blocky:
		out += "
  (each character is an eighth-block part)"
	return out


## Name the ACTUAL blocks a pattern character accepts. Saying "any stone" was
## worse than useless: there is no block called Stone, so it read as a block
## name that does not exist and gave no clue that Grass or Snow are not it.
static func class_label(ch: String) -> String:
	var cls: Array = PART_CLASSES.get(ch, [])
	if cls.is_empty():
		return "?"
	var names := PackedStringArray()
	for id in cls:
		names.append(name_of(int(id)))
	return " / ".join(names)


## Every recipe in the game, flattened into one list the Recipe Book can show.
##
## Each entry carries a STABLE key, so unlocking recipes as you progress is a
## matter of remembering keys rather than reshaping this list.
static func all_recipes() -> Array:
	var out: Array = []
	for r in HAND_RECIPES:
		out.append({"key": "hand:%d" % int(r["out"]), "src": "By hand",
			"cat": str(r.get("cat", "")), "out": int(r["out"]),
			"n": int(r.get("n", 1)), "reqs": r.get("reqs", []),
			"cost": 0, "extra": {}, "diagram": ""})
	for st in STATION_CRAFTS:
		for r in STATION_CRAFTS[st]:
			out.append({"key": "%d:%d" % [int(st), int(r["out"])],
				"src": name_of(int(st)), "cat": "Stations", "out": int(r["out"]),
				"n": int(r.get("n", 1)), "reqs": r.get("reqs", []),
				"cost": int(r.get("cost", 0)), "extra": r.get("extra", {}),
				"diagram": ""})
	for d in PART_STRUCTURES:
		out.append({"key": "part:%s" % str(d["name"]), "src": "Built from blocks",
			"cat": "Machines", "out": int(d["result"]), "n": 1, "reqs": [],
			"cost": 0, "extra": {}, "diagram": part_structure_diagram(d, false)})
	for d in STRUCTURES:
		out.append({"key": "struct:%s" % str(d["name"]), "src": "Built from blocks",
			"cat": "Machines", "out": int(d["result"]), "n": 1, "reqs": [],
			"cost": 0, "extra": {}, "diagram": structure_diagram(d, false)})
	return out


## The materials line for a recipe-book entry.
static func recipe_needs(rec: Dictionary) -> String:
	var parts := PackedStringArray()
	for r in rec.get("reqs", []):
		if r.has("refined"):
			parts.append("%d Refined Material" % int(r["n"]))
		elif r.has("any"):
			parts.append("%d %s" % [int(r["n"]), r.get("label", "items")])
		else:
			parts.append("%d %s" % [int(r["n"]), name_of(int(r["id"]))])
	if int(rec.get("cost", 0)) > 0:
		parts.append("%d Refined Material" % int(rec["cost"]))
	var ex: Dictionary = rec.get("extra", {})
	if not ex.is_empty():
		parts.append("%d %s" % [int(ex["n"]), name_of(int(ex["id"]))])
	if parts.is_empty():
		return "no materials — assembled from placed blocks"
	return ",  ".join(parts)


## A readable build guide for a structure. There is no other way in the game to
## learn what a machine looks like, so a failed assembly prints this rather than
## just saying no.
## `with_name` is off in the Recipe Book, where the entry's own header already
## says which machine this is.
static func structure_diagram(def: Dictionary, with_name := true) -> String:
	var layers: Array = def["layers"]
	var legend: Dictionary = def["legend"]
	var tiers := ["bottom", "middle", "top"]
	var out := "%s  (%dx%dx%d)" % [def["name"] if with_name else "Pattern",
		(def["size"] as Vector3i).x,
		(def["size"] as Vector3i).y, (def["size"] as Vector3i).z]
	for y in layers.size():
		var tier: String = tiers[y] if layers.size() == 3 and y < 3 else "layer %d" % (y + 1)
		out += "
  %-7s %s" % [tier, "  ".join(PackedStringArray(layers[y]))]
	var key := PackedStringArray()
	for ch in legend:
		var id: int = legend[ch]
		key.append("%s = %s" % [ch, "empty" if id == AIR else name_of(id)])
	out += "
  " + "   ".join(key)
	return out


## Cells of a structure pattern as {offset: block_id}, plus which offset is the
## controller. Rotation `rot` is a quarter-turn count about local up.
static func structure_cells(def: Dictionary, rot: int) -> Dictionary:
	var legend: Dictionary = def["legend"]
	var size: Vector3i = def["size"]
	var cells := {}
	var controller := Vector3i.ZERO
	var layers: Array = def["layers"]
	for y in layers.size():
		var rows: Array = layers[y]
		for z in rows.size():
			var row: String = rows[z]
			for x in row.length():
				var ch := row[x]
				var id: int = int(legend.get(ch, AIR))
				var off := _rotate_offset(Vector3i(x, y, z), size, rot)
				cells[off] = id
				if ch == "C":
					controller = off
	return {"cells": cells, "controller": controller}


## Quarter-turns about the local up (Y) axis, keeping offsets non-negative.
static func _rotate_offset(o: Vector3i, size: Vector3i, rot: int) -> Vector3i:
	match posmod(rot, 4):
		1: return Vector3i(size.z - 1 - o.z, o.y, o.x)
		2: return Vector3i(size.x - 1 - o.x, o.y, size.z - 1 - o.z)
		3: return Vector3i(o.z, o.y, size.x - 1 - o.x)
		_: return o

# Hand recipes: things you can assemble from carried materials with no station
# (the bootstrap chain). Each: {out, n, reqs}. A requirement is {id, n} for a
# specific item, or {refined:true, n} for any refined material -- so anything that
# needs refined material can't be made until you've built a Smelter and smelted ore.
# Only the bare essentials are hand-assembled (so you can never get stuck): a
# Smelter to refine, Metal Hull to build with, and the Fabricator crafting hub.
# Everything else is made at a station.
# A requirement is {id,n} (specific item), {refined:true,n} (any refined material),
# or {any:[ids],n} (any of a set, e.g. any wood).
## Categories for the hand-crafting list. A flat list stops being usable long
## before the recipe count gets interesting -- these let the panel filter, and a
## new recipe only has to declare which drawer it lives in.
const CRAFT_CATS := ["All", "Stations", "Light", "Building", "Materials"]

# Stations are BUILT, not crafted: the Smelter, Fabricator and Carpenter's Bench
# are laid out block by block and commissioned with a Wrench (see
# PART_STRUCTURES). What is left here is gear that lives on your person.
const HAND_RECIPES := [
	{"cat": "Stations", "out": CHEST, "n": 1, "reqs": [{"any": WOOD_IDS, "n": 8, "label": "Wood"}]},
	{"cat": "Materials", "out": METAL, "n": 4, "reqs": [{"refined": true, "n": 1}]},        # cast ingots into hull plates
	{"cat": "Stations", "out": SHIPWORKS, "n": 1, "reqs": [{"id": METAL, "n": 20}, {"refined": true, "n": 6}]},
	{"cat": "Stations", "out": MACHINE_CORE, "n": 1,
		"reqs": [{"id": METAL, "n": 4}, {"refined": true, "n": 1}]},
	{"cat": "Stations", "out": SHAPER, "n": 1, "reqs": [{"id": ROCK, "n": 10}, {"id": METAL, "n": 2}]},
	# The tool that turns a pile of blocks into a machine. Deliberately makeable
	# with nothing but what you can gather by hand: every station is built now,
	# so a wrench you could not make would lock the whole game.
	{"cat": "Materials", "out": WRENCH, "n": 1,
		"reqs": [{"id": ROCK, "n": 4}, {"any": WOOD_IDS, "n": 2, "label": "Wood"}]},
	# The base's nervous system: cheap, because a grid you cannot afford to run
	# across your base is a grid you build around instead of with.
	{"cat": "Building", "out": WIRE, "n": 8, "reqs": [{"id": METAL, "n": 1}, {"refined": true, "n": 1}]},
	{"cat": "Stations", "out": BATTERY, "n": 1,
		"reqs": [{"id": METAL, "n": 3}, {"refined": true, "n": 2}]},
	{"cat": "Stations", "out": POWER_BAY, "n": 1,
		"reqs": [{"id": METAL, "n": 8}, {"refined": true, "n": 3}]},
	# Deliberately cheap and made from the most common material there is: a
	# light source gates cave exploration and surviving the first night, so
	# putting it behind rare drops would just make the early game dark.
	{"cat": "Light", "out": TORCH, "n": 4, "reqs": [{"any": WOOD_IDS, "n": 1, "label": "Wood"}]},
	{"cat": "Light", "out": GLOW_LAMP, "n": 2, "reqs": [{"id": CRYSTAL, "n": 1}, {"id": METAL, "n": 1}]},
	# Burns the ore itself: how bright and how far comes from that ore's
	# Combustion, so which ore you feed it actually matters.
	{"cat": "Light", "out": EMBER_TORCH, "n": 6, "carry_props": true,
		"reqs": [{"refined": true, "n": 1}, {"any": WOOD_IDS, "n": 1, "label": "Wood"}]},
]

# Which material TYPE a station builds from (see Blocks.id_matches_material).
# The Smelter combines refined ore + a base resource into intermediates; the two
# gear/ship stations then build from an INTERMEDIATE, not raw refined material,
# so refining ore isn't the answer to every recipe.
static func primary_material_for(kind: int) -> String:
	match kind:
		FABRICATOR:
			return "circuit"
		SHIPWORKS:
			return "alloy"
		SMELTER, FORGE:
			return "refined"
		_:
			return "any"

static func id_matches_material(id: int, mtype: String) -> bool:
	match mtype:
		"refined":
			return is_refined(id)
		"circuit":
			return id == CIRCUIT
		"alloy":
			return id == ALLOY
		_:
			return is_refined(id) or id == ALLOY or id == CIRCUIT

static func is_intermediate(id: int) -> bool:
	return id in INTERMEDIATE_IDS

static func is_smelter_kind(kind: int) -> bool:
	return kind == SMELTER or kind == FORGE

# Each craft consumes either `cost` units of the station's primary material (see
# primary_material_for/id_matches_material above), optionally plus an `extra`
# plain-resource requirement, OR (if it has no meaningful "material with stats")
# a plain `reqs` list like a hand recipe -- checked against the STATION's own
# storage, not the player's inventory. Split by station so recipes read as one
# cohesive idea per bench instead of one giant grab-bag:
#   Smelter/Forge  -- combine refined ore + Metal into intermediates
#   Fabricator     -- personal gear, built from Circuitry
#   Shipworks      -- hull & propulsion, built from Alloy Plating
#   Carpenter      -- structural blocks, built from plain Wood/Rock/Metal
const STATION_CRAFTS := {
	CAMPFIRE: [
		{"label": "Cooked Meat", "out": COOKED_MEAT, "n": 1, "reqs": [{"id": RAW_MEAT, "n": 1}]},
	],
	SMELTER: [
		{"label": "Alloy Plating x2", "out": ALLOY, "n": 2, "cost": 2, "extra": {"id": METAL, "n": 3}},
		{"label": "Circuitry x2", "out": CIRCUIT, "n": 2, "cost": 2, "extra": {"id": METAL, "n": 2}},
	],
	FABRICATOR: [
		{"label": "Drill", "out": DRILL, "n": 1, "cost": 3},
		{"label": "Insulated Suit", "out": SUIT, "n": 1, "cost": 3},
		{"label": "Melee Weapon", "out": WEAPON, "n": 1, "cost": 3},
		{"label": "Pulse Pistol", "out": PULSE_PISTOL, "n": 1, "cost": 4},
	],
	SHIPWORKS: [
		{"label": "Thruster", "out": THRUSTER, "n": 1, "cost": 3},
		{"label": "Life Support", "out": LIFE_SUPPORT, "n": 1, "cost": 4},
		{"label": "Warp Drive", "out": WARP_DRIVE, "n": 1, "cost": 10},
		{"label": "Hull Plate x4", "out": METAL, "n": 4, "reqs": [{"id": ALLOY, "n": 2}]},
	],
	CARPENTER: [
		{"label": "Door", "out": DOOR, "n": 1, "reqs": [{"any": WOOD_IDS, "n": 6}, {"id": METAL, "n": 2}]},
		{"label": "Glass x4", "out": GLASS, "n": 4, "reqs": [{"id": ROCK, "n": 4}, {"id": METAL, "n": 1}]},
		{"label": "Climate Unit", "out": CLIMATE_UNIT, "n": 1,
			"reqs": [{"any": WOOD_IDS, "n": 10, "label": "Wood"}, {"id": METAL, "n": 6}]},
	],
}

# Everything the player can place (scroll-wheel cycles this list). Ores are now raw
# materials for crafting, not placeable blocks.
const PLACEABLE := [ROCK, DIRT, GRASS, REGOLITH, ICE, SNOW, CRYSTAL, METAL,
	WOOD, WOOD_PALE, WOOD_DARK,
	16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27,
	COCKPIT, THRUSTER, LIFE_SUPPORT, GLASS, DOOR, INTERFACE, WARP_DRIVE,
	ROCK_SLAB, DIRT_SLAB, GRASS_SLAB, REGOLITH_SLAB, ICE_SLAB, SNOW_SLAB,
	CRYSTAL_SLAB, METAL_SLAB, WOOD_SLAB, GLASS_SLAB,
	ROCK_STAIR, DIRT_STAIR, GRASS_STAIR, REGOLITH_STAIR, ICE_STAIR, SNOW_STAIR,
	CRYSTAL_STAIR, METAL_STAIR, WOOD_STAIR, GLASS_STAIR,
	TORCH, GLOW_LAMP, EMBER_TORCH, MACHINE_CORE, WIRE,
	PLANK, PLANK_PALE, PLANK_DARK]

const NAMES := {
	TALL_GRASS: "Tall Grass",
	RAW_MEAT: "Raw Meat",
	COOKED_MEAT: "Cooked Meat",
	HIDE: "Hide",
	BONE: "Bone",
	CAMPFIRE: "Campfire",
	AIR: "Air",
	ROCK: "Rock",
	DIRT: "Dirt",
	GRASS: "Grass",
	REGOLITH: "Regolith",
	ICE: "Ice",
	IRON_ORE: "Iron Ore",
	CRYSTAL: "Crystal",
	CORE: "Molten Core",
	SNOW: "Snow",
	METAL: "Metal Hull",
	COCKPIT: "Cockpit",
	THRUSTER: "Thruster",
	WOOD: "Wood",
	WOOD_PALE: "Pale Wood",
	WOOD_DARK: "Dark Wood",
	LEAF_0: "Green Leaves",
	LEAF_1: "Lime Leaves",
	LEAF_2: "Deep Green Leaves",
	LEAF_3: "Olive Leaves",
	LEAF_4: "Autumn Leaves",
	LEAF_5: "Rust Leaves",
	LEAF_6: "Golden Leaves",
	LEAF_7: "Teal Leaves",
	LEAF_8: "Violet Leaves",
	LEAF_9: "Azure Leaves",
	LEAF_10: "Pink Leaves",
	LEAF_11: "Mint Leaves",
	COPPER_ORE: "Copper Ore",
	GOLD_ORE: "Gold Ore",
	TITANIUM_ORE: "Titanium Ore",
	SILICON_ORE: "Silicon Ore",
	URANIUM_ORE: "Uranium Ore",
	WATER: "Water",
	SMELTER: "Smelter",
	FABRICATOR: "Fabricator",
	SHIPWORKS: "Shipworks",
	CHEST: "Wooden Chest",
	CARPENTER: "Carpenter's Bench",
	SHAPER: "Block Shaper",
	MACHINE_CORE: "Machine Core",
	GENERATOR: "Generator",
	OXYGEN_PLANT: "Oxygen Plant",
	HEATER: "Heater",
	COOLER: "Cooler",
	WIRE: "Power Conduit",
	BATTERY: "Battery",
	POWER_BAY: "Power Bay",
	PARTS: "Parts",
	WRENCH: "Wrench",
	PLANK: "Planks",
	PLANK_PALE: "Pale Planks",
	PLANK_DARK: "Dark Planks",
	TORCH: "Torch",
	EMBER_TORCH: "Ember Torch",
	GLOW_LAMP: "Glow Lamp",
	FORGE: "Forge",
	CLIMATE_UNIT: "Climate Unit",
	LIFE_SUPPORT: "Life Support",
	GLASS: "Glass",
	DOOR: "Door",
	DOOR_OPEN: "Open Door",
	ALLOY: "Alloy Plating",
	CIRCUIT: "Circuitry",
	INTERFACE: "Interface Core",
	ROOF_SLAB: "Roof Slab",
	PATH: "Path",
	WARP_DRIVE: "Warp Drive",
	ORE_0: "Ore", ORE_1: "Ore", ORE_2: "Ore", ORE_3: "Ore",
	REFINED_0: "Refined Material", REFINED_1: "Refined Material",
	REFINED_2: "Refined Material", REFINED_3: "Refined Material",
	DRILL: "Drill",
	O2_TANK: "O2 Tank",
	SUIT: "Insulated Suit",
	WEAPON: "Melee Weapon",
	PULSE_PISTOL: "Pulse Pistol",
}

# What each ore is (eventually) used for -- shown when you aim at it.
const USES := {
	IRON_ORE: "Hulls & tools",
	COPPER_ORE: "Wiring & thrusters",
	GOLD_ORE: "Electronics & trade",
	TITANIUM_ORE: "Advanced hull",
	SILICON_ORE: "Glass & circuits",
	URANIUM_ORE: "Reactor fuel",
}

# Seconds of continuous mining to break each block. Default 0.5 if unlisted.
const HARDNESS := {
	GRASS: 0.35, DIRT: 0.35, REGOLITH: 0.3, SNOW: 0.25,
	LEAF_0: 0.2, LEAF_1: 0.2, LEAF_2: 0.2, LEAF_3: 0.2, LEAF_4: 0.2, LEAF_5: 0.2,
	LEAF_6: 0.2, LEAF_7: 0.2, LEAF_8: 0.2, LEAF_9: 0.2, LEAF_10: 0.2, LEAF_11: 0.2,
	WOOD: 0.6, WOOD_PALE: 0.6, WOOD_DARK: 0.6,
	PLANK: 0.5, PLANK_PALE: 0.5, PLANK_DARK: 0.5,
	WIRE: 0.3,
	# Faster than leaves: grass is the one thing you brush aside constantly, and
	# anything you touch that often should not cost you a mining animation.
	TALL_GRASS: 0.05,
	TORCH: 0.1, GLOW_LAMP: 0.3, EMBER_TORCH: 0.1, MACHINE_CORE: 1.2,
	ICE: 0.7, ROCK: 0.9, CRYSTAL: 1.2, CORE: 1.6,
	IRON_ORE: 1.3, COPPER_ORE: 1.3, GOLD_ORE: 1.6,
	TITANIUM_ORE: 1.9, SILICON_ORE: 1.2, URANIUM_ORE: 2.1,
	METAL: 0.25, COCKPIT: 0.25, THRUSTER: 0.25,  # ship parts break fast
	INTERFACE: 0.3,
}

const COLORS := {
	TALL_GRASS: Color(0.42, 0.66, 0.28),
	RAW_MEAT: Color(0.72, 0.26, 0.28),
	COOKED_MEAT: Color(0.55, 0.34, 0.18),
	HIDE: Color(0.60, 0.45, 0.30),
	BONE: Color(0.88, 0.86, 0.76),
	CAMPFIRE: Color(0.86, 0.45, 0.16),
	ROCK: Color(0.44, 0.44, 0.50),
	DIRT: Color(0.40, 0.29, 0.20),
	GRASS: Color(0.34, 0.58, 0.30),
	REGOLITH: Color(0.78, 0.72, 0.55),
	ICE: Color(0.66, 0.84, 0.95),
	IRON_ORE: Color(0.58, 0.47, 0.40),
	CRYSTAL: Color(0.30, 0.86, 0.90),
	CORE: Color(0.92, 0.42, 0.16),
	SNOW: Color(0.94, 0.96, 1.00),
	METAL: Color(0.60, 0.62, 0.66),
	COCKPIT: Color(0.35, 0.55, 0.90),
	THRUSTER: Color(0.85, 0.45, 0.20),
	WOOD: Color(0.42, 0.28, 0.16),
	WOOD_PALE: Color(0.60, 0.48, 0.34),
	WOOD_DARK: Color(0.26, 0.18, 0.12),
	LEAF_0: Color(0.22, 0.55, 0.22),
	LEAF_1: Color(0.55, 0.72, 0.22),
	LEAF_2: Color(0.14, 0.38, 0.18),
	LEAF_3: Color(0.45, 0.50, 0.20),
	LEAF_4: Color(0.82, 0.45, 0.12),
	LEAF_5: Color(0.68, 0.20, 0.16),
	LEAF_6: Color(0.85, 0.78, 0.25),
	LEAF_7: Color(0.15, 0.58, 0.52),
	LEAF_8: Color(0.50, 0.32, 0.68),
	LEAF_9: Color(0.32, 0.46, 0.78),
	LEAF_10: Color(0.85, 0.50, 0.72),
	LEAF_11: Color(0.60, 0.88, 0.68),
	COPPER_ORE: Color(0.72, 0.45, 0.30),
	GOLD_ORE: Color(0.85, 0.72, 0.25),
	TITANIUM_ORE: Color(0.72, 0.74, 0.80),
	SILICON_ORE: Color(0.52, 0.58, 0.64),
	URANIUM_ORE: Color(0.40, 0.78, 0.35),
	WATER: Color(0.20, 0.45, 0.85, 0.55),
	SMELTER: Color(0.34, 0.30, 0.32),
	FABRICATOR: Color(0.30, 0.40, 0.46),
	SHIPWORKS: Color(0.40, 0.42, 0.30),
	CHEST: Color(0.45, 0.31, 0.17),
	CARPENTER: Color(0.48, 0.34, 0.20),
	SHAPER: Color(0.52, 0.52, 0.56),
	MACHINE_CORE: Color(0.86, 0.52, 0.18),
	GENERATOR: Color(0.62, 0.45, 0.28),
	OXYGEN_PLANT: Color(0.42, 0.68, 0.78),
	HEATER: Color(0.74, 0.40, 0.26),
	COOLER: Color(0.36, 0.62, 0.86),
	WIRE: Color(0.72, 0.56, 0.20),
	BATTERY: Color(0.45, 0.80, 0.55),
	POWER_BAY: Color(0.50, 0.70, 0.60),
	PARTS: Color(0.70, 0.70, 0.72),
	WRENCH: Color(0.72, 0.66, 0.30),
	PLANK: Color(0.60, 0.42, 0.24),
	PLANK_PALE: Color(0.78, 0.65, 0.46),
	PLANK_DARK: Color(0.38, 0.26, 0.17),
	TORCH: Color(1.0, 0.74, 0.40),
	EMBER_TORCH: Color(1.0, 0.62, 0.26),
	GLOW_LAMP: Color(0.95, 0.97, 1.0),
	FORGE: Color(0.55, 0.22, 0.16),
	CLIMATE_UNIT: Color(0.35, 0.62, 0.55),
	LIFE_SUPPORT: Color(0.30, 0.78, 0.68),
	GLASS: Color(0.62, 0.78, 0.88, 0.30),
	DOOR: Color(0.55, 0.5, 0.4),
	DOOR_OPEN: Color(0.55, 0.5, 0.4),
	ALLOY: Color(0.68, 0.70, 0.76),
	CIRCUIT: Color(0.35, 0.75, 0.45),
	INTERFACE: Color(0.75, 0.35, 0.85),
	ROOF_SLAB: Color(0.40, 0.28, 0.20),
	PATH: Color(0.58, 0.50, 0.38),
	WARP_DRIVE: Color(0.55, 0.30, 0.90),
	# generic fallbacks; real ore colors are planet-defined and travel with the item
	ORE_0: Color(0.7, 0.6, 0.4), ORE_1: Color(0.6, 0.7, 0.5),
	ORE_2: Color(0.5, 0.6, 0.7), ORE_3: Color(0.7, 0.5, 0.7),
	REFINED_0: Color(0.8, 0.72, 0.55), REFINED_1: Color(0.72, 0.8, 0.62),
	REFINED_2: Color(0.62, 0.72, 0.82), REFINED_3: Color(0.82, 0.62, 0.82),
	DRILL: Color(0.75, 0.76, 0.80),
	O2_TANK: Color(0.45, 0.7, 0.9),
	SUIT: Color(0.8, 0.7, 0.4),
	WEAPON: Color(0.75, 0.78, 0.82),
	PULSE_PISTOL: Color(0.3, 0.75, 0.85),
}

static func is_solid(id: int) -> bool:
	return id != AIR

static func hardness(raw: int) -> float:
	# A slab is the same material as its parent, and a stacked pair is mined as
	# one -- both take the base block's hardness.
	var id := base_material_of(bottom_of(raw))
	return HARDNESS.get(id, 0.5)

static func use_of(id: int) -> String:
	return USES.get(id, "")

## Leaves render with alpha cutouts and are deliberately NON-COLLIDABLE, so a
## canopy feels like foliage you brush through rather than a solid box.
## Plants you walk through: no collision, and they never hide the block behind.
static func is_plant(id: int) -> bool:
	return bottom_of(id) == TALL_GRASS


static func is_leaf(id: int) -> bool:
	return id in LEAF_IDS


static func is_wood(id: int) -> bool:
	return id in WOOD_IDS


static func is_ore(id: int) -> bool:
	return id in ORE_SLOT_IDS

static func is_refined(id: int) -> bool:
	return id in REFINED_SLOT_IDS

static func is_material(id: int) -> bool:
	return id in ORE_SLOT_IDS or id in REFINED_SLOT_IDS or id in INTERMEDIATE_IDS

static func is_station(id: int) -> bool:
	return id in STATION_IDS

## How many vertical inventory cells an item occupies. A suit is a bulky thing
## to haul around, and taking two cells makes carrying a spare a real decision
## rather than a free one.
static func item_cells_tall(id: int) -> int:
	return 2 if id == SUIT else 1


static func is_gear(id: int) -> bool:
	return id in TOOL_IDS

static func is_door(id: int) -> bool:
	return id == DOOR or id == DOOR_OPEN

static func door_toggle_of(id: int) -> int:
	return DOOR_OPEN if id == DOOR else DOOR

# A drill's mining power from the material it's built from: harder + more energetic
# materials drill faster and reach higher ore tiers. Bare hands are 1.0.
static func drill_power(props: Dictionary) -> float:
	return 1.5 + float(props.get("h", 0)) / 100.0 + float(props.get("e", 0)) / 100.0 * 0.8

# Insulated Suit hazard-damage reduction (0..0.9) from its material's Density.
static func suit_resist(props: Dictionary) -> float:
	return 0.30 + float(props.get("d", 0)) / 100.0 * 0.60

# Melee weapon damage per hit from its material's Hardness + Energy. Bare hands
# hit for UNARMED_DAMAGE (see player.gd); any crafted weapon beats that.
static func weapon_damage(props: Dictionary) -> float:
	return 8.0 + float(props.get("h", 0)) / 100.0 * 16.0 + float(props.get("e", 0)) / 100.0 * 8.0

# Ranged weapon damage per shot -- an energy weapon, so it leans on Energy more
# than Hardness (the opposite weighting from the melee blade).
static func ranged_weapon_damage(props: Dictionary) -> float:
	return 6.0 + float(props.get("e", 0)) / 100.0 * 18.0 + float(props.get("h", 0)) / 100.0 * 4.0

# Per-shape combat stats, keyed by the weapon's block id. This is the one place
# new weapon shapes get added -- a new melee shape just needs hit_style/range/
# cooldown entries, a new ranged shape just needs hit_style "hitscan" or
# "projectile" (see player.gd's ranged-fire dispatch and Projectile). The
# per-shot/per-hit damage magnitude itself comes from a separate derived-stat
# function per id (weapon_damage/ranged_weapon_damage, computed once at craft
# time in station.gd -- see the "cmat" pattern there), matching "the shape
# decides the role, the material decides the stats" used everywhere else in
# this game's crafting.
const WEAPON_SHAPES := {
	WEAPON: {
		"category": "melee", "hit_style": "single", "range": 3.0,
		"light_cooldown": 0.35, "heavy_charge": 0.5, "heavy_mult": 2.2, "heavy_stagger": 1.0,
		"light_stagger": 0.35,
	},
	PULSE_PISTOL: {
		"category": "ranged", "hit_style": "projectile", "range": 30.0,
		"cooldown": 0.35, "projectile_speed": 40.0, "stagger": 0.4,
	},
}

# Highest ore tier a given mining power can break (via TIER_MIN_POWER).
static func max_tier_for_power(power: float) -> int:
	var t := 0
	for i in TIER_MIN_POWER.size():
		if power >= TIER_MIN_POWER[i]:
			t = i
	return t

static func is_placeable_block(id: int) -> bool:
	return id in PLACEABLE

# raw ore slot id -> its refined counterpart (same slot index)
static func refined_of(ore_id: int) -> int:
	var i := ORE_SLOT_IDS.find(ore_id)
	return REFINED_SLOT_IDS[i] if i >= 0 else AIR

## What a colour would be CALLED. Leaf blocks carry colour words in their names
## ("Mint Leaves"), but a planet retints them freely, so the fixed name and the
## thing on screen stop agreeing. Naming from the actual colour keeps the two
## honest wherever the world's palette is known.
static func hue_name(c: Color) -> String:
	if c.s < 0.12:
		return "Ashen" if c.v < 0.55 else "Bone"
	var bands := [
		[0.028, "Crimson"], [0.055, "Rust"], [0.09, "Amber"], [0.14, "Golden"],
		[0.19, "Olive"], [0.26, "Lime"], [0.36, "Green"], [0.43, "Mint"],
		[0.50, "Teal"], [0.55, "Cyan"], [0.62, "Azure"], [0.70, "Indigo"],
		[0.78, "Violet"], [0.86, "Magenta"], [0.94, "Rose"], [1.01, "Crimson"],
	]
	for b in bands:
		if c.h < float(b[0]):
			return str(b[1])
	return "Crimson"


static func color_of(raw: int) -> Color:
	# Stacked slabs are looked up by their LOWER half; the mesher draws each
	# half in its own colour, this is just for UI and single-colour uses.
	# Mask off any packed orientation/stacking bits: everything below keys off
	# the plain block id.
	var id := bottom_of(raw)
	# A slab is the same stuff as its parent block, so it never carries its own
	# palette entry -- one less thing to keep in sync per material.
	if SLAB_MATERIAL.has(id):
		return COLORS.get(SLAB_MATERIAL[id], Color.MAGENTA)
	if STAIR_MATERIAL.has(id):
		return COLORS.get(STAIR_MATERIAL[id], Color.MAGENTA)
	return COLORS.get(id, Color.MAGENTA)

static func name_of(raw: int) -> String:
	if is_stacked_slab(raw):
		return "%s + %s" % [name_of(bottom_of(raw)), name_of(top_slab_of(raw))]
	var id := bottom_of(raw)
	if SLAB_MATERIAL.has(id):
		return "%s Slab" % NAMES.get(SLAB_MATERIAL[id], "Unknown")
	if STAIR_MATERIAL.has(id):
		var v := stair_variant_of(raw)
		var t := " Stairs" if v == STAIR_STRAIGHT else " %s Stairs" % stair_variant_name(v)
		return NAMES.get(STAIR_MATERIAL[id], "Unknown") + t
	return NAMES.get(id, "Unknown")
