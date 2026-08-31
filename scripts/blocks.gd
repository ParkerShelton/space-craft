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
const STATION_IDS := [SMELTER, FABRICATOR, SHIPWORKS, CHEST]

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
	{"h": 40, "d": 40, "e": 30, "r": 15},
	{"h": 55, "d": 50, "e": 50, "r": 30},
	{"h": 72, "d": 62, "e": 68, "r": 55},
	{"h": 88, "d": 82, "e": 85, "r": 85},
]
const TIER_HARDNESS := [1.0, 1.4, 2.0, 2.8]   # base mining seconds (before hand penalty / tool)
const TIER_MIN_POWER := [1.0, 1.0, 1.6, 2.4]  # mine_power needed to break at all (hands=1.0)

# Syllables for inventing ore names (planet combines a prefix + suffix from its seed).
const ORE_NAME_PRE := ["Vel", "Cryo", "Pyr", "Aur", "Fer", "Lum", "Xen", "Tor",
	"Zin", "Mag", "Cor", "Nyx", "Hal", "Ryn", "Quar", "Bas", "Dra", "Eos"]
const ORE_NAME_SUF := ["ite", "ium", "ex", "ora", "yte", "ine", "ar", "onite", "ax", "yr"]

const PROP_KEYS := ["h", "d", "e", "r"]
const PROP_LABELS := {"h": "Hardness", "d": "Density", "e": "Energy", "r": "Reactivity"}

# --- crafted gear (inventory-only tools produced at stations) ---
const DRILL := 51            # mining tool; its power (from its material) sets mine speed & max tier
const O2_TANK := 55          # worn gear: raises max oxygen (capacity from Reactivity)
const SUIT := 56             # worn gear: reduces hazard damage (insulation from Density)
const TOOL_IDS := [DRILL, O2_TANK, SUIT]

const LIFE_SUPPORT := 53     # ship block: with a sealed interior it makes the ship habitable
const GLASS := 54            # transparent, solid hull -- windows that still seal a cabin

# Hand recipes: things you can assemble from carried materials with no station
# (the bootstrap chain). Each: {out, n, reqs}. A requirement is {id, n} for a
# specific item, or {refined:true, n} for any refined material -- so anything that
# needs refined material can't be made until you've built a Smelter and smelted ore.
# Only the bare essentials are hand-assembled (so you can never get stuck): a
# Smelter to refine, Metal Hull to build with, and the Fabricator crafting hub.
# Everything else is made at a station.
# A requirement is {id,n} (specific item), {refined:true,n} (any refined material),
# or {any:[ids],n} (any of a set, e.g. any wood).
const HAND_RECIPES := [
	{"out": SMELTER, "n": 1, "reqs": [{"id": ROCK, "n": 15}]},
	{"out": CHEST, "n": 1, "reqs": [{"any": WOOD_IDS, "n": 8, "label": "Wood"}]},
	{"out": METAL, "n": 4, "reqs": [{"refined": true, "n": 1}]},        # cast ingots into hull plates
	{"out": FABRICATOR, "n": 1, "reqs": [{"id": METAL, "n": 20}, {"refined": true, "n": 6}]},
]
const DRILL_COST := 5        # refined material consumed to fabricate one drill

# What each station can build from a loaded refined material. Each craft consumes
# `cost` refined material and outputs `n` of `out`, carrying the material's stats.
# The Fabricator is the crafting hub: gear + ship parts.
const STATION_CRAFTS := {
	FABRICATOR: [
		{"label": "Drill", "out": DRILL, "n": 1, "cost": DRILL_COST},
		{"label": "Thruster", "out": THRUSTER, "n": 1, "cost": 4},
		{"label": "Hull Plate x4", "out": METAL, "n": 4, "cost": 2},
		{"label": "Glass x4", "out": GLASS, "n": 4, "cost": 2},
		{"label": "Life Support", "out": LIFE_SUPPORT, "n": 1, "cost": 6},
		{"label": "O2 Tank", "out": O2_TANK, "n": 1, "cost": 5},
		{"label": "Insulated Suit", "out": SUIT, "n": 1, "cost": 5},
	],
}

