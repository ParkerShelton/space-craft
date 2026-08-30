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

const ORE_IDS := [IRON_ORE, COPPER_ORE, GOLD_ORE, TITANIUM_ORE, SILICON_ORE, URANIUM_ORE]

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
}

static func is_solid(id: int) -> bool:
	return id != AIR

static func hardness(id: int) -> float:
	return HARDNESS.get(id, 0.5)

static func use_of(id: int) -> String:
	return USES.get(id, "")

static func is_ore(id: int) -> bool:
	return id in ORE_IDS

static func color_of(id: int) -> Color:
	return COLORS.get(id, Color.MAGENTA)

static func name_of(id: int) -> String:
	return NAMES.get(id, "Unknown")
