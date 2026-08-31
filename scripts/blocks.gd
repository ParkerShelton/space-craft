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

# --- ores (IRON_ORE=6 already exists) ---
const COPPER_ORE := 28
const GOLD_ORE := 29
const TITANIUM_ORE := 30
const SILICON_ORE := 31
const URANIUM_ORE := 32
const WATER := 33  # liquid: transparent, non-collidable (rendered as a second surface)

const ORE_IDS := [IRON_ORE, COPPER_ORE, GOLD_ORE, TITANIUM_ORE, SILICON_ORE, URANIUM_ORE]

# --- crafting stations (placed in the world, not voxel blocks) ---
const SMELTER := 34
const FABRICATOR := 35
const SHIPWORKS := 36
const STATION_IDS := [SMELTER, FABRICATOR, SHIPWORKS]

# --- refined materials (inventory-only items produced by the Smelter) ---
const REFINED_IRON := 37
const REFINED_COPPER := 38
const REFINED_GOLD := 39
const REFINED_TITANIUM := 40
const REFINED_SILICON := 41
const REFINED_URANIUM := 42
const REFINED_IDS := [REFINED_IRON, REFINED_COPPER, REFINED_GOLD,
	REFINED_TITANIUM, REFINED_SILICON, REFINED_URANIUM]

# raw ore id -> refined material id
const REFINED_OF := {
	IRON_ORE: REFINED_IRON, COPPER_ORE: REFINED_COPPER, GOLD_ORE: REFINED_GOLD,
	TITANIUM_ORE: REFINED_TITANIUM, SILICON_ORE: REFINED_SILICON, URANIUM_ORE: REFINED_URANIUM,
}

# Base material property profile per ore type (0..100). A planet applies a small
# +/- variance on top (Planet.ore_props), so "Copper is always Copper" but each
# world's copper differs a little. Keys: h=Hardness d=Density e=Energy r=Reactivity.
const PROP_KEYS := ["h", "d", "e", "r"]
const PROP_LABELS := {"h": "Hardness", "d": "Density", "e": "Energy", "r": "Reactivity"}
const ORE_PROPS := {
	IRON_ORE:     {"h": 60, "d": 55, "e": 25, "r": 10},  # balanced hull/tool
	COPPER_ORE:   {"h": 35, "d": 45, "e": 70, "r": 20},  # conductive: thrusters/wiring
	GOLD_ORE:     {"h": 20, "d": 80, "e": 85, "r": 15},  # soft, dense, very conductive
	TITANIUM_ORE: {"h": 90, "d": 40, "e": 30, "r": 10},  # hard & light: best armor
	SILICON_ORE:  {"h": 45, "d": 30, "e": 55, "r": 25},  # circuits/glass
	URANIUM_ORE:  {"h": 50, "d": 90, "e": 40, "r": 95},  # reactor fuel
}

# Hand-craftable recipes that need NO station (bootstrap only). cost = {id: count}.
const HAND_CRAFT := {
	SMELTER: {ROCK: 15},
}

# Everything the player can place (scroll-wheel cycles this list).
const PLACEABLE := [ROCK, DIRT, GRASS, REGOLITH, ICE, SNOW, CRYSTAL, METAL,
	WOOD, WOOD_PALE, WOOD_DARK,
	16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27,
	IRON_ORE, COPPER_ORE, GOLD_ORE, TITANIUM_ORE, SILICON_ORE, URANIUM_ORE,
	COCKPIT, THRUSTER]

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
	REFINED_IRON: "Refined Iron",
	REFINED_COPPER: "Refined Copper",
	REFINED_GOLD: "Refined Gold",
	REFINED_TITANIUM: "Refined Titanium",
	REFINED_SILICON: "Refined Silicon",
	REFINED_URANIUM: "Refined Uranium",
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
	REFINED_IRON: Color(0.75, 0.76, 0.78),
	REFINED_COPPER: Color(0.88, 0.55, 0.34),
	REFINED_GOLD: Color(1.00, 0.84, 0.35),
	REFINED_TITANIUM: Color(0.82, 0.85, 0.90),
	REFINED_SILICON: Color(0.70, 0.78, 0.85),
	REFINED_URANIUM: Color(0.55, 0.95, 0.45),
}

static func is_solid(id: int) -> bool:
	return id != AIR

static func hardness(id: int) -> float:
	return HARDNESS.get(id, 0.5)

static func use_of(id: int) -> String:
	return USES.get(id, "")

static func is_ore(id: int) -> bool:
	return id in ORE_IDS

static func is_station(id: int) -> bool:
	return id in STATION_IDS

static func is_refined(id: int) -> bool:
	return id in REFINED_IDS

static func is_placeable_block(id: int) -> bool:
	return id in PLACEABLE

static func refined_of(ore_id: int) -> int:
	return REFINED_OF.get(ore_id, AIR)

static func base_props(ore_id: int) -> Dictionary:
	return ORE_PROPS.get(ore_id, {})

static func color_of(id: int) -> Color:
	return COLORS.get(id, Color.MAGENTA)

static func name_of(id: int) -> String:
	return NAMES.get(id, "Unknown")