# Everything the player can place (scroll-wheel cycles this list). Ores are now raw
# materials for crafting, not placeable blocks.
const PLACEABLE := [ROCK, DIRT, GRASS, REGOLITH, ICE, SNOW, CRYSTAL, METAL,
	WOOD, WOOD_PALE, WOOD_DARK,
	16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27,
	COCKPIT, THRUSTER, LIFE_SUPPORT, GLASS]

const NAMES := {
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
	LIFE_SUPPORT: "Life Support",
	GLASS: "Glass",
	ORE_0: "Ore", ORE_1: "Ore", ORE_2: "Ore", ORE_3: "Ore",
	REFINED_0: "Refined Material", REFINED_1: "Refined Material",
	REFINED_2: "Refined Material", REFINED_3: "Refined Material",
	DRILL: "Drill",
	O2_TANK: "O2 Tank",
	SUIT: "Insulated Suit",
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
	ICE: 0.7, ROCK: 0.9, CRYSTAL: 1.2, CORE: 1.6,
	IRON_ORE: 1.3, COPPER_ORE: 1.3, GOLD_ORE: 1.6,
	TITANIUM_ORE: 1.9, SILICON_ORE: 1.2, URANIUM_ORE: 2.1,
	METAL: 0.25, COCKPIT: 0.25, THRUSTER: 0.25,  # ship parts break fast
}

const COLORS := {
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
	LIFE_SUPPORT: Color(0.30, 0.78, 0.68),
	GLASS: Color(0.62, 0.78, 0.88, 0.30),
	# generic fallbacks; real ore colors are planet-defined and travel with the item
	ORE_0: Color(0.7, 0.6, 0.4), ORE_1: Color(0.6, 0.7, 0.5),
	ORE_2: Color(0.5, 0.6, 0.7), ORE_3: Color(0.7, 0.5, 0.7),
	REFINED_0: Color(0.8, 0.72, 0.55), REFINED_1: Color(0.72, 0.8, 0.62),
	REFINED_2: Color(0.62, 0.72, 0.82), REFINED_3: Color(0.82, 0.62, 0.82),
	DRILL: Color(0.75, 0.76, 0.80),
	O2_TANK: Color(0.45, 0.7, 0.9),
	SUIT: Color(0.8, 0.7, 0.4),
}

static func is_solid(id: int) -> bool:
	return id != AIR

static func hardness(id: int) -> float:
	return HARDNESS.get(id, 0.5)

static func use_of(id: int) -> String:
	return USES.get(id, "")

static func is_ore(id: int) -> bool:
	return id in ORE_SLOT_IDS

static func is_refined(id: int) -> bool:
	return id in REFINED_SLOT_IDS

static func is_material(id: int) -> bool:
	return id in ORE_SLOT_IDS or id in REFINED_SLOT_IDS

static func is_station(id: int) -> bool:
	return id in STATION_IDS

static func is_gear(id: int) -> bool:
	return id in TOOL_IDS

# A drill's mining power from the material it's built from: harder + more energetic
# materials drill faster and reach higher ore tiers. Bare hands are 1.0.
static func drill_power(props: Dictionary) -> float:
	return 1.5 + float(props.get("h", 0)) / 100.0 + float(props.get("e", 0)) / 100.0 * 0.8

# O2 Tank extra oxygen capacity from its material's Reactivity (gas storage).
static func o2_capacity(props: Dictionary) -> float:
	return 50.0 + float(props.get("r", 0)) / 100.0 * 150.0

# Insulated Suit hazard-damage reduction (0..0.9) from its material's Density.
static func suit_resist(props: Dictionary) -> float:
	return 0.30 + float(props.get("d", 0)) / 100.0 * 0.60

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

static func color_of(id: int) -> Color:
	return COLORS.get(id, Color.MAGENTA)

static func name_of(id: int) -> String:
	return NAMES.get(id, "Unknown")
